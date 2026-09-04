import SwiftData
import SwiftUI
import TipKit

/// Lets callers outside the Downloads tab steer its segment bar on an
/// already-mounted `DownloadsView`. `initialSection` can only ever be read once,
/// at init, and re-initialising the view with `.id()` would wipe the tab's
/// navigation stack - so the request travels as shared observable state that
/// `DownloadsView` consumes via `.onChange` and then clears.
@Observable
@MainActor
final class DownloadsNavigator {
    /// Set by a caller, cleared by `DownloadsView` once it has been applied.
    var requestedSection: DownloadSection?
    /// A push to perform on arrival - used by More's search results, which link to
    /// tools that now live in this tab.
    var requestedRoute: DownloadsManagementRoute?

    init() {}

    func show(_ section: DownloadSection) {
        requestedSection = section
    }

    func show(_ route: DownloadsManagementRoute) {
        requestedRoute = route
    }
}

/// Which download the split view's detail column is showing.
///
/// The Downloads tab is three lists in one - qBittorrent torrents, SABnzbd jobs and
/// the Arr queues - but every row that opens anything opens one of two screens. So
/// this names the screen rather than the row: an Arr queue row backed by a torrent
/// and that torrent's own row are the same destination, and selecting either should
/// leave the detail column showing the same thing rather than two views of it.
///
/// Rows that open nothing - history, and an Arr queue row whose download Trawl cannot
/// reach - have no case here, which is what makes them unselectable in this mode.
enum DownloadDetailSelection: Hashable, Sendable {
    case torrent(hash: String)
    case sabJob(id: String, name: String)
}

/// Everything in the Downloads tab that sits one push below the list: the toolbar
/// overflow destinations, plus the qBittorrent tools that More's search links into.
enum DownloadsManagementRoute: Hashable {
    case clients
    case blocklist
    case torrents
    case transferStats
    case categoriesAndTags
    case rssFeeds

    /// True for routes that need a configured qBittorrent server to render anything.
    var requiresQBittorrent: Bool {
        switch self {
        case .clients, .blocklist: false
        case .torrents, .transferStats, .categoriesAndTags, .rssFeeds: true
        }
    }
}

