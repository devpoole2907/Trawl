import Foundation

// MARK: - Series

struct SonarrSeries: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let sortTitle: String?
    let status: String?             // "continuing", "ended", "upcoming", "deleted"
    let ended: Bool?
    let overview: String?
    let network: String?
    let airTime: String?
    let images: [ArrImage]?
    let remotePoster: String?
    let seasons: [SonarrSeason]?
    let year: Int?
    let path: String?
    let qualityProfileId: Int?
    let seasonFolder: Bool?
    let monitored: Bool?
    let tvdbId: Int?
    let tvRageId: Int?
    let tvMazeId: Int?
    let imdbId: String?
    let titleSlug: String?
    let certification: String?
    let genres: [String]?
    let tags: [Int]?
    let added: String?
    let ratings: ArrRatings?
    let statistics: SonarrSeriesStatistics?
    let languageProfileId: Int?
    let runtime: Int?
    let seriesType: String?         // "standard", "daily", "anime"
    let cleanTitle: String?
    let rootFolderPath: String?
    let alternateTitles: [SonarrAlternateTitle]?

    static func == (lhs: SonarrSeries, rhs: SonarrSeries) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case sortTitle
        case status
        case ended
        case overview
        case network
        case airTime
        case images
        case remotePoster
        case seasons
        case year
        case path
        case qualityProfileId
        case seasonFolder
        case monitored
        case tvdbId
        case tvRageId
        case tvMazeId
        case imdbId
        case titleSlug
        case certification
        case genres
        case tags
        case added
        case ratings
        case statistics
        case languageProfileId
        case runtime
        case seriesType
        case cleanTitle
        case rootFolderPath
        case alternateTitles
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        title = try container.decode(String.self, forKey: .title)
        sortTitle = try container.decodeIfPresent(String.self, forKey: .sortTitle)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        ended = try container.decodeIfPresent(Bool.self, forKey: .ended)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        network = try container.decodeIfPresent(String.self, forKey: .network)
        airTime = try container.decodeIfPresent(String.self, forKey: .airTime)
        images = try container.decodeIfPresent([ArrImage].self, forKey: .images)
        remotePoster = try container.decodeIfPresent(String.self, forKey: .remotePoster)
        seasons = try container.decodeIfPresent([SonarrSeason].self, forKey: .seasons)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        qualityProfileId = try container.decodeIfPresent(Int.self, forKey: .qualityProfileId)
        seasonFolder = try container.decodeIfPresent(Bool.self, forKey: .seasonFolder)
        monitored = try container.decodeIfPresent(Bool.self, forKey: .monitored)
        tvdbId = try container.decodeIfPresent(Int.self, forKey: .tvdbId)
        tvRageId = try container.decodeIfPresent(Int.self, forKey: .tvRageId)
        tvMazeId = try container.decodeIfPresent(Int.self, forKey: .tvMazeId)
        imdbId = try container.decodeIfPresent(String.self, forKey: .imdbId)
        titleSlug = try container.decodeIfPresent(String.self, forKey: .titleSlug)
        certification = try container.decodeIfPresent(String.self, forKey: .certification)
        genres = try container.decodeIfPresent([String].self, forKey: .genres)
        tags = try container.decodeIfPresent([Int].self, forKey: .tags)
        added = try container.decodeIfPresent(String.self, forKey: .added)
        ratings = try container.decodeIfPresent(ArrRatings.self, forKey: .ratings)
        statistics = try container.decodeIfPresent(SonarrSeriesStatistics.self, forKey: .statistics)
        languageProfileId = try container.decodeIfPresent(Int.self, forKey: .languageProfileId)
        runtime = try container.decodeIfPresent(Int.self, forKey: .runtime)
        seriesType = try container.decodeIfPresent(String.self, forKey: .seriesType)
        cleanTitle = try container.decodeIfPresent(String.self, forKey: .cleanTitle)
        rootFolderPath = try container.decodeIfPresent(String.self, forKey: .rootFolderPath)
        alternateTitles = try container.decodeIfPresent([SonarrAlternateTitle].self, forKey: .alternateTitles)

        if let decodedID = try container.decodeIfPresent(Int.self, forKey: .id) {
            id = decodedID
        } else if let tvdbId {
            id = -tvdbId
        } else if let tvMazeId {
            id = -tvMazeId
        } else if let tvRageId {
            id = -tvRageId
        } else {
            id = -abs(title.hashValue)
        }
    }

    init(
        id: Int,
        title: String,
        sortTitle: String?,
        status: String?,
        ended: Bool?,
        overview: String?,
        network: String?,
        airTime: String?,
        images: [ArrImage]?,
        remotePoster: String?,
        seasons: [SonarrSeason]?,
        year: Int?,
        path: String?,
        qualityProfileId: Int?,
        seasonFolder: Bool?,
        monitored: Bool?,
        tvdbId: Int?,
        tvRageId: Int?,
        tvMazeId: Int?,
        imdbId: String?,
        titleSlug: String?,
        certification: String?,
        genres: [String]?,
        tags: [Int]?,
        added: String?,
        ratings: ArrRatings?,
        statistics: SonarrSeriesStatistics?,
        languageProfileId: Int?,
        runtime: Int?,
        seriesType: String?,
        cleanTitle: String?,
        rootFolderPath: String?,
        alternateTitles: [SonarrAlternateTitle]?
    ) {
        self.id = id
        self.title = title
        self.sortTitle = sortTitle
        self.status = status
        self.ended = ended
        self.overview = overview
        self.network = network
        self.airTime = airTime
        self.images = images
        self.remotePoster = remotePoster
        self.seasons = seasons
        self.year = year
        self.path = path
        self.qualityProfileId = qualityProfileId
        self.seasonFolder = seasonFolder
        self.monitored = monitored
        self.tvdbId = tvdbId
        self.tvRageId = tvRageId
        self.tvMazeId = tvMazeId
        self.imdbId = imdbId
        self.titleSlug = titleSlug
        self.certification = certification
        self.genres = genres
        self.tags = tags
        self.added = added
        self.ratings = ratings
        self.statistics = statistics
        self.languageProfileId = languageProfileId
        self.runtime = runtime
        self.seriesType = seriesType
        self.cleanTitle = cleanTitle
        self.rootFolderPath = rootFolderPath
        self.alternateTitles = alternateTitles
    }

    /// Best available poster URL
    var posterURL: URL? {
        let poster = images?.first(where: { $0.coverType == "poster" })
        if let remote = poster?.remoteUrl ?? poster?.url {
            return enforceSafeURL(remote)
        }
        return nil
    }

    /// Best available banner/fanart URL
    var fanartURL: URL? {
        let fanart = images?.first(where: { $0.coverType == "fanart" })
        if let remote = fanart?.remoteUrl ?? fanart?.url {
            return enforceSafeURL(remote)
        }
        return nil
    }

    private func enforceSafeURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    func updatingForEdit(
        monitored: Bool,
        qualityProfileId: Int,
        seriesType: String,
        seasonFolder: Bool,
        rootFolderPath: String,
        tags: [Int]
    ) -> SonarrSeries {
        let updatedPath = rebasedLibraryPath(
            existingPath: path,
            existingRootFolderPath: self.rootFolderPath,
            newRootFolderPath: rootFolderPath
        )

        return SonarrSeries(
            id: id,
            title: title,
            sortTitle: sortTitle,
            status: status,
            ended: ended,
            overview: overview,
            network: network,
            airTime: airTime,
            images: images,
            remotePoster: remotePoster,
            seasons: seasons,
            year: year,
            path: updatedPath,
            qualityProfileId: qualityProfileId,
            seasonFolder: seasonFolder,
            monitored: monitored,
            tvdbId: tvdbId,
            tvRageId: tvRageId,
            tvMazeId: tvMazeId,
            imdbId: imdbId,
            titleSlug: titleSlug,
            certification: certification,
            genres: genres,
            tags: tags,
            added: added,
            ratings: ratings,
            statistics: statistics,
            languageProfileId: languageProfileId,
            runtime: runtime,
            seriesType: seriesType,
            cleanTitle: cleanTitle,
            rootFolderPath: rootFolderPath,
            alternateTitles: alternateTitles
        )
    }
}

