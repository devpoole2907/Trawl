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

// MARK: - Indexers

nonisolated enum ArrIndexerProtocol: String, Codable, Sendable {
    case unknown
    case usenet
    case torrent

    var displayName: String {
        switch self {
        case .unknown: "Other"
        case .usenet: "Usenet"
        case .torrent: "Torrent"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .usenet: "envelope.circle"
        case .torrent: "arrow.down.circle"
        }
    }

    var sectionTitle: String {
        switch self {
        case .torrent: "Torrent"
        case .usenet: "Usenet"
        case .unknown: "Other"
        }
    }
}

nonisolated struct ArrManagedIndexer: Codable, Identifiable, Sendable {
    let id: Int
    var name: String?
    let fields: [ArrIndexerField]?
    let implementationName: String?
    let implementation: String?
    let configContract: String?
    let infoLink: String?
    let message: ArrProviderMessage?
    var tags: [Int]?
    let presets: [ArrManagedIndexer]?
    var enableRss: Bool
    var enableAutomaticSearch: Bool
    var enableInteractiveSearch: Bool
    let supportsRss: Bool?
    let supportsSearch: Bool?
    let `protocol`: ArrIndexerProtocol?
    var priority: Int?
    var seasonSearchMaximumSingleEpisodeAge: Int?
    var downloadClientId: Int?
    private let _schemaListID: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fields
        case implementationName
        case implementation
        case configContract
        case infoLink
        case message
        case tags
        case presets
        case enableRss
        case enableAutomaticSearch
        case enableInteractiveSearch
        case supportsRss
        case supportsSearch
        case `protocol`
        case priority
        case seasonSearchMaximumSingleEpisodeAge
        case downloadClientId
    }

    init(
        id: Int,
        name: String?,
        fields: [ArrIndexerField]?,
        implementationName: String?,
        implementation: String?,
        configContract: String?,
        infoLink: String?,
        message: ArrProviderMessage?,
        tags: [Int]?,
        presets: [ArrManagedIndexer]?,
        enableRss: Bool,
        enableAutomaticSearch: Bool,
        enableInteractiveSearch: Bool,
        supportsRss: Bool?,
        supportsSearch: Bool?,
        protocol: ArrIndexerProtocol?,
        priority: Int?,
        seasonSearchMaximumSingleEpisodeAge: Int?,
        downloadClientId: Int?
    ) {
        self.id = id
        self.name = name
        self.fields = fields
        self.implementationName = implementationName
        self.implementation = implementation
        self.configContract = configContract
        self.infoLink = infoLink
        self.message = message
        self.tags = tags
        self.presets = presets
        self.enableRss = enableRss
        self.enableAutomaticSearch = enableAutomaticSearch
        self.enableInteractiveSearch = enableInteractiveSearch
        self.supportsRss = supportsRss
        self.supportsSearch = supportsSearch
        self.protocol = `protocol`
        self.priority = priority
        self.seasonSearchMaximumSingleEpisodeAge = seasonSearchMaximumSingleEpisodeAge
        self.downloadClientId = downloadClientId
        self._schemaListID = Self.computeSchemaListID(
            id: id,
            implementation: implementation,
            configContract: configContract,
            implementationName: implementationName,
            name: name
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        fields = try container.decodeIfPresent([ArrIndexerField].self, forKey: .fields)
        implementationName = try container.decodeIfPresent(String.self, forKey: .implementationName)
        implementation = try container.decodeIfPresent(String.self, forKey: .implementation)
        configContract = try container.decodeIfPresent(String.self, forKey: .configContract)
        infoLink = try container.decodeIfPresent(String.self, forKey: .infoLink)
        message = try container.decodeIfPresent(ArrProviderMessage.self, forKey: .message)
        tags = try container.decodeIfPresent([Int].self, forKey: .tags)
        presets = try container.decodeIfPresent([ArrManagedIndexer].self, forKey: .presets)
        enableRss = try container.decodeIfPresent(Bool.self, forKey: .enableRss) ?? false
        enableAutomaticSearch = try container.decodeIfPresent(Bool.self, forKey: .enableAutomaticSearch) ?? false
        enableInteractiveSearch = try container.decodeIfPresent(Bool.self, forKey: .enableInteractiveSearch) ?? false
        supportsRss = try container.decodeIfPresent(Bool.self, forKey: .supportsRss)
        supportsSearch = try container.decodeIfPresent(Bool.self, forKey: .supportsSearch)
        let protocolValue = try container.decodeIfPresent(String.self, forKey: .protocol)
        `protocol` = protocolValue.flatMap(ArrIndexerProtocol.init(rawValue:))
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        seasonSearchMaximumSingleEpisodeAge = try container.decodeIfPresent(Int.self, forKey: .seasonSearchMaximumSingleEpisodeAge)
        downloadClientId = try container.decodeIfPresent(Int.self, forKey: .downloadClientId)
        _schemaListID = Self.computeSchemaListID(
            id: id,
            implementation: implementation,
            configContract: configContract,
            implementationName: implementationName,
            name: name
        )
    }

    var schemaListID: String { _schemaListID }

    var isEnabled: Bool {
        enableRss || enableAutomaticSearch || enableInteractiveSearch
    }

    private static func computeSchemaListID(
        id: Int,
        implementation: String?,
        configContract: String?,
        implementationName: String?,
        name: String?
    ) -> String {
        if id != 0 {
            return "indexer-\(id)"
        }

        let components = [implementation, configContract, implementationName, name]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }

        return components.isEmpty
            ? "template-unknown"
            : "template-" + components.joined(separator: "::")
    }
}

