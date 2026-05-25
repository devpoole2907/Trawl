#if DEBUG
import Foundation

extension JellyfinUser {
    static let preview = JellyfinUser.makePreview()
    static let previewAdmin = JellyfinUser.makePreview(
        id: "admin-uuid", name: "Admin",
        policy: .previewAdmin
    )
    static let previewDisabled = JellyfinUser.makePreview(
        id: "disabled-uuid", name: "Disabled User",
        policy: .previewDisabled
    )
    static let previewRestricted = JellyfinUser.makePreview(
        id: "restricted-uuid",
        name: "Kids Profile",
        policy: .previewRestricted
    )
    static let previewLongName = JellyfinUser.makePreview(
        id: "long-name-uuid",
        name: "A Very Long Jellyfin Display Name That Wraps In Tight Form Rows",
        policy: .previewStandard
    )
    static let previewList: [JellyfinUser] = [
        preview, previewAdmin, previewDisabled, previewRestricted,
        .makePreview(id: "user4", name: "Alice", policy: .previewStandard),
        .makePreview(id: "user5", name: "Bob", policy: nil),
    ]
    static let previewHeavyList: [JellyfinUser] = (1...20).map { i in
        .makePreview(
            id: "user-\(i)",
            name: i.isMultiple(of: 5) ? "Very Long Display Name User \(i)" : "User \(i)",
            policy: i == 1 ? .previewAdmin : (i.isMultiple(of: 7) ? .previewDisabled : .previewStandard)
        )
    }

    fileprivate static func makePreview(
        id: String = "preview-user-uuid",
        name: String = "Preview User",
        policy: JellyfinUserPolicy? = .previewStandard
    ) -> JellyfinUser {
        JellyfinUser(
            id: id,
            name: name,
            serverId: "preview-server",
            hasPassword: true,
            hasConfiguredPassword: true,
            lastLoginDate: "2026-05-20T09:30:00.0000000Z",
            lastActivityDate: "2026-05-23T19:45:00.0000000Z",
            policy: policy,
            configuration: nil
        )
    }
}

extension JellyfinUserPolicy {
    static let previewStandard: JellyfinUserPolicy = {
        var policy = JellyfinUserPolicy()
        policy.isAdministrator = false
        policy.isHidden = false
        policy.isDisabled = false
        policy.enableMediaPlayback = true
        policy.enableAudioPlaybackTranscoding = true
        policy.enableVideoPlaybackTranscoding = true
        policy.enablePlaybackRemuxing = true
        policy.enableContentDownloading = true
        policy.enableSubtitleManagement = true
        policy.enableRemoteAccess = true
        policy.enableUserPreferenceAccess = true
        policy.enableAllDevices = true
        policy.enableAllChannels = true
        policy.enableAllFolders = true
        policy.syncPlayAccess = "CreateAndJoinGroups"
        policy.maxActiveSessions = 4
        return policy
    }()

    static let previewAdmin: JellyfinUserPolicy = {
        var policy = previewStandard
        policy.isAdministrator = true
        policy.enableContentDeletion = true
        policy.enableCollectionManagement = true
        policy.enableLiveTvManagement = true
        return policy
    }()

    static let previewDisabled: JellyfinUserPolicy = {
        var policy = previewStandard
        policy.isDisabled = true
        policy.enableRemoteAccess = false
        return policy
    }()

    static let previewRestricted: JellyfinUserPolicy = {
        var policy = previewStandard
        policy.enableAllFolders = false
        policy.enabledFolders = ["movies-id", "tvshows-id"]
        policy.blockedMediaFolders = ["music-id"]
        policy.enableAllDevices = false
        policy.enabledDevices = ["device-1"]
        policy.maxParentalRating = 7
        policy.allowedTags = ["family"]
        policy.blockedTags = ["horror"]
        policy.blockUnratedItems = ["Movie", "Series"]
        policy.accessSchedules = [
            JellyfinAccessSchedule(dayOfWeek: "Monday", startHour: 16, endHour: 21.5),
            JellyfinAccessSchedule(dayOfWeek: "Saturday", startHour: 8, endHour: 22),
        ]
        return policy
    }()
}

extension JellyfinParentalRating {
    static let preview = JellyfinParentalRating(name: "PG-13", score: 7)
    static let previewList: [JellyfinParentalRating] = [
        .init(name: "G", score: 1),
        .init(name: "PG", score: 5),
        preview,
        .init(name: "R", score: 9),
        .init(name: "Unrated", score: nil),
    ]
}

extension JellyfinDeviceInfo {
    static let preview = JellyfinDeviceInfo(
        id: "device-1",
        name: "Living Room Apple TV",
        appName: "Infuse",
        lastUserName: "Preview User"
    )
    static let previewList: [JellyfinDeviceInfo] = [
        preview,
        .init(id: "device-2", name: "iPhone", appName: "Jellyfin", lastUserName: "Alice"),
        .init(id: "device-3", name: "Chrome", appName: "Jellyfin Web", lastUserName: "Admin"),
    ]
}

