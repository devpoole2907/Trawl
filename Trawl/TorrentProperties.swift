import Foundation

struct TorrentProperties: Codable, Sendable {
    let savePath: String
    let creationDate: Int
    let pieceSize: Int64
    let comment: String
    let totalWasted: Int64
    let totalUploaded: Int64
    let totalDownloaded: Int64
    let upLimit: Int64
    let dlLimit: Int64
    let timeElapsed: Int
    let seedingTime: Int
    let nbConnections: Int
    let shareRatio: Double
    let additionDate: Int
    let completionDate: Int
    let createdBy: String?
    let lastSeen: Int
    let peers: Int
    let seeds: Int
    let piecesHave: Int
    let piecesNum: Int

    enum CodingKeys: String, CodingKey {
        case savePath = "save_path"
        case creationDate = "creation_date"
        case pieceSize = "piece_size"
        case comment
        case totalWasted = "total_wasted"
        case totalUploaded = "total_uploaded"
        case totalDownloaded = "total_downloaded"
        case upLimit = "up_limit"
        case dlLimit = "dl_limit"
        case timeElapsed = "time_elapsed"
        case seedingTime = "seeding_time"
        case nbConnections = "nb_connections"
        case shareRatio = "share_ratio"
        case additionDate = "addition_date"
        case completionDate = "completion_date"
        case createdBy = "created_by"
        case lastSeen = "last_seen"
        case peers, seeds
        case piecesHave = "pieces_have"
        case piecesNum = "pieces_num"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savePath = try c.decode(String.self, forKey: .savePath)
        creationDate = try c.decode(Int.self, forKey: .creationDate)
        pieceSize = try c.decode(Int64.self, forKey: .pieceSize)
        comment = try c.decode(String.self, forKey: .comment)
        totalWasted = try c.decode(Int64.self, forKey: .totalWasted)
        totalUploaded = try c.decode(Int64.self, forKey: .totalUploaded)
        totalDownloaded = try c.decode(Int64.self, forKey: .totalDownloaded)
        upLimit = try c.decode(Int64.self, forKey: .upLimit)
        dlLimit = try c.decode(Int64.self, forKey: .dlLimit)
        timeElapsed = try c.decode(Int.self, forKey: .timeElapsed)
        seedingTime = try c.decode(Int.self, forKey: .seedingTime)
        nbConnections = try c.decode(Int.self, forKey: .nbConnections)
        shareRatio = try c.decode(Double.self, forKey: .shareRatio)
        additionDate = try c.decode(Int.self, forKey: .additionDate)
        completionDate = try c.decode(Int.self, forKey: .completionDate)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        lastSeen = try c.decode(Int.self, forKey: .lastSeen)
        peers = try c.decode(Int.self, forKey: .peers)
        seeds = try c.decode(Int.self, forKey: .seeds)
        piecesHave = try c.decode(Int.self, forKey: .piecesHave)
        piecesNum = try c.decode(Int.self, forKey: .piecesNum)
    }
}
