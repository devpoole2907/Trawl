import CryptoKit
import Foundation

// MARK: - Movie

struct RadarrMovie: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let originalTitle: String?
    let sortTitle: String?
    let sizeOnDisk: Int64?
    let overview: String?
    let inCinemas: String?
    let physicalRelease: String?
    let digitalRelease: String?
    let status: String?             // "tba", "announced", "inCinemas", "released", "deleted"
    let images: [ArrImage]?
    let website: String?
    let year: Int?
    let hasFile: Bool?
    let youTubeTrailerId: String?
    let studio: String?
    let path: String?
    let rootFolderPath: String?
    let qualityProfileId: Int?
    let monitored: Bool?
    let minimumAvailability: String? // "announced", "inCinemas", "released"
    let isAvailable: Bool?
    let folderName: String?
    let runtime: Int?
    let cleanTitle: String?
    let imdbId: String?
    let tmdbId: Int?
    let titleSlug: String?
    let certification: String?
    let genres: [String]?
    let tags: [Int]?
    let added: String?
    let ratings: RadarrRatings?
    let movieFile: RadarrMovieFile?
    let collection: RadarrCollection?
    let popularity: Double?
    let statistics: RadarrMovieStatistics?
    let alternateTitles: [RadarrAlternateTitle]?

    static func == (lhs: RadarrMovie, rhs: RadarrMovie) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case originalTitle
        case sortTitle
        case sizeOnDisk
        case overview
        case inCinemas
        case physicalRelease
        case digitalRelease
        case status
        case images
        case website
        case year
        case hasFile
        case youTubeTrailerId
        case studio
        case path
        case rootFolderPath
        case qualityProfileId
        case monitored
        case minimumAvailability
        case isAvailable
        case folderName
        case runtime
        case cleanTitle
        case imdbId
        case tmdbId
        case titleSlug
        case certification
        case genres
        case tags
        case added
        case ratings
        case movieFile
        case collection
        case popularity
        case statistics
        case alternateTitles
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        title = try container.decode(String.self, forKey: .title)
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        sortTitle = try container.decodeIfPresent(String.self, forKey: .sortTitle)
        sizeOnDisk = try container.decodeIfPresent(Int64.self, forKey: .sizeOnDisk)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        inCinemas = try container.decodeIfPresent(String.self, forKey: .inCinemas)
        physicalRelease = try container.decodeIfPresent(String.self, forKey: .physicalRelease)
        digitalRelease = try container.decodeIfPresent(String.self, forKey: .digitalRelease)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        images = try container.decodeIfPresent([ArrImage].self, forKey: .images)
        website = try container.decodeIfPresent(String.self, forKey: .website)
        year = try container.decodeIfPresent(Int.self, forKey: .year)
        hasFile = try container.decodeIfPresent(Bool.self, forKey: .hasFile)
        youTubeTrailerId = try container.decodeIfPresent(String.self, forKey: .youTubeTrailerId)
        studio = try container.decodeIfPresent(String.self, forKey: .studio)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        rootFolderPath = try container.decodeIfPresent(String.self, forKey: .rootFolderPath)
        qualityProfileId = try container.decodeIfPresent(Int.self, forKey: .qualityProfileId)
        monitored = try container.decodeIfPresent(Bool.self, forKey: .monitored)
        minimumAvailability = try container.decodeIfPresent(String.self, forKey: .minimumAvailability)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable)
        folderName = try container.decodeIfPresent(String.self, forKey: .folderName)
        runtime = try container.decodeIfPresent(Int.self, forKey: .runtime)
        cleanTitle = try container.decodeIfPresent(String.self, forKey: .cleanTitle)
        imdbId = try container.decodeIfPresent(String.self, forKey: .imdbId)
        tmdbId = try container.decodeIfPresent(Int.self, forKey: .tmdbId)
        titleSlug = try container.decodeIfPresent(String.self, forKey: .titleSlug)
        certification = try container.decodeIfPresent(String.self, forKey: .certification)
        genres = try container.decodeIfPresent([String].self, forKey: .genres)
        tags = try container.decodeIfPresent([Int].self, forKey: .tags)
        added = try container.decodeIfPresent(String.self, forKey: .added)
        ratings = try container.decodeIfPresent(RadarrRatings.self, forKey: .ratings)
        movieFile = try container.decodeIfPresent(RadarrMovieFile.self, forKey: .movieFile)
        collection = try container.decodeIfPresent(RadarrCollection.self, forKey: .collection)
        popularity = try container.decodeIfPresent(Double.self, forKey: .popularity)
        statistics = try container.decodeIfPresent(RadarrMovieStatistics.self, forKey: .statistics)
        alternateTitles = try container.decodeIfPresent([RadarrAlternateTitle].self, forKey: .alternateTitles)

        if let decodedID = try container.decodeIfPresent(Int.self, forKey: .id) {
            id = decodedID
        } else if let tmdbId {
            id = -tmdbId
        } else {
            id = Self.stableFallbackID(for: title)
        }
    }

    init(
        id: Int,
        title: String,
        originalTitle: String?,
        sortTitle: String?,
        sizeOnDisk: Int64?,
        overview: String?,
        inCinemas: String?,
        physicalRelease: String?,
        digitalRelease: String?,
        status: String?,
        images: [ArrImage]?,
        website: String?,
        year: Int?,
        hasFile: Bool?,
        youTubeTrailerId: String?,
        studio: String?,
        path: String?,
        rootFolderPath: String?,
        qualityProfileId: Int?,
        monitored: Bool?,
        minimumAvailability: String?,
        isAvailable: Bool?,
        folderName: String?,
        runtime: Int?,
        cleanTitle: String?,
        imdbId: String?,
        tmdbId: Int?,
        titleSlug: String?,
        certification: String?,
        genres: [String]?,
        tags: [Int]?,
        added: String?,
        ratings: RadarrRatings?,
        movieFile: RadarrMovieFile?,
        collection: RadarrCollection?,
        popularity: Double?,
        statistics: RadarrMovieStatistics?,
        alternateTitles: [RadarrAlternateTitle]?
    ) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.sortTitle = sortTitle
        self.sizeOnDisk = sizeOnDisk
        self.overview = overview
        self.inCinemas = inCinemas
        self.physicalRelease = physicalRelease
        self.digitalRelease = digitalRelease
        self.status = status
        self.images = images
        self.website = website
        self.year = year
        self.hasFile = hasFile
        self.youTubeTrailerId = youTubeTrailerId
        self.studio = studio
        self.path = path
        self.rootFolderPath = rootFolderPath
        self.qualityProfileId = qualityProfileId
        self.monitored = monitored
        self.minimumAvailability = minimumAvailability
        self.isAvailable = isAvailable
        self.folderName = folderName
        self.runtime = runtime
        self.cleanTitle = cleanTitle
        self.imdbId = imdbId
        self.tmdbId = tmdbId
        self.titleSlug = titleSlug
        self.certification = certification
        self.genres = genres
        self.tags = tags
        self.added = added
        self.ratings = ratings
        self.movieFile = movieFile
        self.collection = collection
        self.popularity = popularity
        self.statistics = statistics
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

    /// Best available fanart URL
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

    nonisolated private static func stableFallbackID(for title: String) -> Int {
        let digest = SHA256.hash(data: Data(title.utf8))
        let prefix = digest.prefix(8)
        let value = prefix.reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
        let positive = Int(truncatingIfNeeded: value & 0x3FFF_FFFF_FFFF_FFFF)
        return -max(positive, 1)
    }

    /// Human-readable status
    var displayStatus: String {
        if hasFile == true { return "Downloaded" }
        switch status {
        case "tba": return "TBA"
        case "announced": return "Announced"
        case "inCinemas": return "In Cinemas"
        case "released": return "Released"
        case "deleted": return "Deleted"
        default: return status ?? "Unknown"
        }
    }

    func updatingForEdit(
        monitored: Bool,
        qualityProfileId: Int,
        minimumAvailability: String,
        rootFolderPath: String,
        tags: [Int]
    ) -> RadarrMovie {
        RadarrMovie(
            id: id,
            title: title,
            originalTitle: originalTitle,
            sortTitle: sortTitle,
            sizeOnDisk: sizeOnDisk,
            overview: overview,
            inCinemas: inCinemas,
            physicalRelease: physicalRelease,
            digitalRelease: digitalRelease,
            status: status,
            images: images,
            website: website,
            year: year,
            hasFile: hasFile,
            youTubeTrailerId: youTubeTrailerId,
            studio: studio,
            path: path,
            rootFolderPath: rootFolderPath,
            qualityProfileId: qualityProfileId,
            monitored: monitored,
            minimumAvailability: minimumAvailability,
            isAvailable: isAvailable,
            folderName: folderName,
            runtime: runtime,
            cleanTitle: cleanTitle,
            imdbId: imdbId,
            tmdbId: tmdbId,
            titleSlug: titleSlug,
            certification: certification,
            genres: genres,
            tags: tags,
            added: added,
            ratings: ratings,
            movieFile: movieFile,
            collection: collection,
            popularity: popularity,
            statistics: statistics,
            alternateTitles: alternateTitles
        )
    }
}

