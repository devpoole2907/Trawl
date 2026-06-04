#if DEBUG
import Foundation

enum ArrPreviewRuntime {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}

// MARK: - ArrSystemStatus

extension ArrSystemStatus {
    static let preview = ArrSystemStatus(
        appName: "Sonarr",
        instanceName: "Sonarr Preview",
        version: "4.0.12.2823",
        buildTime: "2026-05-01T09:30:00Z",
        isDebug: false,
        isProduction: true,
        isAdmin: true,
        isUserInteractive: true,
        startupPath: "/app/sonarr/bin",
        appData: "/config",
        osName: "Linux",
        osVersion: "6.8.0",
        isDocker: true,
        isLinux: true,
        isOsx: false,
        isWindows: false,
        urlBase: "",
        runtimeVersion: "8.0.14",
        runtimeName: ".NET"
    )
}

// MARK: - ArrQualityProfile

extension ArrQualityProfile {
    static let preview = ArrQualityProfile(
        id: 1,
        name: "HD-1080p",
        upgradeAllowed: true,
        cutoff: 7,
        items: [
            .init(id: 10, name: "WEB 1080p", quality: .init(id: 7, name: "WEBDL-1080p", source: "web", resolution: 1080), allowed: true, items: nil),
            .init(id: 11, name: "BluRay 1080p", quality: .init(id: 8, name: "Bluray-1080p", source: "bluray", resolution: 1080), allowed: true, items: nil),
            .init(id: 12, name: "HDTV 720p", quality: .init(id: 4, name: "HDTV-720p", source: "television", resolution: 720), allowed: false, items: nil),
        ],
        minFormatScore: 0,
        cutoffFormatScore: 100,
        minUpgradeFormatScore: 1,
        formatItems: [
            .init(id: 1, format: 101, name: "HDR", score: 50),
            .init(id: 2, format: 102, name: "Release Group Penalty", score: -10),
        ],
        language: .init(id: 1, name: "English")
    )
    static let previewList: [ArrQualityProfile] = [
        preview,
        .init(
            id: 2,
            name: "4K",
            upgradeAllowed: true,
            cutoff: 19,
            items: [
                .init(id: 20, name: "WEB 2160p", quality: .init(id: 18, name: "WEBDL-2160p", source: "web", resolution: 2160), allowed: true, items: nil),
                .init(id: 21, name: "BluRay 2160p", quality: .init(id: 19, name: "Bluray-2160p", source: "bluray", resolution: 2160), allowed: true, items: nil),
            ],
            minFormatScore: 0,
            cutoffFormatScore: 200,
            minUpgradeFormatScore: 1,
            formatItems: [.init(id: 3, format: 201, name: "Dolby Vision", score: 80)],
            language: .init(id: 1, name: "English")
        ),
        .init(
            id: 3,
            name: "SD",
            upgradeAllowed: false,
            cutoff: 2,
            items: [
                .init(id: 30, name: "DVD", quality: .init(id: 2, name: "DVD", source: "dvd", resolution: 480), allowed: true, items: nil),
                .init(id: 31, name: "HDTV 720p", quality: .init(id: 4, name: "HDTV-720p", source: "television", resolution: 720), allowed: false, items: nil),
            ],
            minFormatScore: nil,
            cutoffFormatScore: nil,
            minUpgradeFormatScore: nil,
            formatItems: nil,
            language: .init(id: 1, name: "English")
        ),
    ]
}

// MARK: - ArrRootFolder

extension ArrRootFolder {
    static let preview = ArrRootFolder(id: 1, path: "/tv", accessible: true, freeSpace: 500_000_000_000, totalSpace: 2_000_000_000_000)
    static let previewList: [ArrRootFolder] = [
        preview,
        .init(id: 2, path: "/movies", accessible: true, freeSpace: 800_000_000_000, totalSpace: 4_000_000_000_000),
        .init(id: 3, path: "/archive/offline", accessible: false, freeSpace: nil, totalSpace: nil),
    ]
}

// MARK: - ArrTag

extension ArrTag {
    static let preview = ArrTag(id: 1, label: "4k")
    static let previewList: [ArrTag] = [
        preview,
        .init(id: 2, label: "remux"),
        .init(id: 3, label: "anime"),
    ]
}

// MARK: - ArrHealthCheck