extension JellyfinSystemInfo {
    static let preview = JellyfinSystemInfo.makePreview()
    static let previewMissingDetails = JellyfinSystemInfo.makePreview(
        serverName: "Preview Jellyfin",
        version: "10.10.0",
        operatingSystem: ""
    )
    static let previewHeavy = JellyfinSystemInfo.makePreview(
        serverName: "This Is An Extremely Long Jellyfin Server Name That Tests Label Truncation And Layout Stability",
        version: "10.99.999.99999-dev",
        operatingSystem: "Linux (Ubuntu 24.04.2 LTS x86_64 kernel 6.8.0-58-generic)"
    )

    fileprivate static func makePreview(
        serverName: String = "My Jellyfin Server",
        version: String = "10.9.7",
        operatingSystem: String = "Linux"
    ) -> JellyfinSystemInfo {
        let json: [String: Any] = [
            "Id": "server-uuid-0000-0000-0000-000000000000",
            "ServerName": serverName,
            "Version": version,
            "OperatingSystem": operatingSystem,
            "ProductName": "Jellyfin Server",
            "WebSocketPortNumber": 8096
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinSystemInfo.self, from: data)
    }
}

extension JellyfinSession {
    static let preview = JellyfinSession.makePreview()
    static let previewActive = JellyfinSession.makePreview(
        id: "session-2",
        userName: "Alice",
        deviceName: "Apple TV",
        client: "Infuse",
        nowPlayingItem: JellyfinNowPlayingItem.makePreview(),
        playState: .preview
    )
    static let previewPaused = JellyfinSession.makePreview(
        id: "session-4",
        userName: "Preview User",
        deviceName: "iPad",
        client: "Jellyfin",
        nowPlayingItem: JellyfinNowPlayingItem.makePreview(name: "Severance", type: "Episode"),
        playState: .previewPaused
    )
    static let previewList: [JellyfinSession] = [
        previewActive,
        previewPaused,
        preview,
        .makePreview(id: "session-3", userName: "Bob", deviceName: "iPhone", client: "Jellyfin"),
    ]

    fileprivate static func makePreview(
        id: String = "session-1",
        userName: String = "Preview User",
        deviceName: String = "MacBook Pro",
        client: String = "Jellyfin Web",
        nowPlayingItem: JellyfinNowPlayingItem? = nil,
        playState: JellyfinPlayState? = nil
    ) -> JellyfinSession {
        var json: [String: Any] = [
            "Id": id,
            "UserId": "preview-user-uuid",
            "UserName": userName,
            "DeviceName": deviceName,
            "Client": client,
            "ApplicationVersion": "10.9.7",
            "LastActivityDate": "2026-05-23T19:45:00.0000000Z",
            "SupportsRemoteControl": true
        ]
        if let item = nowPlayingItem {
            json["NowPlayingItem"] = [
                "Id": item.id ?? "item-1",
                "Name": item.name ?? "Unknown",
                "Type": item.type ?? "Movie",
                "RunTimeTicks": item.runTimeTicks ?? 7_200_000_000,
                "SeriesName": item.seriesName ?? "Preview Series",
                "SeasonName": item.seasonName ?? "Season 1",
                "IndexNumber": item.indexNumber ?? 1
            ]
            json["PlayState"] = [
                "PositionTicks": playState?.positionTicks ?? 1_800_000_000,
                "IsPaused": playState?.isPaused ?? false,
                "CanSeek": playState?.canSeek ?? true,
                "PlayMethod": playState?.playMethod ?? "DirectPlay",
                "VolumeLevel": playState?.volumeLevel ?? 80
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinSession.self, from: data)
    }
}

extension JellyfinNowPlayingItem {
    static let preview = JellyfinNowPlayingItem.makePreview()

    fileprivate static func makePreview(
        id: String = "item-uuid",
        name: String = "The Shawshank Redemption",
        type: String = "Movie",
        runTimeTicks: Int64 = 8_280_000_000
    ) -> JellyfinNowPlayingItem {
        var json: [String: Any] = [
            "Id": id, "Name": name, "Type": type,
            "RunTimeTicks": runTimeTicks
        ]
        if type == "Episode" {
            json["SeriesName"] = "Preview Series"
            json["SeasonName"] = "Season 1"
            json["IndexNumber"] = 1
        }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinNowPlayingItem.self, from: data)
    }
}

extension JellyfinPlayState {
    static let preview = JellyfinPlayState(
        positionTicks: 1_800_000_000,
        isPaused: false,
        isMuted: false,
        canSeek: true,
        playMethod: "DirectPlay",
        repeatMode: "RepeatNone",
        volumeLevel: 80
    )
    static let previewPaused = JellyfinPlayState(
        positionTicks: 3_200_000_000,
        isPaused: true,
        isMuted: false,
        canSeek: true,
        playMethod: "Transcode",
        repeatMode: "RepeatNone",
        volumeLevel: 35
    )
}

