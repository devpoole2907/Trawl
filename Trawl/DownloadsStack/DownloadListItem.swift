import Foundation

enum DownloadListItem: Identifiable {
    case torrent(Torrent)
    case arrQueue(
        item: ArrQueueItem,
        source: ArrServiceType,
        linkedTorrent: Torrent?,
        linkedSABJob: SABnzbdJob?,
        /// The server fetching this download. `nil` when only one instance of the
        /// service is configured, where naming it would add nothing to the row.
        instance: ArrInstanceRef?
    )
    case arrHistory(HistoryItem)
    case sab(SABnzbdJob)

    var id: String {
        switch self {
        case .torrent(let torrent):
            "qbittorrent-\(torrent.hash)"
        case .arrQueue(let item, let source, _, _, let instance):
            // Both instances of a service number their queue rows from the same
            // sequence, so the service alone is not a unique key across a pair.
            "arr-queue-\(instance?.id.uuidString ?? source.rawValue)-\(item.id)"
        case .arrHistory(let item):
            "arr-history-\(item.id)"
        case .sab(let job):
            "sabnzbd-\(job.source.rawValue)-\(job.id)"
        }
    }

    var searchableText: String {
        switch self {
        case .torrent(let torrent):
            [torrent.name, torrent.category, torrent.state.displayName]
                .compactMap { $0 }
                .joined(separator: " ")
        case .arrQueue(let item, let source, _, let linkedSABJob, _):
            [
                item.title,
                source.rawValue,
                item.status,
                item.trackedDownloadState,
                item.downloadClient,
                item.protocol_,
                item.primaryStatusMessage,
                linkedSABJob?.name,
                linkedSABJob?.status
            ]
                .compactMap { $0 }
                .joined(separator: " ")
        case .arrHistory(let item):
            [
                item.record.sourceTitle,
                item.record.eventDisplayName,
                item.source.rawValue,
                item.record.quality?.quality?.name,
                item.record.data?["releaseTitle"],
                item.record.data?["indexer"]
            ]
                .compactMap { $0 }
                .joined(separator: " ")
        case .sab(let job):
            [job.name, job.status, job.category, job.failureMessage]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    var sortValues: DownloadSortValues {
        switch self {
        case .torrent(let torrent):
            return DownloadSortValues(
                identifier: id,
                name: torrent.name,
                date: torrent.addedOn > 0
                    ? Date(timeIntervalSince1970: TimeInterval(torrent.addedOn))
                    : nil,
                size: torrent.totalSize > 0 ? torrent.totalSize : torrent.size,
                progress: torrent.progress,
                eta: torrent.eta > 0 && torrent.eta < 8_640_000 ? TimeInterval(torrent.eta) : nil,
                status: torrent.state.displayName
            )

        case .arrQueue(let item, let source, let linkedTorrent, let linkedSABJob, _):
            let torrentDate = linkedTorrent.flatMap { torrent in
                torrent.addedOn > 0
                    ? Date(timeIntervalSince1970: TimeInterval(torrent.addedOn))
                    : nil
            }
            let torrentSize = linkedTorrent.flatMap { torrent in
                let size = torrent.totalSize > 0 ? torrent.totalSize : torrent.size
                return size > 0 ? size : nil
            }
            let itemSize = item.size.flatMap { $0 > 0 ? Int64($0) : nil }
            let torrentETA = linkedTorrent.flatMap { torrent in
                torrent.eta > 0 && torrent.eta < 8_640_000 ? TimeInterval(torrent.eta) : nil
            }
            return DownloadSortValues(
                identifier: id,
                name: item.title ?? linkedTorrent?.name ?? linkedSABJob?.name ?? "Unknown Download",
                date: torrentDate ?? linkedSABJob?.addedAt,
                size: torrentSize ?? linkedSABJob?.totalBytes ?? itemSize,
                progress: linkedTorrent?.progress ?? linkedSABJob?.progress ?? item.progress,
                eta: torrentETA
                    ?? DownloadSortValues.etaSeconds(from: linkedSABJob?.timeRemaining)
                    ?? DownloadSortValues.etaSeconds(from: item.timeleft),
                status: linkedTorrent?.state.displayName
                    ?? linkedSABJob?.normalizedStatus.displayName
                    ?? item.trackedDownloadState
                    ?? item.status
                    ?? source.rawValue
            )

        case .arrHistory(let item):
            return DownloadSortValues(
                identifier: id,
                name: item.record.sourceTitle
                    ?? item.record.data?["releaseTitle"]
                    ?? item.record.data?["title"]
                    ?? "Unknown Event",
                date: item.sortDate,
                size: nil,
                progress: nil,
                eta: nil,
                status: item.record.eventDisplayName
            )

        case .sab(let job):
            return DownloadSortValues(
                identifier: id,
                name: job.name,
                date: job.completedAt ?? job.addedAt,
                size: job.totalBytes,
                progress: job.progress,
                eta: DownloadSortValues.etaSeconds(from: job.timeRemaining),
                status: job.normalizedStatus.displayName
            )
        }
    }
}

/// What a selected row can actually be acted on as.
///
/// The Downloads list mixes four kinds of row, and only two of them name something
/// a client can pause, resume or delete. An *arr queue row is not itself a
/// download — it is that service's view of one running in qBittorrent or SABnzbd —
/// so it resolves to whichever it is linked to. Rows that resolve to `nil` are
/// skipped by a batch action and counted in its result, rather than being silently
/// treated as done.
enum DownloadBatchTarget: Equatable {
    case torrent(Torrent)
    case sab(SABnzbdJob)
}

extension DownloadListItem {
    var batchTarget: DownloadBatchTarget? {
        switch self {
        case .torrent(let torrent):
            .torrent(torrent)
        case .sab(let job):
            .sab(job)
        case .arrQueue(_, _, let linkedTorrent, let linkedSABJob, _):
            // The torrent link wins when both are somehow present: qBittorrent is
            // the client that would be holding the file.
            linkedTorrent.map { .torrent($0) } ?? linkedSABJob.map { .sab($0) }
        case .arrHistory:
            // A record of a finished download, not a download. Nothing to act on.
            nil
        }
    }
}
