import Foundation

struct Torrent: Codable, Identifiable, Hashable, Sendable {
    var id: String { hash }

    let hash: String
    var name: String
    var size: Int64
    var progress: Double
    var dlspeed: Int64
    var upspeed: Int64
    var priority: Int
    var numSeeds: Int
    var numLeechs: Int
    var ratio: Double
    var eta: Int
    var state: TorrentState
    var category: String?
    var tags: String?
    var addedOn: Int
    var completionOn: Int
    var savePath: String
    var downloadedSession: Int64
    var uploadedSession: Int64
    var amountLeft: Int64
    var totalSize: Int64
    var comment: String?

    enum CodingKeys: String, CodingKey {
        case hash, name, size, progress, dlspeed, upspeed, priority
        case numSeeds = "num_seeds"
        case numLeechs = "num_leechs"
        case ratio, eta, state, category, tags
        case addedOn = "added_on"
        case completionOn = "completion_on"
        case savePath = "save_path"
        case downloadedSession = "dl_session"
        case uploadedSession = "up_session"
        case amountLeft = "amount_left"
        case totalSize = "total_size"
        case comment
    }

    /// Creates a torrent with defaults for fields not provided in a sync delta
    static func fromDelta(hash: String, delta: SyncTorrentData) -> Torrent {
        Torrent(
            hash: hash,
            name: delta.name ?? "",
            size: delta.size ?? 0,
            progress: delta.progress ?? 0,
            dlspeed: delta.dlspeed ?? 0,
            upspeed: delta.upspeed ?? 0,
            priority: delta.priority ?? 0,
            numSeeds: delta.numSeeds ?? 0,
            numLeechs: delta.numLeechs ?? 0,
            ratio: delta.ratio ?? 0,
            eta: delta.eta ?? 8_640_000,
            state: delta.state ?? .unknown,
            category: delta.category,
            tags: delta.tags,
            addedOn: delta.addedOn ?? 0,
            completionOn: delta.completionOn ?? -1,
            savePath: delta.savePath ?? "",
            downloadedSession: delta.downloadedSession ?? 0,
            uploadedSession: delta.uploadedSession ?? 0,
            amountLeft: delta.amountLeft ?? 0,
            totalSize: delta.totalSize ?? 0,
            comment: delta.comment
        )
    }

    /// Merge non-nil delta fields into this torrent, returning a new value
    func applying(delta: SyncTorrentData) -> Torrent {
        Torrent(
            hash: hash,
            name: delta.name ?? name,
            size: delta.size ?? size,
            progress: delta.progress ?? progress,
            dlspeed: delta.dlspeed ?? dlspeed,
            upspeed: delta.upspeed ?? upspeed,
            priority: delta.priority ?? priority,
            numSeeds: delta.numSeeds ?? numSeeds,
            numLeechs: delta.numLeechs ?? numLeechs,
            ratio: delta.ratio ?? ratio,
            eta: delta.eta ?? eta,
            state: delta.state ?? state,
            category: delta.category ?? category,
            tags: delta.tags ?? tags,
            addedOn: delta.addedOn ?? addedOn,
            completionOn: delta.completionOn ?? completionOn,
            savePath: delta.savePath ?? savePath,
            downloadedSession: delta.downloadedSession ?? downloadedSession,
            uploadedSession: delta.uploadedSession ?? uploadedSession,
            amountLeft: delta.amountLeft ?? amountLeft,
            totalSize: delta.totalSize ?? totalSize,
            comment: delta.comment ?? comment
        )
    }

    var isRunningInTabBadge: Bool {
        switch state {
        case .downloading, .metaDL, .forcedDL, .forcedUP, .uploading, .checkingDL, .checkingUP,
             .checkingResumeData, .allocating, .moving:
            true
        case .stalledDL, .stalledUP, .queuedDL, .queuedUP:
            dlspeed > 0 || upspeed > 0
        case .pausedDL, .pausedUP, .stoppedDL, .stoppedUP, .error, .missingFiles, .unknown:
            false
        }
    }
}
