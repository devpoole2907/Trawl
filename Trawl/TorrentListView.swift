import SwiftUI

struct TorrentListView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @State private var viewModel: TorrentListViewModel?
    @State private var showAddSheet = false
    @State private var showSettings = false
    @State private var torrentToDelete: Torrent?
    @State private var deleteFiles = false

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    torrentList(vm: vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Trawl")
            .toolbar { toolbarContent }
            .searchable(text: searchBinding, prompt: "Search torrents")
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
                    vm.startSync()
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func torrentList(vm: TorrentListViewModel) -> some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TorrentFilter.allCases) { filter in
                        FilterChip(
                            title: filter.rawValue,
                            isSelected: vm.selectedFilter == filter,
                            count: countForFilter(filter, vm: vm)
                        ) {
                            vm.selectedFilter = filter
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            // Sort menu
            HStack {
                Text("\(vm.filteredTorrents.count) torrents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // Torrent list
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
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
                if let vm = viewModel {
                    Label(ByteFormatter.formatSpeed(bytesPerSecond: vm.globalDownloadSpeed), systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Label(ByteFormatter.formatSpeed(bytesPerSecond: vm.globalUploadSpeed), systemImage: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                        .environment(syncService)
                        .environment(torrentService)
                }
            }
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { viewModel?.searchText ?? "" },
            set: { viewModel?.searchText = $0 }
        )
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
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isSelected ? .white.opacity(0.3) : .secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .font(.caption)
            .fontWeight(isSelected ? .semibold : .regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
