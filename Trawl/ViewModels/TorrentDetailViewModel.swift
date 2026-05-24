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
    private(set) var isUpdatingSequentialDownload = false
    private(set) var isUpdatingFirstLastPiecePriority = false
    // Optimistic local overrides; nil defers to live torrent state
    private var optimisticSequentialDownload: Bool? = nil
    private var optimisticFirstLastPiecePriority: Bool? = nil
    #if DEBUG
    private var previewTorrent: Torrent?
    private var previewCategories: [String]?
    private var previewTags: [String]?
    #endif

    private let torrentService: TorrentService
    private let syncService: SyncService
    private let notificationCenter: InAppNotificationCenter

    init(torrentHash: String, torrentService: TorrentService, syncService: SyncService, notificationCenter: InAppNotificationCenter? = nil) {
        self.torrentHash = torrentHash
        self.torrentService = torrentService
        self.syncService = syncService
        self.notificationCenter = notificationCenter ?? .shared
    }

    /// Live torrent data from sync
    var torrent: Torrent? {
        #if DEBUG
        if let previewTorrent { return previewTorrent }
        #endif
        return syncService.torrents[torrentHash]
    }

    /// Available categories from sync
    var availableCategories: [String] {
        #if DEBUG
        if let previewCategories { return previewCategories }
        #endif
        return syncService.sortedCategoryNames
    }

    /// Available tags from sync
    var availableTags: [String] {
        #if DEBUG
        if let previewTags { return previewTags }
        #endif
        return syncService.sortedTags
    }

    var currentTags: [String] {
        guard let rawTags = torrent?.tags else { return [] }
        return rawTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isSequentialDownloadEnabled: Bool {
        optimisticSequentialDownload ?? torrent?.sequentialDownload ?? false
    }

    var isFirstLastPiecePriorityEnabled: Bool {
        optimisticFirstLastPiecePriority ?? torrent?.firstLastPiecePriority ?? false
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
            await syncService.refreshNow()
            notificationCenter.showSuccess(title: "Paused", message: torrent?.name ?? "")
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
            await syncService.refreshNow()
            notificationCenter.showSuccess(title: "Resumed", message: torrent?.name ?? "")
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
            await syncService.refreshNow()
            notificationCenter.showSuccess(title: "Rechecking", message: torrent?.name ?? "")
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Recheck Torrent",
                message: error.localizedDescription
            )
        }
    }

    func deleteTorrent(deleteFiles: Bool) async -> Bool {
        do {
            let name = torrent?.name ?? ""
            try await torrentService.deleteTorrents(hashes: [torrentHash], deleteFiles: deleteFiles)
            error = nil
            actionErrorAlert = nil
            await syncService.refreshNow()
            notificationCenter.showSuccess(title: "Deleted", message: name)
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
            await syncService.refreshNow()
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
            await syncService.refreshNow()
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

    // qBittorrent's toggle endpoints flip server state rather than setting a specific value.
    // We apply an optimistic local change immediately, then refresh and re-check the live
    // state before calling the toggle to avoid double-toggling if a sync beat us to it.
    func setSequentialDownload(_ enabled: Bool) async {
        guard !isUpdatingSequentialDownload else { return }
        guard isSequentialDownloadEnabled != enabled else { return }

        isUpdatingSequentialDownload = true
        optimisticSequentialDownload = enabled
        defer {
            isUpdatingSequentialDownload = false
            optimisticSequentialDownload = nil
        }

        do {
            await syncService.refreshNow()
            let liveEnabled = torrent?.sequentialDownload ?? false
            if liveEnabled != enabled {
                try await torrentService.toggleSequentialDownload(hashes: [torrentHash])
                await syncService.refreshNow()
            }
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Change Sequential Download",
                message: error.localizedDescription
            )
        }
    }

    func setFirstLastPiecePriority(_ enabled: Bool) async {
        guard !isUpdatingFirstLastPiecePriority else { return }
        guard isFirstLastPiecePriorityEnabled != enabled else { return }

        isUpdatingFirstLastPiecePriority = true
        optimisticFirstLastPiecePriority = enabled
        defer {
            isUpdatingFirstLastPiecePriority = false
            optimisticFirstLastPiecePriority = nil
        }

        do {
            await syncService.refreshNow()
            let liveEnabled = torrent?.firstLastPiecePriority ?? false
            if liveEnabled != enabled {
                try await torrentService.toggleFirstLastPiecePriority(hashes: [torrentHash])
                await syncService.refreshNow()
            }
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Change First and Last Piece Priority",
                message: error.localizedDescription
            )
        }
    }
}

#if DEBUG
extension TorrentDetailViewModel {
    convenience init(
        previewTorrent: Torrent = .preview,
        files: [TorrentFile] = TorrentFile.previewList,
        trackers: [TorrentTracker] = TorrentTracker.previewList,
        properties: TorrentProperties? = TorrentProperties.preview,
        isLoading: Bool = false,
        error: String? = nil,
        actionErrorAlert: ErrorAlertItem? = nil,
        availableCategories: [String] = ["movies", "tv", "linux-isos"],
        availableTags: [String] = ["4k", "archived", "priority"],
        syncService: SyncService = .preview(),
        torrentService: TorrentService = .preview()
    ) {
        self.init(torrentHash: previewTorrent.hash, torrentService: torrentService, syncService: syncService)
        self.previewTorrent = previewTorrent
        self.files = files
        self.trackers = trackers
        self.properties = properties
        self.isLoading = isLoading
        self.error = error
        self.actionErrorAlert = actionErrorAlert
        self.previewCategories = availableCategories
        self.previewTags = availableTags
    }
}

extension TorrentTracker {
    static let previewList: [TorrentTracker] = [
        TorrentTracker(
            url: "udp://tracker.opentrackr.org:1337/announce",
            status: 2,
            tier: 0,
            numPeers: 54,
            numSeeds: 42,
            numLeeches: 12,
            numDownloaded: 318,
            msg: "Working"
        ),
        TorrentTracker(
            url: "https://tracker.example.org/announce",
            status: 3,
            tier: 1,
            numPeers: 8,
            numSeeds: 6,
            numLeeches: 2,
            numDownloaded: 75,
            msg: "Updating"
        ),
        TorrentTracker(
            url: "udp://offline.example.net:6969/announce",
            status: 4,
            tier: 2,
            numPeers: 0,
            numSeeds: 0,
            numLeeches: 0,
            numDownloaded: 0,
            msg: "Host not found"
        )
    ]
}
#endif
