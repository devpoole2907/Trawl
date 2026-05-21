import Foundation
import SwiftUI

nonisolated struct SeerrPageInfo: Codable, Sendable {
    let pages: Int?
    let pageSize: Int?
    let results: Int?
    let page: Int?
}

nonisolated struct SeerrRequestCount: Codable, Sendable {
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

nonisolated struct SeerrPagedResponse<Element>: Codable, Sendable where Element: Codable & Sendable {
    let pageInfo: SeerrPageInfo
    let results: [Element]
}

typealias SeerrRequestListResponse = SeerrPagedResponse<SeerrMediaRequest>

nonisolated struct SeerrMediaRequest: Codable, Identifiable, Sendable {
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

    var badgeStatus: SeerrRequestBadgeStatus? {
        guard let requestStatus else { return nil }

        if requestStatus == .approved {
            switch media?.mediaStatus {
            case .processing, .pending, .unknown:
                return .processing
            case .partiallyAvailable:
                return .partiallyAvailable
            case .available:
                return .available
            case .blocklisted, .deleted, nil:
                break
            }
        }

        return SeerrRequestBadgeStatus(requestStatus: requestStatus)
    }

    var createdAtRelativeText: String? {
        SeerrDateFormatter.relativeDateText(from: createdAt)
    }
}

nonisolated struct SeerrRequestMedia: Codable, Sendable {
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

    var mediaStatus: SeerrMediaStatus? {
        guard let status else { return nil }
        return SeerrMediaStatus(rawValue: status)
    }
}

nonisolated enum SeerrMediaStatus: Int, Codable, Sendable {
    case unknown = 1
    case pending = 2
    case processing = 3
    case partiallyAvailable = 4
    case available = 5
    case blocklisted = 6
    case deleted = 7
}

nonisolated struct SeerrMediaSummary: Codable, Sendable {
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

nonisolated enum SeerrRequestStatus: Int, Codable, Sendable {
    case pending = 1
    case approved = 2
    case declined = 3
    case failed = 4
    case completed = 5

    var title: String {
        switch self {
        case .pending: "Pending"
        case .approved: "Approved"
        case .declined: "Declined"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }

    var statusColor: Color {
        switch self {
        case .pending: .orange
        case .approved: .green
        case .declined: .red
        case .failed: .red
        case .completed: .green
        }
    }
}

nonisolated enum SeerrRequestBadgeStatus: Sendable {
    case pending
    case approved
    case processing
    case partiallyAvailable
    case available
    case declined
    case failed
    case completed

    init(requestStatus: SeerrRequestStatus) {
        switch requestStatus {
        case .pending: self = .pending
        case .approved: self = .approved
        case .declined: self = .declined
        case .failed: self = .failed
        case .completed: self = .completed
        }
    }

    var title: String {
        switch self {
        case .pending: "Pending"
        case .approved: "Approved"
        case .processing: "Processing"
        case .partiallyAvailable: "Partial"
        case .available: "Available"
        case .declined: "Declined"
        case .failed: "Failed"
        case .completed: "Completed"
        }
    }

    var statusColor: Color {
        switch self {
        case .pending: .orange
        case .approved: .green
        case .processing: .blue
        case .partiallyAvailable: .teal
        case .available: .green
        case .declined: .red
        case .failed: .red
        case .completed: .green
        }
    }
}

enum SeerrRequestFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case pending = "Pending"
    case approved = "Approved"

    var id: String { rawValue }

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }

    var apiValue: String {
        switch self {
        case .pending: "pending"
        case .approved: "approved"
        case .all: "all"
        }
    }
}

nonisolated struct SeerrJob: Codable, Identifiable, Sendable {
    let id: String
    let name: String?
    let type: String?
    let interval: String?
    let nextExecutionTime: String?
    let running: Bool?
}

nonisolated struct SeerrServerLogEntry: Codable, Identifiable, Sendable {
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

nonisolated enum SeerrJSONValue: Codable, Sendable {
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

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(rawValue, value: self)
    }

    var apiValue: String { rawValue.lowercased() }
}
