import Foundation

// MARK: - Generic Page

nonisolated struct BazarrPage<T: Codable>: Codable {
    let data: [T]
    let total: Int
}

// MARK: - Subtitle Types

nonisolated struct BazarrSubtitle: Codable, Hashable, Sendable {
    let name: String
    let code2: String
    let code3: String
    let path: String?
    let forced: Bool
    let hi: Bool
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case name, code2, code3, path, forced, hi
        case fileSize = "file_size"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        code2 = (try? container.decodeIfPresent(String.self, forKey: .code2)) ?? ""
        code3 = (try? container.decodeIfPresent(String.self, forKey: .code3)) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path)
        forced = (try? container.decode(Bool.self, forKey: .forced)) ?? false
        hi = (try? container.decode(Bool.self, forKey: .hi)) ?? false
        fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
    }
}

nonisolated struct BazarrSubtitleLanguage: Codable, Hashable, Sendable {
    let name: String
    let code2: String
    let code3: String
    let forced: Bool
    let hi: Bool

    enum CodingKeys: String, CodingKey {
        case name, code2, code3, forced, hi
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        code2 = (try? container.decodeIfPresent(String.self, forKey: .code2)) ?? ""
        code3 = (try? container.decodeIfPresent(String.self, forKey: .code3)) ?? ""
        forced = (try? container.decode(Bool.self, forKey: .forced)) ?? false
        hi = (try? container.decode(Bool.self, forKey: .hi)) ?? false
    }
}

nonisolated struct BazarrAudioLanguage: Codable, Hashable, Sendable {
    let name: String
    let code2: String
    let code3: String

    enum CodingKeys: String, CodingKey {
        case name, code2, code3
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "Unknown"
        code2 = (try? container.decodeIfPresent(String.self, forKey: .code2)) ?? ""
        code3 = (try? container.decodeIfPresent(String.self, forKey: .code3)) ?? ""
    }
}

// MARK: - Series

nonisolated struct BazarrSeries: Codable, Identifiable, Hashable, Sendable {
    let sonarrSeriesId: Int
    let title: String
    let year: String?
    let overview: String?
    let poster: String?
    let fanart: String?
    let audioLanguages: [BazarrAudioLanguage]
    let episodeFileCount: Int
    let episodeMissingCount: Int
    let monitored: Bool
    let profileId: Int?
    let seriesType: String?
    let tags: [String]
    let alternativeTitles: [String]
    let ended: Bool?
    let lastAired: String?

    var id: Int { sonarrSeriesId }

    enum CodingKeys: String, CodingKey {
        case sonarrSeriesId, title, year, overview, poster, fanart
        case audioLanguages = "audio_language"
        case episodeFileCount, episodeMissingCount, monitored, profileId, seriesType, tags
        case alternativeTitles, ended, lastAired
    }
}

// MARK: - Movies

nonisolated struct BazarrMovie: Codable, Identifiable, Hashable, Sendable {
    let radarrId: Int
    let title: String
    let year: String?
    let overview: String?
    let poster: String?
    let fanart: String?
    let audioLanguages: [BazarrAudioLanguage]
    let monitored: Bool
    let profileId: Int?
    let subtitles: [BazarrSubtitle]
    let missingSubtitles: [BazarrSubtitleLanguage]
    let tags: [String]
    let alternativeTitles: [String]
    let sceneName: String?

    var id: Int { radarrId }

    enum CodingKeys: String, CodingKey {
        case radarrId, title, year, overview, poster, fanart
        case audioLanguages = "audio_language"
        case monitored, profileId, subtitles
        case missingSubtitles = "missing_subtitles"
        case tags, alternativeTitles, sceneName
    }
}

// MARK: - Episodes

nonisolated struct BazarrEpisode: Codable, Identifiable, Hashable, Sendable {
    let sonarrEpisodeId: Int
    let sonarrSeriesId: Int
    let season: Int
    let episode: Int
    let title: String
    let monitored: Bool
    let subtitles: [BazarrSubtitle]
    let missingSubtitles: [BazarrSubtitleLanguage]
    let audioLanguages: [BazarrAudioLanguage]
    let path: String?
    let sceneName: String?

    var id: Int { sonarrEpisodeId }

    var episodeLabel: String { "s\(season)e\(episode)" }

    enum CodingKeys: String, CodingKey {
        case sonarrEpisodeId, sonarrSeriesId, season, episode, title
        case monitored, subtitles
        case missingSubtitles = "missing_subtitles"
        case audioLanguages = "audio_language"
        case path, sceneName
    }
}

// MARK: - Wanted

