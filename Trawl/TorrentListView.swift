import SwiftUI

struct TorrentListView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @State private var viewModel: TorrentListViewModel?
    @State private var showAddSheet = false
    @State private var torrentToDelete: Torrent?
    @State private var deleteFiles = false
    private let externalSearchText: Binding<String>?
    private let showsSearchField: Bool
    private let title: String

    init(title: String = "Trawl", searchText: Binding<String>? = nil, showsSearchField: Bool = true) {
        self.title = title
        self.externalSearchText = searchText
        self.showsSearchField = showsSearchField
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                torrentList(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(navigationSubtitleText)
        .toolbarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .refreshable {
            await viewModel?.refresh()
        }
        .sheet(isPresented: $showAddSheet) {
            AddTorrentSheet()
                .environment(syncService)
                .environment(torrentService)
        }
        .navigationDestination(for: String.self) { hash in
            TorrentDetailView(torrentHash: hash)
                .environment(syncService)
                .environment(torrentService)
        }
        .alert("Delete Torrent?", isPresented: .init(
            get: { torrentToDelete != nil },
            set: { if !$0 { torrentToDelete = nil } }
        )) {
            Toggle("Also delete files", isOn: $deleteFiles)
            Button("Delete", role: .destructive) {
                if let torrent = torrentToDelete {
                    Task { await viewModel?.deleteTorrent(torrent, deleteFiles: deleteFiles) }
                }
                torrentToDelete = nil
            }
            Button("Cancel", role: .cancel) { torrentToDelete = nil }
        }
        .task {
            if viewModel == nil {
                let vm = TorrentListViewModel(syncService: syncService, torrentService: torrentService)
                viewModel = vm
                vm.searchText = currentSearchText
                vm.startSync()
            }
        }
        .onChange(of: currentSearchText) { _, newValue in
            viewModel?.searchText = newValue
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func torrentList(vm: TorrentListViewModel) -> some View {
        @Bindable var vm = vm

        if vm.filteredTorrents.isEmpty {
            emptyState(for: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(vm.filteredTorrents) { torrent in
                    NavigationLink(value: torrent.hash) {
                        TorrentRowView(torrent: torrent)
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            torrentToDelete = torrent
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let vm = viewModel {
                Menu {
                    ForEach(TorrentFilter.allCases) { filter in
                        Button {
                            vm.selectedFilter = filter
                        } label: {
                            if vm.selectedFilter == filter {
                                Label(filterLabel(for: filter, vm: vm), systemImage: "checkmark")
                            } else {
                                Text(filterLabel(for: filter, vm: vm))
                            }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filterIcon(for: vm.selectedFilter))
                }

                Menu {
                    ForEach(TorrentSortOrder.allCases) { order in
                        Button {
                            vm.sortOrder = order
                        } label: {
                            if vm.sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Add Torrent", systemImage: "plus") {
                showAddSheet = true
            }
            .labelStyle(.iconOnly)
        }
    }

    private var resolvedSearchBinding: Binding<String> {
        if let externalSearchText {
            return externalSearchText
        }

        return Binding(
            get: { viewModel?.searchText ?? "" },
            set: { viewModel?.searchText = $0 }
        )
    }

    private var currentSearchText: String {
        resolvedSearchBinding.wrappedValue
    }

    private var navigationSubtitleText: String {
        guard let viewModel else { return "" }
        return resultSummary(for: viewModel)
    }

    private func countForFilter(_ filter: TorrentFilter, vm: TorrentListViewModel) -> Int {
        let all = Array(syncService.torrents.values)
        switch filter {
        case .all: return all.count
        case .downloading: return all.filter { $0.state.filterCategory == .downloading }.count
        case .seeding: return all.filter { $0.state.filterCategory == .seeding }.count
        case .paused: return all.filter { $0.state.filterCategory == .paused }.count
        case .completed: return all.filter { $0.state.isCompleted }.count
        case .errored: return all.filter { $0.state.filterCategory == .errored }.count
        }
    }

    private func filterLabel(for filter: TorrentFilter, vm: TorrentListViewModel) -> String {
        let count = countForFilter(filter, vm: vm)
        if filter == .all {
            return count == 1 ? "All (1)" : "All (\(count))"
        }
        return "\(filter.rawValue) (\(count))"
    }

    private func filterIcon(for filter: TorrentFilter) -> String {
        switch filter {
        case .all: "line.3.horizontal.decrease.circle"
        case .downloading: "arrow.down.circle"
        case .seeding: "arrow.up.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .errored: "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private func emptyState(for vm: TorrentListViewModel) -> some View {
        if !currentSearchText.isEmpty {
            ContentUnavailableView.search
        } else {
            ContentUnavailableView {
                Label(emptyStateTitle(for: vm.selectedFilter), systemImage: emptyStateSymbol(for: vm.selectedFilter))
            } description: {
                Text(emptyStateDescription(for: vm.selectedFilter))
            }
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