struct RadarrRatings: Codable, Sendable {
    let imdb: RadarrRatingValue?
    let tmdb: RadarrRatingValue?
    let metacritic: RadarrRatingValue?
    let rottenTomatoes: RadarrRatingValue?
}

struct RadarrRatingValue: Codable, Sendable {
    let votes: Int?
    let value: Double?
    let type: String?
}

struct RadarrMovieStatistics: Codable, Sendable {
    let movieFileCount: Int?
    let sizeOnDisk: Int64?
    let releaseGroups: [String]?
}

struct RadarrAlternateTitle: Codable, Sendable {
    let sourceType: String?
    let movieMetadataId: Int?
    let title: String?
    let id: Int?
}

// MARK: - Movie File

struct RadarrMovieFile: Codable, Identifiable, Sendable {
    let id: Int
    let movieId: Int?
    let relativePath: String?
    let path: String?
    let size: Int64?
    let dateAdded: String?
    let quality: ArrHistoryQuality?
    let mediaInfo: RadarrMediaInfo?
    let edition: String?
}

struct RadarrMediaInfo: Codable, Sendable {
    let audioBitrate: Int64?
    let audioChannels: Double?
    let audioCodec: String?
    let audioLanguages: String?
    let audioStreamCount: Int?
    let videoBitDepth: Int?
    let videoBitrate: Int64?
    let videoCodec: String?
    let videoDynamicRangeType: String?
    let videoFps: Double?
    let resolution: String?
    let runTime: String?
    let scanType: String?
    let subtitles: String?
}

// MARK: - Collection

struct RadarrCollection: Codable, Sendable {
    let name: String?
    let tmdbId: Int?
    let images: [ArrImage]?
}

// MARK: - Add Movie Body

struct RadarrAddMovieBody: Codable, Sendable {
    let title: String
    let tmdbId: Int
    let qualityProfileId: Int
    let rootFolderPath: String
    let monitored: Bool
    let minimumAvailability: String
    let addOptions: RadarrAddOptions
    let tags: [Int]?
}

struct RadarrAddOptions: Codable, Sendable {
    let searchForMovie: Bool
    let monitor: String?            // "movieOnly", "movieAndCollection", "none"
}

// MARK: - Radarr Commands

enum RadarrCommand: String, Sendable {
    case refreshMovie = "RefreshMovie"
    case rescanMovie = "RescanMovie"
    case moviesSearch = "MoviesSearch"
    case missingMoviesSearch = "MissingMoviesSearch"
    case rssSync = "RssSync"
    case backup = "Backup"
}

// MARK: - Movie Lookup (search results for adding)
// Uses the same RadarrMovie struct — lookup results have tmdbId but no local id yet.
