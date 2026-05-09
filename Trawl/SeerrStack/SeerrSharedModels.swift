import Foundation

struct SeerrPageInfo: nonisolated Codable, Sendable {
    let pages: Int?
    let pageSize: Int?
    let results: Int?
    let page: Int?
}

struct SeerrRequestCount: nonisolated Codable, Sendable {
    let total: Int?
    let movie: Int?
    let tv: Int?
    let pending: Int?
    let approved: Int?
    let processing: Int?
    let available: Int?
    let declined: Int?
    let failed: Int?
    let completed: Int?
}

struct SeerrPagedResponse<Element>: nonisolated Codable, Sendable where Element: Codable & Sendable {
    let pageInfo: SeerrPageInfo
    let results: [Element]
}

typealias SeerrRequestListResponse = SeerrPagedResponse<SeerrMediaRequest>

struct SeerrMediaRequest: nonisolated Codable, Identifiable, Sendable {
    let id: Int
    let status: Int?
    let media: SeerrRequestMedia?
    let createdAt: String?
    let updatedAt: String?
    let requestedBy: SeerrUser?
    let is4k: Bool?
    let rootFolder: String?

    var requestStatus: SeerrRequestStatus? {
        guard let status else { return nil }
        return SeerrRequestStatus(rawValue: status)
    }

    var createdAtRelativeText: String? {
        SeerrDateFormatter.relativeDateText(from: createdAt)
    }
}

struct SeerrRequestMedia: nonisolated Codable, Sendable {
    let id: Int?
    let tmdbId: Int?
    let tvdbId: Int?
    let status: Int?
    let mediaType: String?
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let posterPath: String?

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? tmdbDisplayTitle
    }

    var typeLabel: String {
        switch mediaType {
        case "movie": "Movie"
        case "tv": "Series"
        case let value?: value.capitalized
        case nil: "Media"
        }
    }

    var posterURL: URL? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }

    private var tmdbDisplayTitle: String {
        if let tmdbId { return "TMDb \(tmdbId)" }
        return "Unknown Media"
    }
}

struct SeerrMediaSummary: nonisolated Codable, Sendable {
    let id: Int?
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let posterPath: String?
    let releaseDate: String?
    let firstAirDate: String?

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? id.map { "TMDb \($0)" } ?? "Unknown Media"
    }

    var yearText: String? {
        let dateText = releaseDate ?? firstAirDate
        guard let dateText, dateText.count >= 4 else { return nil }
        return String(dateText.prefix(4))
    }

    var posterURL: URL? {
        guard let posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
}

enum SeerrRequestStatus: Int, nonisolated Codable, Sendable {
    case pending = 1
    case approved = 2
    case declined = 3
    case processing = 4
    case available = 5
    case failed = 6
    case completed = 7

    var title: String {
        switch self {
        case .pending: "Pending"
        case .approved: "Approved"
        case .declined: "Declined"
        case .processing: "Processing"
        case .available: "Available"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }
}

enum SeerrRequestFilter: String, CaseIterable, Identifiable {
    case pending = "Pending"
    case approved = "Approved"
    case all = "All"

    var id: String { rawValue }

    var apiValue: String {
        switch self {
        case .pending: "pending"
        case .approved: "approved"
        case .all: "all"
        }
    }
}

struct SeerrServerLogEntry: nonisolated Codable, Identifiable, Sendable {
    let label: String?
    let level: String?
    let message: String?
    let timestamp: String?
    let data: SeerrJSONValue?
    let uuid: UUID

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        level = try container.decodeIfPresent(String.self, forKey: .level)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        data = try container.decodeIfPresent(SeerrJSONValue.self, forKey: .data)
        uuid = (try? container.decodeIfPresent(UUID.self, forKey: .uuid)) ?? UUID()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(level, forKey: .level)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encode(uuid, forKey: .uuid)
    }

    var id: String {
        "\(uuid)-\(timestamp ?? "")-\(label ?? "")-\(level ?? "")-\(message ?? "")"
    }

    enum CodingKeys: String, CodingKey {
        case label, level, message, timestamp, data, uuid
    }

    var timestampDate: Date? {
        SeerrDateFormatter.date(from: timestamp)
    }

    var prettyPrintedData: String? {
        guard let data, !data.isEmpty else { return nil }
        return data.prettyPrinted
    }
}

enum SeerrJSONValue: nonisolated Codable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([SeerrJSONValue])
    case object([String: SeerrJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SeerrJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: SeerrJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .null: return true
        case .array(let value): return value.isEmpty
        case .object(let value): return value.isEmpty
        default: return false
        }
    }

    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(self),
            let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }
}

struct SeerrJellyfinUser: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let username: String?
    let email: String?
    let thumb: String?

    var displayName: String {
        if let username, !username.isEmpty { return username }
        if let email, !email.isEmpty { return email }
        return id
    }
}

enum SeerrLogLevelFilter: String, CaseIterable, Identifiable {
    case debug = "Debug"
    case info = "Info"
    case warn = "Warn"
    case error = "Error"

    var id: String { rawValue }
    var apiValue: String { rawValue.lowercased() }
}
