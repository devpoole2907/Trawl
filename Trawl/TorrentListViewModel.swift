import Foundation
import Observation

@Observable
final class TorrentListViewModel {
    var selectedFilter: TorrentFilter = .all
    var searchText: String = ""
    var sortOrder: TorrentSortOrder = .name
    var actionError: String?

    private let syncService: SyncService
    private let torrentService: TorrentService

    init(syncService: SyncService, torrentService: TorrentService) {
        self.syncService = syncService
        self.torrentService = torrentService
    }

    // MARK: - Derived State

    var filteredTorrents: [Torrent] {
        var result = Array(syncService.torrents.values)

        // Apply filter
        switch selectedFilter {
        case .all:
            break
        case .downloading:
            result = result.filter { $0.state.filterCategory == .downloading }
        case .seeding:
            result = result.filter { $0.state.filterCategory == .seeding }
        case .paused:
            result = result.filter { $0.state.filterCategory == .paused }
        case .completed:
            result = result.filter { $0.state.isCompleted }
        case .errored:
            result = result.filter { $0.state.filterCategory == .errored }
        }

        // Apply search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(query) }
        }

        // Apply sort
        result.sort { a, b in
            switch sortOrder {
            case .name:
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .addedDate:
                a.addedOn > b.addedOn
            case .size:
                a.size > b.size
            case .progress:
                a.progress > b.progress
            case .downloadSpeed:
                a.dlspeed > b.dlspeed
            case .uploadSpeed:
                a.upspeed > b.upspeed
            case .eta:
                a.eta < b.eta
            }
        }

        return result
    }

    var globalDownloadSpeed: Int64 { syncService.serverState?.dlInfoSpeed ?? 0 }
    var globalUploadSpeed: Int64 { syncService.serverState?.upInfoSpeed ?? 0 }
    var isPolling: Bool { syncService.isPolling }
    var syncError: QBError? { syncService.lastError }
    var categories: [String] { syncService.sortedCategoryNames }

    // MARK: - Actions

    func startSync() {
        syncService.startPolling()
    }

    func stopSync() {
        syncService.stopPolling()
    }

    func refresh() async {
        await syncService.refreshNow()
    }

    func pauseTorrent(_ torrent: Torrent) async {
        do {
            try await torrentService.pauseTorrents(hashes: [torrent.hash])
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    func resumeTorrent(_ torrent: Torrent) async {
        do {
            try await torrentService.resumeTorrents(hashes: [torrent.hash])
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    func deleteTorrent(_ torrent: Torrent, deleteFiles: Bool) async {
        do {
            try await torrentService.deleteTorrents(hashes: [torrent.hash], deleteFiles: deleteFiles)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
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
