import Foundation

// MARK: - Indexer

struct ProwlarrIndexer: Codable, Identifiable, Sendable {
    let id: Int
    var name: String?
    var enable: Bool
    let implementation: String?
    let implementationName: String?
    let configContract: String?
    let infoLink: String?
    var tags: [Int]?
    var priority: Int?
    let shouldSearch: Bool?
    let supportsRss: Bool?
    let supportsSearch: Bool?
    let `protocol`: ProwlarrIndexerProtocol?
    let fields: [ProwlarrIndexerField]?

    func toTestPayload() -> [String: Any] {
        var dict: [String: Any] = ["id": id]
        if let name { dict["name"] = name }
        dict["enable"] = enable
        if let implementation { dict["implementation"] = implementation }
        if let configContract { dict["configContract"] = configContract }
        if let fields {
            dict["fields"] = fields.map { field -> [String: Any] in
                var f: [String: Any] = ["name": field.name ?? ""]
                if let v = field.value {
                    switch v {
                    case .string(let s): f["value"] = s
                    case .int(let i): f["value"] = i
                    case .double(let d): f["value"] = d
                    case .bool(let b): f["value"] = b
                    case .null: break
                    }
                }
                return f
            }
        }
        return dict
    }
}

enum ProwlarrIndexerProtocol: String, Codable, Sendable {
    case usenet = "usenet"
    case torrent = "torrent"

    var displayName: String {
        switch self {
        case .usenet: "Usenet"
        case .torrent: "Torrent"
        }
    }

    var isTorrent: Bool { self == .torrent }

    var systemImage: String {
        switch self {
        case .torrent: "arrow.down.circle"
        case .usenet: "envelope.circle"
        }
    }
}

struct ProwlarrIndexerField: Codable, Sendable {
    let name: String?
    let label: String?
    let value: AnyCodableValue?
    let type: String?
    let advanced: Bool?
    let hidden: String?
}

/// Type-erased JSON value for indexer config fields
enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    var displayString: String? {
        switch self {
        case .string(let v): return v.isEmpty ? nil : v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "Yes" : "No"
        case .null: return nil
        }
    }
}

// MARK: - Search

enum ProwlarrSearchType: String, CaseIterable, Identifiable, Sendable {
    case search
    case tvsearch
    case moviesearch
    case audiosearch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .search: "All"
        case .tvsearch: "TV"
        case .moviesearch: "Movies"
        case .audiosearch: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .tvsearch: "tv"
        case .moviesearch: "film"
        case .audiosearch: "music.note"
        }
    }
}

struct ProwlarrSearchResult: Codable, Identifiable, Sendable {
    let guid: String?
    let title: String?
    let indexerId: Int?
    let indexer: String?
    let size: Int64?
    let seeders: Int?
    let leechers: Int?
    let categories: [ProwlarrCategory]?
    let downloadUrl: String?
    let infoUrl: String?
    let publishDate: String?
    let grabs: Int?
    let files: Int?
    let downloadVolumeFactor: Double?
    let uploadVolumeFactor: Double?
    let `protocol`: ProwlarrIndexerProtocol?

    var id: String { guid ?? UUID().uuidString }

    var isFreeleech: Bool { downloadVolumeFactor == 0.0 }

    var isTorrent: Bool { `protocol` == .torrent }

    var isMagnet: Bool {
        guard let url = downloadUrl else { return false }
        return url.lowercased().hasPrefix("magnet:")
    }

    var ageDescription: String? {
        guard let publishDate,
              let date = ISO8601DateFormatter().date(from: publishDate) else { return nil }
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: date, to: Date())
        if let days = components.day, days > 0 {
            return days == 1 ? "1d ago" : "\(days)d ago"
        }
        if let hours = components.hour, hours > 0 {
            return "\(hours)h ago"
        }
        return "Just now"
    }
}

struct ProwlarrCategory: Codable, Sendable {
    let id: Int?
    let name: String?
}

// MARK: - Indexer Stats

struct ProwlarrIndexerStats: Codable, Sendable {
    let indexers: [ProwlarrIndexerStatEntry]?
}

struct ProwlarrIndexerStatEntry: Codable, Identifiable, Sendable {
    let indexerId: Int?
    let indexerName: String?
    let averageResponseTime: Double?
    let numberOfQueries: Int?
    let numberOfGrabs: Int?
    let numberOfRssQueries: Int?
    let numberOfAuthQueries: Int?
    let numberOfFailedQueries: Int?
    let numberOfFailedGrabs: Int?
    let numberOfFailedRssQueries: Int?
    let numberOfFailedAuthQueries: Int?

    var id: Int { indexerId ?? 0 }

    var successRate: Double? {
        guard let total = numberOfQueries, total > 0, let failed = numberOfFailedQueries else { return nil }
        return Double(total - failed) / Double(total)
    }

    var avgResponseTimeFormatted: String? {
        guard let ms = averageResponseTime else { return nil }
        return String(format: "%.0fms", ms)
    }
}

// MARK: - Indexer Status

struct ProwlarrIndexerStatus: Codable, Identifiable, Sendable {
    let id: Int?
    let indexerId: Int?
    let disabledTill: String?
    let lastRssSyncReleaseDate: String?

    var isDisabled: Bool {
        guard let disabledTill,
              let date = ISO8601DateFormatter().date(from: disabledTill) else { return false }
        return date > Date()
    }
}