extension JellyfinActivityEntry {
    static let preview = JellyfinActivityEntry.makePreview()
    static let previewList: [JellyfinActivityEntry] = [
        preview,
        .makePreview(id: 2, name: "User logged in", type: "SessionStarted", severity: "Info"),
        .makePreview(id: 3, name: "Playback error", type: "PlaybackError", severity: "Error"),
        .makePreview(id: 4, name: "Library scan completed", type: "LibraryScanComplete", severity: "Info"),
    ]

    fileprivate static func makePreview(
        id: Int = 1,
        name: String = "Preview User logged in",
        type: String? = "SessionStarted",
        severity: String? = "Info"
    ) -> JellyfinActivityEntry {
        var json: [String: Any] = [
            "Id": id, "Name": name,
            "Type": type ?? NSNull(),
            "Severity": severity ?? NSNull(),
            "ShortOverview": "\(name) on the preview server.",
            "Date": "2024-01-15T12:00:00.0000000Z"
        ]
        if id.isMultiple(of: 2) {
            json["UserId"] = "preview-user-uuid"
        }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinActivityEntry.self, from: data)
    }
}

extension JellyfinScheduledTask {
    static let preview = JellyfinScheduledTask.makePreview()
    static let previewRunning = JellyfinScheduledTask.makePreview(id: "scan-task", name: "Scan Media Library", state: "Running", progress: 45.0)
    static let previewList: [JellyfinScheduledTask] = [
        preview, previewRunning,
        .makePreview(id: "clean-task", name: "Clean Up Database", state: "Idle"),
        .makePreview(id: "transcode-task", name: "Transcode Sub Items", state: "Idle"),
    ]

    fileprivate static func makePreview(
        id: String = "refresh-task",
        name: String = "Refresh Metadata",
        state: String = "Idle",
        progress: Double? = nil
    ) -> JellyfinScheduledTask {
        var json: [String: Any] = [
            "Id": id, "Name": name,
            "Description": "Refreshes metadata for items in your library.",
            "Category": "Library",
            "State": state,
            "LastExecutionResult": [
                "StartTimeUtc": "2026-05-23T04:00:00.0000000Z",
                "EndTimeUtc": "2026-05-23T04:08:00.0000000Z",
                "Status": "Completed"
            ]
        ]
        if let progress = progress {
            json["CurrentProgressPercentage"] = progress
        }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinScheduledTask.self, from: data)
    }
}

extension JellyfinPlugin {
    static let preview = JellyfinPlugin.makePreview()
    static let previewList: [JellyfinPlugin] = [
        preview,
        .makePreview(id: "plugin2", name: "Trakt", version: "3.0.2"),
        .makePreview(id: "plugin3", name: "Skin Manager", version: "2.0.0.1"),
    ]

    fileprivate static func makePreview(
        id: String = "plugin1",
        name: String = "TMDb Box Sets",
        version: String = "1.0.0.0"
    ) -> JellyfinPlugin {
        let json: [String: Any] = [
            "Id": id, "Name": name, "Version": version,
            "Description": "Organizes movies into collections based on TMDb box sets.",
            "Status": "Active"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinPlugin.self, from: data)
    }
}

extension JellyfinVirtualFolder {
    static let preview = JellyfinVirtualFolder.makePreview()
    static let previewList: [JellyfinVirtualFolder] = [
        preview,
        .makePreview(name: "Movies", itemId: "movies-id", collectionType: "movies", locations: ["/data/movies"]),
        .makePreview(name: "Music", itemId: "music-id", collectionType: "music", locations: ["/data/music"]),
    ]

    fileprivate static func makePreview(
        name: String = "TV Shows",
        itemId: String = "tvshows-id",
        collectionType: String = "tvshows",
        locations: [String] = ["/data/tv"]
    ) -> JellyfinVirtualFolder {
        let json: [String: Any] = [
            "Name": name, "ItemId": itemId,
            "CollectionType": collectionType, "Locations": locations,
            "RefreshStatus": "Idle"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinVirtualFolder.self, from: data)
    }
}

extension JellyfinLibraryItem {
    static let preview = JellyfinLibraryItem.makePreview()
    static let previewList: [JellyfinLibraryItem] = [
        preview,
        .makePreview(id: "item2", name: "Breaking Bad S01E01", type: "Episode"),
        .makePreview(id: "item3", name: "Dune: Part Two", type: "Movie", productionYear: 2024),
    ]
    static let previewHeavyList: [JellyfinLibraryItem] = (1...30).map { i in
        .makePreview(id: "item-\(i)", name: i.isMultiple(of: 5) ? "Very Long Media Item Name \(i)" : "Item \(i)")
    }

    fileprivate static func makePreview(
        id: String = "item1",
        name: String = "The Shawshank Redemption",
        type: String = "Movie",
        productionYear: Int = 1994
    ) -> JellyfinLibraryItem {
        let json: [String: Any] = [
            "Id": id, "Name": name, "Type": type,
            "ProductionYear": productionYear,
            "RunTimeTicks": 7_200_000_000
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(JellyfinLibraryItem.self, from: data)
    }
}
#endif
