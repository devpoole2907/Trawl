import Foundation
import Observation

@MainActor
@Observable
final class DownloadsViewModel {
    var searchText = ""

    /// Arr queue rows the user has just removed. The queue cache lives on
    /// `ArrServiceManager` now and is refreshed by a poller this view model doesn't
    /// own, so a poll already in flight when the delete landed would otherwise put
    /// the row straight back. Keys stay suppressed until the shared cache agrees
    /// the row is gone.
    private var removedQueueItemKeys: Set<String> = []

    /// Whether this view model is currently holding a fast-cadence request open.
    /// Keeps `begin`/`end` balanced across appear/disappear.
    private var isFastPollingActive = false

    // MARK: - Polling

    /// The Arr queue is polled centrally by `ArrServiceManager` — Downloads only
    /// asks it to speed up while the tab is on screen.
    func startPolling(serviceManager: ArrServiceManager) {
        serviceManager.startQueuePolling()
        guard !isFastPollingActive else { return }
        isFastPollingActive = true
        serviceManager.beginFastQueuePolling()
    }

    func stopPolling(serviceManager: ArrServiceManager) {
        guard isFastPollingActive else { return }
        isFastPollingActive = false
        serviceManager.endFastQueuePolling()
    }

    func refresh(serviceManager: ArrServiceManager) async {
        await serviceManager.refreshQueues()
        pruneRemovedQueueItems(serviceManager: serviceManager)
    }

    func items(
        for section: DownloadSection,
        serviceManager: ArrServiceManager,
        torrents: [String: Torrent],
        sabActiveJobs: [SABnzbdJob],
        sabHistoryJobs: [SABnzbdJob]
    ) -> [DownloadListItem] {
        let matched = Self.match(
            queueRecords: arrQueueRecords(serviceManager: serviceManager),
            torrents: torrents,
            sabActiveJobs: sabActiveJobs,
            sabHistoryJobs: sabHistoryJobs
        )
        let queueItems = matched.queueItems
        let unmatchedTorrents = matched.unmatchedTorrents
        let unmatchedSABJobs = matched.unmatchedSABJobs
        let unmatchedSABHistoryJobs = matched.unmatchedSABHistoryJobs
        let result: [DownloadListItem]

        switch section {
        case .active:
            let activeQueue = queueItems.filter { item in
                guard case .arrQueue(let record, _, _, _) = item else { return false }
                return Self.isActive(record) && !record.isImportIssueQueueItem
            }
            let activeTorrents = unmatchedTorrents
                .filter { Self.isActive($0) }
                .sorted { $0.addedOn > $1.addedOn }
                .map(DownloadListItem.torrent)
            let activeSAB = unmatchedSABJobs
                .filter { Self.isActive($0) }
                .map(DownloadListItem.sab)
            result = activeQueue + activeTorrents + activeSAB

        case .queue:
            let waitingQueue = queueItems.filter { item in
                guard case .arrQueue(let record, _, _, _) = item else { return false }
                return !Self.isActive(record) && !record.isImportIssueQueueItem
            }
            let waitingTorrents = unmatchedTorrents
                .filter { Self.isWaiting($0) }
                .sorted { $0.addedOn > $1.addedOn }
                .map(DownloadListItem.torrent)
            let waitingSAB = unmatchedSABJobs
                .filter { Self.isWaiting($0) }
                .map(DownloadListItem.sab)
            result = waitingQueue + waitingTorrents + waitingSAB

        case .completed:
            // Finished but not uploading — paused or stopped on the seeding side.
            // `isCompleted` alone means "fully downloaded", which is why these used
            // to sit in Seeding alongside torrents that were actually seeding.
            result = unmatchedTorrents
                .filter { $0.state.isCompleted && $0.state.filterCategory == .paused }
                .sorted { $0.addedOn > $1.addedOn }
                .map(DownloadListItem.torrent)

        case .seeding:
            // Actually uploading. Unmatched only: a completed-but-still-importing
            // torrent is already rendered as its Arr queue row over in Active.
            result = unmatchedTorrents
                .filter { $0.state.filterCategory == .seeding }
                .sorted { $0.addedOn > $1.addedOn }
                .map(DownloadListItem.torrent)

        case .history:
            let arrHistory = arrHistoryItems(serviceManager: serviceManager)
            // Same downloadId reconciliation the queue does: Arr history already
            // names the grab, so drop the SABnzbd row for the same nzo.
            let arrDownloadIDs = Set(
                arrHistory.compactMap { historyItem -> String? in
                    let downloadID = historyItem.record.downloadId?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard let downloadID, !downloadID.isEmpty else { return nil }
                    return downloadID
                }
            )
            let sabHistory = unmatchedSABHistoryJobs
                .filter { !arrDownloadIDs.contains($0.id.lowercased()) }
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .map(DownloadListItem.sab)
            result = arrHistory.map(DownloadListItem.arrHistory) + sabHistory

        case .issues:
            result = Self.issueItems(matched)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        return result.filter { $0.searchableText.localizedStandardContains(query) }
    }

    // MARK: - App-wide failures

    /// Everything in the app that needs a human right now — Arr import issues,
    /// errored torrents, failed SABnzbd jobs — composed exactly the way the Downloads
    /// Issues segment composes them, because it runs the same code. The tab-bar
    /// accessory reads this; a pill that disagrees with the tab it links to would be
    /// worse than no pill at all.
    ///
    /// Every input is optional: an unconfigured qBittorrent passes an empty
    /// `torrents`, an unconfigured SABnzbd passes empty job lists, and an
    /// unconfigured Sonarr/Radarr leaves the shared queue cache empty.
    static func attentionItems(
        serviceManager: ArrServiceManager,
        torrents: [String: Torrent],
        sabActiveJobs: [SABnzbdJob],
        sabHistoryJobs: [SABnzbdJob]
    ) -> [DownloadListItem] {
        issueItems(
            match(
                queueRecords: serviceManager.queueItemsBySource,
                torrents: torrents,
                sabActiveJobs: sabActiveJobs,
                sabHistoryJobs: sabHistoryJobs
            )
        )
    }

    // MARK: - Queue actions

    /// Whether "Blocklist & Search Again" can be offered — Sonarr needs an episode
    /// (or at least a series) and Radarr needs a movie to search for.
    nonisolated static func canSearchAgain(_ item: ArrQueueItem, source: ArrServiceType) -> Bool {
        switch source {
        case .sonarr: item.episodeId != nil || item.seriesId != nil
        case .radarr: item.movieId != nil
        default: false
        }
    }

    /// Removes an Arr queue item (and the download from its client), optionally
    /// blocklisting the release and kicking off a fresh search for it.
    /// Returns an error description on failure, `nil` on success.
    func removeQueueItem(
        _ item: ArrQueueItem,
        source: ArrServiceType,
        blocklist: Bool,
        searchAgain: Bool,
        serviceManager: ArrServiceManager
    ) async -> String? {
        do {
            switch source {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return "Sonarr isn’t connected." }
                try await client.deleteQueueItem(id: item.id, removeFromClient: true, blocklist: blocklist)
                if searchAgain {
                    if let episodeId = item.episodeId {
                        _ = try await client.searchEpisodes(episodeIds: [episodeId])
                    } else if let seriesId = item.seriesId {
                        _ = try await client.searchSeries(seriesId: seriesId)
                    }
                }
            case .radarr:
                guard let client = serviceManager.radarrClient else { return "Radarr isn’t connected." }
                try await client.deleteQueueItem(id: item.id, removeFromClient: true, blocklist: blocklist)
                if searchAgain, let movieId = item.movieId {
                    _ = try await client.searchMovie(movieIds: [movieId])
                }
            default:
                return "This queue item can’t be modified from Downloads."
            }
        } catch {
            return error.localizedDescription
        }

        // Drop the row immediately so the list reflects the action even if a poll
        // is mid-flight and swallows the refresh below. Suppression (rather than a
        // direct edit of the shared cache) is what survives that poll landing.
        removedQueueItemKeys.insert(Self.queueItemKey(item, source: source))
        if blocklist {
            await serviceManager.loadBlocklist()
        }
        await refresh(serviceManager: serviceManager)
        return nil
    }