private func rebasedLibraryPath(
    existingPath: String?,
    existingRootFolderPath: String?,
    newRootFolderPath: String
) -> String? {
    guard let existingPath, !existingPath.isEmpty else { return existingPath }
    guard let existingRootFolderPath, !existingRootFolderPath.isEmpty else { return existingPath }
    guard existingRootFolderPath != newRootFolderPath else { return existingPath }

    let normalizedExistingRoot = existingRootFolderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    let normalizedNewRoot = newRootFolderPath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    let normalizedExistingPath = existingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))

    let pathComponents = normalizedExistingPath.split(whereSeparator: { $0 == "/" || $0 == "\\" })
    let rootComponents = normalizedExistingRoot.split(whereSeparator: { $0 == "/" || $0 == "\\" })
    let isWindowsStyle = existingPath.contains("\\") || existingRootFolderPath.contains("\\") || newRootFolderPath.contains("\\")
    let separator = isWindowsStyle ? "\\" : "/"

    guard pathComponents.count > rootComponents.count else { return existingPath }
    guard Array(pathComponents.prefix(rootComponents.count)).map(String.init) == rootComponents.map(String.init) else {
        return existingPath
    }

    let suffixComponents = pathComponents.dropFirst(rootComponents.count).map(String.init)
    guard !suffixComponents.isEmpty else { return existingPath }

    return ([normalizedNewRoot] + suffixComponents).joined(separator: separator)
}

