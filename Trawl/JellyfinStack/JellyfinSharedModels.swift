import Foundation

// Convention: camelCase Swift properties, `CodingKeys` map to Jellyfin's
// PascalCase JSON. All structs are `nonisolated`, `Codable`, `Sendable`
// so they cross actor boundaries safely.

// MARK: - Auth

nonisolated struct JellyfinAuthByNameBody: Encodable, Sendable {
    let username: String
    let pw: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case pw = "Pw"
    }
}

nonisolated struct JellyfinAuthResponse: Decodable, Sendable {
    let user: JellyfinUser
    let accessToken: String
    let serverId: String?

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

// MARK: - User

nonisolated struct JellyfinUser: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let serverId: String?
    let hasPassword: Bool?
    let hasConfiguredPassword: Bool?
    let lastLoginDate: String?
    let lastActivityDate: String?
    let policy: JellyfinUserPolicy?
    let configuration: JellyfinUserConfiguration?

    var isAdministrator: Bool { policy?.isAdministrator == true }
    var isDisabled: Bool { policy?.isDisabled == true }
    var isHidden: Bool { policy?.isHidden == true }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
        case hasPassword = "HasPassword"
        case hasConfiguredPassword = "HasConfiguredPassword"
        case lastLoginDate = "LastLoginDate"
        case lastActivityDate = "LastActivityDate"
        case policy = "Policy"
        case configuration = "Configuration"
    }
}

nonisolated struct JellyfinUserPolicy: Codable, Sendable {
    var isAdministrator: Bool?
    var isHidden: Bool?
    var isDisabled: Bool?
    var enableContentDeletion: Bool?
    var enableMediaPlayback: Bool?
    var enableAudioPlaybackTranscoding: Bool?
    var enableVideoPlaybackTranscoding: Bool?
    var enablePlaybackRemuxing: Bool?
    var enableLiveTvAccess: Bool?
    var enableLiveTvManagement: Bool?
    var enableSyncTranscoding: Bool?
    var enableMediaConversion: Bool?
    var enableSharedDeviceControl: Bool?
    var enableRemoteAccess: Bool?
    var enableUserPreferenceAccess: Bool?

    enum CodingKeys: String, CodingKey {
        case isAdministrator = "IsAdministrator"
        case isHidden = "IsHidden"
        case isDisabled = "IsDisabled"
        case enableContentDeletion = "EnableContentDeletion"
        case enableMediaPlayback = "EnableMediaPlayback"
        case enableAudioPlaybackTranscoding = "EnableAudioPlaybackTranscoding"
        case enableVideoPlaybackTranscoding = "EnableVideoPlaybackTranscoding"
        case enablePlaybackRemuxing = "EnablePlaybackRemuxing"
        case enableLiveTvAccess = "EnableLiveTvAccess"
        case enableLiveTvManagement = "EnableLiveTvManagement"
        case enableSyncTranscoding = "EnableSyncTranscoding"
        case enableMediaConversion = "EnableMediaConversion"
        case enableSharedDeviceControl = "EnableSharedDeviceControl"
        case enableRemoteAccess = "EnableRemoteAccess"
        case enableUserPreferenceAccess = "EnableUserPreferenceAccess"
    }
}

nonisolated struct JellyfinUserConfiguration: Codable, Sendable {
    var audioLanguagePreference: String?
    var subtitleLanguagePreference: String?
    var displayMissingEpisodes: Bool?
    var enableNextEpisodeAutoPlay: Bool?
    var subtitleMode: String?
    var displayCollectionsView: Bool?
    var hidePlayedInLatest: Bool?
    var rememberAudioSelections: Bool?
    var rememberSubtitleSelections: Bool?
    var orderedViews: [String]?

    enum CodingKeys: String, CodingKey {
        case audioLanguagePreference = "AudioLanguagePreference"
        case subtitleLanguagePreference = "SubtitleLanguagePreference"
        case displayMissingEpisodes = "DisplayMissingEpisodes"
        case enableNextEpisodeAutoPlay = "EnableNextEpisodeAutoPlay"
        case subtitleMode = "SubtitleMode"
        case displayCollectionsView = "DisplayCollectionsView"
        case hidePlayedInLatest = "HidePlayedInLatest"
        case rememberAudioSelections = "RememberAudioSelections"
        case rememberSubtitleSelections = "RememberSubtitleSelections"
        case orderedViews = "OrderedViews"
    }
}

nonisolated struct JellyfinCreateUserBody: Encodable, Sendable {
    let name: String
    let password: String?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case password = "Password"
    }
}

nonisolated struct JellyfinPasswordChangeBody: Encodable, Sendable {
    let currentPw: String?
    let newPw: String
    let resetPassword: Bool

    enum CodingKeys: String, CodingKey {
        case currentPw = "CurrentPw"
        case newPw = "NewPw"
        case resetPassword = "ResetPassword"
    }
}