extension ArrHealthCheck {
    static let preview = ArrHealthCheck.makePreview()
    static let previewWarning = ArrHealthCheck.makePreview(type: "warning", message: "Indexer is disabled due to failures: TorrentLeech")
    static let previewError = ArrHealthCheck.makePreview(type: "error", message: "Download client Transmission is unavailable")
    static let previewList: [ArrHealthCheck] = [
        preview,
        previewWarning,
        previewError,
        .makePreview(type: "notice", message: "Update available: 4.0.2"),
    ]

    static func makePreview(
        source: String = "HealthCheck",
        type: String = "ok",
        message: String = "All systems operational",
        wikiUrl: String? = "https://wiki.servarr.com"
    ) -> ArrHealthCheck {
        ArrHealthCheck(source: source, type: type, message: message, wikiUrl: wikiUrl)
    }
}

// MARK: - ArrQueueItem

extension ArrQueueItem {
    static let preview = ArrQueueItem.makePreview()
    static let previewImportIssue = ArrQueueItem.makePreview(
        id: 2, title: "Breaking Bad S01E01",
        status: "importPending", trackedDownloadStatus: "warning",
        trackedDownloadState: "importPending"
    )
    static let previewList: [ArrQueueItem] = [
        preview,
        previewImportIssue,
        .makePreview(id: 3, title: "The Bear S02E01", status: "downloading", size: 2_000_000_000, sizeleft: 800_000_000),
    ]
    static let previewHeavyList: [ArrQueueItem] = (1...20).map { i in
        .makePreview(
            id: 100 + i,
            title: "Show \(i) S0\(i % 4 + 1)E0\(i % 10 + 1)",
            status: i.isMultiple(of: 3) ? "importPending" : "downloading"
        )
    }

    static func makePreview(
        id: Int = 1,
        title: String = "Breaking Bad S01E01",
        status: String = "downloading",
        trackedDownloadStatus: String = "ok",
        trackedDownloadState: String = "downloading",
        size: Double = 1_500_000_000,
        sizeleft: Double = 600_000_000,
        seriesId: Int? = 1,
        episodeId: Int? = 1,
        movieId: Int? = nil,
        outputPath: String? = "/downloads/complete/Breaking.Bad.S01E01"
    ) -> ArrQueueItem {
        let json: [String: Any?] = [
            "id": id, "title": title, "status": status,
            "trackedDownloadStatus": trackedDownloadStatus,
            "trackedDownloadState": trackedDownloadState,
            "size": size, "sizeleft": sizeleft,
            "protocol": "torrent",
            "downloadClient": "qBittorrent",
            "downloadId": "preview-\(id)",
            "outputPath": outputPath,
            "timeleft": "00:12:42",
            "estimatedCompletionTime": "2026-05-24T11:45:00Z",
            "seriesId": seriesId,
            "episodeId": episodeId,
            "movieId": movieId,
            "statusMessages": trackedDownloadStatus == "ok" ? [] : [
                ["title": "Import warning", "messages": ["Sample path is waiting for manual import."]]
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 }, options: [])
        return try! JSONDecoder().decode(ArrQueueItem.self, from: data)
    }
}

// MARK: - ArrHistoryRecord

extension ArrHistoryRecord {
    static let preview = ArrHistoryRecord.makePreview()
    static let previewFailed = ArrHistoryRecord.makePreview(id: 2, eventType: "downloadFailed", successful: false)
    static let previewImported = ArrHistoryRecord.makePreview(id: 3, eventType: "downloadFolderImported", successful: true)
    static let previewList: [ArrHistoryRecord] = [
        preview, previewFailed, previewImported,
        .makePreview(id: 4, eventType: "grabbed", sourceTitle: "Breaking.Bad.S01E01.1080p.BluRay.x264"),
    ]
    static let previewHeavyList: [ArrHistoryRecord] = (1...20).map { i in
        .makePreview(
            id: 100 + i,
            eventType: i.isMultiple(of: 3) ? "downloadFailed" : "grabbed",
            sourceTitle: "Show.\(i).S01E0\(i % 9 + 1).1080p",
            successful: !i.isMultiple(of: 4)
        )
    }

    static func makePreview(
        id: Int = 1,
        eventType: String = "grabbed",
        sourceTitle: String = "Breaking.Bad.S01E01.1080p",
        successful: Bool = true,
        seriesId: Int? = 1,
        movieId: Int? = nil,
        indexerId: Int? = nil
    ) -> ArrHistoryRecord {
        let json: [String: Any?] = [
            "id": id, "eventType": eventType,
            "sourceTitle": sourceTitle,
            "successful": successful,
            "date": "2026-05-24T08:30:00Z",
            "seriesId": seriesId,
            "episodeId": seriesId == nil ? nil : 1,
            "movieId": movieId,
            "indexerId": indexerId,
            "quality": [
                "quality": ["id": 7, "name": "WEBDL-1080p", "source": "web", "resolution": 1080]
            ],
            "data": [
                "releaseTitle": sourceTitle,
                "query": "breaking bad s01e01",
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 }, options: [])
        return try! JSONDecoder().decode(ArrHistoryRecord.self, from: data)
    }
}

