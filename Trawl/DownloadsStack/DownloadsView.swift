import SwiftData
import SwiftUI

struct DownloadsView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    @State private var viewModel = DownloadsViewModel()
    @State private var selectedSection: DownloadSection
    @State private var isSearchExpanded = false
    @State private var showAddTorrent = false

    init(initialSection: DownloadSection = .active) {
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        content
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
                    items: DownloadSection.allCases.map(\.segmentBarItem),
                    searchText: $viewModel.searchText,
                    searchHint: "Search downloads",
                    isSearchExpanded: $isSearchExpanded,
                    searchPlacement: .leading,
                    alignment: .leading
                )
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink {
                        DownloadClientManagementView()
                            .environment(syncService)
                            .environment(torrentService)
                            .environment(sabnzbdServiceManager)
                    } label: {
                        Label("Client Management", systemImage: "server.rack")
                    }

                    if hasQBittorrentServer {
                        Button("Add Torrent", systemImage: "plus") {
                            showAddTorrent = true
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            .sheet(isPresented: $showAddTorrent) {
                AddTorrentSheet()
                    .environment(syncService)
                    .environment(torrentService)
            }
            .task(id: reloadKey) {
                await viewModel.refresh(serviceManager: arrServiceManager)
            }
            .task {
                await sabnzbdServiceManager.refresh()
                sabnzbdServiceManager.startPolling()
            }
            .onDisappear {
                sabnzbdServiceManager.stopPolling()
            }
            .refreshable {
                async let arrRefresh: Void = viewModel.refresh(serviceManager: arrServiceManager)
                async let torrentRefresh: Void = syncService.refreshNow()
                async let sabRefresh: Void = sabnzbdServiceManager.refresh()
                _ = await (arrRefresh, torrentRefresh, sabRefresh)
            }
    }

    private var items: [DownloadListItem] {
        viewModel.items(
            for: selectedSection,
            torrents: syncService.torrents,
            sabActiveJobs: sabnzbdServiceManager.activeJobs,
            sabHistoryJobs: sabnzbdServiceManager.historyJobs
        )
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isRefreshing && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage,
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

        case .arrQueue(let queueItem, let source, let linkedTorrent, _):
            if let linkedTorrent {
                NavigationLink {
                    TorrentDetailView(torrentHash: linkedTorrent.hash)
                        .environment(syncService)
                        .environment(torrentService)
                } label: {
                    ArrInfoRowView(queueItem: queueItem, source: source, linkedTorrent: linkedTorrent)
                }
            } else {
                ArrInfoRowView(queueItem: queueItem, source: source)
            }

        case .arrHistory(let historyItem):
            HistoryRow(item: historyItem)

        case .sab(let job):
            sabRow(for: job)
        }
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
            ArrReleaseInfoChip(job.size, color: .secondary),
            ArrReleaseInfoChip("SABnzbd", color: .indigo)
        ]
        if let category = job.category, !category.isEmpty {
            chips.insert(ArrReleaseInfoChip(category, color: .primary), at: 1)
        }
        return chips
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
        case .seeding: "Nothing Seeding"
        case .history: "No Download History"
        case .issues: "No Download Issues"
        }
    }

    private var emptyDescription: String {
        switch selectedSection {
        case .active: "Downloads, repairs, unpacking, and imports in progress will appear here."
        case .queue: "Downloads waiting for a client or import will appear here."
        case .seeding: "Completed torrents that are uploading will appear here."
        case .history: "Completed grabs and imports will appear here."
        case .issues: "Client failures and imports requiring attention will appear here."
        }
    }

    private var emptySystemImage: String {
        switch selectedSection {
        case .active: "arrow.down.circle"
        case .queue: "tray"
        case .seeding: "arrow.up.circle"
        case .history: "clock.arrow.circlepath"
        case .issues: "checkmark.circle"
        }
    }

    private var navigationSubtitle: String {
        let count = items.count
        return count == 1 ? "1 item" : "\(count) items"
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

private extension DownloadSection {
    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }
}
