import SwiftData
import SwiftUI

/// Lets callers outside the Downloads tab steer its segment bar on an
/// already-mounted `DownloadsView`. `initialSection` can only ever be read once,
/// at init, and re-initialising the view with `.id()` would wipe the tab's
/// navigation stack — so the request travels as shared observable state that
/// `DownloadsView` consumes via `.onChange` and then clears.
@Observable
@MainActor
final class DownloadsNavigator {
    /// Set by a caller, cleared by `DownloadsView` once it has been applied.
    var requestedSection: DownloadSection?
    /// A push to perform on arrival — used by More's search results, which link to
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

    init(initialSection: DownloadSection = .active) {
        _selectedSection = State(initialValue: initialSection)
    }

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
        managementRoute = requested
        downloadsNavigator?.requestedRoute = nil
    }

    var body: some View {
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
            .navigationTitle("Downloads")
            .navigationSubtitle(navigationSubtitle)
            #if os(iOS)
            .toolbarTitleDisplayMode(.inlineLarge)
            #endif
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
                // can't see around — the torrent client being removed.
                if !sections.contains(selectedSection) {
                    withAnimation { selectedSection = .active }
                }
            }
            .toolbar {
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

                    // Client Management and the Blocklist are both "look at the
                    // plumbing" destinations rather than per-download actions, so
                    // they share one overflow menu.
                    Menu {
                        Button("Client Management", systemImage: "server.rack") {
                            managementRoute = .clients
                        }

                        Button("Blocklist", systemImage: "hand.raised.slash.fill") {
                            managementRoute = .blocklist
                        }
                    } label: {
                        Label("Downloads Options", systemImage: "ellipsis")
                    }
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
            .task {
                await sabnzbdServiceManager.refresh()
                sabnzbdServiceManager.startPolling()
                viewModel.startPolling(serviceManager: arrServiceManager)
            }
            .onDisappear {
                sabnzbdServiceManager.stopPolling()
                viewModel.stopPolling(serviceManager: arrServiceManager)
            }
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
            // it points at Client Management — the place in *this* tab where you'd add
            // one — rather than at Settings.
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: ServiceIdentity.qbittorrent.systemImage)
            } description: {
                Text("Add a qBittorrent server to use its transfer stats, categories, and RSS tools.")
            } actions: {
                Button("Client Management") {
                    managementRoute = .clients
                }
            }
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
                TorrentListView(title: "qBittorrent")
                    .environment(syncService)
                    .environment(torrentService)
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

    private var items: [DownloadListItem] {
        viewModel.items(
            for: selectedSection,
            serviceManager: arrServiceManager,
            torrents: syncService.torrents,
            sabActiveJobs: sabnzbdServiceManager.activeJobs,
            sabHistoryJobs: sabnzbdServiceManager.historyJobs
        )
        .sorted {
            sortOrder.areInIncreasingOrder($0.sortValues, $1.sortValues)
        }
    }

    @ViewBuilder
    private var content: some View {
        // Gated on the first load rather than on `isLoadingQueue`, which flips true on
        // every poll — an empty queue would otherwise flicker spinner/empty each cycle.
        if arrServiceManager.isLoadingQueue && !arrServiceManager.hasLoadedQueueOnce && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = arrServiceManager.queueError,
                  items.isEmpty,
                  syncService.torrents.isEmpty,
                  !hasQBittorrentServer,
                  !hasSABnzbdServer {
            ContentUnavailableView {
                Label("Downloads Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") {
                    Task { await viewModel.refresh(serviceManager: arrServiceManager) }
                }
            }
            .scrollableUnavailableState()
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

    /// A failing SABnzbd must not blank this screen — it is a unified view and
    /// qBittorrent may still be perfectly healthy — but it must not fail silently
    /// either. Before this, a rejected API key simply made SABnzbd's jobs vanish
    /// from the list with no explanation anywhere on the Downloads tab; the only
    /// place that surfaced `connectionError` was the SABnzbd manager screen, four
    /// navigations away.
    @ViewBuilder
    private var sabnzbdConnectionWarning: some View {
        if hasSABnzbdServer, let message = sabnzbdServiceManager.connectionError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SABnzbd Unavailable")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                row(for: item)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.default, value: items.map(\.id))
    }

    @ViewBuilder
    private func row(for item: DownloadListItem) -> some View {
        switch item {
        case .torrent(let torrent):
            NavigationLink {
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
            NavigationLink {
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
    /// was linked — which is exactly the stuck-import case the Issues segment
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
                NavigationLink {
                    TorrentDetailView(torrentHash: linkedTorrent.hash)
                        .environment(syncService)
                        .environment(torrentService)
                } label: {
                    ArrInfoRowView(queueItem: item, source: source, linkedTorrent: linkedTorrent, instance: badgeInstance(instance, source))
                }
            } else if let linkedSABJob {
                // A matched Usenet job is every bit as navigable as a matched
                // torrent — the detail view already exists and the `.sab` rows
                // use it. This branch was simply missing, so Arr rows backed by
                // SABnzbd dead-ended in the actions dialog.
                NavigationLink {
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
                Button {
                    queueActionTarget = target
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        ArrInfoRowView(queueItem: item, source: source, instance: badgeInstance(instance, source))
                        if showsUnlinkedNotice(for: item) {
                            unlinkedNotice
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
    /// client Trawl can't see — the same disconnect `DownloadClientLinkChecker`
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
    /// of that service is configured — the badge would then label every Sonarr row
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
    /// its empty state and only disappears — animated, with the selection change —
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

    private var reloadKey: String {
        [
            arrServiceManager.activeSonarrInstanceID?.uuidString ?? "no-sonarr",
            arrServiceManager.activeRadarrInstanceID?.uuidString ?? "no-radarr",
            String(arrServiceManager.sonarrConnected),
            String(arrServiceManager.radarrConnected)
        ].joined(separator: "|")
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [Color.indigo.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [Color.blue.opacity(0.12), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
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