nonisolated struct BazarrWantedEpisode: Codable, Identifiable, Hashable, Sendable {
    let seriesTitle: String
    let episodeNumber: String
    let episodeTitle: String
    let missingSubtitles: [BazarrSubtitleLanguage]
    let sonarrSeriesId: Int
    let sonarrEpisodeId: Int
    let sceneName: String?
    let tags: [String]
    let seriesType: String?

    var id: Int { sonarrEpisodeId }

    enum CodingKeys: String, CodingKey {
        case seriesTitle, episodeNumber = "episode_number", episodeTitle
        case missingSubtitles = "missing_subtitles"
        case sonarrSeriesId, sonarrEpisodeId, sceneName, tags, seriesType
    }
}

// MARK: - System

nonisolated struct BazarrSystemStatus: Codable, Sendable {
    let bazarrVersion: String
    let packageVersion: String?
    let sonarrVersion: String?
    let radarrVersion: String?
    let operatingSystem: String?
    let pythonVersion: String?
    let databaseEngine: String?
    let databaseMigration: String?
    let bazarrDirectory: String?
    let bazarrConfigDirectory: String?
    let startTime: String?
    let timezone: String?
    let cpuCores: Int?

    enum CodingKeys: String, CodingKey {
        case bazarrVersion = "bazarr_version"
        case packageVersion = "package_version"
        case sonarrVersion = "sonarr_version"
        case radarrVersion = "radarr_version"
        case operatingSystem = "operating_system"
        case pythonVersion = "python_version"
        case databaseEngine = "database_engine"
        case databaseMigration = "database_migration"
        case bazarrDirectory = "bazarr_directory"
        case bazarrConfigDirectory = "bazarr_config_directory"
        case startTime = "start_time"
        case timezone
        case cpuCores = "cpu_cores"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bazarrVersion = try container.decodeFlexibleString(forKey: .bazarrVersion) ?? "Unknown"
        packageVersion = try container.decodeFlexibleString(forKey: .packageVersion)
        sonarrVersion = try container.decodeFlexibleString(forKey: .sonarrVersion)
        radarrVersion = try container.decodeFlexibleString(forKey: .radarrVersion)
        operatingSystem = try container.decodeFlexibleString(forKey: .operatingSystem)
        pythonVersion = try container.decodeFlexibleString(forKey: .pythonVersion)
        databaseEngine = try container.decodeFlexibleString(forKey: .databaseEngine)
        databaseMigration = try container.decodeFlexibleString(forKey: .databaseMigration)
        bazarrDirectory = try container.decodeFlexibleString(forKey: .bazarrDirectory)
        bazarrConfigDirectory = try container.decodeFlexibleString(forKey: .bazarrConfigDirectory)
        startTime = try container.decodeFlexibleString(forKey: .startTime)
        timezone = try container.decodeFlexibleString(forKey: .timezone)
        cpuCores = try container.decodeFlexibleInt(forKey: .cpuCores)
    }
}