    // MARK: - Composition

    /// The Arr queue as Downloads sees it: the shared cache minus anything this view
    /// model has optimistically removed.
    private func arrQueueRecords(
        serviceManager: ArrServiceManager
    ) -> [(item: ArrQueueItem, source: ArrServiceType)] {
        guard !removedQueueItemKeys.isEmpty else { return serviceManager.queueItemsBySource }
        return serviceManager.queueItemsBySource.filter {
            !removedQueueItemKeys.contains(Self.queueItemKey($0.item, source: $0.source))
        }
    }

    /// Stops suppressing rows the shared cache has caught up on. A row the cache
    /// still reports stays hidden — the delete simply hasn't been picked up yet.
    private func pruneRemovedQueueItems(serviceManager: ArrServiceManager) {
        guard !removedQueueItemKeys.isEmpty else { return }
        let live = Set(
            serviceManager.queueItemsBySource.map { Self.queueItemKey($0.item, source: $0.source) }
        )
        removedQueueItemKeys.formIntersection(live)
    }

    private static func queueItemKey(_ item: ArrQueueItem, source: ArrServiceType) -> String {
        "\(source.rawValue)-\(item.id)"
    }

    /// Arr queue rows linked to their download-client job, plus the torrents and
    /// SABnzbd jobs no Arr row claims. Shared with `attentionItems` so the app-wide
    /// failure list is built from exactly the same matching the tab uses.
    private static func match(
        queueRecords: [(item: ArrQueueItem, source: ArrServiceType)],
        torrents: [String: Torrent],
        sabActiveJobs: [SABnzbdJob],
        sabHistoryJobs: [SABnzbdJob]
    ) -> MatchedDownloads {
        // History jobs are matched too: a failed grab leaves the SABnzbd queue and
        // lands in history while the Arr queue item stays behind as an import issue.
        // Active jobs come first so a live job always wins the link.
        let sabJobs = sabActiveJobs + sabHistoryJobs
        let queueItems = queueRecords
            .map { record in
                DownloadListItem.arrQueue(
                    item: record.item,
                    source: record.source,
                    linkedTorrent: linkedTorrent(for: record.item, torrents: torrents),
                    linkedSABJob: linkedSABJob(for: record.item, jobs: sabJobs)
                )
            }
            .sorted { lhs, rhs in
                queueSortRank(lhs) < queueSortRank(rhs)
            }

        let linkedHashes = Set(queueItems.compactMap { item -> String? in
            guard case .arrQueue(_, _, let linkedTorrent, _) = item else { return nil }
            return linkedTorrent?.hash.lowercased()
        })
        let linkedSABIDs = Set(queueItems.compactMap { item -> String? in
            guard case .arrQueue(_, _, _, let linkedSABJob) = item else { return nil }
            return linkedSABJob?.id.lowercased()
        })

        return MatchedDownloads(
            queueItems: queueItems,
            unmatchedTorrents: torrents.values.filter { !linkedHashes.contains($0.hash.lowercased()) },
            unmatchedSABJobs: sabActiveJobs.filter { !linkedSABIDs.contains($0.id.lowercased()) },
            unmatchedSABHistoryJobs: sabHistoryJobs.filter { !linkedSABIDs.contains($0.id.lowercased()) }
        )
    }