struct SonarrSeriesStatistics: Codable, Sendable {
    let seasonCount: Int?
    let episodeFileCount: Int?
    let episodeCount: Int?
    let totalEpisodeCount: Int?
    let sizeOnDisk: Int64?
    let percentOfEpisodes: Double?
}

struct SonarrAlternateTitle: Codable, Sendable {
    let title: String?
    let seasonNumber: Int?
}

// MARK: - Season

struct SonarrSeason: Codable, Sendable {
    let seasonNumber: Int
    let monitored: Bool?
    let statistics: SonarrSeasonStatistics?
}

struct SonarrSeasonStatistics: Codable, Sendable {
    let episodeFileCount: Int?
    let episodeCount: Int?
    let totalEpisodeCount: Int?
    let sizeOnDisk: Int64?
    let percentOfEpisodes: Double?
    let previousAiring: String?
    let nextAiring: String?
}

// MARK: - Episode

struct SonarrEpisode: Codable, Identifiable, Sendable {
    let id: Int
    let seriesId: Int?
    let series: SonarrSeries?
    let tvdbId: Int?
    let episodeFileId: Int?
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String?
    let airDate: String?
    let airDateUtc: String?
    let overview: String?
    let hasFile: Bool?
    let monitored: Bool?
    let absoluteEpisodeNumber: Int?
    let sceneAbsoluteEpisodeNumber: Int?
    let sceneEpisodeNumber: Int?
    let sceneSeasonNumber: Int?
    let unverifiedSceneNumbering: Bool?
    let grabbed: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case seriesId
        case series
        case tvdbId
        case episodeFileId
        case seasonNumber
        case episodeNumber
        case title
        case airDate
        case airDateUtc
        case overview
        case hasFile
        case monitored
        case absoluteEpisodeNumber
        case sceneAbsoluteEpisodeNumber
        case sceneEpisodeNumber
        case sceneSeasonNumber
        case unverifiedSceneNumbering
        case grabbed
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(Int.self, forKey: .id)
        seriesId = try container.decodeIfPresent(Int.self, forKey: .seriesId)
        series = try container.decodeIfPresent(SonarrSeries.self, forKey: .series)
        tvdbId = try container.decodeIfPresent(Int.self, forKey: .tvdbId)
        episodeFileId = try container.decodeIfPresent(Int.self, forKey: .episodeFileId)
        seasonNumber = try container.decode(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decode(Int.self, forKey: .episodeNumber)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        airDate = try container.decodeIfPresent(String.self, forKey: .airDate)
        airDateUtc = try container.decodeIfPresent(String.self, forKey: .airDateUtc)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        hasFile = try container.decodeIfPresent(Bool.self, forKey: .hasFile)
        monitored = try container.decodeIfPresent(Bool.self, forKey: .monitored)
        absoluteEpisodeNumber = try container.decodeIfPresent(Int.self, forKey: .absoluteEpisodeNumber)
        sceneAbsoluteEpisodeNumber = try container.decodeIfPresent(Int.self, forKey: .sceneAbsoluteEpisodeNumber)
        sceneEpisodeNumber = try container.decodeIfPresent(Int.self, forKey: .sceneEpisodeNumber)
        sceneSeasonNumber = try container.decodeIfPresent(Int.self, forKey: .sceneSeasonNumber)
        unverifiedSceneNumbering = try container.decodeIfPresent(Bool.self, forKey: .unverifiedSceneNumbering)
        grabbed = try container.decodeIfPresent(Bool.self, forKey: .grabbed)
    }

