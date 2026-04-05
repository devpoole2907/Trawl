import Foundation
import Observation

@Observable
final class TorrentListViewModel {
    var selectedFilter: TorrentFilter = .all
    var searchText: String = ""
    var sortOrder: TorrentSortOrder = .addedDate
    var actionErrorAlert: ErrorAlertItem?

    // Cached off-main — only recomputed when inputs change
    private(set) var filteredTorrents: [Torrent] = []
    private(set) var filterCounts: [TorrentFilter: Int] = [:]

    private let syncService: SyncService
    private let torrentService: TorrentService
    private var filterTask: Task<Void, Never>?

    init(syncService: SyncService, torrentService: TorrentService) {
        self.syncService = syncService
        self.torrentService = torrentService
    }

    // MARK: - Passthrough State

    var globalDownloadSpeed: Int64 { syncService.serverState?.dlInfoSpeed ?? 0 }
    var globalUploadSpeed: Int64 { syncService.serverState?.upInfoSpeed ?? 0 }
    var isPolling: Bool { syncService.isPolling }
    var syncError: QBError? { syncService.lastError }
    var categories: [String] { syncService.sortedCategoryNames }

    // MARK: - Sync

    func startSync() {
        syncService.startPolling()
        scheduleFilterUpdate()
        registerObservation()
    }

    func stopSync() {
        syncService.stopPolling()
        filterTask?.cancel()
    }

    func refresh() async {
        await syncService.refreshNow()
    }

    // MARK: - Observation

    /// Re-registers after each change so we react to every future update.
    @MainActor
    private func registerObservation() {
        withObservationTracking {
            _ = syncService.torrents
            _ = selectedFilter
            _ = searchText
            _ = sortOrder
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleFilterUpdate()
                self.registerObservation()
            }
        }
    }

    /// Cancels any in-flight work and starts a new computation on a background thread.
    private func scheduleFilterUpdate() {
        filterTask?.cancel()
        let snapshot = syncService.torrents
        let filter = selectedFilter
        let search = searchText
        let sort = sortOrder
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.compute(torrents: snapshot, filter: filter, searchText: search, sortOrder: sort)
            await MainActor.run { [weak self] in
                self?.filteredTorrents = result.sorted
                self?.filterCounts = result.counts
            }
        }
    }

    /// Pure, nonisolated — safe to run on any thread.
    nonisolated private static func compute(
        torrents: [String: Torrent],
        filter: TorrentFilter,
        searchText: String,
        sortOrder: TorrentSortOrder
    ) -> (sorted: [Torrent], counts: [TorrentFilter: Int]) {
        let all = Array(torrents.values)

        // Compute all filter counts in a single pass
        var counts: [TorrentFilter: Int] = [
            .all: all.count,
            .downloading: 0, .seeding: 0, .paused: 0, .completed: 0, .errored: 0
        ]
        for torrent in all {
            switch torrent.state.filterCategory {
            case .downloading: counts[.downloading]! += 1
            case .seeding:     counts[.seeding]! += 1
            case .paused:      counts[.paused]! += 1
            case .errored:     counts[.errored]! += 1
            default:           break
            }
            if torrent.state.isCompleted { counts[.completed]! += 1 }
        }

        // Filter
        var result = all
        switch filter {
        case .all:         break
        case .downloading: result = result.filter { $0.state.filterCategory == .downloading }
        case .seeding:     result = result.filter { $0.state.filterCategory == .seeding }
        case .paused:      result = result.filter { $0.state.filterCategory == .paused }
        case .completed:   result = result.filter { $0.state.isCompleted }
        case .errored:     result = result.filter { $0.state.filterCategory == .errored }
        }

        // Search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(query) }
        }

        // Sort
        result.sort { a, b in
            switch sortOrder {
            case .name:          a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .addedDate:     a.addedOn > b.addedOn
            case .size:          a.size > b.size
            case .progress:      a.progress > b.progress
            case .downloadSpeed: a.dlspeed > b.dlspeed
            case .uploadSpeed:   a.upspeed > b.upspeed
            case .eta:           a.eta < b.eta
            }
        }

        return (result, counts)
    }

    // MARK: - Actions

    func pauseTorrent(_ torrent: Torrent) async {
        do {
            try await torrentService.pauseTorrents(hashes: [torrent.hash])
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Pause Torrent",
                message: error.localizedDescription
            )
        }
    }

    func resumeTorrent(_ torrent: Torrent) async {
        do {
            try await torrentService.resumeTorrents(hashes: [torrent.hash])
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Resume Torrent",
                message: error.localizedDescription
            )
        }
    }

    func recheckTorrent(_ torrent: Torrent) async {
        do {
            try await torrentService.recheckTorrents(hashes: [torrent.hash])
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Recheck Torrent",
                message: error.localizedDescription
            )
        }
    }

    func deleteTorrent(_ torrent: Torrent, deleteFiles: Bool) async {
        do {
            try await torrentService.deleteTorrents(hashes: [torrent.hash], deleteFiles: deleteFiles)
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: deleteFiles ? "Couldn't Delete Torrent and Files" : "Couldn't Delete Torrent",
                message: error.localizedDescription
            )
        }
    }
}

enum TorrentSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case addedDate = "Date Added"
    case size = "Size"
    case progress = "Progress"
    case downloadSpeed = "Download Speed"
    case uploadSpeed = "Upload Speed"
    case eta = "ETA"

    var id: String { rawValue }
}