// MARK: - ArrBlocklistItem

extension ArrBlocklistItem {
    static let preview = ArrBlocklistItem(
        id: 1,
        seriesId: 1,
        movieId: nil,
        episodeIds: [1],
        sourceTitle: "Breaking.Bad.S01E01.PROPER.1080p.WEB-DL",
        indexer: "NZBgeek",
        message: "Release rejected by import rules",
        date: "2026-05-23T18:20:00Z",
        quality: ArrBlocklistQuality(quality: ArrQuality(id: 7, name: "WEBDL-1080p", source: "web", resolution: 1080))
    )
    static let previewMovie = ArrBlocklistItem(
        id: 2,
        seriesId: nil,
        movieId: 278,
        episodeIds: nil,
        sourceTitle: "The.Shawshank.Redemption.1994.2160p.UHD.BluRay",
        indexer: "TorrentLeech",
        message: "Download client failed to import the release",
        date: "2026-05-22T12:10:00Z",
        quality: ArrBlocklistQuality(quality: ArrQuality(id: 19, name: "Bluray-2160p", source: "bluray", resolution: 2160))
    )
    static let previewList: [ArrBlocklistItem] = [
        preview,
        previewMovie,
        .init(
            id: 3,
            seriesId: 2,
            movieId: nil,
            episodeIds: [22],
            sourceTitle: "The.Bear.S02E03.1080p.HDTV",
            indexer: "1337x",
            message: "Manual blocklist entry",
            date: "2026-05-21T09:05:00Z",
            quality: ArrBlocklistQuality(quality: ArrQuality(id: 4, name: "HDTV-720p", source: "television", resolution: 720))
        ),
    ]
}

// MARK: - ArrImportListExclusion

extension ArrImportListExclusion {
    static let preview = ArrImportListExclusion(id: 1, tvdbId: 81189, tmdbId: nil, title: "Breaking Bad", movieTitle: nil, movieYear: nil)
    static let previewMovie = ArrImportListExclusion(id: 2, tvdbId: nil, tmdbId: 278, title: nil, movieTitle: "The Shawshank Redemption", movieYear: 1994)
    static let previewList: [ArrImportListExclusion] = [
        preview,
        previewMovie,
        .init(id: 3, tvdbId: nil, tmdbId: 693134, title: nil, movieTitle: "Dune: Part Two", movieYear: 2024),
    ]
}

// MARK: - ArrUpdateInfo

extension ArrUpdateInfo {
    static let preview = ArrUpdateInfo(
        version: "4.0.12.2823",
        releaseDate: "2026-05-18T09:00:00Z",
        fileName: "Sonarr.main.4.0.12.2823.linux-core-x64.tar.gz",
        url: "https://example.com/sonarr-update",
        installed: true,
        installable: false,
        latest: false,
        changes: .init(
            new: ["Improved interactive search filtering", "Added download client health checks"],
            fixed: ["Fixed manual import path validation", "Resolved calendar timezone display"]
        )
    )
    static let previewAvailable = ArrUpdateInfo(
        version: "4.0.13.2910",
        releaseDate: "2026-05-22T14:00:00Z",
        fileName: "Sonarr.main.4.0.13.2910.linux-core-x64.tar.gz",
        url: "https://example.com/sonarr-update-latest",
        installed: false,
        installable: true,
        latest: true,
        changes: .init(
            new: ["Expanded queue action telemetry"],
            fixed: ["Fixed a rare blocklist pagination issue"]
        )
    )
    static let previewList: [ArrUpdateInfo] = [
        previewAvailable,
        preview,
        .init(
            version: "4.0.11.2760",
            releaseDate: "2026-05-08T08:00:00Z",
            fileName: nil,
            url: "https://example.com/sonarr-update-previous",
            installed: false,
            installable: false,
            latest: false,
            changes: .init(new: nil, fixed: ["Maintenance release"])
        ),
    ]
}

// MARK: - ArrDownloadClient

