import Foundation

enum DownloadListItem: Identifiable {
    case torrent(Torrent)
    case arrQueue(
        item: ArrQueueItem,
        source: ArrServiceType,
        linkedTorrent: Torrent?,
        linkedSABJob: SABnzbdJob?
    )
    case arrHistory(HistoryItem)
    case sab(SABnzbdJob)

    var id: String {
        switch self {
        case .torrent(let torrent):
            "qbittorrent-\(torrent.hash)"
        case .arrQueue(let item, let source, _, _):
            "arr-queue-\(source.rawValue)-\(item.id)"
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
        case .arrQueue(let item, let source, _, let linkedSABJob):
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
}