struct DownloadsView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter
    /// Optional so previews and any host that doesn't inject a navigator still work.
    @Environment(DownloadsNavigator.self) private var downloadsNavigator: DownloadsNavigator?
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    @State private var viewModel = DownloadsViewModel()
    @Environment(\.setTabChromeHidden) private var setTabChromeHidden
    @State private var selectedSection: DownloadSection
    @State private var sortOrder: DownloadSortCriterion = .date
    @State private var isSearchExpanded = false
    @State private var showAddTorrent = false
    @State private var torrentPendingDeletion: Torrent?
    @State private var sabJobPendingDeletion: SABnzbdJob?
    @State private var queueActionTarget: ArrQueueActionTarget?
    /// Arr queue rows whose action is still running, keyed by `ArrQueueActionTarget.id`.
    @State private var queueActionInFlightIDs: Set<String> = []
    /// Drives the toolbar overflow menu's pushes. A menu can't hold a
    /// `NavigationLink`, so the selection travels through state instead.
    @State private var managementRoute: DownloadsManagementRoute?
    /// Which of the tab's three lists is showing. Switched from the title menu
    /// rather than by pushing: these are peers, not details of one another, and
    /// reaching a client's own queue by way of Client Management never made sense.
    @State private var titleDestination: DownloadsTitleDestination = .downloads
    private let queueSwitchTip = DownloadsQueueSwitchTip()
    /// Drives the title menu's shrink. A `.principal` toolbar item is fixed, so
    /// this stands in for the large-title collapse the system would do for us.
    @State private var isTitleCompact = false
    /// What the visible list can do. One toolbar serves all three destinations, so
    /// the buttons stay put and only their contents flex.
    @State private var chrome = DownloadsListChrome()
    /// Multi-select over the blended list. Rows here are of four different kinds -
    /// a torrent, a SABnzbd job, an *arr queue row, or a history entry - so a batch
    /// action has to dispatch per row rather than call one API.
    ///
    /// Selection is the List's own, not hand-drawn. The earlier version painted its
    /// own `checkmark.circle` into a `Button` per row, which meant re-deriving every
    /// piece of chrome the system already provides - and getting one of them wrong
    /// (a row background that stayed opaque over the gradient) was invisible until
    /// someone looked at it in dark mode.
    @State private var editMode: SelectionMode = .inactive
    @State private var selectedRowIDs: Set<String> = []
    @State private var showBatchDeleteConfirm = false

    /// Set by the split view's content column, so a tap selects instead of pushing.
    /// Nil in the tab chrome, where the row keeps its `NavigationLink`.
    var detailSelection: Binding<DownloadDetailSelection?>?

    init(initialSection: DownloadSection = .active, detailSelection: Binding<DownloadDetailSelection?>? = nil) {
        self.detailSelection = detailSelection
        _selectedSection = State(initialValue: initialSection)
    }

    #if os(iOS)
    /// `EditMode` is unavailable on macOS and this file compiles into TrawlMac, so
    /// the app-wide `SelectionMode` shim holds the state and only iOS bridges it
    /// into the environment. macOS gets `List`'s native click selection instead.
    private var swiftUIEditMode: Binding<EditMode> {
        Binding(
            get: { editMode.isEditing ? .active : .inactive },
            set: { newMode in
                withAnimation { editMode = newMode.isEditing ? .active : .inactive }
            }
        )
    }
    #endif

    /// Applies a pending segment request and clears it, so the same request can
    /// be made again later.
    private func applyRequestedSection(_ requested: DownloadSection?) {
        guard let requested else { return }
        withAnimation { selectedSection = requested }
        downloadsNavigator?.requestedSection = nil
    }

    /// Applies a pending push and clears it, so the same route can be requested again.
    private func applyRequestedRoute(_ requested: DownloadsManagementRoute?) {
        guard let requested else { return }
        if requested == .torrents {
            // Torrents is one of this tab's own lists now, not a screen to push. More's
            // search still offers it, and selecting the list is what that should mean -
            // pushing a second copy would give the same view two homes, and the pushed
            // one would need navigation chrome that the embedded one must not have.
            withAnimation { titleDestination = .torrents }
        } else {
            managementRoute = requested
        }
        downloadsNavigator?.requestedRoute = nil
    }

    var body: some View {
        // One screen. The title menu changes which downloads are listed - it does
        // not swap in another view. Every earlier attempt embedded SABnzbdManagerView
        // and TorrentListView here, and each brought its own list, chrome, lifecycle
        // and navigation title, so the tab inherited a second of everything: two
        // titles, two subtitles, and a polling task that stopped itself when the list
        // it was attached to went away. Those were symptoms of the same mistake.
        downloadsContent
            // Directly under the title, not anchored to it. A `.popoverTip` on the
            // `.principal` toolbar item never presented: that placement replaces the
            // navigation title and its popovers do not appear, whether the tip is
            // attached to the menu or to a hairline sibling beside it - both were
            // tried. An inset immediately below the bar is the nearest thing that
            // does show, it is the same inline treatment the two library tips use,
            // and the tip's own words say which control to tap.
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsTitleMenu {
                    TipView(queueSwitchTip)
                        .tipBackground(.bar)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .trawlTitleMenuShrinksOnScroll($isTitleCompact)
            .toolbar { titleMenuToolbarItem }
            .toolbar { sharedToolbarContent }
    }

    /// The title menu replaces the navigation title rather than joining it, so
    /// everything below has to stop drawing one of its own while it is showing.
    ///
    /// It stands down while selecting. Switching lists mid-selection is not on
    /// offer - a scope change clears the selection - so leaving the menu up would
    /// advertise a move that throws the user's work away, and the title is better
    /// spent saying how much is selected.
    private var showsTitleMenu: Bool {
        availableTitleDestinations.count > 1 && !editMode.isEditing
    }

    /// Kept in step with `showsTitleMenu` - the tip's transient rule is that exact
    /// condition, so the popover cannot be anchored to a control that is not drawn.
    private func updateQueueSwitchTipEligibility() {
        DownloadsQueueSwitchTip.isEligible = showsTitleMenu
    }

    /// The title menu's own selection, told apart from the app changing lists by
    /// itself.
    ///
    /// Invalidating the tip on `titleDestination` alone was too broad: More's search
    /// can route to Torrents, which sets the same state without the user ever finding
    /// the menu - and the invalidation is permanent, so the one hint that would have
    /// shown them the menu was spent on a route they took another way. Only a change
    /// that arrives *through* the menu counts as having done the thing.
    private var userChosenTitleDestination: Binding<DownloadsTitleDestination> {
        Binding(
            get: { titleDestination },
            set: { newValue in
                guard newValue != titleDestination else { return }
                titleDestination = newValue
                queueSwitchTip.invalidate(reason: .actionPerformed)
            }
        )
    }

    /// The title doubles as the switch between this tab's three lists.
    ///
    /// Deliberately a `Menu` inside a `ToolbarItem` styled to read as the title,
    /// not `ToolbarTitleMenu`: that modifier does nothing for a large title, which
    /// is the size this reads at. The trade-off is that a menu hidden in a title is
    /// easy to overlook, so it only appears when there is actually somewhere else
    /// to go, and it carries a chevron to say it opens.
    @ToolbarContentBuilder
    private var titleMenuToolbarItem: some ToolbarContent {
        // `showsTitleMenu`, not the raw count: a `.principal` item *replaces* the
        // navigation title, so leaving this in place while selecting would draw
        // the menu over the selection count rather than beside it.
        if showsTitleMenu {
            ToolbarItem(placement: .principal) {
                TrawlTitleMenu(
                    options: availableTitleDestinations.map {
                        TrawlTitleMenuOption(value: $0, title: $0.title, systemImage: $0.systemImage)
                    },
                    selection: userChosenTitleDestination,
                    isCompact: isTitleCompact
                )
            }
        }
    }

    /// The tab's one toolbar.
    ///
    /// Add Download, sort, Select, Client Management and the Blocklist belong to the
    /// tab and never move. What changes with the scope is only which batch actions
    /// the selection offers - a SABnzbd queue cannot be rechecked.
    @ToolbarContentBuilder
    private var sharedToolbarContent: some ToolbarContent {
        if chrome.isSelecting {
            ToolbarItem(placement: platformTopBarLeadingPlacement) {
                Button(chrome.selectAllTitle) { chrome.toggleSelectAll?() }
                    .disabled(chrome.totalCount == 0)
            }

            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button("Done") { chrome.endSelecting?() }
            }

            ToolbarItemGroup(placement: platformBottomBarPlacement) {
                if chrome.supportsPauseResume {
                    Button {
                        chrome.pauseSelected?()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .disabled(!chrome.hasSelection)

                    Button {
                        chrome.resumeSelected?()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .disabled(!chrome.hasSelection)
                }

                if chrome.supportsRecheck {
                    Button {
                        chrome.recheckSelected?()
                    } label: {
                        Label("Recheck", systemImage: "arrow.clockwise")
                    }
                    .disabled(!chrome.hasSelection)
                }

                Button(role: .destructive) {
                    chrome.deleteSelected?()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(!chrome.hasSelection)
            }
        } else {
            if hasQBittorrentServer || hasSABnzbdServer {
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    Button("Add Download", systemImage: "plus") {
                        showAddTorrent = true
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
            }

            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                DownloadSortMenu(selection: $sortOrder, defaultSelection: .date)

                Menu {
                    // Selection acts on what is on screen, where the two routes at
                    // the bottom leave it.
                    if chrome.canSelect {
                        Button {
                            chrome.beginSelecting?()
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .disabled(chrome.totalCount == 0)
                    }

                    ForEach(chrome.extraActions) { action in
                        if let isOn = action.isOn {
                            Toggle(isOn: Binding(get: { isOn }, set: { _ in action.perform() })) {
                                Label(action.title, systemImage: action.systemImage)
                            }
                            .disabled(!action.isEnabled)
                        } else {
                            Button {
                                action.perform()
                            } label: {
                                Label(action.title, systemImage: action.systemImage)
                            }
                            .disabled(!action.isEnabled)
                        }
                    }

                    Divider()

                    // Same reasoning as Calendar: Download Clients, qBittorrent and
                    // SABnzbd are sidebar rows on iPad and Mac, so the shortcut into
                    // them only earns its place in the tab chrome.
                    if !isDrivingDetailColumn {
                        Button("Client Management", systemImage: "server.rack") {
                            managementRoute = .clients
                        }
                    }

                    Button("Blocklist", systemImage: "hand.raised.slash.fill") {
                        managementRoute = .blocklist
                    }
                } label: {
                    Label("Downloads Options", systemImage: "ellipsis")
                }
            }
        }
    }

    /// Only the lists this setup actually has a client for.
    private var availableTitleDestinations: [DownloadsTitleDestination] {
        var destinations: [DownloadsTitleDestination] = [.downloads]
        if hasSABnzbdServer { destinations.append(.sabQueue) }
        if hasQBittorrentServer { destinations.append(.torrents) }
        return destinations
    }

    private var downloadsContent: some View {
        content
            // Applied before .safeAreaInset so the RefreshAction stays scoped to the list.
            // Attached after the inset it also propagates into the segment bar, which then
            // becomes pull-to-refreshable itself.
            .refreshable {
                async let arrRefresh: Void = viewModel.refresh(serviceManager: arrServiceManager)
                async let torrentRefresh: Void = syncService.refreshNow()
                async let sabRefresh: Void = sabnzbdServiceManager.refresh()
                _ = await (arrRefresh, torrentRefresh, sabRefresh)
            }
            .onChange(of: downloadsNavigator?.requestedSection) { _, requested in
                applyRequestedSection(requested)
            }
            .onChange(of: downloadsNavigator?.requestedRoute) { _, requested in
                applyRequestedRoute(requested)
            }
            .onAppear {
                // Catches a request made while this view wasn't mounted yet.
                applyRequestedSection(downloadsNavigator?.requestedSection)
                applyRequestedRoute(downloadsNavigator?.requestedRoute)
            }
            .background(backgroundGradient)
            .navigationTitle(navigationTitleText)
            .navigationSubtitle(navigationSubtitle)
            #if os(iOS)
            // Inline while selecting: a large "3 Selected" would tower over the
            // Select All / Done pair it sits between, and it is a transient count
            // rather than the name of the screen.
            .toolbarTitleDisplayMode(showsTitleMenu || editMode.isEditing ? .inline : .inlineLarge)
            // Selecting takes the screen over: its batch actions live in the bottom
            // bar, which the tab bar and the notification pill would otherwise sit
            // on top of. This is what the torrent list did before it was folded in.
            .toolbarVisibility(editMode.isEditing ? .hidden : .visible, for: .tabBar)
            #endif
            .onChange(of: editMode.isEditing) { _, isEditing in
                setTabChromeHidden(isEditing)
            }
            // A queue that never fills is the symptom; "Sonarr has no download
            // client" is the cause, and this is the screen the user is looking at
            // when they notice.
            //
            // Before the segment bar's inset, so it ends up *below* it. A later
            // `safeAreaInset` is the outer one and sits nearer the top edge, so
            // applying this last - which is where it started - drove a wedge between
            // the title and the filter controls that belong to it.
            .configurationAttention(.downloads)
            .safeAreaInset(edge: .top) {
                TrawlSegmentBar(
                    "Downloads",
                    selection: Binding(
                        get: { selectedSection },
                        set: { newSection in
                            withAnimation { selectedSection = newSection }
                        }
                    ),
                    items: visibleSections.map(\.segmentBarItem),
                    searchText: $viewModel.searchText,
                    searchHint: "Search downloads",
                    isSearchExpanded: $isSearchExpanded,
                    searchPlacement: .leading,
                    alignment: .leading
                )
            }
            .onChange(of: visibleSections) { _, sections in
                // The selected segment keeps itself visible while it's selected, so
                // this only fires when the segment goes away for a reason the user
                // can't see around - the torrent client being removed.
                if !sections.contains(selectedSection) {
                    withAnimation { selectedSection = .active }
                }
            }
            .navigationDestination(item: $managementRoute) { route in
                managementDestination(route)
            }
            .sheet(isPresented: $showAddTorrent) {
                AddTorrentSheet()
                    .environment(syncService)
                    .environment(torrentService)
                    .environment(sabnzbdServiceManager)
            }
            .task(id: reloadKey) {
                await viewModel.refresh(serviceManager: arrServiceManager)
            }
            // One view, one lifecycle. Polling starts when the tab appears and stops
            // when it goes, and changing scope touches neither - the earlier design
            // attached this to whichever list was showing, so switching lists tore
            // down the poll that the next list depended on.
            .task {
                await sabnzbdServiceManager.refresh()
                sabnzbdServiceManager.startPolling()
                viewModel.startPolling(serviceManager: arrServiceManager)
            }
            .onDisappear {
                sabnzbdServiceManager.stopPolling()
                viewModel.stopPolling(serviceManager: arrServiceManager)
                setTabChromeHidden(false)
            }
            .animation(.snappy, value: titleDestination)
            .animation(.snappy, value: editMode.isEditing)
            // Changing scope changes which rows exist, so a selection made against
            // the previous scope cannot survive it.
            .onChange(of: titleDestination) { _, _ in
                editMode = .inactive
                selectedRowIDs.removeAll()
                publishChrome()
            }
            .onAppear { updateQueueSwitchTipEligibility() }
            .onChange(of: showsTitleMenu) { _, _ in updateQueueSwitchTipEligibility() }
            .onAppear { publishChrome() }
            .onChange(of: publishedChromeSignature) { _, _ in publishChrome() }
            .alert("Delete Torrent?", isPresented: torrentDeletionPresented) {
                Button("Delete and Remove Files", role: .destructive) {
                    deletePendingTorrent(deleteFiles: true)
                }
                Button("Delete Torrent Only", role: .destructive) {
                    deletePendingTorrent(deleteFiles: false)
                }
                Button("Cancel", role: .cancel) { torrentPendingDeletion = nil }
            } message: {
                Text("This action can’t be undone.")
            }
            .alert("Remove Download?", isPresented: sabDeletionPresented) {
                Button("Remove and Delete Files", role: .destructive) {
                    deletePendingSABJob(deleteFiles: true)
                }
                Button("Remove Job Only", role: .destructive) {
                    deletePendingSABJob(deleteFiles: false)
                }
                Button("Cancel", role: .cancel) { sabJobPendingDeletion = nil }
            } message: {
                Text("This action can’t be undone.")
            }
            .confirmationDialog(
                queueActionTarget?.item.title ?? "Queue Item",
                isPresented: queueActionDialogPresented,
                titleVisibility: .visible,
                presenting: queueActionTarget
            ) { target in
                arrQueueClientActions(
                    linkedTorrent: target.linkedTorrent,
                    linkedSABJob: target.linkedSABJob,
                    includesSeparators: false
                )
                arrQueueRemovalActions(item: target.item, source: target.source, instance: target.instance)
                Button("Cancel", role: .cancel) { queueActionTarget = nil }
            }
    }

    @ViewBuilder
    private func managementDestination(_ route: DownloadsManagementRoute) -> some View {
        if route.requiresQBittorrent && !hasQBittorrentServer {
            // Reachable from More's search even with no torrent client configured, so
            // it points at Client Management - the place in *this* tab where you'd add
            // one - rather than at Settings.
            ServiceSetupView(title: "qBittorrent Not Set Up", message: "Add a qBittorrent server to use its transfer stats, categories, and RSS tools.", systemImage: ServiceIdentity.qbittorrent.systemImage, actionTitle: "Client Management", onSetup: { managementRoute = .clients })
            .scrollableUnavailableState()
        } else {
            switch route {
            case .clients:
                DownloadClientManagementView()
                    .environment(syncService)
                    .environment(torrentService)
                    .environment(sabnzbdServiceManager)
            case .blocklist:
                // Blocklisting happens from the queue actions in this very view,
                // so the resulting list lives here too rather than in More.
                ArrBlocklistView()
                    .environment(arrServiceManager)
            case .torrents:
                // Unreachable: `applyRequestedRoute` diverts this to the tab's own
                // Torrents list rather than pushing one. Kept so the switch stays
                // exhaustive if the route is ever requested from somewhere new.
                EmptyView()
            case .transferStats:
                TorrentStatsView()
                    .environment(syncService)
            case .categoriesAndTags:
                QBittorrentCategoriesAndTagsView()
                    .environment(syncService)
                    .environment(torrentService)
            case .rssFeeds:
                QBittorrentRSSView()
                    .environment(torrentService)
            }
        }
    }

    /// The rows for the chosen section, narrowed to the chosen client. Switching the
    /// title menu changes this and nothing else - no view is replaced.
    private var items: [DownloadListItem] {
        viewModel.items(
            for: selectedSection,
            scope: titleDestination.scope,
            serviceManager: arrServiceManager,
            torrents: syncService.torrents,
            sabActiveJobs: sabnzbdServiceManager.activeJobs,
            sabHistoryJobs: sabnzbdServiceManager.historyJobs,
            sabRevision: sabnzbdServiceManager.queueRevision,
            torrentsRevision: syncService.torrentsRevision
        )
        .sortedByDownloadOrder(sortOrder)
    }

    @ViewBuilder
    private var content: some View {
        // Gated on the first load rather than on `isLoadingQueue`, which flips true on
        // every poll - an empty queue would otherwise flicker spinner/empty each cycle.
        if arrServiceManager.isLoadingQueue && !arrServiceManager.hasLoadedQueueOnce && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let scopedFailure, items.isEmpty {
            // A scope names one client, so when that client is unreachable this list
            // has to say so. Showing an empty list instead would report "no
            // downloads" for a server that is simply refusing to answer - and an
            // expired API key would look exactly like an idle queue.
            ServiceErrorView(
                title: scopedFailure.title,
                message: scopedFailure.message,
                identity: scopedFailure.identity,
                onRetry: { scopedFailure.retry() }
            )
        } else if let errorMessage = arrServiceManager.queueError,
                  items.isEmpty,
                  syncService.torrents.isEmpty,
                  !hasQBittorrentServer,
                  !hasSABnzbdServer {
            ServiceErrorView(
                title: "Downloads Unavailable",
                message: errorMessage,
                onRetry: { await viewModel.refresh(serviceManager: arrServiceManager) }
            )
        } else {
            // Keep the List mounted even when filtering yields zero results so the
            // segment-bar search field doesn't lose keyboard focus the moment the
            // results drop to empty. Swapping the List out for the empty state
            // tears down the scroll container and resigns first responder.
            VStack(spacing: 0) {
                sabnzbdConnectionWarning

                ZStack {
                    list
                        .opacity(items.isEmpty ? 0 : 1)
                        .allowsHitTesting(!items.isEmpty)

                    if items.isEmpty {
                        emptyState
                    }
                }
            }
        }
    }

    /// A failing SABnzbd must not blank this screen - it is a unified view and
    /// qBittorrent may still be perfectly healthy - but it must not fail silently
    /// either. Before this, a rejected API key simply made SABnzbd's jobs vanish
    /// from the list with no explanation anywhere on the Downloads tab; the only
    /// place that surfaced `connectionError` was the SABnzbd manager screen, four
    /// navigations away.
    @ViewBuilder
    private var sabnzbdConnectionWarning: some View {
        if hasSABnzbdServer, let message = sabnzbdServiceManager.connectionError {
            ServiceErrorView(
                title: "SABnzbd Unavailable",
                message: message,
                identity: .sabnzbd,
                hasContent: true,
                onRetry: { await sabnzbdServiceManager.refresh() }
            )
        }
    }

    /// The failure to show when the list is scoped to one client and that client
    /// cannot answer. Nil on the blended list, which still has other clients' rows
    /// to show and its own empty state to fall back on.
    private struct ScopedFailure {
        let identity: ServiceIdentity
        let title: String
        let message: String
        let retry: () -> Void
    }

    private var scopedFailure: ScopedFailure? {
        switch titleDestination {
        case .downloads:
            return nil
        case .sabQueue:
            guard let message = sabnzbdServiceManager.connectionError else { return nil }
            return ScopedFailure(identity: .sabnzbd, title: "SABnzbd Unavailable", message: message) {
                Task { await sabnzbdServiceManager.refresh() }
            }
        case .torrents:
            guard let error = syncService.lastError else { return nil }
            return ScopedFailure(identity: .qbittorrent, title: "qBittorrent Unavailable", message: error.localizedDescription) {
                Task { await syncService.refreshNow() }
            }
        }
    }

    /// True while the list is driving a detail column rather than pushing.
    ///
    /// Editing wins when both are available: a split view still needs multi-select
    /// while the user is picking rows to delete, and the two selections cannot share
    /// one `List` - one is a set of row ids, the other an optional destination.
    private var isDrivingDetailColumn: Bool {
        detailSelection != nil && !editMode.isEditing
    }

    private var list: some View {
        // Rows drop their `NavigationLink` while editing (see `rowLink`), so
        // selecting never fights with pushing and there is no second tap handler to
        // keep in step.
        selectableList {
            ForEach(items) { item in
                listRow(for: item)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        #if os(iOS)
        .environment(\.editMode, swiftUIEditMode)
        #endif
        .animation(.default, value: items.map(\.id))
        .animation(.snappy, value: editMode.isEditing)
        .onChange(of: items.map(\.id)) { _, _ in reconcileDetailSelection() }
    }

    /// Drops the detail column's selection once the download it names has left the
    /// list.
    ///
    /// Deliberately not the libraries' rule, which also *opens* the first row on
    /// arrival. A library is a stable list where landing on something beats landing
    /// on an empty pane; this list churns - downloads finish and disappear on their
    /// own - and auto-selecting would take the detail column away from whatever the
    /// user was reading every time it did. Clearing a selection that no longer exists
    /// is the half that is unambiguously right: the alternative is a detail view of a
    /// download that has gone.
    private func reconcileDetailSelection() {
        guard let detailSelection, let current = detailSelection.wrappedValue else { return }
        guard !items.contains(where: { detailDestination(for: $0) == current }) else { return }
        detailSelection.wrappedValue = nil
    }

    @ViewBuilder
    private func selectableList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let detailSelection, !editMode.isEditing {
            List(selection: detailSelection) { content() }
        } else {
            List(selection: $selectedRowIDs) { content() }
        }
    }

    /// One row, tagged for whichever selection the list is currently running.
    ///
    /// The tag is applied only while the detail column is being driven: a `.tag` of
    /// the wrong type is silently ignored by `List`, and leaving a destination tag on
    /// a row whose list selects by id is exactly the kind of mismatch that shows up
    /// later as "selection stopped working" rather than as a compile error.
    @ViewBuilder
    private func listRow(for item: DownloadListItem) -> some View {
        if isDrivingDetailColumn, let destination = detailDestination(for: item) {
            row(for: item)
                // The tag is the destination itself, not an optional wrapping one:
                // `List` matches a tag against its selection by type, and an
                // `Optional<DownloadDetailSelection>` tag never matches a
                // `DownloadDetailSelection` selection - the rows simply stop
                // selecting, with nothing to say why.
                .tag(destination)
                .listRowBackground(detailRowBackground(for: item))
        } else if isDrivingDetailColumn {
            row(for: item)
                .selectionDisabled(true)
                .listRowBackground(Color.clear)
        } else {
            row(for: item)
                // A row that names no client cannot be acted on - a history
                // entry, or an *arr queue row whose download Trawl can't reach.
                // Making those unselectable is stricter than the hand-rolled
                // version, which let them be ticked and then dropped them from
                // the batch without saying so.
                .selectionDisabled(item.batchTarget == nil)
                // The list draws over the services gradient with its own background
                // hidden, so a row that keeps the default `systemBackground` punches
                // an opaque block through it - black in dark mode.
                .listRowBackground(Color.clear)
        }
    }

    /// What this row opens in the detail column, if anything.
    ///
    /// An Arr queue row resolves to whichever client is actually carrying the grab,
    /// which is the same screen that client's own row opens. That is deliberate: the
    /// two rows are two views of one download, and selecting either should leave the
    /// detail column showing the same thing.
    private func detailDestination(for item: DownloadListItem) -> DownloadDetailSelection? {
        switch item {
        case .torrent(let torrent):
            return .torrent(hash: torrent.hash)
        case .sab(let job):
            return .sabJob(id: job.id, name: job.name)
        case .arrQueue(_, _, let linkedTorrent, let linkedSABJob, _):
            if let linkedTorrent { return .torrent(hash: linkedTorrent.hash) }
            if let linkedSABJob { return .sabJob(id: linkedSABJob.id, name: linkedSABJob.name) }
            return nil
        case .arrHistory:
            return nil
        }
    }

    /// Rows are transparent so the services gradient shows through, and that
    /// transparency also swallows the system's selection tint - the row driving the
    /// detail column looked exactly like every other row. So it is drawn here.
    @ViewBuilder
    private func detailRowBackground(for item: DownloadListItem) -> some View {
        if let destination = detailDestination(for: item),
           destination == detailSelection?.wrappedValue {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.16))
                .padding(.vertical, 2)
        } else {
            Color.clear
        }
    }

    // MARK: - Batch actions across mixed rows

    /// Resolution lives on `DownloadListItem` so it can be tested without a view:
    /// which rows a batch can act on is the load-bearing part of the mixed
    /// selection, and getting it wrong means silently skipping downloads or acting
    /// on the wrong client.
    private var selectedTargets: [DownloadBatchTarget] {
        selectedItems.compactMap(\.batchTarget)
    }

    private var selectedTorrentHashes: [String] {
        selectedTargets.compactMap {
            if case .torrent(let torrent) = $0 { return torrent.hash }
            return nil
        }
    }

    private var selectedSABJobs: [SABnzbdJob] {
        selectedTargets.compactMap {
            if case .sab(let job) = $0 { return job }
            return nil
        }
    }

    /// Runs a batch across both clients and reports once. A selection that mixes a
    /// torrent, a SABnzbd job and an *arr row pointing at either is one action to
    /// the user, so it reads as one result - including when part of it could not be
    /// acted on at all.
    private func performBatch(
        verb: String,
        torrents: @escaping ([String]) async throws -> Void,
        sab: ((SABnzbdJob) async throws -> Void)?
    ) {
        let hashes = selectedTorrentHashes
        let jobs = sab == nil ? [] : selectedSABJobs
        let skipped = selectedItems.count - (hashes.count + jobs.count)
        guard !hashes.isEmpty || !jobs.isEmpty else { return }

        Task { @MainActor in
            var failures: [String] = []
            if !hashes.isEmpty {
                do { try await torrents(hashes) } catch { failures.append(error.localizedDescription) }
            }
            if let sab {
                for job in jobs {
                    do { try await sab(job) } catch { failures.append(error.localizedDescription) }
                }
            }
            await syncService.refreshNow()
            await sabnzbdServiceManager.refresh()

            if let first = failures.first {
                notificationCenter.showError(title: "\(verb) Failed", message: first)
            } else {
                let acted = hashes.count + jobs.count
                notificationCenter.showSuccess(
                    title: verb,
                    message: skipped > 0
                        ? "\(acted) of \(selectedItems.count) - \(skipped) could not be \(verb.lowercased())."
                        : (acted == 1 ? "1 download." : "\(acted) downloads.")
                )
            }
            editMode = .inactive
            selectedRowIDs.removeAll()
        }
    }

    /// The rows a batch could actually act on. `Select All` and the toolbar's
    /// enablement are counted over these rather than over every row, so a list of
    /// nothing but history doesn't offer a selection that can't do anything.
    private var selectableItems: [DownloadListItem] {
        items.filter { $0.batchTarget != nil }
    }

    /// Everything the shared toolbar reads.
    private var publishedChromeSignature: String {
        [
            String(editMode.isEditing),
            String(selectedRowIDs.count),
            String(items.count),
            String(selectableItems.count),
            String(selectedTorrentHashes.count)
        ].joined(separator: "|")
    }

    private func publishChrome() {
        chrome.canSelect = true
        chrome.isSelecting = editMode.isEditing
        chrome.selectedCount = selectedRowIDs.count
        chrome.totalCount = selectableItems.count
        // Recheck is a qBittorrent concept, so it appears only when the selection
        // actually contains torrents rather than sitting permanently greyed.
        chrome.supportsRecheck = !selectedTorrentHashes.isEmpty
        chrome.supportsPauseResume = true
        chrome.beginSelecting = { withAnimation { editMode = .active } }
        chrome.endSelecting = {
            withAnimation {
                editMode = .inactive
                selectedRowIDs.removeAll()
            }
        }
        chrome.toggleSelectAll = {
            let all = Set(selectableItems.map(\.id))
            withAnimation { selectedRowIDs = selectedRowIDs == all ? [] : all }
        }
        chrome.pauseSelected = {
            performBatch(
                verb: "Paused",
                torrents: { try await torrentService.pauseTorrents(hashes: $0) },
                sab: { try await sabnzbdServiceManager.pause(job: $0) }
            )
        }
        chrome.resumeSelected = {
            performBatch(
                verb: "Resumed",
                torrents: { try await torrentService.resumeTorrents(hashes: $0) },
                sab: { try await sabnzbdServiceManager.resume(job: $0) }
            )
        }
        chrome.recheckSelected = {
            performBatch(
                verb: "Rechecked",
                torrents: { try await torrentService.recheckTorrents(hashes: $0) },
                sab: nil
            )
        }
        chrome.deleteSelected = { showBatchDeleteConfirm = true }
        chrome.extraActions = []
    }

    private var selectedItems: [DownloadListItem] {
        items.filter { selectedRowIDs.contains($0.id) }
    }

    /// A row that pushes when tapped normally, and is plain content while editing or
    /// while a detail column is being driven.
    ///
    /// `List` disables `NavigationLink`s in edit mode so its own tap can select the
    /// row - but a disabled link dims everything inside its label, so every row went
    /// grey the moment Select was pressed while still being perfectly selectable.
    /// Removing the link rather than letting it be disabled keeps the row at full
    /// strength; selection is the List's either way.
    ///
    /// The same applies beside a detail column, for a different reason. A
    /// `NavigationLink(destination:)` in a split view's *content* column presents
    /// into the *detail* column, and that presentation outlives the sidebar selection
    /// that made it: opening a download and then switching to Series swapped the
    /// detail column's root underneath while the download detail stayed sitting on
    /// top of it. Driving the column from state instead is what the libraries already
    /// do - see `ArrMediaListView.itemRow`.
    @ViewBuilder
    private func rowLink<Destination: View, Label: View>(
        @ViewBuilder destination: () -> Destination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if editMode.isEditing || isDrivingDetailColumn {
            label()
        } else {
            NavigationLink(destination: destination(), label: label)
        }
    }

    @ViewBuilder
    private func row(for item: DownloadListItem) -> some View {
        switch item {
        case .torrent(let torrent):
            rowLink {
                TorrentDetailView(torrentHash: torrent.hash)
                    .environment(syncService)
                    .environment(torrentService)
            } label: {
                TorrentRowView(torrent: torrent)
            }
            .contextMenu { torrentActions(for: torrent) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if isPaused(torrent) {
                        Button("Resume", systemImage: "play.fill") {
                            performTorrentAction(successTitle: "Resumed", successMessage: torrent.name) {
                                try await torrentService.resumeTorrents(hashes: [torrent.hash])
                            }
                        }
                    .tint(.green)
                    } else {
                        Button("Pause", systemImage: "pause.fill") {
                            performTorrentAction(successTitle: "Paused", successMessage: torrent.name) {
                                try await torrentService.pauseTorrents(hashes: [torrent.hash])
                            }
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    torrentPendingDeletion = torrent
                }
                Button("Recheck", systemImage: "arrow.clockwise") {
                    performTorrentAction(successTitle: "Rechecking", successMessage: torrent.name) {
                        try await torrentService.recheckTorrents(hashes: [torrent.hash])
                    }
                }
                .tint(.blue)
            }

        case .arrQueue(let queueItem, let source, let linkedTorrent, let linkedSABJob, let instance):
            arrQueueRow(
                item: queueItem,
                source: source,
                linkedTorrent: linkedTorrent,
                linkedSABJob: linkedSABJob,
                instance: instance
            )

        case .arrHistory(let historyItem):
            HistoryRow(item: historyItem)

        case .sab(let job):
            // Mirrors the `.torrent` case: the NavigationLink owns the row, and
            // the context menu / swipe actions hang off the link so they keep
            // working alongside the push.
            rowLink {
                SABnzbdJobDetailView(jobID: job.id, fallbackName: job.name)
                    .environment(sabnzbdServiceManager)
            } label: {
                sabRow(for: job)
            }
                .contextMenu { sabActions(for: job) }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if job.source == .queue {
                        if job.normalizedStatus == .paused {
                            Button("Resume", systemImage: "play.fill") {
                                performSABAction(successTitle: "Resumed", successMessage: job.name) {
                                    try await sabnzbdServiceManager.resume(job: job)
                                }
                            }
                            .tint(.green)
                        } else {
                            Button("Pause", systemImage: "pause.fill") {
                                performSABAction(successTitle: "Paused", successMessage: job.name) {
                                    try await sabnzbdServiceManager.pause(job: job)
                                }
                            }
                            .tint(.orange)
                        }
                    } else if job.normalizedStatus == .failed {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            performSABAction(successTitle: "Retrying", successMessage: job.name) {
                                try await sabnzbdServiceManager.retry(job: job)
                            }
                        }
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        sabJobPendingDeletion = job
                    }
                }
        }
    }

    // MARK: - Arr queue row

    /// Arr queue rows used to render as bare, untappable text whenever no torrent
    /// was linked - which is exactly the stuck-import case the Issues segment
    /// exists for. Every variant now leads somewhere: the torrent detail when a
    /// torrent is behind it, otherwise a tap opens the same actions the context
    /// menu offers.
    @ViewBuilder
    private func arrQueueRow(
        item: ArrQueueItem,
        source: ArrServiceType,
        linkedTorrent: Torrent?,
        linkedSABJob: SABnzbdJob?,
        instance: ArrInstanceRef?
    ) -> some View {
        let target = ArrQueueActionTarget(
            item: item,
            source: source,
            linkedTorrent: linkedTorrent,
            linkedSABJob: linkedSABJob,
            instance: instance
        )
        let isInFlight = queueActionInFlightIDs.contains(target.id)

        Group {
            if let linkedTorrent {
                rowLink {
                    TorrentDetailView(torrentHash: linkedTorrent.hash)
                        .environment(syncService)
                        .environment(torrentService)
                } label: {
                    ArrInfoRowView(queueItem: item, source: source, linkedTorrent: linkedTorrent, instance: badgeInstance(instance, source))
                }
            } else if let linkedSABJob {
                // A matched Usenet job is every bit as navigable as a matched
                // torrent - the detail view already exists and the `.sab` rows
                // use it. This branch was simply missing, so Arr rows backed by
                // SABnzbd dead-ended in the actions dialog.
                rowLink {
                    SABnzbdJobDetailView(jobID: linkedSABJob.id, fallbackName: linkedSABJob.name)
                        .environment(sabnzbdServiceManager)
                } label: {
                    ArrInfoRowView(
                        queueItem: item,
                        source: source,
                        linkedSABJob: linkedSABJob,
                        instance: badgeInstance(instance, source)
                    )
                }
            } else {
                let unlinkedContent = VStack(alignment: .leading, spacing: 4) {
                    ArrInfoRowView(queueItem: item, source: source, instance: badgeInstance(instance, source))
                    if showsUnlinkedNotice(for: item) {
                        unlinkedNotice
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if editMode.isEditing {
                    unlinkedContent
                } else {
                    Button {
                        queueActionTarget = target
                    } label: {
                        unlinkedContent.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .disabled(isInFlight)
        .contextMenu {
            if linkedTorrent != nil || linkedSABJob != nil {
                arrQueueClientActions(linkedTorrent: linkedTorrent, linkedSABJob: linkedSABJob)
                Divider()
            }
            arrQueueRemovalActions(item: item, source: source, instance: instance)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "xmark.circle", role: .destructive) {
                performQueueAction(item: item, source: source, instance: instance, blocklist: false, searchAgain: false)
            }
            Button("Blocklist", systemImage: "hand.raised") {
                performQueueAction(item: item, source: source, instance: instance, blocklist: true, searchAgain: false)
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if DownloadsViewModel.canSearchAgain(item, source: source) {
                Button("Search Again", systemImage: "magnifyingglass") {
                    performQueueAction(item: item, source: source, instance: instance, blocklist: true, searchAgain: true)
                }
                .tint(.blue)
            }
        }
    }

    /// An Arr says this is downloading right now, but neither client Trawl is
    /// connected to has it. Usually that means the Arr is pointed at a download
    /// client Trawl can't see - the same disconnect `DownloadClientLinkChecker`
    /// reports over in Client Management.
    ///
    /// Deliberately narrow. Only "downloading" qualifies: an importing or moving
    /// item may have legitimately already left the client, and an item with no
    /// client configured at all isn't a mismatch, it's an empty setup.
    private func showsUnlinkedNotice(for item: ArrQueueItem) -> Bool {
        guard hasQBittorrentServer || hasSABnzbdServer else { return false }
        guard !item.isImportIssueQueueItem else { return false }
        return item.normalizedState == "downloading"
    }

    private var unlinkedNotice: some View {
        Label(
            "No matching download in the clients Trawl is connected to.",
            systemImage: "questionmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
    }

    private func sabRow(for job: SABnzbdJob) -> some View {
        ArrInfoRowView(
            icon: (job.normalizedStatus.systemImage, job.normalizedStatus.color),
            title: job.name,
            subtitleLeading: job.normalizedStatus.displayName,
            subtitleLeadingColor: job.normalizedStatus.color,
            subtitleTrailing: job.timeRemaining,
            chips: sabChips(for: job),
            message: job.failureMessage.map { ($0, Color.red) }
        )
    }

    private func sabChips(for job: SABnzbdJob) -> [ArrReleaseInfoChip] {
        var chips = [
            ArrReleaseInfoChip("\(Int(job.progress * 100))%", color: job.normalizedStatus.color, isProminent: true),
            ArrReleaseInfoChip(job.downloadedSizeSummary, color: .secondary),
            ArrReleaseInfoChip("SABnzbd", color: .indigo)
        ]
        if let category = job.category, !category.isEmpty {
            chips.insert(ArrReleaseInfoChip(category, color: .primary), at: 1)
        }
        return chips
    }

    // MARK: - Row actions

    // `includesSeparators` is off inside confirmation dialogs, which drop any
    // non-button content anyway.
    @ViewBuilder
    private func torrentActions(for torrent: Torrent, includesSeparators: Bool = true) -> some View {
        if isPaused(torrent) {
            Button("Resume", systemImage: "play.fill") {
                performTorrentAction(successTitle: "Resumed", successMessage: torrent.name) {
                    try await torrentService.resumeTorrents(hashes: [torrent.hash])
                }
            }
        } else {
            Button("Pause", systemImage: "pause.fill") {
                performTorrentAction(successTitle: "Paused", successMessage: torrent.name) {
                    try await torrentService.pauseTorrents(hashes: [torrent.hash])
                }
            }
        }
        Button("Recheck", systemImage: "arrow.clockwise") {
            performTorrentAction(successTitle: "Rechecking", successMessage: torrent.name) {
                try await torrentService.recheckTorrents(hashes: [torrent.hash])
            }
        }
        if includesSeparators { Divider() }
        Button("Delete", systemImage: "trash", role: .destructive) {
            torrentPendingDeletion = torrent
        }
    }

    @ViewBuilder
    private func sabActions(for job: SABnzbdJob, includesSeparators: Bool = true) -> some View {
        if job.source == .queue {
            if job.normalizedStatus == .paused {
                Button("Resume", systemImage: "play.fill") {
                    performSABAction(successTitle: "Resumed", successMessage: job.name) {
                        try await sabnzbdServiceManager.resume(job: job)
                    }
                }
            } else {
                Button("Pause", systemImage: "pause.fill") {
                    performSABAction(successTitle: "Paused", successMessage: job.name) {
                        try await sabnzbdServiceManager.pause(job: job)
                    }
                }
            }
        }
        if job.normalizedStatus == .failed {
            Button("Retry", systemImage: "arrow.clockwise") {
                performSABAction(successTitle: "Retrying", successMessage: job.name) {
                    try await sabnzbdServiceManager.retry(job: job)
                }
            }
        }
        if includesSeparators { Divider() }
        Button("Remove", systemImage: "trash", role: .destructive) {
            sabJobPendingDeletion = job
        }
    }

    /// Client-side verbs for whatever is actually carrying an Arr queue item.
    @ViewBuilder
    private func arrQueueClientActions(
        linkedTorrent: Torrent?,
        linkedSABJob: SABnzbdJob?,
        includesSeparators: Bool = true
    ) -> some View {
        if let linkedTorrent {
            torrentActions(for: linkedTorrent, includesSeparators: includesSeparators)
        } else if let linkedSABJob {
            sabActions(for: linkedSABJob, includesSeparators: includesSeparators)
        }
    }

    @ViewBuilder
    private func arrQueueRemovalActions(
        item: ArrQueueItem,
        source: ArrServiceType,
        instance: ArrInstanceRef?
    ) -> some View {
        Group {
            Button("Remove from Queue", systemImage: "xmark.circle", role: .destructive) {
                performQueueAction(item: item, source: source, instance: instance, blocklist: false, searchAgain: false)
            }
            Button("Blocklist & Remove", systemImage: "hand.raised", role: .destructive) {
                performQueueAction(item: item, source: source, instance: instance, blocklist: true, searchAgain: false)
            }
            if DownloadsViewModel.canSearchAgain(item, source: source) {
                Button("Blocklist & Search Again", systemImage: "magnifyingglass") {
                    performQueueAction(item: item, source: source, instance: instance, blocklist: true, searchAgain: true)
                }
            }
        }
    }

    /// Whether to badge a row with its server. Suppressed when only one instance
    /// of that service is configured - the badge would then label every Sonarr row
    /// "Sonarr" and say nothing. Routing still uses the real instance either way.
    private func badgeInstance(_ instance: ArrInstanceRef?, _ source: ArrServiceType) -> ArrInstanceRef? {
        guard arrServiceManager.showsInstanceProvenance(for: source) else { return nil }
        return instance
    }

    private func isPaused(_ torrent: Torrent) -> Bool {
        switch torrent.state {
        case .pausedDL, .pausedUP, .stoppedDL, .stoppedUP: true
        default: false
        }
    }

    // MARK: - Performing actions

    private func performQueueAction(
        item: ArrQueueItem,
        source: ArrServiceType,
        instance: ArrInstanceRef?,
        blocklist: Bool,
        searchAgain: Bool
    ) {
        queueActionTarget = nil
        let key = ArrQueueActionTarget.id(for: item, source: source, instance: instance)
        guard !queueActionInFlightIDs.contains(key) else { return }
        queueActionInFlightIDs.insert(key)

        Task { @MainActor in
            defer { queueActionInFlightIDs.remove(key) }
            let failure = await viewModel.removeQueueItem(
                item,
                source: source,
                instance: instance,
                blocklist: blocklist,
                searchAgain: searchAgain,
                serviceManager: arrServiceManager
            )
            if let failure {
                notificationCenter.showError(title: "Queue Action Failed", message: failure)
            } else if searchAgain {
                notificationCenter.showSuccess(
                    title: "Searching Again",
                    message: "The release was blocklisted and a new search was started."
                )
            } else if blocklist {
                notificationCenter.showSuccess(
                    title: "Blocked",
                    message: "The queue item was removed and blocklisted."
                )
            } else {
                notificationCenter.showSuccess(
                    title: "Removed",
                    message: "The queue item was removed from \(source.displayName)."
                )
            }
        }
    }

    private func deletePendingTorrent(deleteFiles: Bool) {
        guard let torrent = torrentPendingDeletion else { return }
        torrentPendingDeletion = nil
        performTorrentAction(successTitle: "Deleted", successMessage: torrent.name) {
            try await torrentService.deleteTorrents(hashes: [torrent.hash], deleteFiles: deleteFiles)
        }
    }

    private func deletePendingSABJob(deleteFiles: Bool) {
        guard let job = sabJobPendingDeletion else { return }
        sabJobPendingDeletion = nil
        performSABAction(successTitle: "Removed", successMessage: job.name) {
            if job.source == .queue {
                try await sabnzbdServiceManager.delete(job: job, deleteFiles: deleteFiles)
            } else {
                try await sabnzbdServiceManager.deleteHistory(job: job, permanently: true, deleteFiles: deleteFiles)
            }
        }
    }

    /// qBittorrent commands don't push, so pull a fresh sync rather than waiting
    /// out the poll interval.
    private func performTorrentAction(
        successTitle: String,
        successMessage: String,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await operation()
                await syncService.refreshNow()
                notificationCenter.showSuccess(title: successTitle, message: successMessage)
            } catch {
                notificationCenter.showError(
                    title: "Torrent Action Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// `SABnzbdServiceManager` refreshes itself after each job action.
    private func performSABAction(
        successTitle: String,
        successMessage: String,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await operation()
                notificationCenter.showSuccess(title: successTitle, message: successMessage)
            } catch {
                notificationCenter.showError(
                    title: "SABnzbd Action Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private var torrentDeletionPresented: Binding<Bool> {
        Binding(
            get: { torrentPendingDeletion != nil },
            set: { if !$0 { torrentPendingDeletion = nil } }
        )
    }

    private var sabDeletionPresented: Binding<Bool> {
        Binding(
            get: { sabJobPendingDeletion != nil },
            set: { if !$0 { sabJobPendingDeletion = nil } }
        )
    }

    private var queueActionDialogPresented: Binding<Bool> {
        Binding(
            get: { queueActionTarget != nil },
            set: { if !$0 { queueActionTarget = nil } }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySystemImage)
        } description: {
            if viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(emptyDescription)
            } else {
                Text("No downloads match “\(viewModel.searchText)”.")
            }
        }
        .scrollableUnavailableState()
    }

    private var emptyTitle: String {
        switch selectedSection {
        case .active: "No Active Downloads"
        case .queue: "Queue is Empty"
        case .completed: "Nothing Completed"
        case .seeding: "Nothing Seeding"
        case .history: "No Download History"
        case .issues: "No Download Issues"
        }
    }

    private var emptyDescription: String {
        switch selectedSection {
        case .active: "Downloads, repairs, unpacking, and imports in progress will appear here."
        case .queue: "Downloads waiting for a client or import will appear here."
        case .completed: "Finished downloads will appear here."
        case .seeding: "Finished torrents that are still uploading will appear here."
        case .history: "Completed grabs and imports will appear here."
        case .issues: "Client failures and imports requiring attention will appear here."
        }
    }

    private var emptySystemImage: String {
        switch selectedSection {
        case .active: "arrow.down.circle"
        case .queue: "tray"
        case .completed: "checkmark.circle"
        case .seeding: "arrow.up.circle"
        case .history: "clock.arrow.circlepath"
        case .issues: "exclamationmark.triangle"
        }
    }

    /// While selecting, the title counts the selection and the subtitle keeps the
    /// list's own size, so "how many have I picked, out of how many" reads in one
    /// glance without a second line of chrome.
    private var navigationTitleText: String {
        guard editMode.isEditing else { return showsTitleMenu ? "" : "Downloads" }
        let selected = selectedRowIDs.count
        return selected == 1 ? "1 Selected" : "\(selected) Selected"
    }

    private var navigationSubtitle: String {
        let count = items.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    /// Seeding is torrent-only, while Completed can contain stopped torrents and
    /// completed SABnzbd jobs. Each is dropped when its relevant client is absent,
    /// and again when it has nothing in it rather than sitting permanently empty.
    ///
    /// The segment the user is currently *on* always stays, even once it empties.
    /// Pausing the last seeding torrent while sitting on Seeding would otherwise
    /// yank the tab out from under them mid-action; instead the segment holds with
    /// its empty state and only disappears - animated, with the selection change -
    /// once they move somewhere else.
    ///
    /// The counts are taken straight from the client caches rather than through the
    /// view model: this runs on every body pass, and the full match/sort pipeline is
    /// far too expensive to drive a segment bar with.
    private var visibleSections: [DownloadSection] {
        DownloadSection.allCases.filter { section in
            switch section {
            case .completed:
                (hasQBittorrentServer || hasSABnzbdServer)
                    && (hasCompletedDownloads || selectedSection == .completed)
            case .seeding:
                hasQBittorrentServer && (hasSeedingTorrents || selectedSection == .seeding)
            case .active, .queue, .history, .issues:
                true
            }
        }
    }

    private var hasSeedingTorrents: Bool {
        syncService.torrents.values.contains { $0.state.filterCategory == .seeding }
    }

    private var hasCompletedTorrents: Bool {
        syncService.torrents.values.contains { $0.state.isCompleted && $0.state.filterCategory == .paused }
    }

    private var hasCompletedDownloads: Bool {
        hasCompletedTorrents
            || sabnzbdServiceManager.historyJobs.contains { $0.normalizedStatus == .completed }
    }

    private var hasQBittorrentServer: Bool {
        !qbittorrentServers.isEmpty
    }

    private var hasSABnzbdServer: Bool {
        !sabnzbdProfiles.isEmpty
    }

    /// Keyed on every configured server, not the active pair: the queue this screen
    /// shows is the union of both, so a second server connecting has to reload it.
    private var reloadKey: String {
        arrServiceManager.arrConnectionKey
    }

    /// The blend of whichever download clients are configured, reusing the same
    /// mesh the More tab builds from its own services. A qBittorrent-and-SABnzbd
    /// setup reads as both; one client reads as that one; neither falls back to the
    /// plain grouped background rather than inventing a colour.
    ///
    /// Only the blended list uses this. Switching to SABnzbd or Torrents shows those
    /// views' own single-service gradients, which is the point - the background says
    /// which list you are on.
    private var backgroundGradient: some View {
        MoreServicesGradientBackground(services: configuredDownloadServices)
            .animation(.snappy, value: titleDestination)
    }

    /// The colours behind the list follow what the list is showing.
    ///
    /// The blended list mixes both clients, so the background does too. Narrow to one
    /// client and the background narrows with it - that is the same single-service
    /// gradient those lists used to carry when they were separate screens, which is
    /// what makes the switch read as changing *what you are looking at* rather than
    /// just filtering it. An unconfigured client contributes nothing, so a
    /// SABnzbd-only setup never shows a qBittorrent tint.
    private var configuredDownloadServices: [ServiceIdentity] {
        switch titleDestination {
        case .downloads:
            var identities: [ServiceIdentity] = []
            if hasQBittorrentServer { identities.append(.qbittorrent) }
            if hasSABnzbdServer { identities.append(.sabnzbd) }
            return identities
        case .torrents:
            return hasQBittorrentServer ? [.qbittorrent] : []
        case .sabQueue:
            return hasSABnzbdServer ? [.sabnzbd] : []
        }
    }
}

/// The Arr queue row a confirmation dialog is acting on, plus whatever download
/// client is carrying it so the dialog can offer that client's verbs inline.
private struct ArrQueueActionTarget: Identifiable {
    let item: ArrQueueItem
    let source: ArrServiceType
    let linkedTorrent: Torrent?
    let linkedSABJob: SABnzbdJob?
    let instance: ArrInstanceRef?

    var id: String { Self.id(for: item, source: source, instance: instance) }

    /// Keyed by instance as well as service: an in-flight removal on the HD
    /// server must not disable the identically-numbered row on the 4K one.
    static func id(for item: ArrQueueItem, source: ArrServiceType, instance: ArrInstanceRef?) -> String {
        "\(instance?.id.uuidString ?? source.rawValue)-\(item.id)"
    }
}

private extension DownloadSection {
    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }
}

/// The three peer lists the Downloads tab can show.
///
/// SABnzbd's queue and qBittorrent's torrents used to live two pushes deep behind
/// Client Management, which put a client's own downloads under a heading about
/// configuring clients. They are the same kind of thing as the unified list, so
/// they sit beside it.
enum DownloadsTitleDestination: String, CaseIterable, Identifiable, Hashable {
    case downloads
    case sabQueue
    case torrents

    var id: String { rawValue }

    /// Which downloads this destination lists. The destination is a filter, not a
    /// screen - that distinction is the whole point of the tab being one view.
    var scope: DownloadsViewModel.DownloadScope {
        switch self {
        case .downloads: .all
        case .sabQueue: .sab
        case .torrents: .torrents
        }
    }

    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .sabQueue: "SABnzbd"
        case .torrents: "Torrents"
        }
    }

    var systemImage: String {
        switch self {
        case .downloads: "tray.and.arrow.down"
        case .sabQueue: ServiceIdentity.sabnzbd.systemImage
        case .torrents: "arrow.down.circle.fill"
        }
    }
}
