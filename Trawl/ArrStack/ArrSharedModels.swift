import Foundation

// MARK: - System Status

nonisolated struct ArrSystemStatus: Codable, Sendable {
    let appName: String?
    let instanceName: String?
    let version: String?
    let buildTime: String?
    let isDebug: Bool?
    let isProduction: Bool?
    let isAdmin: Bool?
    let isUserInteractive: Bool?
    let startupPath: String?
    let appData: String?
    let osName: String?
    let osVersion: String?
    let isDocker: Bool?
    let isLinux: Bool?
    let isOsx: Bool?
    let isWindows: Bool?
    let urlBase: String?
    let runtimeVersion: String?
    let runtimeName: String?
}

// MARK: - Health Check

struct ArrHealthCheck: Codable, Identifiable, Sendable {
    var id: String { [source, type, message, wikiUrl].map { $0 ?? "" }.joined(separator: "|") }
    let source: String?
    let type: String?       // "ok", "notice", "warning", "error"
    let message: String?
    let wikiUrl: String?
}

// MARK: - Quality Profile

nonisolated struct ArrQualityProfile: Codable, Identifiable, Sendable {
    var id: Int
    var name: String
    var upgradeAllowed: Bool?
    var cutoff: Int?
    var items: [ArrQualityProfileItem]?
}

nonisolated struct ArrQualityProfileItem: Codable, Sendable {
    var quality: ArrQuality?
    var allowed: Bool?
    var items: [ArrQualityProfileItem]?
}

nonisolated struct ArrQuality: Codable, Sendable {
    var id: Int?
    var name: String?
    var source: String?
    var resolution: Int?
}

// MARK: - Root Folder

struct ArrRootFolder: Codable, Identifiable, Sendable {
    let id: Int
    let path: String
    let accessible: Bool?
    let freeSpace: Int64?
    let totalSpace: Int64?
}

// MARK: - Tag

struct ArrTag: Codable, Identifiable, Sendable {
    let id: Int
    let label: String
}

// MARK: - Release Sort

enum ArrReleaseSortKey: String, CaseIterable, Identifiable, Codable {
    case `default` = "Default"
    case age = "Age"
    case quality = "Quality"
    case size = "Size"
    case seeders = "Seeders"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .default:  "square.stack"
        case .age:      "clock"
        case .quality:  "sparkles"
        case .size:     "externaldrive"
        case .seeders:  "arrow.up.circle"
        }
    }
}

enum ArrSeasonPackFilter: String, CaseIterable, Identifiable, Codable {
    case any = "Any"
    case season = "Season Pack"
    case episode = "Single Episode"

    var id: String { rawValue }
}

// MARK: - Release Sort State

struct ArrReleaseSort: RawRepresentable, Codable {
    var option: ArrReleaseSortKey = .default
    var isAscending: Bool = false
    var indexer: String = ""   // "" = all indexers
    var quality: String = ""   // "" = all qualities
    var approvedOnly: Bool = false
    var seasonPack: ArrSeasonPackFilter = .any

    var isFiltered: Bool {
        !indexer.isEmpty || !quality.isEmpty || approvedOnly || seasonPack != .any
    }

    var isActive: Bool {
        option != .default || isFiltered
    }

    init() {}

    var rawValue: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    init?(rawValue: String) {
        if let data = rawValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ArrReleaseSort.self, from: data) {
            self = decoded
        } else {
            self = ArrReleaseSort()
        }
    }
}

// MARK: - Releases

struct ArrRelease: Codable, Identifiable, Sendable {
    let guid: String?
    let indexerId: Int?
    let title: String?
    let indexer: String?
    let protocol_: String?
    let size: Int64?
    let age: Int?
    let ageHours: Double?
    let ageMinutes: Double?
    let approved: Bool?
    let rejected: Bool?
    let temporarilyRejected: Bool?
    let downloadAllowed: Bool?
    let rejections: [String]?
    let seeders: Int?
    let leechers: Int?
    let customFormatScore: Int?
    let quality: ArrReleaseQuality?
    let infoUrl: String?
    let downloadUrl: String?
    let magnetUrl: String?
    let fullSeason: Bool?

