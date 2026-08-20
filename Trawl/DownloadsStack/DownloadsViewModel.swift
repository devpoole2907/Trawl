import Foundation
import Observation

@MainActor
@Observable
final class DownloadsViewModel {
    var searchText = ""
    private(set) var sonarrQueue: [ArrQueueItem] = []
    private(set) var radarrQueue: [ArrQueueItem] = []
    private(set) var sonarrHistory: [ArrHistoryRecord] = []
    private(set) var radarrHistory: [ArrHistoryRecord] = []
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    func refresh(serviceManager: ArrServiceManager) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sonarrClient = serviceManager.sonarrClient
        let radarrClient = serviceManager.radarrClient

        async let sonarrResult = Self.loadSonarr(client: sonarrClient)
        async let radarrResult = Self.loadRadarr(client: radarrClient)

        let (loadedSonarr, loadedRadarr) = await (sonarrResult, radarrResult)
        sonarrQueue = loadedSonarr.queue
        sonarrHistory = loadedSonarr.history
        radarrQueue = loadedRadarr.queue
        radarrHistory = loadedRadarr.history

        let errors = [loadedSonarr.error, loadedRadarr.error].compactMap { $0 }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func items(
        for section: DownloadSection,
        torrents: [String: Torrent],
        sabActiveJobs: [SABnzbdJob],
        sabHistoryJobs: [SABnzbdJob]
    ) -> [DownloadListItem] {
        let queueItems = arrQueueItems(torrents: torrents, sabJobs: sabActiveJobs)
        let linkedHashes = Set(queueItems.compactMap { item -> String? in
            guard case .arrQueue(_, _, let linkedTorrent, _) = item else { return nil }
            return linkedTorrent?.hash.lowercased()
        })
        let linkedSABIDs = Set(queueItems.compactMap { item -> String? in
            guard case .arrQueue(_, _, _, let linkedSABJob) = item else { return nil }
            return linkedSABJob?.id.lowercased()
        })

        let unmatchedTorrents = torrents.values.filter { !linkedHashes.contains($0.hash.lowercased()) }
        let unmatchedSABJobs = sabActiveJobs.filter { !linkedSABIDs.contains($0.id.lowercased()) }
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

        case .seeding:
            result = torrents.values
                .filter { $0.state.isCompleted }
                .sorted { $0.addedOn > $1.addedOn }
                .map(DownloadListItem.torrent)

        case .history:
            let arrHistory = arrHistoryItems().map(DownloadListItem.arrHistory)
            let sabHistory = sabHistoryJobs
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .map(DownloadListItem.sab)
            result = arrHistory + sabHistory

        case .issues:
            let queueIssues = queueItems.filter { item in
                guard case .arrQueue(let record, _, _, _) = item else { return false }
                return record.isImportIssueQueueItem
            }
            let torrentIssues = unmatchedTorrents
                .filter { $0.state.filterCategory == .errored }
                .sorted { $0.addedOn > $1.addedOn }
                .map(DownloadListItem.torrent)
            let sabIssues = (sabActiveJobs + sabHistoryJobs)
                .filter { $0.normalizedStatus == .failed }
                .reduce(into: [String: SABnzbdJob]()) { result, job in result[job.id] = job }
                .values
                .map(DownloadListItem.sab)
            result = queueIssues + torrentIssues + sabIssues
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        return result.filter { $0.searchableText.localizedStandardContains(query) }
    }

    private func arrQueueItems(
        torrents: [String: Torrent],
        sabJobs: [SABnzbdJob]
    ) -> [DownloadListItem] {
        let sonarr = sonarrQueue.map { item in
            DownloadListItem.arrQueue(
                item: item,
                source: .sonarr,
                linkedTorrent: Self.linkedTorrent(for: item, torrents: torrents),
                linkedSABJob: Self.linkedSABJob(for: item, jobs: sabJobs)
            )
        }
        let radarr = radarrQueue.map { item in
            DownloadListItem.arrQueue(
                item: item,
                source: .radarr,
                linkedTorrent: Self.linkedTorrent(for: item, torrents: torrents),
                linkedSABJob: Self.linkedSABJob(for: item, jobs: sabJobs)
            )
        }
        return (sonarr + radarr).sorted { lhs, rhs in
            Self.queueSortRank(lhs) < Self.queueSortRank(rhs)
        }
    }

    private func arrHistoryItems() -> [HistoryItem] {
        let sonarr = sonarrHistory.map { HistoryItem(record: $0, source: .sonarr) }
        let radarr = radarrHistory.map { HistoryItem(record: $0, source: .radarr) }
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

    private nonisolated static func loadSonarr(client: SonarrAPIClient?) async -> ArrDownloadSnapshot {
        guard let client else { return .empty }
        do {
            async let queue = client.getQueue(page: 1, pageSize: 100)
            async let history = client.getHistory(page: 1, pageSize: 100)
            let (queuePage, historyPage) = try await (queue, history)
            return ArrDownloadSnapshot(
                queue: queuePage.records ?? [],
                history: historyPage.records ?? [],
                error: nil
            )
        } catch {
            return ArrDownloadSnapshot(queue: [], history: [], error: "Sonarr: \(error.localizedDescription)")
        }
    }

    private nonisolated static func loadRadarr(client: RadarrAPIClient?) async -> ArrDownloadSnapshot {
        guard let client else { return .empty }
        do {
            async let queue = client.getQueue(page: 1, pageSize: 100)
            async let history = client.getHistory(page: 1, pageSize: 100)
            let (queuePage, historyPage) = try await (queue, history)
            return ArrDownloadSnapshot(
                queue: queuePage.records ?? [],
                history: historyPage.records ?? [],
                error: nil
            )
        } catch {
            return ArrDownloadSnapshot(queue: [], history: [], error: "Radarr: \(error.localizedDescription)")
        }
    }
}

private nonisolated struct ArrDownloadSnapshot: Sendable {
    let queue: [ArrQueueItem]
    let history: [ArrHistoryRecord]
    let error: String?

    static let empty = ArrDownloadSnapshot(queue: [], history: [], error: nil)
}
