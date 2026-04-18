import Foundation

// MARK: - System Status

struct ArrSystemStatus: Codable, Sendable {
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
    var id: String { "\(source ?? "")_\(type ?? "")" }
    let source: String?
    let type: String?       // "ok", "notice", "warning", "error"
    let message: String?
    let wikiUrl: String?
}

// MARK: - Quality Profile

struct ArrQualityProfile: Codable, Identifiable, Sendable {
    let id: Int
    let name: String
    let upgradeAllowed: Bool?
    let cutoff: Int?
    let items: [ArrQualityProfileItem]?
}

struct ArrQualityProfileItem: Codable, Sendable {
    let quality: ArrQuality?
    let allowed: Bool?
    let items: [ArrQualityProfileItem]?
}

struct ArrQuality: Codable, Sendable {
    let id: Int?
    let name: String?
    let source: String?
    let resolution: Int?
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

// MARK: - Queue

struct ArrQueuePage: Codable, Sendable {
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
}

struct ArrStatusMessage: Codable, Sendable {
    let title: String?
    let messages: [String]?
}

// MARK: - History

struct ArrHistoryPage: Codable, Sendable {
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

struct ArrCommand: Codable, Identifiable, Sendable {
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
        }
    }
}
