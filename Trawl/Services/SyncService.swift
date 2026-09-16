import Foundation
import Observation

protocol SyncDataFetching: Sendable {
    func syncMainData(rid: Int) async throws -> SyncMainData
}

extension QBittorrentAPIClient: SyncDataFetching {}

@MainActor
@Observable
final class SyncService {
    // MARK: - Published State (read by ViewModels)
    private(set) var torrents: [String: Torrent] = [:] {
        didSet { torrentsRevision &+= 1 }
    }
    /// Moves whenever `torrents` is written. Coarser than the Arr and SABnzbd
    /// revisions - this one bumps on any assignment rather than only on a real
    /// change - which costs a cache miss, never a stale read.
    private(set) var torrentsRevision: Int = 0
    private(set) var categories: [String: SyncCategory] = [:]
    private(set) var tags: [String] = []
    private(set) var serverState: ServerState?
    private(set) var isPolling: Bool = false
    private(set) var lastError: QBError?
    private(set) var activeTorrentCount: Int = 0
    var defaultSavePath: String?

    // MARK: - Speed History
    struct SpeedSample: Sendable {
        let timestamp: Date
        let dlSpeed: Int64
        let upSpeed: Int64
    }
    private(set) var speedHistory: [SpeedSample] = []
    private let maxSpeedHistoryCount = 150 // ~5 minutes at 2 s intervals

    // MARK: - Internal State
    private var rid: Int = 0
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration: UInt64 = 0
    private let apiClient: any SyncDataFetching
    var pollingInterval: TimeInterval = 2.0
    /// Stretches the automatic cadence while the server is unreachable. Read only
    /// by the polling loop - `refreshNow()` deliberately never waits on it.
    @ObservationIgnored private var backoff = PollBackoff()
    private let waitForPollingInterval: @Sendable (TimeInterval) async -> Void

    init(
        apiClient: any SyncDataFetching,
        waitForPollingInterval: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.apiClient = apiClient
        self.waitForPollingInterval = waitForPollingInterval
    }

    /// Returns the loop to base cadence without claiming a request succeeded, for
    /// when something outside the loop makes a retry worth trying immediately -
    /// the app returning to the foreground after an outage it slept through.
    func resetBackoff() {
        backoff.reset()
    }

    // MARK: - Sorted accessors

    /// Category names sorted alphabetically
    var sortedCategoryNames: [String] {
        categories.keys.sorted()
    }

    var sortedTags: [String] {
        tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func setTorrentCategoryLocally(hash: String, category: String) {
        guard var torrent = torrents[hash] else { return }
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        torrent.category = normalizedCategory.isEmpty ? nil : normalizedCategory
        torrents[hash] = torrent
    }

    func addCategoryLocally(name: String, savePath: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedSavePath = savePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        categories[trimmedName] = SyncCategory(
            name: trimmedName,
            savePath: trimmedSavePath?.isEmpty == true ? nil : trimmedSavePath
        )
    }

    func removeCategoriesLocally(names: [String]) {
        let removedNames = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard !removedNames.isEmpty else { return }

        for name in removedNames {
            categories.removeValue(forKey: name)
        }

        var updatedTorrents = torrents
        for (hash, var torrent) in updatedTorrents where torrent.category.map(removedNames.contains) == true {
            torrent.category = nil
            updatedTorrents[hash] = torrent
        }
        torrents = updatedTorrents
    }

    func addTagLocally(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        guard !tags.contains(where: { $0.caseInsensitiveCompare(trimmedName) == .orderedSame }) else { return }
        tags.append(trimmedName)
        tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func removeTagsLocally(names: [String]) {
        let removedNames = Set(
            names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !removedNames.isEmpty else { return }

        tags.removeAll { removedNames.contains($0.lowercased()) }

        var updatedTorrents = torrents
        for (hash, torrent) in updatedTorrents {
            let currentTags = parsedTags(from: torrent.tags)
            let filteredTags = currentTags.filter { !removedNames.contains($0.lowercased()) }
            guard filteredTags != currentTags else { continue }
            var updatedTorrent = torrent
            updatedTorrent.tags = joinedTags(filteredTags)
            updatedTorrents[hash] = updatedTorrent
        }
        torrents = updatedTorrents
    }

    func addTagsToTorrentLocally(hash: String, tags names: [String]) {
        guard var torrent = torrents[hash] else { return }
        let existingTags = parsedTags(from: torrent.tags)
        let additions = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !additions.isEmpty else { return }

        var merged = existingTags
        for tag in additions where !merged.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            merged.append(tag)
        }
        torrent.tags = joinedTags(merged)
        torrents[hash] = torrent
    }

    func removeTagsFromTorrentLocally(hash: String, tags names: [String]) {
        guard var torrent = torrents[hash] else { return }
        let removals = Set(
            names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !removals.isEmpty else { return }

        let filteredTags = parsedTags(from: torrent.tags).filter { !removals.contains($0.lowercased()) }
        torrent.tags = joinedTags(filteredTags)
        torrents[hash] = torrent
    }

    // MARK: - Polling Control

    func startPolling() {
        guard pollingTask == nil else { return }
        isPolling = true
        rid = 0
        pollingGeneration &+= 1
        backoff.reset()
        let generation = pollingGeneration

        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let data = try await self.apiClient.syncMainData(rid: self.rid)
                    guard !Task.isCancelled, generation == self.pollingGeneration else { break }
                    // Recorded before the staleness check, not after: a response
                    // that arrives out of order is still proof the server is
                    // answering, which is the only thing the backoff measures.
                    self.backoff.recordSuccess()
                    // An out-of-order response is dropped rather than applied, but
                    // it used to `continue` straight past the sleep below, so a
                    // server stuck behind our rid was polled in a tight loop.
                    if data.rid >= self.rid {
                        self.applyDelta(data)
                        self.rid = data.rid
                    }
                    self.lastError = nil
                } catch {
                    self.lastError = error as? QBError ?? .networkError(error.localizedDescription)
                    self.backoff.recordFailure()
                }
                await self.waitForPollingInterval(self.backoff.interval(base: self.pollingInterval))
            }
        }
    }