// MARK: - System

nonisolated struct JellyfinSystemPublicInfo: Decodable, Sendable {
    let id: String?
    let serverName: String?
    let version: String?
    let productName: String?
    let startupCompleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case startupCompleted = "StartupCompleted"
    }
}

nonisolated struct JellyfinSystemInfo: Decodable, Sendable {
    let id: String?
    let serverName: String?
    let version: String?
    let operatingSystem: String?
    let productName: String?
    let webSocketPortNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case operatingSystem = "OperatingSystem"
        case productName = "ProductName"
        case webSocketPortNumber = "WebSocketPortNumber"
    }
}

// MARK: - Libraries

nonisolated struct JellyfinVirtualFolder: Decodable, Identifiable, Sendable {
    let name: String
    let locations: [String]
    let collectionType: String?
    let itemId: String
    let refreshStatus: String?

    var id: String { itemId }

    var collectionIcon: String {
        switch collectionType {
        case "movies": "film"
        case "tvshows": "tv"
        case "music": "music.note"
        case "books": "book"
        case "homevideos": "house"
        case "musicvideos": "music.note.list"
        case "mixed": "square.grid.2x2"
        default: "folder"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case locations = "Locations"
        case collectionType = "CollectionType"
        case itemId = "ItemId"
        case refreshStatus = "RefreshStatus"
    }
}

nonisolated struct JellyfinFileSystemEntryInfo: Decodable, Identifiable, Sendable {
    let name: String?
    let path: String
    let type: String?

    var id: String { path }

    var isDirectory: Bool {
        switch type?.lowercased() {
        case "file":
            false
        default:
            true
        }
    }

    var remotePathEntry: RemotePathEntry {
        RemotePathEntry(
            name: displayName,
            path: path,
            kind: remoteKind,
            isDirectory: isDirectory
        )
    }

    private var remoteKind: RemotePathEntryKind {
        switch type?.lowercased() {
        case "file":
            .file
        case "directory":
            .directory
        case "networkshare":
            .networkShare
        case "parent":
            .parent
        case "drive":
            .drive
        default:
            isDirectory ? .directory : .unknown
        }
    }

    private var displayName: String {
        if let name, !name.isEmpty { return name }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case path = "Path"
        case type = "Type"
    }
}

nonisolated struct JellyfinVirtualFolderBody: Encodable, Sendable {
    let name: String
    let collectionType: String
    let paths: [String]
    let refreshLibrary: Bool

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case collectionType = "CollectionType"
        case paths = "Paths"
        case refreshLibrary = "RefreshLibrary"
    }
}

nonisolated struct JellyfinMediaPathBody: Encodable, Sendable {
    let name: String
    let pathInfo: JellyfinMediaPathInfo

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case pathInfo = "PathInfo"
    }
}

nonisolated struct JellyfinMediaPathInfo: Encodable, Sendable {
    let path: String

    enum CodingKeys: String, CodingKey {
        case path = "Path"
    }
}

nonisolated struct JellyfinItemsResponse: Decodable, Sendable {
    let items: [JellyfinLibraryItem]
    let totalRecordCount: Int?
    let startIndex: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }
}

nonisolated struct JellyfinLibraryItem: Decodable, Identifiable, Sendable {
    let id: String
    let name: String?
    let type: String?
    let path: String?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let dateCreated: String?
    let providerIds: [String: String]?
    let mediaSources: [JellyfinMediaSource]?

    var providerIDSummary: String {
        guard let providerIds, !providerIds.isEmpty else { return "No provider IDs" }
        return providerIds
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }

    var fileSize: Int64? {
        mediaSources?.compactMap(\.size).first
    }

    var runtimeMinutes: Int? {
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        return Int((Double(runTimeTicks) / 10_000_000 / 60).rounded())
    }

    func providerID(for keys: [String]) -> String? {
        guard let providerIds else { return nil }
        for key in keys {
            if let exact = providerIds[key], !exact.isEmpty {
                return exact
            }
            if let matched = providerIds.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
               !matched.isEmpty {
                return matched
            }
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case path = "Path"
        case productionYear = "ProductionYear"
        case runTimeTicks = "RunTimeTicks"
        case dateCreated = "DateCreated"
        case providerIds = "ProviderIds"
        case mediaSources = "MediaSources"
    }
}

nonisolated struct JellyfinMediaSource: Decodable, Sendable {
    let id: String?
    let path: String?
    let size: Int64?
    let container: String?
    let videoType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case path = "Path"
        case size = "Size"
        case container = "Container"
        case videoType = "VideoType"
    }
}

// MARK: - Sessions

