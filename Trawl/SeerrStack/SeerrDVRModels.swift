import Foundation

nonisolated enum SeerrDVRKind: String, Identifiable, CaseIterable, Sendable {
    case sonarr
    case radarr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        }
    }

    var symbolName: String {
        serviceIdentity.systemImage
    }

    var serviceIdentity: ServiceIdentity {
        switch self {
        case .sonarr: .sonarr
        case .radarr: .radarr
        }
    }

    var apiPathSegment: String {
        rawValue
    }

    var settingsPath: String { "/api/v1/settings/\(apiPathSegment)" }
    func settingsItemPath(id: Int) -> String { "/api/v1/settings/\(apiPathSegment)/\(id)" }
    var testPath: String { "/api/v1/settings/\(apiPathSegment)/test" }
    func servicePath(id: Int) -> String { "/api/v1/service/\(apiPathSegment)/\(id)" }
}

/// The settings record Overseerr returns from `/api/v1/settings/{sonarr|radarr}`.
/// One struct works for both because the optional fields collapse appropriately.
nonisolated struct SeerrDVRSettings: Codable, Identifiable, Sendable {
    var id: Int
    var name: String
    var hostname: String
    var port: Int
    var apiKey: String
    var useSsl: Bool?
    var baseUrl: String?
    var activeProfileId: Int
    var activeProfileName: String?
    var activeDirectory: String
    var is4k: Bool?
    var isDefault: Bool?
    var externalUrl: String?
    var syncEnabled: Bool?
    var preventSearch: Bool?
    var tagRequests: Bool?
    var tags: [Int]?
    // Radarr-only
    var minimumAvailability: String?
    // Sonarr-only
    var activeAnimeProfileId: Int?
    var activeAnimeDirectory: String?
    var activeLanguageProfileId: Int?
    var activeAnimeLanguageProfileId: Int?
    var enableSeasonFolders: Bool?

    var displayURL: String {
        let scheme = (useSsl ?? false) ? "https" : "http"
        var url = "\(scheme)://\(hostname):\(port)"
        if let baseUrl, !baseUrl.isEmpty {
            url += baseUrl.hasPrefix("/") ? baseUrl : "/\(baseUrl)"
        }
        return url
    }
}

/// Body posted to `/api/v1/settings/{sonarr|radarr}/test` to fetch profiles, root folders, and tags
/// before a server has been saved.
nonisolated struct SeerrDVRTestBody: Codable, Sendable {
    var hostname: String
    var port: Int
    var apiKey: String
    var useSsl: Bool
    var baseUrl: String?
}

nonisolated struct SeerrDVRTestResponse: Codable, Sendable {
    let profiles: [SeerrQualityProfile]?
    let rootFolders: [SeerrRootFolder]?
    let tags: [SeerrDVRTag]?
}

/// The `/api/v1/service/{kind}/{id}` endpoint also returns a stripped-down `server`
/// object alongside the picker data, but without credentials like `hostname` or
/// `apiKey`. We already have the full settings from the list call, so we ignore the
/// `server` field here and only decode what we need for the editor's pickers.
nonisolated struct SeerrDVRServiceResponse: Codable, Sendable {
    let profiles: [SeerrQualityProfile]?
    let rootFolders: [SeerrRootFolder]?
    let tags: [SeerrDVRTag]?
}

nonisolated struct SeerrQualityProfile: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String?

    var displayName: String { name ?? "Profile \(id)" }
}

nonisolated struct SeerrRootFolder: Codable, Identifiable, Hashable, Sendable {
    let id: Int?
    let path: String?
    let freeSpace: Int64?

    var resolvedID: Int { id ?? path?.hashValue ?? 0 }
    var displayPath: String { path ?? "Unknown" }
}

extension SeerrRootFolder {
    var safeID: String { path ?? "id-\(id ?? 0)" }
}

nonisolated struct SeerrDVRTag: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let label: String?

    var displayLabel: String { label ?? "Tag \(id)" }
}

nonisolated enum SeerrRadarrAvailability: String, CaseIterable, Identifiable, Sendable {
    case announced
    case inCinemas = "inCinemas"
    case released
    case preDB = "preDB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .announced: "Announced"
        case .inCinemas: "In Cinemas"
        case .released: "Released"
        case .preDB: "PreDB"
        }
    }
}