private extension KeyedDecodingContainer {
    nonisolated func decodeFlexibleString(forKey key: Key) throws -> String? {
        guard contains(key) else {
            return nil
        }
        if try decodeNil(forKey: key) {
            return nil
        }
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    nonisolated func decodeFlexibleInt(forKey key: Key) throws -> Int? {
        guard contains(key) else {
            return nil
        }
        if try decodeNil(forKey: key) {
            return nil
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

typealias BazarrHealthCheck = JSONValue

nonisolated struct BazarrBadges: Codable, Sendable {
    let episodes: Int
    let movies: Int
    let providers: Int
    let status: Int
    let announcements: Int
}

// MARK: - Tasks

nonisolated struct BazarrTask: Codable, Identifiable, Sendable {
    let interval: String?
    let jobId: String
    let jobRunning: Bool
    let name: String
    let nextRunIn: String?
    let nextRunTime: String?

    var id: String { jobId }

    enum CodingKeys: String, CodingKey {
        case interval
        case jobId = "job_id"
        case jobRunning = "job_running"
        case name
        case nextRunIn = "next_run_in"
        case nextRunTime = "next_run_time"
    }
}

// MARK: - Languages

nonisolated struct BazarrLanguage: Codable, Identifiable, Sendable {
    let name: String
    let code2: String
    let code3: String
    let enabled: Bool

    var id: String { code2 }
}

nonisolated struct BazarrLanguageProfile: Codable, Identifiable, Sendable {
    let profileId: Int
    let name: String
    let cutoff: Int?
    let itemsJSON: String?
    let mustContain: [String]?
    let mustNotContain: [String]?
    let originalFormat: Int?
    let tag: Int?

    var id: Int { profileId }

    enum CodingKeys: String, CodingKey {
        case profileId, name, cutoff
        case itemsJSON = "items"
        case mustContain = "mustContain"
        case mustNotContain = "mustNotContain"
        case originalFormat, tag
    }

    var parsedItems: [BazarrLanguageProfileItem] {
        guard let json = itemsJSON, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([BazarrLanguageProfileItem].self, from: data)) ?? []
    }
}

nonisolated struct BazarrLanguageProfileItem: Codable, Identifiable, Sendable {
    let language: String
    let hi: Bool
    let forced: Bool

    var id: String { language + (hi ? ":hi" : "") + (forced ? ":forced" : "") }
}

// MARK: - Providers

nonisolated struct BazarrProvider: Codable, Identifiable, Sendable {
    let name: String
    let status: String
    let retry: String?

    var id: String { name }
}

// MARK: - History

nonisolated struct BazarrHistoryStats: Codable, Sendable {
    let series: [BazarrHistoryStat]
    let movies: [BazarrHistoryStat]
}

nonisolated struct BazarrHistoryStat: Codable, Identifiable, Sendable {
    let date: String
    let count: Int

    var id: String { date }
}

// MARK: - Search

nonisolated struct BazarrSearchResult: Codable, Identifiable, Sendable {
    let title: String
    let year: String?
    let poster: String?
    let sonarrSeriesId: Int?
    let radarrId: Int?

    var id: String { "\(title)-\(sonarrSeriesId ?? radarrId ?? 0)" }
}

// MARK: - Announcements

nonisolated struct BazarrAnnouncement: Codable, Identifiable, Sendable {
    let hash: String
    let title: String?
    let message: String?

    var id: String { hash }
}

// MARK: - Interactive Search

nonisolated struct BazarrInteractiveSearchResult: Codable, Identifiable, Sendable {
    let provider: String
    let subtitle: String?
    let score: Double?
    let matches: [String]
    let releaseInfo: String?
    let title: String?
    let hearingImpaired: Bool
    let forcedSubtitle: Bool
    let language: BazarrAudioLanguage?

    var id: String { subtitle ?? "\(provider)-\(score ?? 0)-\(releaseInfo ?? "")" }

    enum CodingKeys: String, CodingKey {
        case provider, subtitle, score, matches, title, language
        case releaseInfo = "release_info"
        case hearingImpaired = "hearing_impaired"
        case forcedSubtitle = "forced_subtitle"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? "Unknown"
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        matches = (try? c.decode([String].self, forKey: .matches)) ?? []
        releaseInfo = try c.decodeIfPresent(String.self, forKey: .releaseInfo)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        hearingImpaired = (try? c.decode(Bool.self, forKey: .hearingImpaired)) ?? false
        forcedSubtitle = (try? c.decode(Bool.self, forKey: .forcedSubtitle)) ?? false
        language = try c.decodeIfPresent(BazarrAudioLanguage.self, forKey: .language)
    }
}

// MARK: - Actions

nonisolated enum BazarrSeriesAction: String, CaseIterable, Sendable {
    case scanDisk = "scan-disk"
    case searchMissing = "search-missing"
    case searchWanted = "search-wanted"
    case sync

    var displayName: String {
        switch self {
        case .scanDisk: "Scan Disk"
        case .searchMissing: "Search Missing"
        case .searchWanted: "Search Wanted"
        case .sync: "Sync"
        }
    }

    var systemImage: String {
        switch self {
        case .scanDisk: "arrow.triangle.2.circlepath"
        case .searchMissing: "magnifyingglass"
        case .searchWanted: "exclamationmark.magnifyingglass"
        case .sync: "arrow.triangle.2.circlepath.circle"
        }
    }
}

// MARK: - Subtitle Track Info

nonisolated struct BazarrSubtitleTrackInfo: Codable, Sendable {
    let audioTracks: [BazarrAudioTrack]?
    let embeddedSubtitlesTracks: [BazarrEmbeddedSubtitleTrack]?
    let externalSubtitlesTracks: [BazarrExternalSubtitleTrack]?

    enum CodingKeys: String, CodingKey {
        case audioTracks = "audio_tracks"
        case embeddedSubtitlesTracks = "embedded_subtitles_tracks"
        case externalSubtitlesTracks = "external_subtitles_tracks"
    }
}

nonisolated struct BazarrAudioTrack: Codable, Identifiable, Sendable {
    let stream: String?
    let name: String?
    let language: String?

    var id: String { stream ?? UUID().uuidString }
}

nonisolated struct BazarrEmbeddedSubtitleTrack: Codable, Identifiable, Sendable {
    let stream: String?
    let name: String?
    let language: String?
    let forced: Bool
    let hearingImpaired: Bool?

    var id: String { stream ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case stream, name, language, forced
        case hearingImpaired = "hearing_impaired"
    }
}

nonisolated struct BazarrExternalSubtitleTrack: Codable, Identifiable, Sendable {
    let name: String?
    let path: String?
    let language: String?
    let forced: Bool
    let hearingImpaired: Bool?

    var id: String { path ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case name, path, language, forced
        case hearingImpaired = "hearing_impaired"
    }
}
