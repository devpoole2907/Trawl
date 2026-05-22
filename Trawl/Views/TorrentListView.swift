import SwiftUI
import SwiftData

struct TorrentListView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(\.modelContext) private var modelContext
    #if os(iOS)
    @Environment(\.setTabChromeHidden) private var setTabChromeHidden
    #endif
    @Query(sort: \ServerProfile.dateAdded) private var servers: [ServerProfile]
    @State private var viewModel: TorrentListViewModel?
    @State private var showAddSheet = false
    @State private var torrentToDelete: Torrent?
    @State private var showBatchDeleteConfirm = false
    @State private var batchDeleteFiles = false
    @State private var editMode: SelectionMode = .inactive
    @State private var listScrollPosition: String?
    @State private var isFilterSearchExpanded = false
    private let title: String

    init(title: String = "Trawl") {
        self.title = title
    }

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
        configuredContent
        #if os(iOS)
        .toolbarTitleDisplayMode(.inlineLarge)
        .environment(\.editMode, swiftUIEditMode)
        .toolbarVisibility(editMode.isEditing ? .hidden : .visible, for: .tabBar)
        #endif
        .toolbar { toolbarContent }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: editMode.isEditing)
        .refreshable {
            await viewModel?.refresh()
        }
        .safeAreaInset(edge: .top) {
            if let vm = viewModel, !editMode.isEditing {
                TrawlSegmentBar(
                    "Filter",
                    selection: Binding(
                        get: { vm.selectedFilter },
                        set: { newFilter in withAnimation { vm.selectedFilter = newFilter } }
                    ),
                    items: TorrentFilter.allCases.map(\.segmentBarItem),
                    searchText: torrentSearchText,
                    searchHint: "Search torrents",
                    isSearchExpanded: $isFilterSearchExpanded,
                    searchPlacement: .leading
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddTorrentSheet()
                .environment(syncService)
                .environment(torrentService)
        }
        .alert("Delete Torrent?", isPresented: .init(
            get: { torrentToDelete != nil },
            set: { if !$0 { torrentToDelete = nil } }
        )) {
            Button("Delete and Remove Files", role: .destructive) {
                if let torrent = torrentToDelete {
                    Task { await viewModel?.deleteTorrent(torrent, deleteFiles: true) }
                }
                torrentToDelete = nil
            }
            Button("Delete Torrent Only", role: .destructive) {
                if let torrent = torrentToDelete {
                    Task { await viewModel?.deleteTorrent(torrent, deleteFiles: false) }
                }
                torrentToDelete = nil
            }
            Button("Cancel", role: .cancel) { torrentToDelete = nil }
        } message: {
            Text("This action can't be undone.")
        }
        .alert(batchDeleteAlertTitle, isPresented: $showBatchDeleteConfirm) {
            Button("Delete and Remove Files", role: .destructive) {
                Task { await viewModel?.deleteSelected(deleteFiles: true) }
            }
            Button("Delete Torrents Only", role: .destructive) {
                Task { await viewModel?.deleteSelected(deleteFiles: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action can't be undone.")
        }
        .alert(item: Binding(
            get: { viewModel?.actionErrorAlert },
            set: { viewModel?.actionErrorAlert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            if viewModel == nil {
                let vm = TorrentListViewModel(
                    syncService: syncService,
                    torrentService: torrentService,
                    notificationCenter: inAppNotificationCenter
                )
                viewModel = vm
                vm.startSync()
                await vm.loadAlternativeSpeedMode()
            }
        }
        .onAppear {
            viewModel?.startSync()
        }
        .onChange(of: ObjectIdentifier(syncService)) {
            let vm = TorrentListViewModel(
                syncService: syncService,
                torrentService: torrentService,
                notificationCenter: inAppNotificationCenter
            )
            viewModel = vm
            vm.startSync()
            Task { await vm.loadAlternativeSpeedMode() }
        }
        .onChange(of: activeServerID) { _, _ in
            Task {
                await viewModel?.loadAlternativeSpeedMode()
            }
        }
        .onDisappear {
            // Stop the active sync but keep the viewModel alive so scroll position is preserved
            // when the user returns to this tab.
            viewModel?.stopSync()
            #if os(iOS)
            setTabChromeHidden(false)
            #endif
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func torrentList(vm: TorrentListViewModel) -> some View {
        @Bindable var vm = vm

        ZStack {
            List {
                ForEach(vm.filteredTorrents) { torrent in
                    row(for: torrent, vm: vm)
                }
            }
            .scrollPosition(id: $listScrollPosition)
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
            .opacity(vm.filteredTorrents.isEmpty ? 0 : 1)
            .allowsHitTesting(!vm.filteredTorrents.isEmpty)

            if vm.filteredTorrents.isEmpty {
                emptyState(for: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.default, value: vm.filteredTorrents.map(\.id))
        .onChange(of: vm.selectedFilter) {
            withAnimation {
                editMode = .inactive
                vm.clearSelection()
            }
        }
        .onChange(of: editMode) { _, newMode in
            if !newMode.isEditing {
                vm.clearSelection()
            }
            vm.isSelecting = newMode.isEditing
            #if os(iOS)
            setTabChromeHidden(newMode.isEditing)
            #endif
        }
    }

    @ViewBuilder
    private func row(for torrent: Torrent, vm: TorrentListViewModel) -> some View {
        let isProcessing = vm.processingHashes.contains(torrent.hash)
        
        if editMode.isEditing {
            Button {
                withAnimation {
                    vm.toggleSelection(torrent)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: vm.selectedHashes.contains(torrent.hash) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(vm.selectedHashes.contains(torrent.hash) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                    TorrentRowView(torrent: torrent, isProcessing: isProcessing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            NavigationLink {
                TorrentDetailView(torrentHash: torrent.hash)
                    .environment(syncService)
                    .environment(torrentService)
            } label: {
                TorrentRowView(torrent: torrent, isProcessing: isProcessing)
            }
            .contextMenu {
                let isPaused = torrent.state == .pausedDL || torrent.state == .pausedUP || torrent.state == .stoppedDL || torrent.state == .stoppedUP
                if isPaused {
                    Button {
                        Task { await vm.resumeTorrent(torrent) }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button {
                        Task { await vm.pauseTorrent(torrent) }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                }
                Button {
                    Task { await vm.recheckTorrent(torrent) }
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                Divider()
                Button(role: .destructive) {
                    torrentToDelete = torrent
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading) {
                if torrent.state == .pausedDL || torrent.state == .pausedUP || torrent.state == .stoppedDL || torrent.state == .stoppedUP {
                    Button {
                        Task { await vm.resumeTorrent(torrent) }
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .tint(.green)
                } else {
                    Button {
                        Task { await vm.pauseTorrent(torrent) }
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .leading) {
                Button {
                    Task { await vm.recheckTorrent(torrent) }
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    torrentToDelete = torrent
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing, let vm = viewModel {
            ToolbarItem(placement: torrentSelectionLeadingToolbarPlacement) {
                Button(torrentSelectAllButtonTitle(for: vm)) {
                    toggleAllTorrents(for: vm)
                }
                .disabled(vm.filteredTorrents.isEmpty)
            }

            ToolbarItem(placement: torrentSelectionDoneToolbarPlacement) {
                Button("Done") {
                    withAnimation {
                        editMode = .inactive
                        vm.clearSelection()
                    }
                }
            }

            ToolbarItemGroup(placement: torrentSelectionActionToolbarPlacement) {
                Button {
                    Task { await vm.pauseSelected() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .disabled(vm.selectedHashes.isEmpty)

                Button {
                    Task { await vm.resumeSelected() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .disabled(vm.selectedHashes.isEmpty)

                Button {
                    Task { await vm.recheckSelected() }
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .disabled(vm.selectedHashes.isEmpty)

                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(vm.selectedHashes.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: torrentLeadingToolbarPlacement) {
            }

            ToolbarItemGroup(placement: torrentTrailingToolbarPlacement) {
                Button("Add Torrent", systemImage: "plus") {
                    showAddSheet = true
                }
                .labelStyle(.iconOnly)
            }
            ToolbarSpacer(.flexible, placement: torrentTrailingToolbarPlacement)
            ToolbarItemGroup(placement: torrentTrailingToolbarPlacement) {
                if let vm = viewModel {
                    Menu {
                        ForEach(TorrentSortOrder.allCases) { order in
                            Button {
                                withAnimation { vm.sortOrder = order }
                            } label: {
                                if vm.sortOrder == order {
                                    Label(order.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(order.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: vm.sortOrder != .addedDate ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
                    }

                    Menu {
                        Toggle(isOn: Binding(
                            get: { vm.isAlternativeSpeedEnabled },
                            set: { newValue in
                                guard newValue != vm.isAlternativeSpeedEnabled else { return }
                                Task { await vm.toggleAlternativeSpeed() }
                            }
                        )) {
                            Label("Alternative Speed Mode", systemImage: "speedometer")
                        }
                        .disabled(vm.isUpdatingAlternativeSpeed)

                        Button {
                            withAnimation { editMode = .active }
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Label("More Actions", systemImage: "ellipsis")
                    }
                    .accessibilityLabel("Torrent Actions")
                    .accessibilityHint("Shows more torrent list actions")
                }
            }
        }
    }

    private var activeServerName: String {
        servers.first(where: { $0.isActive })?.displayName
            ?? servers.first?.displayName
            ?? title
    }

    private var torrentSearchText: Binding<String> {
        Binding {
            viewModel?.searchText ?? ""
        } set: { newValue in
            viewModel?.searchText = newValue
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [ServiceIdentity.qbittorrent.brandColor.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [ServiceIdentity.qbittorrent.brandColor.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var configuredContent: some View {
        let baseContent = Group {
            if let vm = viewModel {
                torrentList(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(backgroundGradient)
        .navigationTitle(activeServerName)
        .navigationSubtitle(navigationSubtitleText)

        if shouldShowServerSwitcher {
            baseContent.toolbarTitleMenu {
                ForEach(servers) { server in
                    Button {
                        switchToServer(server)
                    } label: {
                        if server.isActive {
                            Label(server.displayName, systemImage: "checkmark")
                        } else {
                            Text(server.displayName)
                        }
                    }
                }
            }
        } else {
            baseContent
        }
    }

    private var shouldShowServerSwitcher: Bool {
        !editMode.isEditing && servers.count > 1
    }

    private var activeServerID: UUID? {
        servers.first(where: { $0.isActive })?.id ?? servers.first?.id
    }

    private func switchToServer(_ server: ServerProfile) {
        for s in servers { s.isActive = (s.id == server.id) }
        do {
            try modelContext.save()
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Switch Server",
                message: error.localizedDescription
            )
        }
    }

    private var navigationSubtitleText: String {
        guard let viewModel else { return "" }
        if editMode.isEditing {
            let count = viewModel.selectedHashes.count
            return count == 0 ? "None Selected" : count == 1 ? "1 Selected" : "\(count) Selected"
        }
        return resultSummary(for: viewModel)
    }

    private var batchDeleteAlertTitle: String {
        let count = viewModel?.selectedHashes.count ?? 0
        return count == 1 ? "Delete 1 Torrent?" : "Delete \(count) Torrents?"
    }

    private func areAllTorrentsSelected(_ vm: TorrentListViewModel) -> Bool {
        let filteredHashSet = Set(vm.filteredTorrents.map(\.hash))
        return !filteredHashSet.isEmpty && vm.selectedHashes.isSuperset(of: filteredHashSet)
    }

    private func torrentSelectAllButtonTitle(for vm: TorrentListViewModel) -> String {
        areAllTorrentsSelected(vm) ? "Deselect All" : "Select All"
    }

    private func toggleAllTorrents(for vm: TorrentListViewModel) {
        withAnimation {
            let filteredHashSet = Set(vm.filteredTorrents.map(\.hash))
            if !filteredHashSet.isEmpty && vm.selectedHashes.isSuperset(of: filteredHashSet) {
                vm.selectedHashes = []
            } else {
                vm.selectAll()
            }
        }
    }

    @ViewBuilder
    private func emptyState(for vm: TorrentListViewModel) -> some View {
        let query = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            ContentUnavailableView {
                Label(emptyStateTitle(for: vm.selectedFilter), systemImage: emptyStateSymbol(for: vm.selectedFilter))
            } description: {
                Text(emptyStateDescription(for: vm.selectedFilter))
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func resultSummary(for vm: TorrentListViewModel) -> String {
        let count = vm.filteredTorrents.count
        return count == 1 ? "1 torrent" : "\(count) torrents"
    }

    private func emptyStateTitle(for filter: TorrentFilter) -> String {
        switch filter {
        case .all: "No Torrents Yet"
        case .downloading: "No Active Downloads"
        case .seeding: "Nothing Seeding"
        case .paused: "No Paused Torrents"
        case .completed: "No Completed Torrents"
        case .errored: "No Errors"
        }
    }

    private func emptyStateDescription(for filter: TorrentFilter) -> String {
        switch filter {
        case .all: "Add a magnet link or torrent file to start downloading."
        case .downloading: "Active downloads will appear here."
        case .seeding: "Finished torrents that are uploading will appear here."
        case .paused: "Paused torrents will appear here."
        case .completed: "Completed downloads will appear here."
        case .errored: "Torrents with tracker or transfer problems will appear here."
        }
    }

    private func emptyStateSymbol(for filter: TorrentFilter) -> String {
        switch filter {
        case .all: "tray"
        case .downloading: "arrow.down.circle"
        case .seeding: "arrow.up.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .errored: "exclamationmark.triangle"
        }
    }
}

private extension TorrentFilter {
    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }
}

private var torrentSelectionLeadingToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .automatic
    #endif
}

private var torrentSelectionDoneToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .primaryAction
    #endif
}

private var torrentSelectionActionToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .bottomBar
    #else
    .automatic
    #endif
}

private var torrentLeadingToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .automatic
    #endif
}

private var torrentTrailingToolbarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .automatic
    #endif
}