    func stopPolling() {
        pollingGeneration &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    /// Force an immediate poll cycle (e.g. pull-to-refresh).
    /// Preserves the current rid so we get a delta, not a full refresh.
    ///
    /// Never consults the backoff - a refresh the user asked for goes out now, at
    /// whatever cadence the loop has stretched to - but does feed it. A success
    /// here returns the loop to base cadence, which is what makes a Retry that
    /// works also fix the polling behind it.
    func refreshNow() async {
        do {
            let data = try await apiClient.syncMainData(rid: rid)
            backoff.recordSuccess()
            guard data.rid >= rid else { return }
            applyDelta(data)
            rid = data.rid
            lastError = nil
        } catch {
            lastError = error as? QBError ?? .networkError(error.localizedDescription)
            backoff.recordFailure()
        }
    }

    // MARK: - Delta Application

    private func applyDelta(_ data: SyncMainData) {
        let isFullUpdate = data.fullUpdate == true
        var completedTorrentNames: [String] = []

        // --- Torrents ---
        if isFullUpdate {
            // Full update: build a fresh dict and assign in one shot
            var fresh: [String: Torrent] = [:]
            if let newTorrents = data.torrents {
                for (hash, syncData) in newTorrents {
                    let nextTorrent = Torrent.fromDelta(hash: hash, delta: syncData)
                    if let existing = torrents[hash], !existing.state.isCompleted, nextTorrent.state.isCompleted {
                        completedTorrentNames.append(nextTorrent.name)
                    }
                    fresh[hash] = nextTorrent
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
                        let nextTorrent = existing.applying(delta: delta)
                        if !existing.state.isCompleted, nextTorrent.state.isCompleted {
                            completedTorrentNames.append(nextTorrent.name)
                        }
                        updated[hash] = nextTorrent
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

        // --- Speed History ---
        if let state = serverState {
            let sample = SpeedSample(
                timestamp: .now,
                dlSpeed: state.dlInfoSpeed ?? 0,
                upSpeed: state.upInfoSpeed ?? 0
            )
            speedHistory.append(sample)
            if speedHistory.count > maxSpeedHistoryCount {
                speedHistory.removeFirst(speedHistory.count - maxSpeedHistoryCount)
            }
        }

        let nextActiveTorrentCount = torrents.values.reduce(into: 0) { count, torrent in
            if torrent.isRunningInTabBadge {
                count += 1
            }
        }
        if activeTorrentCount != nextActiveTorrentCount {
            activeTorrentCount = nextActiveTorrentCount
        }

        if !completedTorrentNames.isEmpty {
            if completedTorrentNames.count == 1 {
                InAppNotificationCenter.shared.showDownloadCompleted(name: completedTorrentNames[0])
            } else {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Downloads Complete",
                    message: "\(completedTorrentNames.count) downloads completed."
                )
            }
        }
    }

    private func parsedTags(from rawValue: String?) -> [String] {
        guard let rawValue else { return [] }
        return rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func joinedTags(_ tags: [String]) -> String? {
        let normalizedTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return normalizedTags.isEmpty ? nil : normalizedTags.joined(separator: ", ")
    }
}

#if DEBUG
extension SyncService {
    static func preview() -> SyncService {
        SyncService(apiClient: QBittorrentAPIClient.preview())
    }
}
#endif