nonisolated struct ArrIndexerField: Codable, Sendable {
    let order: Int?
    let name: String?
    let label: String?
    let unit: String?
    let helpText: String?
    let helpTextWarning: String?
    let helpLink: String?
    let value: ArrIndexerFieldValue?
    let type: String?
    let advanced: Bool?
    let selectOptions: [ArrIndexerSelectOption]?
    let selectOptionsProviderAction: String?
    let section: String?
    let hidden: String?
    let placeholder: String?
    let isFloat: Bool?
}

nonisolated struct ArrIndexerSelectOption: Codable, Identifiable, Sendable {
    let value: Int?
    let name: String?
    let order: Int?
    let hint: String?

    var id: String {
        "opt-\(value ?? order ?? 0)-\(name ?? "")"
    }
}

nonisolated struct ArrProviderMessage: Codable, Sendable {
    let message: String?
    let type: String?
}

nonisolated enum ArrIndexerFieldValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ArrIndexerFieldValue])
    case object([String: ArrIndexerFieldValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ArrIndexerFieldValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ArrIndexerFieldValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var displayString: String? {
        switch self {
        case .string(let value):
            return value.isEmpty ? nil : value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .bool(let value):
            return value ? "Yes" : "No"
        case .array(let value):
            return value.isEmpty ? nil : value.compactMap(\.displayString).joined(separator: ", ")
        case .object(let value):
            let entries = value
                .sorted { $0.key < $1.key }
                .compactMap { key, value -> String? in
                    guard let display = value.displayString, !display.isEmpty else { return nil }
                    return "\(key): \(display)"
                }
            return entries.isEmpty ? nil : entries.joined(separator: ", ")
        case .null:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return value.isFinite ? Int(value) : nil
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }
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
        status == "completed" || status == "failed" || status == "aborted" || status == "cancelled" || status == "orphaned"
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

// MARK: - Download Client

nonisolated struct ArrDownloadClient: Codable, Identifiable, Sendable {
    let id: Int
    var name: String?
    var fields: [ArrIndexerField]?
    let implementationName: String?
    let implementation: String?
    let configContract: String?
    let infoLink: String?
    let message: ArrProviderMessage?
    var tags: [Int]?
    var enable: Bool
    let supportsCategories: Bool?
    var priority: Int?
    var removeCompletedDownloads: Bool?
    var removeFailedDownloads: Bool?
    let `protocol`: ArrIndexerProtocol?

    enum CodingKeys: String, CodingKey {
        case id, name, fields, implementationName, implementation, configContract
        case infoLink, message, tags, enable, supportsCategories, priority
        case removeCompletedDownloads, removeFailedDownloads
        case `protocol`
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name)
        fields = try container.decodeIfPresent([ArrIndexerField].self, forKey: .fields)
        implementationName = try container.decodeIfPresent(String.self, forKey: .implementationName)
        implementation = try container.decodeIfPresent(String.self, forKey: .implementation)
        configContract = try container.decodeIfPresent(String.self, forKey: .configContract)
        infoLink = try container.decodeIfPresent(String.self, forKey: .infoLink)
        message = try container.decodeIfPresent(ArrProviderMessage.self, forKey: .message)
        tags = try container.decodeIfPresent([Int].self, forKey: .tags)
        enable = try container.decodeIfPresent(Bool.self, forKey: .enable) ?? false
        supportsCategories = try container.decodeIfPresent(Bool.self, forKey: .supportsCategories)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        removeCompletedDownloads = try container.decodeIfPresent(Bool.self, forKey: .removeCompletedDownloads)
        removeFailedDownloads = try container.decodeIfPresent(Bool.self, forKey: .removeFailedDownloads)
        let protocolValue = try container.decodeIfPresent(String.self, forKey: .protocol)
        `protocol` = protocolValue.flatMap(ArrIndexerProtocol.init(rawValue:))
    }

    var hostDisplayValue: String? {
        fields?.first(where: { ["host", "hostname"].contains($0.name?.lowercased()) })?.value?.displayString
    }

    var portDisplayValue: String? {
        fields?.first(where: { $0.name?.lowercased() == "port" })?.value?.displayString
    }

    func updatingField(named fieldName: String, with value: ArrIndexerFieldValue) -> ArrDownloadClient {
        var updated = self
        var nextFields = updated.fields ?? []
        if let index = nextFields.firstIndex(where: { $0.name == fieldName }) {
            let existing = nextFields[index]
            nextFields[index] = ArrIndexerField(
                order: existing.order, name: existing.name, label: existing.label,
                unit: existing.unit, helpText: existing.helpText,
                helpTextWarning: existing.helpTextWarning, helpLink: existing.helpLink,
                value: value, type: existing.type, advanced: existing.advanced,
                selectOptions: existing.selectOptions,
                selectOptionsProviderAction: existing.selectOptionsProviderAction,
                section: existing.section, hidden: existing.hidden,
                placeholder: existing.placeholder, isFloat: existing.isFloat
            )
        } else {
            nextFields.append(ArrIndexerField(
                order: nil, name: fieldName, label: nil, unit: nil,
                helpText: nil, helpTextWarning: nil, helpLink: nil,
                value: value, type: nil, advanced: nil, selectOptions: nil,
                selectOptionsProviderAction: nil, section: nil, hidden: nil,
                placeholder: nil, isFloat: nil
            ))
        }
        updated.fields = nextFields
        return updated
    }
}

// MARK: - Remote Path Mapping

nonisolated struct ArrRemotePathMapping: Codable, Identifiable, Sendable {
    var id: Int
    var host: String
    var remotePath: String
    var localPath: String
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
    case unsupportedIndexerService(String)
    case commandTimeout(commandId: Int?, lastKnownCommand: ArrCommand?)

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
        case .unsupportedIndexerService(let service):
            "\(service) does not support direct indexer management."
        case .commandTimeout(let commandId, let lastKnownCommand):
            if let cmd = lastKnownCommand, let status = cmd.status {
                "Command \(commandId ?? -1) timed out with status '\(status)'."
            } else {
                "Command \(commandId ?? -1) did not finish within the timeout period."
            }
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

    // Guard against path traversal in the server-supplied existingPath.
    // Reject the rebase if any component is ".." or "." to prevent directory escapes.
    let existingPathComponents = normalizedExisting.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !existingPathComponents.contains(".."), !existingPathComponents.contains(".") else {
        return existingPath // Return the original path unchanged rather than producing a traversed result
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

// MARK: - Naming Config

enum ArrColonReplacementFormat: Int, Codable, CaseIterable, Identifiable, Sendable {
    case delete = 0
    case dash = 1
    case spaceDash = 2
    case spaceDashSpace = 3
    case smart = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .delete: "Delete"
        case .dash: "Dash"
        case .spaceDash: "Space Dash"
        case .spaceDashSpace: "Space Dash Space"
        case .smart: "Smart"
        }
    }
}

nonisolated struct SonarrNamingConfig: Codable, Sendable {
    var id: Int?
    var renameEpisodes: Bool?
    var replaceIllegalCharacters: Bool?
    var colonReplacementFormat: Int?
    var multiEpisodeStyle: Int?
    var standardEpisodeFormat: String?
    var dailyEpisodeFormat: String?
    var animeEpisodeFormat: String?
    var seriesFolderFormat: String?
    var seasonFolderFormat: String?
    var specialsFolderFormat: String?
}

nonisolated struct RadarrNamingConfig: Codable, Sendable {
    var id: Int?
    var renameMovies: Bool?
    var replaceIllegalCharacters: Bool?
    var colonReplacementFormat: Int?
    var standardMovieFormat: String?
    var movieFolderFormat: String?

    private enum CodingKeys: String, CodingKey {
        case id, renameMovies, replaceIllegalCharacters, colonReplacementFormat, standardMovieFormat, movieFolderFormat
    }

    init(id: Int? = nil, renameMovies: Bool? = nil, replaceIllegalCharacters: Bool? = nil,
         colonReplacementFormat: Int? = nil, standardMovieFormat: String? = nil, movieFolderFormat: String? = nil) {
        self.id = id
        self.renameMovies = renameMovies
        self.replaceIllegalCharacters = replaceIllegalCharacters
        self.colonReplacementFormat = colonReplacementFormat
        self.standardMovieFormat = standardMovieFormat
        self.movieFolderFormat = movieFolderFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        renameMovies = try container.decodeIfPresent(Bool.self, forKey: .renameMovies)
        replaceIllegalCharacters = try container.decodeIfPresent(Bool.self, forKey: .replaceIllegalCharacters)
        standardMovieFormat = try container.decodeIfPresent(String.self, forKey: .standardMovieFormat)
        movieFolderFormat = try container.decodeIfPresent(String.self, forKey: .movieFolderFormat)
        // Some Radarr builds return colonReplacementFormat as a string ("delete", "dash", etc.)
        if let intVal = try? container.decodeIfPresent(Int.self, forKey: .colonReplacementFormat) {
            colonReplacementFormat = intVal
        } else if let strVal = try? container.decodeIfPresent(String.self, forKey: .colonReplacementFormat) {
            let map: [String: Int] = ["delete": 0, "dash": 1, "spacedash": 2, "spacedashspace": 3, "smart": 4]
            colonReplacementFormat = map[strVal.lowercased().replacingOccurrences(of: " ", with: "")]
        } else {
            colonReplacementFormat = nil
        }
    }
}