extension ArrDownloadClient {
    static let preview = ArrDownloadClient.makePreview()
    static let previewDisabled = ArrDownloadClient.makePreview(id: 2, name: "SABnzbd", implementationName: "SABnzbd", implementation: "Sabnzbd", protocolValue: "usenet", host: "sabnzbd.local", port: 8085, enable: false, priority: 2)
    static let previewList: [ArrDownloadClient] = [
        preview,
        previewDisabled,
        .makePreview(id: 3, name: "Transmission", implementationName: "Transmission", implementation: "Transmission", protocolValue: "torrent", host: "transmission.local", port: 9091, enable: true, priority: 3),
    ]

    static func makePreview(
        id: Int = 1,
        name: String = "qBittorrent",
        implementationName: String = "qBittorrent",
        implementation: String = "QBittorrent",
        protocolValue: String = "torrent",
        host: String = "qbit.local",
        port: Int = 8080,
        enable: Bool = true,
        priority: Int = 1
    ) -> ArrDownloadClient {
        let json: [String: Any] = [
            "id": id,
            "name": name,
            "implementationName": implementationName,
            "implementation": implementation,
            "configContract": "\(implementation)Settings",
            "enable": enable,
            "supportsCategories": true,
            "priority": priority,
            "removeCompletedDownloads": true,
            "removeFailedDownloads": true,
            "protocol": protocolValue,
            "fields": [
                ["name": "host", "label": "Host", "value": host, "type": "textbox"],
                ["name": "port", "label": "Port", "value": port, "type": "textbox"],
                ["name": "useSsl", "label": "Use SSL", "value": false, "type": "checkbox"],
                ["name": "username", "label": "Username", "value": "admin", "type": "textbox"],
                ["name": "password", "label": "Password", "value": "secret", "type": "password"],
                ["name": "tvCategory", "label": "Category", "value": "tv-sonarr", "type": "textbox"],
                ["name": "movieCategory", "label": "Category", "value": "radarr", "type": "textbox"],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(ArrDownloadClient.self, from: data)
    }
}

// MARK: - ArrRemotePathMapping

extension ArrRemotePathMapping {
    static let preview = ArrRemotePathMapping(id: 1, host: "*", remotePath: "/downloads/complete", localPath: "/media/downloads/complete")
    static let previewList: [ArrRemotePathMapping] = [
        preview,
        .init(id: 2, host: "qbit.local", remotePath: "/data/torrents", localPath: "/mnt/media/downloads"),
        .init(id: 3, host: "Sonarr", remotePath: "/tv", localPath: "/media/tv"),
    ]
}

// MARK: - ArrDiskSpace

extension ArrDiskSpace {
    static let preview = ArrDiskSpace(path: "/media/tv", label: "TV Library", freeSpace: 820_000_000_000, totalSpace: 4_000_000_000_000)
    static let previewLowSpace = ArrDiskSpace(path: "/media/movies", label: "Movie Library", freeSpace: 180_000_000_000, totalSpace: 8_000_000_000_000)
    static let previewList: [ArrDiskSpace] = [
        preview,
        previewLowSpace,
        .init(path: "/downloads", label: "Downloads", freeSpace: 95_000_000_000, totalSpace: 1_000_000_000_000),
    ]
}

extension ArrDiskSpaceSnapshot {
    static let previewList: [ArrDiskSpaceSnapshot] = [
        .init(serviceType: .sonarr, path: "/media/tv", label: "TV Library", freeSpace: 820_000_000_000, totalSpace: 4_000_000_000_000),
        .init(serviceType: .sonarr, path: "/downloads", label: "Downloads", freeSpace: 95_000_000_000, totalSpace: 1_000_000_000_000),
        .init(serviceType: .radarr, path: "/media/movies", label: "Movie Library", freeSpace: 180_000_000_000, totalSpace: 8_000_000_000_000),
    ]
}

// MARK: - ArrScheduledTask

extension ArrScheduledTask {
    static let preview = ArrScheduledTask(
        name: "Refresh Monitored Downloads",
        taskName: "RefreshMonitoredDownloads",
        interval: 1_440,
        lastExecution: "2026-05-24T05:00:00Z",
        lastDuration: "00:01:12",
        nextExecution: "2026-05-25T05:00:00Z",
        lastStartMessage: nil,
        isRunning: false
    )
    static let previewRunning = ArrScheduledTask(
        name: "RSS Sync",
        taskName: "RssSync",
        interval: 15,
        lastExecution: "2026-05-24T10:15:00Z",
        lastDuration: "00:00:09",
        nextExecution: "2026-05-24T10:30:00Z",
        lastStartMessage: "Started by scheduler",
        isRunning: true
    )
    static let previewList: [ArrScheduledTask] = [
        previewRunning,
        preview,
        .init(
            name: "Housekeeping",
            taskName: "Housekeeping",
            interval: 1_440,
            lastExecution: "2026-05-23T03:00:00Z",
            lastDuration: "00:00:41",
            nextExecution: "2026-05-24T03:00:00Z",
            lastStartMessage: nil,
            isRunning: false
        ),
    ]
}

// MARK: - ArrCommand

extension ArrCommand {
    static let preview = ArrCommand(
        id: 12,
        name: "RefreshSeries",
        commandName: "Refresh Series",
        status: "started",
        queued: "2026-05-24T10:20:00Z",
        started: "2026-05-24T10:20:05Z",
        ended: nil,
        stateChangeTime: "2026-05-24T10:20:05Z",
        lastExecutionTime: nil,
        trigger: "manual",
        exception: nil
    )
    static let previewList: [ArrCommand] = [
        preview,
        .init(
            id: 13,
            name: "RssSync",
            commandName: "RSS Sync",
            status: "completed",
            queued: "2026-05-24T10:05:00Z",
            started: "2026-05-24T10:05:02Z",
            ended: "2026-05-24T10:05:12Z",
            stateChangeTime: "2026-05-24T10:05:12Z",
            lastExecutionTime: "00:00:10",
            trigger: "scheduled",
            exception: nil
        ),
    ]
}

// MARK: - ArrQualityDefinition

extension ArrQualityDefinition {
    static let preview = ArrQualityDefinition(id: 1, quality: ArrQuality(id: 7, name: "WEBDL-1080p", source: "web", resolution: 1080), title: "WEBDL-1080p", weight: 70, minSize: 15, maxSize: 180, preferredSize: 90)
    static let previewList: [ArrQualityDefinition] = [
        .init(id: 1, quality: ArrQuality(id: 2, name: "DVD", source: "dvd", resolution: 480), title: "DVD", weight: 20, minSize: 0, maxSize: 80, preferredSize: 35),
        .init(id: 2, quality: ArrQuality(id: 4, name: "HDTV-720p", source: "television", resolution: 720), title: "HDTV-720p", weight: 40, minSize: 8, maxSize: 120, preferredSize: 55),
        preview,
        .init(id: 3, quality: ArrQuality(id: 19, name: "Bluray-2160p", source: "bluray", resolution: 2160), title: "Bluray-2160p", weight: 100, minSize: 70, maxSize: 400, preferredSize: 220),
    ]
}

// MARK: - Naming Config

extension SonarrNamingConfig {
    static let preview = SonarrNamingConfig(
        id: 1,
        renameEpisodes: true,
        replaceIllegalCharacters: true,
        colonReplacementFormat: ArrColonReplacementFormat.smart.rawValue,
        multiEpisodeStyle: 0,
        standardEpisodeFormat: "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {Quality Full}",
        dailyEpisodeFormat: "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} {Quality Full}",
        animeEpisodeFormat: "{Series TitleYear} - {absolute:000} - {Episode CleanTitle} {Quality Full}",
        seriesFolderFormat: "{Series TitleYear}",
        seasonFolderFormat: "Season {season:00}",
        specialsFolderFormat: "Specials"
    )
}

extension RadarrNamingConfig {
    static let preview = RadarrNamingConfig(
        id: 1,
        renameMovies: true,
        replaceIllegalCharacters: true,
        colonReplacementFormat: ArrColonReplacementFormat.smart.rawValue,
        standardMovieFormat: "{Movie Title} ({Release Year}) {Quality Full}",
        movieFolderFormat: "{Movie Title} ({Release Year})"
    )
}

// MARK: - ArrBackup

extension ArrBackup {
    static let preview = ArrBackup(id: 1, name: "sonarr_backup_2026.05.24_10.00.00.zip", type: "manual", time: "2026-05-24T10:00:00Z", size: 42_000_000, path: "/config/Backups/manual/sonarr_backup.zip")
    static let previewList: [ArrBackup] = [
        preview,
        .init(id: 2, name: "sonarr_backup_2026.05.23_03.00.00.zip", type: "scheduled", time: "2026-05-23T03:00:00Z", size: 39_000_000, path: "/config/Backups/scheduled/sonarr_backup.zip"),
        .init(id: 3, name: "sonarr_update_backup_2026.05.22.zip", type: "update", time: "2026-05-22T06:30:00Z", size: 41_000_000, path: "/config/Backups/update/sonarr_backup.zip"),
    ]
}
#endif