    /// Formatted episode identifier e.g. "S01E05"
    var episodeIdentifier: String {
        String(format: "S%02dE%02d", seasonNumber, episodeNumber)
    }
}

// MARK: - Episode File

struct SonarrEpisodeFile: Codable, Identifiable, Sendable {
    let id: Int
    let seriesId: Int?
    let seasonNumber: Int?
    let relativePath: String?
    let path: String?
    let size: Int64?
    let dateAdded: String?
    let quality: ArrHistoryQuality?
    let mediaInfo: SonarrMediaInfo?
}

struct SonarrMediaInfo: Codable, Sendable {
    let audioBitrate: Int64?
    let audioChannels: Double?
    let audioCodec: String?
    let audioLanguages: String?
    let audioStreamCount: Int?
    let videoBitDepth: Int?
    let videoBitrate: Int64?
    let videoCodec: String?
    let videoFps: Double?
    let resolution: String?
    let runTime: String?
    let scanType: String?
    let subtitles: String?
}

// MARK: - Series Lookup (for adding new series)

/// When looking up a series via /api/v3/series/lookup, the response is a [SonarrSeries].
/// The struct is the same but the series won't have an `id` from the local database yet.
/// It will have tvdbId, imdbId, etc. for identification.

// MARK: - Monitor body for PUT /api/v3/episode/monitor

struct SonarrEpisodeMonitorBody: Codable, Sendable {
    let episodeIds: [Int]
    let monitored: Bool
}

// MARK: - Add Series body

struct SonarrAddSeriesBody: Codable, Sendable {
    let tvdbId: Int
    let title: String
    let qualityProfileId: Int
    let languageProfileId: Int?
    let titleSlug: String
    let images: [ArrImage]
    let seasons: [SonarrAddSeason]
    let rootFolderPath: String
    let monitored: Bool
    let seasonFolder: Bool
    let seriesType: String
    let addOptions: SonarrAddOptions
    let tags: [Int]?
}

struct SonarrAddSeason: Codable, Sendable {
    let seasonNumber: Int
    let monitored: Bool
}

struct SonarrAddOptions: Codable, Sendable {
    let monitor: String             // "all", "future", "missing", "existing", "firstSeason", "latestSeason", "none"
    let searchForMissingEpisodes: Bool
    let searchForCutoffUnmetEpisodes: Bool
}

// MARK: - Sonarr Commands

enum SonarrCommand: String, Sendable {
    case refreshSeries = "RefreshSeries"
    case rescanSeries = "RescanSeries"
    case episodeSearch = "EpisodeSearch"
    case seasonSearch = "SeasonSearch"
    case seriesSearch = "SeriesSearch"
    case missingEpisodeSearch = "missingEpisodeSearch"
    case rssSync = "RssSync"
    case backup = "Backup"
    case applicationUpdate = "ApplicationUpdate"
}
