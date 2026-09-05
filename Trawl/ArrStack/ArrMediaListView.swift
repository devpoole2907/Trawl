import SwiftUI
import TipKit
import SwiftData
import Foundation

@MainActor
// `ArrMonitorable & ArrTitleable & ArrSortable` are required rather than tested for
// at runtime. Both conforming types - `SonarrSeries` and `RadarrMovie` - already
// conform, so nothing is excluded, but the `as? any ArrMonitorable` casts these
// replace were paid per copy, per row, on every frame of a scroll. A dynamic cast
// to an existential goes through the runtime demangler and conformance checker,
// which measured on device as ~250ms of `swift_getTypeByMangledName`,
// `_checkGenericRequirements` and key-path pattern walking across a 28-second
// scroll. Stating the requirement makes the same accesses static.
struct ArrMediaListView<Item, VM, Row, Detail>: View
where Item: Identifiable & JellyfinMatchable & Equatable & ArrMergeableLibraryItem,
      Item: ArrMonitorable & ArrTitleable & ArrSortable, Item.ID == Int,
      VM: ArrMediaListViewModel & Observable, VM.Item == Item,
      Row: View, Detail: View {
    /// One row of the blended library: a title, with every server's copy of it.
    typealias Entry = ArrLibraryEntry<Item>

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.setTabChromeHidden) private var setTabChromeHidden
    #endif
    @Query private var profiles: [ArrServiceProfile]

    @Bindable var viewModel: VM
    let serviceType: ArrServiceType
    let nounSingular: String
    let nounPlural: String
    let emptyIcon: String
    let row: (Entry, Bool) -> Row
    /// Present when this list is the content column of a split view; `nil` on iPhone.
    /// See `ArrLibraryListView.navigationSelection` for why the two modes differ.
    ///
    /// Declared before `detailDestination` so the memberwise initialiser takes it in
    /// that order at every call site.
    var detailSelection: Binding<ArrMergeKey?>?
    let detailDestination: (ArrMergeKey) -> Detail

    @State private var listScrollPosition: ArrMergeKey?
    @Namespace private var namespace
    @State private var showSettings = false
    @State private var showAddSheet = false
    @State private var showCalendar = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// True where the app draws a sidebar, which is where these toolbar shortcuts
    /// have a row of their own and stop earning their place.
    private var hasSidebarChrome: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }
    @State private var showWantedMissing = false
    @State private var pendingDeleteItem: Entry?
    @State private var isRunningCommand = false
    @State private var editMode: SelectionMode = .inactive

    /// The library list has one inline slot for a tip, and two tips want it.
    ///
    /// `.firstAvailable` rather than `.ordered` on purpose: the blended-library tip
    /// requires more than one configured instance, which a single-server user will
    /// never have. An ordered group would queue the quick-actions tip behind a tip
    /// that can never become eligible, and those users would simply never see it.
    @State private var libraryTips = TipGroup(.firstAvailable) {
        ArrBlendedLibraryTip()
        ArrLibraryQuickActionsTip()
    }
    @State private var selectedIDs: Set<ArrMergeKey> = []
    @State private var showBulkDeleteAlert = false
    @State private var isFilterSearchExpanded = false
    /// Drives the title menu's shrink. A `.principal` toolbar item is fixed, so
    /// this stands in for the large-title collapse the system would do for us.
    @State private var isTitleCompact = false

    #if os(iOS)
    private var swiftUIEditMode: Binding<EditMode> {
        Binding(
            get: { editMode.isEditing ? .active : .inactive },
            set: { newMode in
                withAnimation {
                    editMode = newMode.isEditing ? .active : .inactive
                }
            }
        )
    }
    #endif

    var body: some View {
        baseContent
            .trawlTitleMenuShrinksOnScroll($isTitleCompact)
            .navigationTitle(navigationTitleText)
            .navigationSubtitle(showsTitleMenu && detailSelection != nil ? "" : navigationSubtitleText)
            #if os(iOS)
            .toolbarTitleDisplayMode(showsTitleMenu || editMode.isEditing ? .inline : .inlineLarge)
            .environment(\.editMode, swiftUIEditMode)
            .toolbarVisibility(editMode.isEditing ? .hidden : .visible, for: .tabBar)
            #endif
            .toolbar { titleMenuToolbarItem }
            .toolbar { toolbarContent }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: editMode.isEditing)
            .onChange(of: editMode.isEditing) { _, isEditing in
                #if os(iOS)
                setTabChromeHidden(isEditing)
                #endif
            }
            .onDisappear {
                #if os(iOS)
                setTabChromeHidden(false)
                #endif
            }
            .modifier(ArrMediaListViewAlertsAndSheets(
                serviceType: serviceType,
                nounSingular: nounSingular,
                nounPlural: nounPlural,
                viewModel: viewModel,
                serviceManager: serviceManager,
                syncService: syncService,
                namespace: namespace,
                pendingDeleteItem: $pendingDeleteItem,
                showBulkDeleteAlert: $showBulkDeleteAlert,
                selectedIDs: $selectedIDs,
                showSettings: $showSettings,
                showAddSheet: $showAddSheet,
                showCalendar: $showCalendar,
                showWantedMissing: $showWantedMissing,
                onBulkDelete: bulkDeleteItems
            ))
            .refreshableIfEnabled(!editMode.isEditing) {
                async let loadItems = viewModel.loadLibraryItems()
                async let loadQueue = viewModel.loadQueue()
                _ = await (loadItems, loadQueue)
                if serviceManager.hasAnyConnectedBazarrInstance {
                    await serviceManager.refreshActiveBazarrSubtitleCache()
                }
                viewModel.refreshFilters()
            }
            .safeAreaInset(edge: .top) {
                if !editMode.isEditing {
                    TrawlSegmentBar(
                        "Filter",
                        selection: $viewModel.selectedFilter,
                        items: VM.Filter.allCases.map { TrawlSegmentBarItem($0.rawValue, value: $0) },
                        searchText: $viewModel.searchText,
                        searchHint: "Search \(nounPlural.lowercased())",
                        isSearchExpanded: $isFilterSearchExpanded,
                        searchPlacement: .leading,
                        alignment: .leading
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))

                    if let tip = libraryTips.currentTip {
                        TipView(tip)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .onAppear { updateLibraryTipEligibility() }
            .onChange(of: viewModel.filteredItems.isEmpty) { _, _ in updateLibraryTipEligibility() }
            .onChange(of: editMode.isEditing) { _, _ in updateLibraryTipEligibility() }
            .onChange(of: availableInstanceRefs.count) { _, _ in updateLibraryTipEligibility() }
            // Keyed by the merge key rather than a library ID: a row stands for a
            // title, and the same title has a different ID on each server.
            .navigationDestination(for: ArrMergeKey.self) { key in
                detailDestination(key)
                    .environment(syncService)
            }
            // Keyed by the view model's identity rather than the active instance ID.
            // Repointing a profile at a different server keeps its ID, so the ID alone
            // never changes and this task was not restarted. The list view recreates
            // its view model for the new client, but on re-appear this task had
            // already started against the *previous* one - leaving a freshly created,
            // empty view model that nothing ever asked to load, and a library list
            // stuck on "No Series" while the app was correctly connected to the new
            // server. Identity changes exactly when the view model is swapped, and
            // still covers an instance switch, which also builds a new view model.
            .task(id: ObjectIdentifier(viewModel)) { [viewModel] in
                await performInitialLoadAndStartPolling(viewModel: viewModel)
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Backgrounding never fires `onDisappear`, so the `.task` above
                // doesn't re-run on return and the list would sit on whatever it
                // had when the app went away. The staleness window means a quick
                // trip out of the app still costs nothing.
                guard newPhase == .active else { return }
                Task { [viewModel] in
                    await viewModel.loadLibraryItems(maxAge: ArrLibraryCachePolicy.appearMaxAge)
                }
            }
            .task(id: serviceManager.lastLibraryImportTimestamp) { [viewModel] in
                guard serviceManager.lastLibraryImportTimestamp != .distantPast else { return }
                await viewModel.loadLibraryItems()
            }
            .task(id: serviceManager.activeBazarrProfileID) { [viewModel] in
                await refreshBazarrStatus(viewModel: viewModel)
            }
            .task(id: "\(jellyfinManager.activeProfileID?.uuidString ?? ""):\(jellyfinManager.isConnected)") { [viewModel] in
                await viewModel.refreshJellyfinLibraryCache()
            }
    }

    @ViewBuilder
    private var baseContent: some View {
        if serviceManager.isConnected(serviceType) {
            mainContent
        } else if isShowingConnectingState || serviceManager.connectionError(serviceType) != nil {
            ConnectionStatusCard(
                identity: serviceType.serviceIdentity,
                title: isShowingConnectingState ? "Connecting to \(serviceType.displayName)" : "\(serviceType.displayName) Unreachable",
                message: serviceManager.connectionError(serviceType) ?? "Checking your configured \(serviceType.displayName) server.",
                isConnecting: isShowingConnectingState,
                detailTitle: activeProfile?.displayName,
                detailSubtitle: activeProfile?.hostURL,
                presentation: .embedded,
                onRetry: { Task { await serviceManager.retry(serviceType) } },
                onEdit: {
                    withAnimation(.snappy) {
                        showSettings = true
                    }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            notSetUpView
        }
    }

    private var notSetUpView: some View {
        notSetUpContent
            .scrollableUnavailableState()
    }

    private var notSetUpContent: some View {
        ServiceSetupView(
            title: "\(serviceType.displayName) Not Set Up",
            message: "Add a \(serviceType.displayName) server in Settings to get started.",
            systemImage: emptyIcon,
            actionTitle: "Add Server",
            onSetup: {
                withAnimation(.snappy) {
                    if profiles.filter({ $0.resolvedServiceType == serviceType }).isEmpty {
                        showAddSheet = true
                    } else {
                        showSettings = true
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        ArrLibraryListView(
            items: viewModel.filteredItems,
            isLoading: viewModel.isLoading && viewModel.items.isEmpty,
            error: nil,
            nounSingular: nounSingular,
            nounPlural: nounPlural,
            emptyIcon: emptyIcon,
            titleKeyPath: \.titlePlaceholder,
            sectionTitle: { entry in
                let item = entry.primary
                return item.sortTitle ?? item.title
            },
            usesTitleSections: viewModel.sortOrder.rawValue == "Title",
            selection: $selectedIDs,
            navigationSelection: detailSelection,
            row: { entry, _ in itemRow(entry) },
            retry: nil
        )
        .scrollPosition(id: $listScrollPosition)
        .animation(.default, value: viewModel.filteredItems)
        .onChange(of: viewModel.filteredItems) { _, items in
            reconcileSelection(with: items)
        }
        .onAppear { reconcileSelection(with: viewModel.filteredItems) }
    }

    /// One row shape in both modes, minus the link while editing.
    ///
    /// `List` disables `NavigationLink`s in edit mode so its own tap can select the
    /// row, and a disabled link dims everything inside its label - every row went
    /// grey the moment Select was pressed while still being perfectly selectable.
    /// Dropping the link keeps the row at full strength; selection is the List's
    /// either way, so there is still no second tap handler and no hand-drawn
    /// checkmark to keep in step with the system's.
    /// Keeps the detail column pointed at a row that is actually on screen.
    ///
    /// It opens the library on its first title rather than an empty pane, and it
    /// re-points when the open title leaves the visible list - which covers the case
    /// that was outright broken, bulk-deleting the title the detail column is
    /// showing, and would otherwise leave a series that no longer exists sitting
    /// there.
    ///
    /// It follows filtering and search too, and that is a choice rather than an
    /// oversight. Mail would keep the selection and let the detail show something no
    /// longer in the list; in three columns that reads as a mistake, because the two
    /// panes are side by side and visibly disagree. The rule here is the simpler one
    /// to hold in your head: the detail always shows a row you can see.
    private func reconcileSelection(with items: [Entry]) {
        guard let detailSelection else { return }
        if let current = detailSelection.wrappedValue,
           items.contains(where: { $0.id == current }) {
            return
        }
        detailSelection.wrappedValue = items.first?.id
    }

    @ViewBuilder
    private func itemRow(_ entry: Entry) -> some View {
        if editMode.isEditing {
            row(entry, true)
        } else if detailSelection != nil {
            // No `NavigationLink` in this mode: the List owns the tap and the
            // selection drives the detail column beside it. Wrapping the row in a
            // link as well gives the tap two owners, and the row stops selecting.
            // The swipes are identical either way, so they live in one place.
            row(entry, false)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) { rowSwipeActions(entry) }
        } else {
            NavigationLink(value: entry.id) {
                row(entry, false)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { rowSwipeActions(entry) }
        }
    }

    @ViewBuilder
    private func rowSwipeActions(_ entry: Entry) -> some View {
        Button(role: .destructive) {
            ArrLibraryQuickActionsTip().invalidate(reason: .actionPerformed)
            pendingDeleteItem = entry
        } label: {
            Label("Delete", systemImage: "trash")
        }

        // A swipe acts on the title, so it acts on every server holding it.
        // Monitoring one copy and not the other would leave the row showing a state
        // that is true of neither server.
        // One answer, used three times: the label, the icon and the tint each asked
        // the same question of every copy independently.
        let monitored = isMonitored(entry)
        Button {
            ArrLibraryQuickActionsTip().invalidate(reason: .actionPerformed)
            Task { await viewModel.toggleMonitoredAcrossInstances(entry) }
        } label: {
            Label(
                monitored ? "Unmonitor" : "Monitor",
                systemImage: monitored ? "bookmark.slash" : "bookmark.fill"
            )
        }
        .tint(monitored ? .orange : .blue)
    }

    /// Keeps both library tips' transient rules in step with what is on screen.
    ///
    /// All of this is live view state rather than anything worth persisting: whether
    /// the library has rows, whether a second server is configured, whether the user
    /// is midway through a bulk selection. A stale copy of any of it would put a tip
    /// over a loading spinner, an empty library, or a selection in progress.
    private func updateLibraryTipEligibility() {
        let hasItems = !viewModel.filteredItems.isEmpty
        let isBrowsing = hasItems && !editMode.isEditing
        ArrBlendedLibraryTip.isEligible = isBrowsing && availableInstanceRefs.count > 1
        ArrLibraryQuickActionsTip.isEligible = isBrowsing
    }

    /// A merged row counts as monitored when any server is monitoring it, so the
    /// swipe offers "Unmonitor" while at least one copy is still being watched.
    private func isMonitored(_ entry: Entry) -> Bool {
        entry.copies.contains { $0.monitored ?? true }
    }

    private func bulkDeleteItems(deleteFiles: Bool) {
        let keys = selectedIDs
        guard !keys.isEmpty else { return }
        let entries = viewModel.filteredItems.filter { keys.contains($0.id) }
        withAnimation {
            selectedIDs = []
            editMode = .inactive
        }
        Task {
            await viewModel.deleteEntries(entries, deleteFiles: deleteFiles)
        }
    }

    private var titleMenuPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        detailSelection == nil ? .principal : platformTopBarLeadingPlacement
        #endif
    }

    @ToolbarContentBuilder
    private var titleMenuToolbarItem: some ToolbarContent {
        if showsTitleMenu {
            ToolbarItem(placement: titleMenuPlacement) {
                TrawlTitleMenu(
                    options: titleMenuOptions,
                    selection: titleMenuSelection,
                    isCompact: isTitleCompact,
                    subtitle: detailSelection == nil ? nil : navigationSubtitleText
                )
            }
            .sharedBackgroundVisibility(detailSelection == nil ? .automatic : .hidden)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: platformTopBarLeadingPlacement) {
                Button(selectAllButtonTitle) {
                    toggleAllItems()
                }
                .disabled(viewModel.filteredItems.isEmpty)
            }

            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button(role: .destructive) {
                    showBulkDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(selectedIDs.isEmpty)

                Button("Done") {
                    withAnimation {
                        editMode = .inactive
                        selectedIDs = []
                    }
                }
            }
        } else {
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                // Not where there is a sidebar. Calendar is a row there, and a
                // toolbar button that opens a sheet over the library duplicates a
                // destination that is already one click away - with the sheet being
                // the worse of the two, because it covers the list it came from.
                if !hasSidebarChrome {
                    Button("Calendar", systemImage: "calendar") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            showCalendar = true
                        }
                    }
                    #if os(iOS)
                    .matchedTransitionSource(id: "calendar", in: namespace)
                    #endif
                }
            }
            ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Menu {
                    ForEach(Array(VM.Sort.allCases)) { order in
                        Button {
                            withAnimation {
                                viewModel.sortOrder = order
                            }
                        } label: {
                            if viewModel.sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: viewModel.isNonDefaultSortOrder ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
                }

                Menu {
                    Button("Missing", systemImage: "exclamationmark.triangle") {
                        showWantedMissing = true
                    }
                    if !viewModel.filteredItems.isEmpty {
                        Button("Select", systemImage: "checkmark.circle") {
                            withAnimation { editMode = .active }
                        }
                    }
                    Divider()
                    Button("Refresh All", systemImage: "arrow.clockwise") {
                        Task { await runCommand { try await viewModel.refreshLibrary() } }
                    }
                    .disabled(isRunningCommand)
                    Button("Check for New Releases", systemImage: "dot.radiowaves.left.and.right") {
                        Task { await runCommand { try await viewModel.rssSync() } }
                    }
                    .disabled(isRunningCommand)
                } label: {
                    if isRunningCommand {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .accessibilityLabel("\(serviceType.displayName) Actions")

            }
        }
    }

    private var navigationSubtitleText: String {
        let count = viewModel.filteredItems.count
        return count == 1 ? "1 \(nounSingular.lowercased())" : "\(count) \(nounPlural.lowercased())"
    }

    private var areAllItemsSelected: Bool {
        let filteredIDs = Set(viewModel.filteredItems.map(\.id))
        return !filteredIDs.isEmpty && filteredIDs.isSubset(of: selectedIDs)
    }

    private var selectAllButtonTitle: String {
        areAllItemsSelected ? "Deselect All" : "Select All"
    }

    private func toggleAllItems() {
        withAnimation {
            let filteredIDs = Set(viewModel.filteredItems.map(\.id))
            if !filteredIDs.isEmpty && filteredIDs.isSubset(of: selectedIDs) {
                selectedIDs = []
            } else {
                selectedIDs = Set(viewModel.filteredItems.map(\.id))
            }
        }
    }

    private func runCommand(action: @escaping () async throws -> Void) async {
        isRunningCommand = true
        do {
            try await action()
        } catch {
            InAppNotificationCenter.shared.showError(title: "Command Failed", message: error.localizedDescription)
        }
        isRunningCommand = false
    }

    private var activeProfile: ArrServiceProfile? {
        serviceManager.resolvedProfile(for: serviceType, in: profiles)
    }

    private var instanceProfiles: [ArrServiceProfile] {
        profiles
            .filter { $0.resolvedServiceType == serviceType && $0.isEnabled }
            .sorted { lhs, rhs in
                if lhs.dateAdded == rhs.dateAdded {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.dateAdded < rhs.dateAdded
            }
    }

    private var shouldShowInstanceTitleMenu: Bool {
        instanceProfiles.count > 1
    }

    /// Always the library's own name. Titling the screen after one server made
    /// sense when the list showed one server; the list is now the union of both,
    /// and naming either of them would misdescribe it.
    /// Which servers this tab is showing: every one, or exactly one.
    ///
    /// Derived from `ArrServiceManager.instanceFilter` rather than held
    /// separately - the filter is what every unified surface already reads, so a
    /// second copy here could disagree with the library it is meant to describe.
    private enum InstanceScope: Hashable {
        case all
        case only(UUID)
    }

    private var instanceScope: InstanceScope {
        guard !serviceManager.instanceFilter.isShowingAll(serviceType) else { return .all }
        let visible = availableInstanceRefs.filter {
            serviceManager.instanceFilter.isIncluded($0.id, serviceType: serviceType)
        }
        // The filter refuses to hide the last server, so "not showing all" with a
        // single survivor is the only narrowed state the menu can produce.
        return visible.count == 1 ? .only(visible[0].id) : .all
    }

    private var availableInstanceRefs: [ArrInstanceRef] {
        serviceManager.refs(for: serviceType)
    }

    /// Only worth a menu when there is a choice to make, and never while
    /// selecting - the title has a count to show, and a `.principal` toolbar item
    /// would replace it.
    private var showsTitleMenu: Bool {
        availableInstanceRefs.count > 1 && !editMode.isEditing
    }

    private var titleMenuOptions: [TrawlTitleMenuOption<InstanceScope>] {
        [TrawlTitleMenuOption(value: .all, title: nounPlural, systemImage: emptyIcon)]
            + availableInstanceRefs.map {
                // The server's own name, as the user typed it in setup - this menu
                // is about which box to look at, and "Default"/"4K" names a tier
                // rather than a server.
                TrawlTitleMenuOption(value: .only($0.id), title: $0.displayName, systemImage: "server.rack")
            }
    }

    /// Called when the user narrows or widens the library through the title menu -
    /// the exact action the blended-library tip advertises.
    private func invalidateBlendedLibraryTip() {
        ArrBlendedLibraryTip().invalidate(reason: .actionPerformed)
    }

    private var titleMenuSelection: Binding<InstanceScope> {
        Binding(
            get: { instanceScope },
            set: { newScope in
                switch newScope {
                case .all:
                    serviceManager.showAllInstances(of: serviceType)
                case .only(let id):
                    serviceManager.showOnlyInstance(id, serviceType: serviceType)
                }
                invalidateBlendedLibraryTip()
                rebuildAfterInstanceFilterChange()
            }
        )
    }

    /// Re-derives the list for the servers the filter now admits.
    ///
    /// Driven from the menu rather than by observing `instanceFilter`, because
    /// that state also settles during launch - pruned of servers that no longer
    /// exist - and a rebuild triggered then runs before the servers have
    /// connected, so the union comes back empty and blanks a list that had just
    /// loaded. Only a user changing the scope should rebuild.
    ///
    /// The cached adoption is what makes the change feel immediate: changing the
    /// filter drops cache freshness but keeps the items, so the narrowed union is
    /// already in hand and the refetch behind it only restores freshness.
    private func rebuildAfterInstanceFilterChange() {
        withAnimation { viewModel.adoptCachedLibraryItems() }
        Task { [viewModel] in
            await viewModel.loadLibraryItems(maxAge: ArrLibraryCachePolicy.appearMaxAge)
        }
    }

    /// The title carries the selection count while editing, matching Downloads,
    /// so the subtitle is free to keep saying how big the list is.
    private var navigationTitleText: String {
        if editMode.isEditing {
            let count = selectedIDs.count
            return count == 1 ? "1 Selected" : "\(count) Selected"
        }
        guard !showsTitleMenu else { return "" }
        if case .only(let id) = instanceScope,
           let ref = availableInstanceRefs.first(where: { $0.id == id }) {
            return ref.displayName
        }
        return nounPlural
    }

    private var isShowingConnectingState: Bool {
        activeProfile != nil && (serviceManager.isInitializing || serviceManager.isConnecting(serviceType))
    }

    private func instanceDisplayName(for profile: ArrServiceProfile) -> String {
        InstanceDisplayNameResolver.displayName(
            for: profile,
            in: instanceProfiles,
            serviceType: serviceType
        )
    }

    private func performInitialLoadAndStartPolling(viewModel: VM) async {
        guard serviceManager.isConnected(serviceType) else { return }

        // `.task` restarts on every appear, not just the first, so this runs again
        // on each tab switch and every pop back from a detail view. Seed from the
        // shared cache first so those show content immediately, then let the
        // staleness window decide whether the whole library is worth refetching.
        viewModel.adoptCachedLibraryItems()
        async let loadItems: Void = viewModel.loadLibraryItems(maxAge: ArrLibraryCachePolicy.appearMaxAge)
        async let loadQueue: Void = viewModel.loadQueue()
        _ = await (loadItems, loadQueue)

        var knownQueueIds = Set(viewModel.queue.map(\.id))
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                break
            } catch {
                continue
            }

            guard serviceManager.isConnected(serviceType) else { continue }

            await viewModel.loadQueue()
            let currentIds = Set(viewModel.queue.map(\.id))
            if !knownQueueIds.subtracting(currentIds).isEmpty {
                await viewModel.loadLibraryItems()
            }
            knownQueueIds = currentIds
        }
    }

    private func refreshBazarrStatus(viewModel: VM) async {
        guard serviceManager.hasAnyConnectedBazarrInstance else {
            viewModel.refreshFilters()
            return
        }
        await serviceManager.refreshActiveBazarrSubtitleCache()
        viewModel.refreshFilters()
    }
}

// MARK: - Helper Protocols

protocol ArrTitleable {
    var title: String { get }
}

protocol ArrSortable {
    var sortTitle: String? { get }
}

protocol ArrMonitorable {
    var monitored: Bool? { get }
}

extension SonarrSeries: ArrTitleable, ArrSortable, ArrMonitorable {}
extension RadarrMovie: ArrTitleable, ArrSortable, ArrMonitorable {}

private extension Identifiable {
    var titlePlaceholder: String { "" }
}

private extension View {
    @ViewBuilder
    func refreshableIfEnabled(_ enabled: Bool, action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        if enabled {
            refreshable(action: action)
        } else {
            self
        }
    }
}

struct ArrMediaListViewAlertsAndSheets<Item, VM>: ViewModifier
where Item: Identifiable & JellyfinMatchable & Equatable & ArrMergeableLibraryItem, Item.ID == Int,
      VM: ArrMediaListViewModel & Observable, VM.Item == Item {
    let serviceType: ArrServiceType
    let nounSingular: String
    let nounPlural: String
    @Bindable var viewModel: VM
    let serviceManager: ArrServiceManager
    let syncService: SyncService
    let namespace: Namespace.ID

    @Binding var pendingDeleteItem: ArrLibraryEntry<Item>?
    @Binding var showBulkDeleteAlert: Bool
    @Binding var selectedIDs: Set<ArrMergeKey>
    @Binding var showSettings: Bool
    @Binding var showAddSheet: Bool
    @Binding var showCalendar: Bool
    @Binding var showWantedMissing: Bool

    let onBulkDelete: (Bool) -> Void

    /// Names the servers when a title lives on more than one, so a destructive
    /// action can't be confirmed without knowing it hits both.
    private func deleteButtonTitle(for entry: ArrLibraryEntry<Item>) -> String {
        let names = instanceNames(for: entry)
        guard names.count > 1 else { return "Delete from \(serviceType.displayName)" }
        return "Delete from \(names.joined(separator: " and "))"
    }

    private func deleteMessage(for entry: ArrLibraryEntry<Item>) -> String {
        let title = (entry.primary as? any ArrTitleable)?.title ?? nounSingular
        let names = instanceNames(for: entry)
        if names.count > 1 {
            return "\(title) is on \(names.joined(separator: " and ")). Choose whether to remove it from both or also delete its files."
        }
        return "Choose whether to remove only \(title) from \(serviceType.displayName) or also delete its files."
    }

    private func instanceNames(for entry: ArrLibraryEntry<Item>) -> [String] {
        serviceManager.badgeRefs(for: entry).map(\.displayName)
    }

    func body(content: Content) -> some View {
        content
            .alert(
                "Delete \(nounSingular)?",
                isPresented: Binding(
                    get: { pendingDeleteItem != nil },
                    set: { if !$0 { pendingDeleteItem = nil } }
                ),
                presenting: pendingDeleteItem
            ) { entry in
                Button(deleteButtonTitle(for: entry), role: .destructive) {
                    pendingDeleteItem = nil
                    Task { await viewModel.deleteEntries([entry], deleteFiles: false) }
                }
                Button("Delete \(nounSingular) and Files", role: .destructive) {
                    pendingDeleteItem = nil
                    Task { await viewModel.deleteEntries([entry], deleteFiles: true) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteItem = nil
                }
            } message: { entry in
                Text(deleteMessage(for: entry))
            }
            .alert("Delete \(selectedIDs.count) \(selectedIDs.count == 1 ? nounSingular : nounPlural)?", isPresented: $showBulkDeleteAlert) {
                Button("Delete from \(serviceType.displayName)", role: .destructive) {
                    onBulkDelete(false)
                }
                Button("Delete \(nounPlural) and Files", role: .destructive) {
                    onBulkDelete(true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose whether to remove the selected \(nounPlural.lowercased()) from \(serviceType.displayName) or also delete their files. This action can't be undone.")
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    ArrServiceSettingsView(serviceType: serviceType)
                        .environment(serviceManager)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                ArrSetupSheet(initialServiceType: serviceType, onComplete: {
                    Task { await serviceManager.refreshConfiguration() }
                })
                .environment(serviceManager)
            }
            .sheet(isPresented: $showCalendar) {
                NavigationStack {
                    ArrCalendarView(showsCloseButton: true)
                        .environment(serviceManager)
                        .environment(syncService)
                }
                #if os(iOS)
                .navigationTransition(.zoom(sourceID: "calendar", in: namespace))
                #endif
            }
            .sheet(isPresented: $showWantedMissing) {
                NavigationStack {
                    ArrWantedView(initialScope: serviceType == .sonarr ? .series : .movies, showsCloseButton: true)
                        .environment(serviceManager)
                }
            }
    }
}
