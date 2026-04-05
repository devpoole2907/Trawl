import Foundation
import Observation

@Observable
final class TorrentDetailViewModel {
    let torrentHash: String
    var files: [TorrentFile] = []
    var trackers: [TorrentTracker] = []
    var properties: TorrentProperties?
    var isLoading: Bool = false
    var error: String?

    private let torrentService: TorrentService
    private let syncService: SyncService

    init(torrentHash: String, torrentService: TorrentService, syncService: SyncService) {
        self.torrentHash = torrentHash
        self.torrentService = torrentService
        self.syncService = syncService
    }

    /// Live torrent data from sync
    var torrent: Torrent? { syncService.torrents[torrentHash] }

    /// Available categories from sync
    var availableCategories: [String] { syncService.sortedCategoryNames }

    // MARK: - Data Loading

    func loadFiles() async {
        isLoading = true
        do {
            files = try await torrentService.getTorrentFiles(hash: torrentHash)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func loadProperties() async {
        do {
            properties = try await torrentService.getTorrentProperties(hash: torrentHash)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadTrackers() async {
        do {
            trackers = try await torrentService.getTrackers(hash: torrentHash)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Actions

    func setFilePriority(indices: [Int], priority: FilePriority) async {
        do {
            try await torrentService.setFilePriority(hash: torrentHash, fileIndices: indices, priority: priority)
            // Reload files to reflect changes
            await loadFiles()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func pause() async {
        do {
            try await torrentService.pauseTorrents(hashes: [torrentHash])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resume() async {
        do {
            try await torrentService.resumeTorrents(hashes: [torrentHash])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func recheck() async {
        do {
            try await torrentService.recheckTorrents(hashes: [torrentHash])
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteTorrent(deleteFiles: Bool) async {
        do {
            try await torrentService.deleteTorrents(hashes: [torrentHash], deleteFiles: deleteFiles)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rename(to newName: String) async {
        guard !newName.isEmpty else { return }
        do {
            try await torrentService.renameTorrent(hash: torrentHash, name: newName)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setLocation(_ path: String) async {
        guard !path.isEmpty else { return }
        do {
            try await torrentService.setTorrentLocation(hashes: [torrentHash], location: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setCategory(_ category: String) async {
        do {
            try await torrentService.setTorrentCategory(hashes: [torrentHash], category: category)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
