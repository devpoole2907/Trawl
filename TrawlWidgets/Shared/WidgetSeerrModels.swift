import Foundation

// MARK: - Lightweight Seerr DTOs for widgets
//
// Split out of `WidgetSeerrClient.swift` so decoding and the display-name/title
// fallback chains can be compiled into the test target. The client itself depends
// on `HTTPTransport`, which the widget test target does not link.

nonisolated struct WidgetSeerrPageInfo: Codable, Sendable {
    let results: Int?
}

nonisolated struct WidgetSeerrPagedResponse<Element>: Codable, Sendable where Element: Codable & Sendable {
    let pageInfo: WidgetSeerrPageInfo
    let results: [Element]
}

nonisolated struct WidgetSeerrRequestCount: Codable, Sendable {
    let pending: Int?
}

typealias WidgetSeerrRequestListResponse = WidgetSeerrPagedResponse<WidgetSeerrMediaRequest>
typealias WidgetSeerrIssueListResponse = WidgetSeerrPagedResponse<WidgetSeerrIssue>

nonisolated struct WidgetSeerrMediaRequest: Codable, Identifiable, Sendable {
    let id: Int
    let media: WidgetSeerrRequestMedia?
    let createdAt: String?
    let requestedBy: WidgetSeerrUser?
    let is4k: Bool?
}

nonisolated struct WidgetSeerrRequestMedia: Codable, Sendable {
    let mediaType: String?
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? "Unknown Media"
    }

    var typeLabel: String {
        switch mediaType {
        case "movie": "Movie"
        case "tv": "Series"
        case let value?: value.capitalized
        case nil: "Media"
        }
    }
}

nonisolated struct WidgetSeerrIssue: Codable, Identifiable, Sendable {
    let id: Int
    let issueType: Int?
    let media: WidgetSeerrIssueMedia?
    let createdBy: WidgetSeerrUser?
    let createdAt: String?

    var issueKindLabel: String {
        switch issueType {
        case 1: "Video"
        case 2: "Audio"
        case 3: "Subtitle"
        case 4: "Other"
        default: "Issue"
        }
    }
}

nonisolated struct WidgetSeerrIssueMedia: Codable, Sendable {
    let title: String?
    let originalTitle: String?
    let name: String?
    let originalName: String?

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? "Unknown Media"
    }
}

nonisolated struct WidgetSeerrUser: Codable, Identifiable, Sendable {
    let id: Int
    let displayNameValue: String?
    let jellyfinUsername: String?
    let discordUsername: String?
    let email: String?
    let username: String?
    let plexUsername: String?

    var displayName: String {
        displayNameValue ??
        jellyfinUsername ??
        username ??
        plexUsername ??
        discordUsername ??
        fallbackNameFromEmail ??
        "User"
    }

    private var fallbackNameFromEmail: String? {
        guard let email, let localPart = email.split(separator: "@").first, !localPart.isEmpty else {
            return nil
        }
        return localPart
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { chunk in
                let value = String(chunk)
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayNameValue = "displayName"
        case jellyfinUsername
        case discordUsername
        case email
        case username
        case plexUsername
    }
}
