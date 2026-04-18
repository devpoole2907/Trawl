import Foundation

struct SyncMainData: Codable, Sendable {
    let rid: Int
    let fullUpdate: Bool?
    let torrents: [String: SyncTorrentData]?
    let torrentsRemoved: [String]?
    let categories: [String: SyncCategory]?
    let categoriesRemoved: [String]?
    let tags: [String]?
    let tagsRemoved: [String]?
    let serverState: ServerState?

    enum CodingKeys: String, CodingKey {
        case rid
        case fullUpdate = "full_update"
        case torrents
        case torrentsRemoved = "torrents_removed"
        case categories
        case categoriesRemoved = "categories_removed"
        case tags
        case tagsRemoved = "tags_removed"
        case serverState = "server_state"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rid = try c.decode(Int.self, forKey: .rid)
        fullUpdate = try c.decodeIfPresent(Bool.self, forKey: .fullUpdate)
        torrents = try c.decodeIfPresent([String: SyncTorrentData].self, forKey: .torrents)
        torrentsRemoved = try c.decodeIfPresent([String].self, forKey: .torrentsRemoved)
        categories = try c.decodeIfPresent([String: SyncCategory].self, forKey: .categories)
        categoriesRemoved = try c.decodeIfPresent([String].self, forKey: .categoriesRemoved)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        tagsRemoved = try c.decodeIfPresent([String].self, forKey: .tagsRemoved)
        serverState = try c.decodeIfPresent(ServerState.self, forKey: .serverState)
    }
}

/// Partial torrent data from sync — all fields optional because deltas only include changed fields
struct SyncTorrentData: Codable, Sendable {
    let name: String?
    let size: Int64?
    let progress: Double?
    let dlspeed: Int64?
    let upspeed: Int64?
    let priority: Int?
    let numSeeds: Int?
    let numLeechs: Int?
    let ratio: Double?
    let eta: Int?
    let state: TorrentState?
    let category: String?
    let tags: String?
    let addedOn: Int?
    let completionOn: Int?
    let savePath: String?
    let downloadedSession: Int64?
    let uploadedSession: Int64?
    let amountLeft: Int64?
    let totalSize: Int64?
    let comment: String?

    enum CodingKeys: String, CodingKey {
        case name, size, progress, dlspeed, upspeed, priority
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
}

struct SyncCategory: Codable, Sendable {
    let name: String?
    let savePath: String?

    enum CodingKeys: String, CodingKey {
        case name
        case savePath = "savePath"
    }
}

struct ServerState: Codable, Sendable {
    var dlInfoSpeed: Int64?
    var dlInfoData: Int64?
    var upInfoSpeed: Int64?
    var upInfoData: Int64?
    var dlRateLimit: Int64?
    var upRateLimit: Int64?
    var dhtNodes: Int?
    var connectionStatus: String?

    enum CodingKeys: String, CodingKey {
        case dlInfoSpeed = "dl_info_speed"
        case dlInfoData = "dl_info_data"
        case upInfoSpeed = "up_info_speed"
        case upInfoData = "up_info_data"
        case dlRateLimit = "dl_rate_limit"
        case upRateLimit = "up_rate_limit"
        case dhtNodes = "dht_nodes"
        case connectionStatus = "connection_status"
    }

    /// Merge non-nil fields from another ServerState into this one
    func merging(_ other: ServerState) -> ServerState {
        var merged = self
        if let v = other.dlInfoSpeed { merged.dlInfoSpeed = v }
        if let v = other.dlInfoData { merged.dlInfoData = v }
        if let v = other.upInfoSpeed { merged.upInfoSpeed = v }
        if let v = other.upInfoData { merged.upInfoData = v }
        if let v = other.dlRateLimit { merged.dlRateLimit = v }
        if let v = other.upRateLimit { merged.upRateLimit = v }
        if let v = other.dhtNodes { merged.dhtNodes = v }
        if let v = other.connectionStatus { merged.connectionStatus = v }
        return merged
    }
}

/// Placeholder for app-level preferences from qBittorrent
struct AppPreferences: Codable, Sendable {
    let savePath: String?
    let maxRatio: Double?
    let maxSeedingTime: Int?
    let webUiPort: Int?
    let altDownloadLimit: Int64?
    let altUploadLimit: Int64?

    enum CodingKeys: String, CodingKey {
        case savePath = "save_path"
        case maxRatio = "max_ratio"
        case maxSeedingTime = "max_seeding_time"
        case webUiPort = "web_ui_port"
        case altDownloadLimit = "alt_dl_limit"
        case altUploadLimit = "alt_up_limit"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savePath = try c.decodeIfPresent(String.self, forKey: .savePath)
        maxRatio = try c.decodeIfPresent(Double.self, forKey: .maxRatio)
        maxSeedingTime = try c.decodeIfPresent(Int.self, forKey: .maxSeedingTime)
        webUiPort = try c.decodeIfPresent(Int.self, forKey: .webUiPort)
        altDownloadLimit = try c.decodeIfPresent(Int64.self, forKey: .altDownloadLimit)
        altUploadLimit = try c.decodeIfPresent(Int64.self, forKey: .altUploadLimit)
    }
}

/// Tracker info from /api/v2/torrents/trackers
struct TorrentTracker: Codable, Identifiable, Sendable {
    var id: String { url }

    let url: String
    let status: Int
    let tier: Int
    let numPeers: Int
    let numSeeds: Int
    let numLeeches: Int
    let numDownloaded: Int
    let msg: String

    enum CodingKeys: String, CodingKey {
        case url, status, tier
        case numPeers = "num_peers"
        case numSeeds = "num_seeds"
        case numLeeches = "num_leeches"
        case numDownloaded = "num_downloaded"
        case msg
    }
}
