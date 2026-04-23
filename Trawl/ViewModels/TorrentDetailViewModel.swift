import Foundation
import Observation

@MainActor
@Observable
final class TorrentDetailViewModel {
    let torrentHash: String
    var files: [TorrentFile] = []
    var trackers: [TorrentTracker] = []
    var properties: TorrentProperties?
    var isLoading: Bool = false
    var error: String?
    var actionErrorAlert: ErrorAlertItem?

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

    /// Available tags from sync
    var availableTags: [String] { syncService.sortedTags }

    var currentTags: [String] {
        guard let rawTags = torrent?.tags else { return [] }
        return rawTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

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
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Pause Torrent",
                message: error.localizedDescription
            )
        }
    }

    func resume() async {
        do {
            try await torrentService.resumeTorrents(hashes: [torrentHash])
            error = nil
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Resume Torrent",
                message: error.localizedDescription
            )
        }
    }

    func recheck() async {
        do {
            try await torrentService.recheckTorrents(hashes: [torrentHash])
            error = nil
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Recheck Torrent",
                message: error.localizedDescription
            )
        }
    }

    func deleteTorrent(deleteFiles: Bool) async -> Bool {
        do {
            try await torrentService.deleteTorrents(hashes: [torrentHash], deleteFiles: deleteFiles)
            error = nil
            actionErrorAlert = nil
            return true
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: deleteFiles ? "Couldn't Delete Torrent and Files" : "Couldn't Delete Torrent",
                message: error.localizedDescription
            )
            return false
        }
    }

    func rename(to newName: String) async {
        guard !newName.isEmpty else { return }
        do {
            try await torrentService.renameTorrent(hash: torrentHash, name: newName)
            error = nil
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Rename Torrent",
                message: error.localizedDescription
            )
        }
    }

    func setLocation(_ path: String) async {
        guard !path.isEmpty else { return }
        do {
            try await torrentService.setTorrentLocation(hashes: [torrentHash], location: path)
            error = nil
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Move Torrent",
                message: error.localizedDescription
            )
        }
    }

    func setCategory(_ category: String) async {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await torrentService.setTorrentCategory(hashes: [torrentHash], category: normalizedCategory)
            if !normalizedCategory.isEmpty {
                syncService.addCategoryLocally(name: normalizedCategory, savePath: nil)
            }
            syncService.setTorrentCategoryLocally(hash: torrentHash, category: normalizedCategory)
            await syncService.refreshNow()
            error = nil
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Change Category",
                message: error.localizedDescription
            )
        }
    }

    func toggleTag(_ tag: String) async {
        let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTag.isEmpty else { return }

        let containsTag = currentTags.contains { $0.caseInsensitiveCompare(normalizedTag) == .orderedSame }

        do {
            if containsTag {
                try await torrentService.removeTorrentTags(hashes: [torrentHash], tags: [normalizedTag])
                syncService.removeTagsFromTorrentLocally(hash: torrentHash, tags: [normalizedTag])
            } else {
                try await torrentService.addTorrentTags(hashes: [torrentHash], tags: [normalizedTag])
                syncService.addTagLocally(name: normalizedTag)
                syncService.addTagsToTorrentLocally(hash: torrentHash, tags: [normalizedTag])
            }
            await syncService.refreshNow()
            error = nil
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: containsTag ? "Couldn't Remove Tag" : "Couldn't Add Tag",
                message: error.localizedDescription
            )
        }
    }

    func setTorrentDownloadLimit(_ limit: Int64) async {
        do {
            try await torrentService.setTorrentDownloadLimit(hashes: [torrentHash], limit: limit)
            await loadProperties()
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Set Download Limit",
                message: error.localizedDescription
            )
        }
    }

    func setTorrentUploadLimit(_ limit: Int64) async {
        do {
            try await torrentService.setTorrentUploadLimit(hashes: [torrentHash], limit: limit)
            await loadProperties()
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Set Upload Limit",
                message: error.localizedDescription
            )
        }
    }
}
