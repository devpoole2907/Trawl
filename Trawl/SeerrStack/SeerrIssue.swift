import Foundation

struct SeerrIssueListResponse: Codable, Sendable {
    let pageInfo: SeerrPageInfo
    let results: [SeerrIssue]
}

struct SeerrIssue: Codable, Identifiable, Sendable {
    let id: Int
    let issueType: Int?
    let status: Int?
    let media: SeerrIssueMedia?
    let createdBy: SeerrUser?
    let modifiedBy: SeerrUser?
    let comments: [SeerrIssueComment]?
    let createdAt: String?
    let updatedAt: String?

    var issueStatus: SeerrIssueStatus? {
        guard let status else { return nil }
        return SeerrIssueStatus(rawValue: status)
    }

    var issueKind: SeerrIssueType? {
        guard let issueType else { return nil }
        return SeerrIssueType(rawValue: issueType)
    }

    var commentCount: Int {
        comments?.count ?? 0
    }

    var createdAtRelativeText: String? {
        Self.relativeDateText(from: createdAt)
    }

    var updatedAtRelativeText: String? {
        Self.relativeDateText(from: updatedAt)
    }

    fileprivate static func relativeDateText(from value: String?) -> String? {
        guard let value, let date = isoFormatter.date(from: value) else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let relativeFormatter = RelativeDateTimeFormatter()
}

struct SeerrIssueMedia: Codable, Sendable {
    let id: Int?
    let tmdbId: Int?
    let mediaType: String?
    let status: Int?
    let title: String?
    let originalTitle: String?
    let name: String?
    let originalName: String?
    let posterPath: String?

    var posterURL: URL? {
        guard let posterPath = posterPath, !posterPath.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
    var displayTitle: String { title ?? name ?? originalTitle ?? originalName ?? "Unknown Media" }
}

struct SeerrIssueComment: Codable, Identifiable, Sendable {
    let id: Int
    let user: SeerrUser?
    let message: String
    let createdAt: String?
    let updatedAt: String?

    var createdAtRelativeText: String? {
        SeerrIssue.relativeDateText(from: createdAt)
    }
}

enum SeerrIssueStatus: Int, Codable, Sendable {
    case open = 1
    case resolved = 2

    var title: String {
        switch self {
        case .open: "Open"
        case .resolved: "Resolved"
        }
    }

    var symbolName: String {
        switch self {
        case .open: "exclamationmark.circle"
        case .resolved: "checkmark.circle.fill"
        }
    }

    var tint: String {
        switch self {
        case .open: "orange"
        case .resolved: "green"
        }
    }
}

enum SeerrIssueType: Int, Codable, CaseIterable, Identifiable, Sendable {
    case video = 1
    case audio = 2
    case subtitle = 3
    case other = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .subtitle: "Subtitle"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .video: "video.slash"
        case .audio: "speaker.slash"
        case .subtitle: "captions.bubble.slash"
        case .other: "questionmark.circle"
        }
    }
}

struct SeerrUpdateUserBody: Codable, Sendable {
    let permissions: Int
}

struct SeerrImportJellyfinUsersBody: Codable, Sendable {
    let jellyfinUserIds: [String]
}

struct SeerrIssueCommentBody: Codable, Sendable {
    let message: String
}

struct EmptyRequestBody: Codable, Sendable {}