    enum CodingKeys: String, CodingKey {
        case guid, indexerId, title, indexer, size, age, ageHours, ageMinutes
        case approved, rejected, temporarilyRejected, downloadAllowed, rejections
        case seeders, leechers, customFormatScore, quality, infoUrl, downloadUrl, magnetUrl, fullSeason
        case protocol_ = "protocol"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        indexerId = try container.decodeIfPresent(Int.self, forKey: .indexerId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        indexer = try container.decodeIfPresent(String.self, forKey: .indexer)
        protocol_ = try container.decodeIfPresent(String.self, forKey: .protocol_)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        age = try container.decodeIfPresent(Int.self, forKey: .age)
        ageHours = try container.decodeFlexibleDoubleIfPresent(forKey: .ageHours)
        ageMinutes = try container.decodeFlexibleDoubleIfPresent(forKey: .ageMinutes)
        approved = try container.decodeIfPresent(Bool.self, forKey: .approved)
        rejected = try container.decodeIfPresent(Bool.self, forKey: .rejected)
        temporarilyRejected = try container.decodeIfPresent(Bool.self, forKey: .temporarilyRejected)
        downloadAllowed = try container.decodeIfPresent(Bool.self, forKey: .downloadAllowed)
        rejections = try container.decodeIfPresent([String].self, forKey: .rejections)
        seeders = try container.decodeIfPresent(Int.self, forKey: .seeders)
        leechers = try container.decodeIfPresent(Int.self, forKey: .leechers)
        customFormatScore = try container.decodeIfPresent(Int.self, forKey: .customFormatScore)
        quality = try container.decodeIfPresent(ArrReleaseQuality.self, forKey: .quality)
        infoUrl = try container.decodeIfPresent(String.self, forKey: .infoUrl)
        downloadUrl = try container.decodeIfPresent(String.self, forKey: .downloadUrl)
        magnetUrl = try container.decodeIfPresent(String.self, forKey: .magnetUrl)
        fullSeason = try container.decodeIfPresent(Bool.self, forKey: .fullSeason)
    }

    var id: String {
        let guidPart = guid ?? title ?? "release"
        return "\(guidPart)|\(indexerId ?? -1)"
    }

    var canGrab: Bool {
        if downloadAllowed == false { return false }
        if rejected == true || temporarilyRejected == true { return false }
        return approved ?? true
    }

    var qualityName: String {
        quality?.quality?.name ?? "Unknown Quality"
    }

    var protocolName: String {
        protocol_?.uppercased() ?? "UNKNOWN"
    }

    var ageDescription: String? {
        if let ageHours, ageHours > 0 {
            let roundedHours = Int(ageHours.rounded())
            return roundedHours >= 24 ? "\(roundedHours / 24)d" : "\(roundedHours)h"
        }
        if let age, age > 0 {
            return "\(age)d"
        }
        if let ageMinutes, ageMinutes > 0 {
            let roundedMinutes = Int(ageMinutes.rounded())
            return "\(roundedMinutes)m"
        }
        return nil
    }
}

struct ArrReleaseQuality: Codable, Sendable {
    let quality: ArrQuality?
}

nonisolated struct ArrReleaseGrabRequest: Codable, Sendable {
    let guid: String
    let indexerId: Int
}

private extension KeyedDecodingContainer where K == ArrRelease.CodingKeys {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

// MARK: - Queue

nonisolated struct ArrQueuePage: Codable, Sendable {
    let page: Int?
    let pageSize: Int?
    let sortKey: String?
    let sortDirection: String?
    let totalRecords: Int?
    let records: [ArrQueueItem]?
}

struct ArrQueueItem: Codable, Identifiable, Sendable {
    let id: Int
    let title: String?
    let status: String?             // "downloading", "completed", "delay", "paused", etc.
    let trackedDownloadStatus: String?  // "ok", "warning", "error"
    let trackedDownloadState: String?   // "downloading", "importPending", "importing", "failedPending"
    let statusMessages: [ArrStatusMessage]?
    let downloadId: String?
    let protocol_: String?
    let downloadClient: String?
    let outputPath: String?
    let size: Double?
    let sizeleft: Double?
    let timeleft: String?           // TimeSpan format "HH:MM:SS"
    let estimatedCompletionTime: String?

    // Sonarr-specific
    let seriesId: Int?
    let episodeId: Int?
    let seasonNumber: Int?

    // Radarr-specific
    let movieId: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, status, trackedDownloadStatus, trackedDownloadState
        case statusMessages, downloadId
        case protocol_ = "protocol"
        case downloadClient, outputPath, size, sizeleft, timeleft
        case estimatedCompletionTime
        case seriesId, episodeId, seasonNumber
        case movieId
    }

    /// Download progress 0.0 to 1.0
    var progress: Double {
        guard let size, size > 0, let sizeleft else { return 0 }
        return max(0, min(1, (size - sizeleft) / size))
    }

