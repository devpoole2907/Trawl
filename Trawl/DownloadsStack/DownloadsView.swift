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

    init() {}

    func show(_ section: DownloadSection) {
        requestedSection = section
    }
}

/// Toolbar overflow destinations for the Downloads tab.
enum DownloadsManagementRoute: Hashable {
    case clients
    case blocklist
}

struct DownloadsView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    /// Optional so previews and any host that doesn't inject a navigator still work.
    @Environment(DownloadsNavigator.self) private var downloadsNavigator: DownloadsNavigator?
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    @State private var viewModel = DownloadsViewModel()
    @State private var selectedSection: DownloadSection
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
            .onAppear {
                // Catches a request made while this view wasn't mounted yet.
                applyRequestedSection(downloadsNavigator?.requestedSection)
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
            .onChange(of: hasQBittorrentServer) { _, _ in
                // Removing the last torrent client while sitting on Seeding would otherwise
                // strand the user on a segment that no longer has a tab.
                if !visibleSections.contains(selectedSection) {
                    withAnimation { selectedSection = .active }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Client Management and the Blocklist are both "look at the
                    // plumbing" destinations rather than per-download actions, so
                    // they share one overflow menu and leave Add Download as the
                    // only bare button.
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

                    // SABnzbd-only setups get an Add button too; the sheet routes
                    // the torrent/NZB/URL source itself.
                    if hasQBittorrentServer || hasSABnzbdServer {
                        Button("Add Download", systemImage: "plus") {
                            showAddTorrent = true
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            .navigationDestination(item: $managementRoute) { route in
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
                }
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
                arrQueueRemovalActions(item: target.item, source: target.source)
                Button("Cancel", role: .cancel) { queueActionTarget = nil }
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
    }

    @ViewBuilder
    private var content: some View {
        if arrServiceManager.isLoadingQueue && items.isEmpty {
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
            .contextMenu { torrentActions(for: torrent) }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if isPaused(torrent) {
                    Button("Resume", systemImage: "play.fill") {
                        performTorrentAction { try await torrentService.resumeTorrents(hashes: [torrent.hash]) }
                    }
                    .tint(.green)
                } else {
                    Button("Pause", systemImage: "pause.fill") {
                        performTorrentAction { try await torrentService.pauseTorrents(hashes: [torrent.hash]) }
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    torrentPendingDeletion = torrent
                }
                Button("Recheck", systemImage: "arrow.clockwise") {
                    performTorrentAction { try await torrentService.recheckTorrents(hashes: [torrent.hash]) }
                }
                .tint(.blue)
            }

        case .arrQueue(let queueItem, let source, let linkedTorrent, let linkedSABJob):
            arrQueueRow(
                item: queueItem,
                source: source,
                linkedTorrent: linkedTorrent,
                linkedSABJob: linkedSABJob
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
                                performSABAction { try await sabnzbdServiceManager.resume(job: job) }
                            }
                            .tint(.green)
                        } else {
                            Button("Pause", systemImage: "pause.fill") {
                                performSABAction { try await sabnzbdServiceManager.pause(job: job) }
                            }
                            .tint(.orange)
                        }
                    } else if job.normalizedStatus == .failed {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            performSABAction { try await sabnzbdServiceManager.retry(job: job) }
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
        linkedSABJob: SABnzbdJob?
    ) -> some View {
        let target = ArrQueueActionTarget(
            item: item,
            source: source,
            linkedTorrent: linkedTorrent,
            linkedSABJob: linkedSABJob
        )
        let isInFlight = queueActionInFlightIDs.contains(target.id)

        Group {
            if let linkedTorrent {
                NavigationLink {
                    TorrentDetailView(torrentHash: linkedTorrent.hash)
                        .environment(syncService)
                        .environment(torrentService)
                } label: {
                    ArrInfoRowView(queueItem: item, source: source, linkedTorrent: linkedTorrent)
                }
            } else {
                Button {
                    queueActionTarget = target
                } label: {
                    ArrInfoRowView(queueItem: item, source: source)
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
            arrQueueRemovalActions(item: item, source: source)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "xmark.circle", role: .destructive) {
                performQueueAction(item: item, source: source, blocklist: false, searchAgain: false)
            }
            Button("Blocklist", systemImage: "hand.raised") {
                performQueueAction(item: item, source: source, blocklist: true, searchAgain: false)
            }
            .tint(.orange)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if DownloadsViewModel.canSearchAgain(item, source: source) {
                Button("Search Again", systemImage: "magnifyingglass") {
                    performQueueAction(item: item, source: source, blocklist: true, searchAgain: true)
                }
                .tint(.blue)
            }
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

    // MARK: - Row actions

    // `includesSeparators` is off inside confirmation dialogs, which drop any
    // non-button content anyway.
    @ViewBuilder
    private func torrentActions(for torrent: Torrent, includesSeparators: Bool = true) -> some View {
        if isPaused(torrent) {
            Button("Resume", systemImage: "play.fill") {
                performTorrentAction { try await torrentService.resumeTorrents(hashes: [torrent.hash]) }
            }
        } else {
            Button("Pause", systemImage: "pause.fill") {
                performTorrentAction { try await torrentService.pauseTorrents(hashes: [torrent.hash]) }
            }
        }
        Button("Recheck", systemImage: "arrow.clockwise") {
            performTorrentAction { try await torrentService.recheckTorrents(hashes: [torrent.hash]) }
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
                    performSABAction { try await sabnzbdServiceManager.resume(job: job) }
                }
            } else {
                Button("Pause", systemImage: "pause.fill") {
                    performSABAction { try await sabnzbdServiceManager.pause(job: job) }
                }
            }
        }
        if job.normalizedStatus == .failed {
            Button("Retry", systemImage: "arrow.clockwise") {
                performSABAction { try await sabnzbdServiceManager.retry(job: job) }
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
    private func arrQueueRemovalActions(item: ArrQueueItem, source: ArrServiceType) -> some View {
        Button("Remove from Queue", systemImage: "xmark.circle", role: .destructive) {
            performQueueAction(item: item, source: source, blocklist: false, searchAgain: false)
        }
        Button("Blocklist & Remove", systemImage: "hand.raised", role: .destructive) {
            performQueueAction(item: item, source: source, blocklist: true, searchAgain: false)
        }
        if DownloadsViewModel.canSearchAgain(item, source: source) {
            Button("Blocklist & Search Again", systemImage: "magnifyingglass") {
                performQueueAction(item: item, source: source, blocklist: true, searchAgain: true)
            }
        }
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
        blocklist: Bool,
        searchAgain: Bool
    ) {
        queueActionTarget = nil
        let key = ArrQueueActionTarget.id(for: item, source: source)
        guard !queueActionInFlightIDs.contains(key) else { return }
        queueActionInFlightIDs.insert(key)

        Task { @MainActor in
            defer { queueActionInFlightIDs.remove(key) }
            let failure = await viewModel.removeQueueItem(
                item,
                source: source,
                blocklist: blocklist,
                searchAgain: searchAgain,
                serviceManager: arrServiceManager
            )
            if let failure {
                InAppNotificationCenter.shared.showError(title: "Queue Action Failed", message: failure)
            } else if searchAgain {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Searching Again",
                    message: "The release was blocklisted and a new search was started."
                )
            } else if blocklist {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Blocked",
                    message: "The queue item was removed and blocklisted."
                )
            } else {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Removed",
                    message: "The queue item was removed from \(source.displayName)."
                )
            }
        }
    }

    private func deletePendingTorrent(deleteFiles: Bool) {
        guard let torrent = torrentPendingDeletion else { return }
        torrentPendingDeletion = nil
        performTorrentAction {
            try await torrentService.deleteTorrents(hashes: [torrent.hash], deleteFiles: deleteFiles)
        }
    }

    private func deletePendingSABJob(deleteFiles: Bool) {
        guard let job = sabJobPendingDeletion else { return }
        sabJobPendingDeletion = nil
        performSABAction {
            if job.source == .queue {
                try await sabnzbdServiceManager.delete(job: job, deleteFiles: deleteFiles)
            } else {
                try await sabnzbdServiceManager.deleteHistory(job: job, permanently: true, deleteFiles: deleteFiles)
            }
        }
    }

    /// qBittorrent commands don't push, so pull a fresh sync rather than waiting
    /// out the poll interval.
    private func performTorrentAction(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
                await syncService.refreshNow()
            } catch {
                InAppNotificationCenter.shared.showError(
                    title: "Torrent Action Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    /// `SABnzbdServiceManager` refreshes itself after each job action.
    private func performSABAction(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                InAppNotificationCenter.shared.showError(
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
        case .issues: "exclamationmark.triangle"
        }
    }

    private var navigationSubtitle: String {
        let count = items.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    /// Seeding is a torrent-only concept — a Usenet job never seeds — so the segment is
    /// dropped entirely when no torrent client is configured rather than sitting there
    /// permanently empty.
    private var visibleSections: [DownloadSection] {
        guard !hasQBittorrentServer else { return DownloadSection.allCases }
        return DownloadSection.allCases.filter { $0 != .seeding }
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

    var id: String { Self.id(for: item, source: source) }

    static func id(for item: ArrQueueItem, source: ArrServiceType) -> String {
        "\(source.rawValue)-\(item.id)"
    }
}

private extension DownloadSection {
    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }
}