    /// The single definition of "needs attention", rendered by the Issues segment
    /// and counted by the tab-bar accessory.
    private static func issueItems(_ matched: MatchedDownloads) -> [DownloadListItem] {
        let queueIssues = matched.queueItems.filter { item in
            guard case .arrQueue(let record, _, _, _) = item else { return false }
            return record.isImportIssueQueueItem
        }
        let torrentIssues = matched.unmatchedTorrents
            .filter { $0.state.filterCategory == .errored }
            .sorted { $0.addedOn > $1.addedOn }
            .map(DownloadListItem.torrent)
        // Unmatched only, otherwise a failed job linked to an Arr queue item
        // shows up twice. The reduce collapses a job present in both the live
        // queue and history while keeping the order stable.
        let sabIssues = (matched.unmatchedSABJobs + matched.unmatchedSABHistoryJobs)
            .filter { $0.normalizedStatus == .failed }
            .reduce(into: [SABnzbdJob]()) { result, job in
                guard !result.contains(where: { $0.id == job.id }) else { return }
                result.append(job)
            }
            .map(DownloadListItem.sab)
        return queueIssues + torrentIssues + sabIssues
    }

    private func arrHistoryItems(serviceManager: ArrServiceManager) -> [HistoryItem] {
        let sonarr = serviceManager.sonarrHistory.map { HistoryItem(record: $0, source: .sonarr) }
        let radarr = serviceManager.radarrHistory.map { HistoryItem(record: $0, source: .radarr) }
        return (sonarr + radarr).sorted { $0.sortDate > $1.sortDate }
    }

    private static func isActive(_ item: ArrQueueItem) -> Bool {
        let state = item.normalizedState
        return state == "downloading" || state == "importing" || state == "moving"
    }

    private static func isActive(_ torrent: Torrent) -> Bool {
        switch torrent.state {
        case .downloading, .forcedDL, .metaDL, .stalledDL, .checkingDL, .allocating, .moving:
            true
        default:
            false
        }
    }

    private static func isWaiting(_ torrent: Torrent) -> Bool {
        switch torrent.state {
        case .queuedDL, .pausedDL, .stoppedDL, .checkingResumeData:
            true
        default:
            false
        }
    }

    private static func isActive(_ job: SABnzbdJob) -> Bool {
        switch job.normalizedStatus {
        case .downloading, .repairing, .unpacking, .processing:
            true
        default:
            false
        }
    }

    private static func isWaiting(_ job: SABnzbdJob) -> Bool {
        switch job.normalizedStatus {
        case .waiting, .paused:
            true
        default:
            false
        }
    }

    private static func linkedTorrent(for item: ArrQueueItem, torrents: [String: Torrent]) -> Torrent? {
        guard let downloadID = item.downloadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !downloadID.isEmpty else {
            return nil
        }
        return torrents[downloadID]
            ?? torrents[downloadID.lowercased()]
            ?? torrents[downloadID.uppercased()]
    }

    private static func linkedSABJob(for item: ArrQueueItem, jobs: [SABnzbdJob]) -> SABnzbdJob? {
        guard let downloadID = item.downloadId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !downloadID.isEmpty else {
            return nil
        }
        return jobs.first { $0.id.caseInsensitiveCompare(downloadID) == .orderedSame }
    }

    private static func queueSortRank(_ item: DownloadListItem) -> Double {
        guard case .arrQueue(let record, _, _, _) = item else { return .greatestFiniteMagnitude }
        return record.sizeleft ?? .greatestFiniteMagnitude
    }
}

/// Arr queue rows and the download-client jobs nothing claimed, resolved once per
/// composition pass and reused by every segment.
private struct MatchedDownloads {
    let queueItems: [DownloadListItem]
    let unmatchedTorrents: [Torrent]
    let unmatchedSABJobs: [SABnzbdJob]
    let unmatchedSABHistoryJobs: [SABnzbdJob]
}