    var normalizedState: String {
        (trackedDownloadState ?? status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var isDownloadingQueueItem: Bool {
        normalizedState == "downloading"
    }

    var isImportIssueQueueItem: Bool {
        if normalizedState == "importpending" || normalizedState == "failedpending" {
            return true
        }

        let normalizedStatus = trackedDownloadStatus?.lowercased()
        return normalizedStatus == "warning" || normalizedStatus == "error"
    }

    var primaryStatusMessage: String? {
        statusMessages?
            .compactMap(\.messages)
            .flatMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct ArrStatusMessage: Codable, Sendable {
    let title: String?
    let messages: [String]?
}

// MARK: - History

nonisolated struct ArrHistoryPage: Codable, Sendable {
    let page: Int?
    let pageSize: Int?
    let sortKey: String?
    let sortDirection: String?
    let totalRecords: Int?
    let records: [ArrHistoryRecord]?
}

struct ArrHistoryRecord: Codable, Identifiable, Sendable {
    let id: Int
    let eventType: String?          // "grabbed", "downloadFolderImported", "downloadFailed", etc.
    let date: String?
    let sourceTitle: String?
    let quality: ArrHistoryQuality?
    let downloadId: String?

    // Sonarr
    let seriesId: Int?
    let episodeId: Int?

    // Radarr
    let movieId: Int?
}

struct ArrHistoryQuality: Codable, Sendable {
    let quality: ArrQuality?
}

// MARK: - Calendar (shared shape, content type differs)

struct ArrImage: Codable, Sendable {
    let coverType: String?      // "banner", "poster", "fanart"
    let url: String?
    let remoteUrl: String?
}

// MARK: - Ratings

struct ArrRatings: Codable, Sendable {
    let votes: Int?
    let value: Double?
}

// MARK: - Command

nonisolated struct ArrCommand: Codable, Identifiable, Sendable {
    let id: Int?
    let name: String?
    let commandName: String?
    let status: String?         // "queued", "started", "completed", "failed"
    let queued: String?
    let started: String?
    let ended: String?
    let stateChangeTime: String?
    let lastExecutionTime: String?
    let trigger: String?
    let exception: String?      // error message when status == "failed"

    var isTerminal: Bool {
        status == "completed" || status == "failed"
    }
    var succeeded: Bool { status == "completed" }
}

// MARK: - Blocklist

nonisolated struct ArrBlocklistPage: Codable, Sendable {
    let page: Int?
    let pageSize: Int?
    let totalRecords: Int?
    let records: [ArrBlocklistItem]?
}

struct ArrBlocklistItem: Codable, Identifiable, Sendable {
    let id: Int
    let seriesId: Int?
    let movieId: Int?
    let episodeIds: [Int]?
    let sourceTitle: String?
    let indexer: String?
    let message: String?
    let date: String?
    let quality: ArrBlocklistQuality?

    enum CodingKeys: String, CodingKey {
        case id, seriesId, movieId, episodeIds, sourceTitle, indexer, message, date, quality
    }
}

struct ArrBlocklistQuality: Codable, Sendable {
    let quality: ArrQuality?
}

// MARK: - Disk Space

struct ArrDiskSpace: Codable, Identifiable, Sendable {
    let id: String
    let path: String?
    let label: String?
    let freeSpace: Int64?
    let totalSpace: Int64?

    init(path: String?, label: String?, freeSpace: Int64?, totalSpace: Int64?) {
        self.path = path
        self.label = label
        self.freeSpace = freeSpace
        self.totalSpace = totalSpace
        self.id = path ?? UUID().uuidString
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        freeSpace = try container.decodeIfPresent(Int64.self, forKey: .freeSpace)
        totalSpace = try container.decodeIfPresent(Int64.self, forKey: .totalSpace)
        id = path ?? UUID().uuidString
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(freeSpace, forKey: .freeSpace)
        try container.encodeIfPresent(totalSpace, forKey: .totalSpace)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case label
        case freeSpace
        case totalSpace
    }
}

// MARK: - Disk Space Snapshot (UI model)

struct ArrDiskSpaceSnapshot: Identifiable, Sendable {
    let serviceType: ArrServiceType
    let path: String
    let label: String?
    let freeSpace: Int64?
    let totalSpace: Int64?

    var id: String { "\(serviceType.rawValue)-\(path)" }
}

// MARK: - Update Info

struct ArrUpdateInfo: Codable, Identifiable, Sendable {
    let id: String
    let version: String?
    let releaseDate: String?
    let fileName: String?
    let url: String?
    let installed: Bool?
    let installable: Bool?
    let latest: Bool?
    let changes: ArrUpdateChanges?

    struct ArrUpdateChanges: Codable, Sendable {
        let new: [String]?
        let fixed: [String]?
    }

    init(version: String?, releaseDate: String?, fileName: String?, url: String?, installed: Bool?, installable: Bool?, latest: Bool?, changes: ArrUpdateChanges?) {
        self.id = version ?? UUID().uuidString
        self.version = version
        self.releaseDate = releaseDate
        self.fileName = fileName
        self.url = url
        self.installed = installed
        self.installable = installable
        self.latest = latest
        self.changes = changes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed)
        installable = try container.decodeIfPresent(Bool.self, forKey: .installable)
        latest = try container.decodeIfPresent(Bool.self, forKey: .latest)
        changes = try container.decodeIfPresent(ArrUpdateChanges.self, forKey: .changes)
        id = version ?? UUID().uuidString
    }

    private enum CodingKeys: String, CodingKey {
        case version, releaseDate, fileName, url, installed, installable, latest, changes
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(installed, forKey: .installed)
        try container.encodeIfPresent(installable, forKey: .installable)
        try container.encodeIfPresent(latest, forKey: .latest)
        try container.encodeIfPresent(changes, forKey: .changes)
    }
}

// MARK: - Arr Error

enum ArrError: LocalizedError, Sendable {
    case invalidAPIKey
    case invalidURL
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
    case serverError(statusCode: Int, message: String?)
    case noServiceConfigured
    case connectionFailed
    case unsupportedNotificationsService(String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Invalid API key. Check your *arr service settings."
        case .invalidURL:
            "Invalid service URL."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            "Invalid response from server."
        case .decodingError(let error):
            "Failed to parse response: \(error.localizedDescription)"
        case .serverError(let code, let msg):
            "Server error (\(code)): \(msg ?? "Unknown")"
        case .noServiceConfigured:
            "No service configured."
        case .connectionFailed:
            "Could not connect. Check the URL and ensure the service is running."
        case .unsupportedNotificationsService(let service):
            "\(service) does not support one-tap notification setup."
        }
    }
}

// MARK: - Shared Helpers

/// Computes a new absolute path by replacing an existing root with a new one.
/// Preserves leading separators (POSIX / or Windows UNC/Root) to ensure the path remains absolute.
func rebasedLibraryPath(existingPath: String, existingRoot: String, newRoot: String) -> String {
    let normalizedExisting = existingPath.replacingOccurrences(of: "\\", with: "/")
    let normalizedExistingRoot = existingRoot.replacingOccurrences(of: "\\", with: "/")
    let normalizedNewRoot = newRoot.replacingOccurrences(of: "\\", with: "/")

    if normalizedExisting.isEmpty {
        return ""
    }

    let suffix: String
    if normalizedExistingRoot.isEmpty {
        suffix = normalizedExisting
    } else if normalizedExisting.compare(normalizedExistingRoot, options: [.anchored]) == .orderedSame,
              (normalizedExisting.count == normalizedExistingRoot.count ||
               normalizedExisting[normalizedExisting.index(normalizedExisting.startIndex, offsetBy: normalizedExistingRoot.count)] == "/") {
        suffix = String(normalizedExisting.dropFirst(normalizedExistingRoot.count))
    } else {
        suffix = normalizedExisting
    }

    // Guard against path traversal in the server-supplied newRoot.
    // Reject the rebase if any component is ".." or "." to prevent directory escapes.
    let newRootComponents = normalizedNewRoot.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !newRootComponents.contains(".."), !newRootComponents.contains(".") else {
        return existingPath // Return the original path unchanged rather than producing a traversed result
    }

    // Trim only trailing separators from newRoot, not leading
    var resultRoot = normalizedNewRoot
    while resultRoot.hasSuffix("/") { resultRoot.removeLast() }

    // Join
    let trimmedSuffix = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
    let finalPath: String
    if resultRoot.isEmpty {
        finalPath = suffix
    } else if trimmedSuffix.isEmpty {
        finalPath = resultRoot
    } else {
        finalPath = resultRoot + "/" + trimmedSuffix
    }
    
    // Restore separators based on the new root style.
    if newRoot.contains("\\") {
        return finalPath.replacingOccurrences(of: "/", with: "\\")
    }

    return finalPath.replacingOccurrences(of: "\\", with: "/")
}
