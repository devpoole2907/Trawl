import Foundation
import Observation

@Observable
final class SyncService {
    // MARK: - Published State (read by ViewModels)
    private(set) var torrents: [String: Torrent] = [:]
    private(set) var categories: [String: SyncCategory] = [:]
    private(set) var tags: [String] = []
    private(set) var serverState: ServerState?
    private(set) var isPolling: Bool = false
    private(set) var lastError: QBError?
    var defaultSavePath: String?

    // MARK: - Internal State
    private var rid: Int = 0
    private var pollingTask: Task<Void, Never>?
    private let apiClient: QBittorrentAPIClient
    var pollingInterval: TimeInterval = 2.0

    init(apiClient: QBittorrentAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Sorted accessors

    /// All torrents as a sorted array (by name)
    var sortedTorrents: [Torrent] {
        torrents.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Category names sorted alphabetically
    var sortedCategoryNames: [String] {
        categories.keys.sorted()
    }

    // MARK: - Polling Control

    func startPolling() {
        guard pollingTask == nil else { return }
        isPolling = true
        rid = 0

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let data = try await self.apiClient.syncMainData(rid: self.rid)
                    self.applyDelta(data)
                    self.rid = data.rid
                    self.lastError = nil
                } catch {
                    self.lastError = error as? QBError ?? .networkError(error)
                }
                try? await Task.sleep(for: .seconds(self.pollingInterval))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    /// Force an immediate poll cycle (e.g. pull-to-refresh).
    /// Preserves the current rid so we get a delta, not a full refresh.
    func refreshNow() async {
        do {
            let data = try await apiClient.syncMainData(rid: rid)
            applyDelta(data)
            rid = data.rid
            lastError = nil
        } catch {
            lastError = error as? QBError ?? .networkError(error)
        }
    }

    // MARK: - Delta Application

    private func applyDelta(_ data: SyncMainData) {
        let isFullUpdate = data.fullUpdate == true

        // --- Torrents ---
        if isFullUpdate {
            // Full update: build a fresh dict and assign in one shot
            var fresh: [String: Torrent] = [:]
            if let newTorrents = data.torrents {
                for (hash, syncData) in newTorrents {
                    fresh[hash] = Torrent.fromDelta(hash: hash, delta: syncData)
                }
            }
            if let removed = data.torrentsRemoved {
                for hash in removed { fresh.removeValue(forKey: hash) }
            }
            torrents = fresh
        } else {
            // Partial update: batch all mutations into a single assignment so
            // @Observable fires exactly one notification instead of one per torrent.
            var updated = torrents
            if let updatedTorrents = data.torrents {
                for (hash, delta) in updatedTorrents {
                    if let existing = updated[hash] {
                        updated[hash] = existing.applying(delta: delta)
                    } else {
                        updated[hash] = Torrent.fromDelta(hash: hash, delta: delta)
                    }
                }
            }
            if let removed = data.torrentsRemoved {
                for hash in removed { updated.removeValue(forKey: hash) }
            }
            torrents = updated
        }

        // --- Categories ---
        if isFullUpdate, let newCategories = data.categories {
            categories = newCategories
        } else if let updatedCategories = data.categories {
            for (name, cat) in updatedCategories {
                categories[name] = cat
            }
        }

        if let removedCategories = data.categoriesRemoved {
            for name in removedCategories {
                categories.removeValue(forKey: name)
            }
        }

        // --- Tags ---
        if let newTags = data.tags {
            if isFullUpdate {
                tags = newTags
            } else {
                let existing = Set(tags)
                let additions = newTags.filter { !existing.contains($0) }
                tags.append(contentsOf: additions)
            }
        }

        if let removedTags = data.tagsRemoved {
            let removeSet = Set(removedTags)
            tags.removeAll { removeSet.contains($0) }
        }

        // --- Server State ---
        if let newState = data.serverState {
            if let existing = serverState {
                serverState = existing.merging(newState)
            } else {
                serverState = newState
            }
        }
    }
}
