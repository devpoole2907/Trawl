#if DEBUG
import Foundation

extension RadarrMovie {
    static let preview = RadarrMovie.makePreview()
    static let previewReleased = RadarrMovie.makePreview(id: 2, title: "Dune: Part Two", status: "released", hasFile: true)
    static let previewMissingArt = RadarrMovie.makePreview(id: 3, title: "Oppenheimer", images: nil, studio: nil)
    static let previewLongTitle = RadarrMovie.makePreview(
        id: 4,
        title: "Everything Everywhere All at Once: The Extended Director's Cut With Additional Scenes"
    )
    static let previewAnnounced = RadarrMovie.makePreview(id: 5, title: "Avatar 3", status: "announced", monitored: true, hasFile: false)
    static let previewUnmonitored = RadarrMovie.makePreview(id: 6, title: "Blade Runner 2049", monitored: false, hasFile: true)
    static let previewSparse = RadarrMovie.makePreview(
        id: 7,
        title: "Untitled Mystery Project",
        status: "tba",
        hasFile: false,
        year: nil,
        images: nil,
        sizeOnDisk: nil,
        runtime: nil,
        studio: nil,
        ratings: nil,
        collection: nil,
        alternateTitles: nil
    )

    static let previewList: [RadarrMovie] = [
        preview, previewReleased, previewMissingArt, previewLongTitle, previewAnnounced, previewUnmonitored,
    ]

    static let previewHeavyList: [RadarrMovie] = (1...40).map { i in
        .makePreview(
            id: 100 + i,
            title: i.isMultiple(of: 7) ? "Very Long Movie Title Number \(i) That Wraps Across Many Lines" : "Movie \(i)",
            status: i.isMultiple(of: 3) ? "released" : "announced",
            monitored: !i.isMultiple(of: 5),
            hasFile: i.isMultiple(of: 2),
            year: i.isMultiple(of: 6) ? nil : 1980 + (i % 45),
            images: i.isMultiple(of: 4) ? nil : [.init(coverType: "poster", url: "https://example.com/movie\(i).jpg", remoteUrl: nil)],
            sizeOnDisk: i.isMultiple(of: 2) ? Int64(i) * 1_250_000_000 : 0
        )
    }

    fileprivate static func makePreview(
        id: Int = 1,
        title: String = "The Shawshank Redemption",
        status: String = "released",
        monitored: Bool = true,
        hasFile: Bool = true,
        year: Int? = 1994,
        images: [ArrImage]? = [
            .init(coverType: "poster", url: "https://example.com/shawshank.jpg", remoteUrl: nil),
            .init(coverType: "fanart", url: "https://example.com/shawshank-fanart.jpg", remoteUrl: nil)
        ],
        sizeOnDisk: Int64? = nil,
        runtime: Int? = 142,
        studio: String? = "Castle Rock Entertainment",
        ratings: RadarrRatings? = .preview,
        collection: RadarrCollection? = .preview,
        alternateTitles: [RadarrAlternateTitle]? = [.preview]
    ) -> RadarrMovie {
        RadarrMovie(
            id: id,
            title: title,
            originalTitle: title,
            sortTitle: title.lowercased(),
            sizeOnDisk: sizeOnDisk ?? (hasFile ? 4_800_000_000 : 0),
            overview: "Two imprisoned men bond over a number of years, finding solace and eventual redemption through acts of common decency.",
            inCinemas: "1994-09-23T00:00:00Z",
            physicalRelease: "1995-01-24T00:00:00Z",
            digitalRelease: "1995-01-24T00:00:00Z",
            status: status,
            images: images,
            website: "https://example.com",
            year: year,
            hasFile: hasFile,
            youTubeTrailerId: "6hB3S9bIaco",
            studio: studio,
            path: "/movies/\(title) (\(year ?? 0))",
            rootFolderPath: "/movies",
            qualityProfileId: 1,
            monitored: monitored,
            minimumAvailability: "released",
            isAvailable: status == "released",
            folderName: "\(title) (\(year ?? 0))",
            runtime: runtime,
            cleanTitle: title.lowercased().replacingOccurrences(of: " ", with: ""),
            imdbId: "tt0111161",
            tmdbId: 278 + id,
            titleSlug: title.lowercased().replacingOccurrences(of: " ", with: "-"),
            certification: "R",
            genres: ["Drama", "Crime"],
            tags: id.isMultiple(of: 2) ? [1] : [],
            added: "2025-06-01T12:00:00Z",
            ratings: ratings,
            movieFile: hasFile ? .makePreview(movieId: id) : nil,
            collection: collection,
            popularity: 48.2,
            statistics: RadarrMovieStatistics(movieFileCount: hasFile ? 1 : 0, sizeOnDisk: sizeOnDisk ?? (hasFile ? 4_800_000_000 : 0), releaseGroups: ["FRAME"]),
            alternateTitles: alternateTitles
        )
    }
}

extension RadarrRatings {
    static let preview = RadarrRatings(
        imdb: RadarrRatingValue(votes: 2_800_000, value: 9.3, type: "user"),
        tmdb: RadarrRatingValue(votes: 26_000, value: 8.7, type: "user"),
        metacritic: RadarrRatingValue(votes: 21, value: 82, type: "critic"),
        rottenTomatoes: RadarrRatingValue(votes: 91, value: 91, type: "critic")
    )
}

extension RadarrMovieFile {
    static let preview = RadarrMovieFile.makePreview(movieId: 1)

    static func makePreview(
        id: Int = 1,
        movieId: Int = 1,
        relativePath: String = "The Shawshank Redemption (1994) - 1080p.mkv",
        size: Int64 = 4_800_000_000
    ) -> RadarrMovieFile {
        RadarrMovieFile(
            id: id,
            movieId: movieId,
            relativePath: relativePath,
            path: "/movies/The Shawshank Redemption (1994)/\(relativePath)",
            size: size,
            dateAdded: "2025-06-01T12:00:00Z",
            quality: ArrHistoryQuality(quality: ArrQuality(id: 3, name: "Bluray-1080p", source: "bluray", resolution: 1080)),
            mediaInfo: .preview,
            edition: "Remastered"
        )
    }
}

extension RadarrMediaInfo {
    static let preview = RadarrMediaInfo(
        audioBitrate: 768_000,
        audioChannels: 5.1,
        audioCodec: "DTS",
        audioLanguages: "English",
        audioStreamCount: 1,
        videoBitDepth: 10,
        videoBitrate: 8_500_000,
        videoCodec: "HEVC",
        videoDynamicRangeType: "HDR10",
        videoFps: 23.976,
        resolution: "1920x1080",
        runTime: "2:22:00",
        scanType: "Progressive",
        subtitles: "English"
    )
}

extension RadarrCollection {
    static let preview = RadarrCollection(
        name: "Stephen King Adaptations",
        tmdbId: 999001,
        images: [.init(coverType: "poster", url: "https://example.com/collection.jpg", remoteUrl: nil)]
    )
}

extension RadarrAlternateTitle {
    static let preview = RadarrAlternateTitle(
        sourceType: "tmdb",
        movieMetadataId: 1,
        title: "Rita Hayworth and Shawshank Redemption",
        id: 1
    )
}
#endif