nonisolated struct JellyfinSession: Decodable, Identifiable, Sendable {
    let id: String
    let userId: String?
    let userName: String?
    let deviceName: String?
    let client: String?
    let applicationVersion: String?
    let lastActivityDate: String?
    let supportsRemoteControl: Bool?
    let nowPlayingItem: JellyfinNowPlayingItem?
    let playState: JellyfinPlayState?

    var isActive: Bool { nowPlayingItem != nil }

    var progressFraction: Double {
        guard
            let position = playState?.positionTicks, position > 0,
            let total = nowPlayingItem?.runTimeTicks, total > 0
        else { return 0 }
        return min(Double(position) / Double(total), 1)
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userId = "UserId"
        case userName = "UserName"
        case deviceName = "DeviceName"
        case client = "Client"
        case applicationVersion = "ApplicationVersion"
        case lastActivityDate = "LastActivityDate"
        case supportsRemoteControl = "SupportsRemoteControl"
        case nowPlayingItem = "NowPlayingItem"
        case playState = "PlayState"
    }
}

nonisolated struct JellyfinNowPlayingItem: Decodable, Sendable {
    let id: String?
    let name: String?
    let type: String?
    let runTimeTicks: Int64?
    let seriesName: String?
    let seasonName: String?
    let indexNumber: Int?

    var mediaType: String { type ?? "Unknown" }

    var episodeDetail: String? {
        var parts: [String] = []
        if let season = seasonName { parts.append(season) }
        if let episode = indexNumber { parts.append("Episode \(episode)") }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    /// Human-readable duration like "1h 23m". Ticks are 100-nanosecond intervals.
    var formattedDuration: String {
        guard let ticks = runTimeTicks, ticks > 0 else { return "" }
        let seconds = ticks / 10_000_000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case runTimeTicks = "RunTimeTicks"
        case seriesName = "SeriesName"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
    }
}

nonisolated struct JellyfinPlayState: Decodable, Sendable {
    let positionTicks: Int64?
    let isPaused: Bool?
    let isMuted: Bool?
    let canSeek: Bool?
    let playMethod: String?
    let repeatMode: String?
    let volumeLevel: Int?

    enum CodingKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
        case repeatMode = "RepeatMode"
        case volumeLevel = "VolumeLevel"
    }
}

nonisolated struct JellyfinSessionMessageBody: Encodable, Sendable {
    let header: String
    let text: String
    let timeoutMs: Int?

    enum CodingKeys: String, CodingKey {
        case header = "Header"
        case text = "Text"
        case timeoutMs = "TimeoutMs"
    }
}

// MARK: - Activity Log

nonisolated struct JellyfinActivityResponse: Decodable, Sendable {
    let items: [JellyfinActivityEntry]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

nonisolated struct JellyfinActivityEntry: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let overview: String?
    let shortOverview: String?
    let type: String?
    let userId: String?
    let date: String
    let severity: String?

    var severityIcon: String {
        switch severity?.lowercased() {
        case "error", "fatal": "xmark.circle.fill"
        case "warning", "warn": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case overview = "Overview"
        case shortOverview = "ShortOverview"
        case type = "Type"
        case userId = "UserId"
        case date = "Date"
        case severity = "Severity"
    }
}

// MARK: - Scheduled Tasks

nonisolated struct JellyfinScheduledTask: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let category: String?
    let state: String
    let currentProgressPercentage: Double?
    let lastExecutionResult: JellyfinScheduledTaskResult?

    var isRunning: Bool { state == "Running" }
    var isIdle: Bool { state == "Idle" }
    var isCancelling: Bool { state == "Cancelling" }

    var stateBadge: String {
        switch state {
        case "Running": "Running"
        case "Cancelling": "Cancelling"
        default: "Idle"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case description = "Description"
        case category = "Category"
        case state = "State"
        case currentProgressPercentage = "CurrentProgressPercentage"
        case lastExecutionResult = "LastExecutionResult"
    }
}

nonisolated struct JellyfinScheduledTaskResult: Decodable, Sendable {
    let startTimeUtc: String?
    let endTimeUtc: String?
    let status: String?
    let errorMessage: String?

    var statusBadge: String {
        switch status {
        case "Completed": "Completed"
        case "Failed": "Failed"
        case "Cancelled": "Cancelled"
        default: status ?? "Unknown"
        }
    }

    var isSuccess: Bool { status == "Completed" }
    var isFailure: Bool { status == "Failed" || status == "Cancelled" }

    enum CodingKeys: String, CodingKey {
        case startTimeUtc = "StartTimeUtc"
        case endTimeUtc = "EndTimeUtc"
        case status = "Status"
        case errorMessage = "ErrorMessage"
    }
}

// MARK: - Plugins

nonisolated struct JellyfinPlugin: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let configurationFileName: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case version = "Version"
        case description = "Description"
        case configurationFileName = "ConfigurationFileName"
        case status = "Status"
    }
}
