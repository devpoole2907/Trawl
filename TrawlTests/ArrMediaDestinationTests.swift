import Testing
@testable import Trawl

/// `RadarrMovie`/`SonarrSeries` both implement `Hashable` purely in terms of `id`
/// (see `RadarrModels.swift`/`SonarrModels.swift`: `static func == (lhs, rhs) { lhs.id == rhs.id }`).
/// `ArrMediaDestination`'s synthesized `Hashable` conformance therefore inherits that ID-based
/// equality for the `.movieLookup`/`.seriesLookup` cases: two lookup results that share an `id`
/// (Radarr/Sonarr both report `id == 0` for anything not yet in the library) compare equal even
/// if every other field differs. These tests pin down that actual, occasionally-surprising
/// behavior rather than an idealized one.
@Suite("ArrMediaDestination Tests")
@MainActor
struct ArrMediaDestinationTests {

    // MARK: - Library-mode cases (.movie / .series)

    @Test("Movie destinations with the same id are equal")
    func movieSameIDEqual() {
        #expect(ArrMediaDestination.movie(id: 42) == .movie(id: 42))
        #expect(ArrMediaDestination.movie(id: 42).hashValue == ArrMediaDestination.movie(id: 42).hashValue)
    }

    @Test("Movie destinations with different ids are not equal")
    func movieDifferentIDNotEqual() {
        #expect(ArrMediaDestination.movie(id: 1) != .movie(id: 2))
    }

    @Test("Series destinations with the same id are equal")
    func seriesSameIDEqual() {
        #expect(ArrMediaDestination.series(id: 7) == .series(id: 7))
        #expect(ArrMediaDestination.series(id: 7).hashValue == ArrMediaDestination.series(id: 7).hashValue)
    }

    @Test("Series destinations with different ids are not equal")
    func seriesDifferentIDNotEqual() {
        #expect(ArrMediaDestination.series(id: 1) != .series(id: 2))
    }

    // MARK: - Discover-mode cases (.movieLookup / .seriesLookup)

    @Test("Movie lookup equality is ID-based, not value-based")
    func movieLookupEqualityIsIDBased() {
        // Same id, wildly different titles: RadarrMovie's own `==` only compares `id`
        // (`RadarrModels.swift`), so these two lookup destinations are considered equal
        // despite representing different movies.
        let movieA = RadarrMovie.makeLookupResult(id: 99, title: "Movie A")
        let movieB = RadarrMovie.makeLookupResult(id: 99, title: "Movie B")

        #expect(movieA == movieB) // confirms the premise: RadarrMovie equality is id-only.
        #expect(ArrMediaDestination.movieLookup(movieA) == .movieLookup(movieB))
        #expect(ArrMediaDestination.movieLookup(movieA).hashValue == ArrMediaDestination.movieLookup(movieB).hashValue)
    }

    @Test("Movie lookup results that Radarr hasn't added yet all collapse to id 0")
    func unaddedMovieLookupResultsCollide() {
        // Radarr's /movie/lookup endpoint reports id 0 for anything not in the library yet.
        // Two distinct search results therefore produce colliding ArrMediaDestination values.
        let dune = RadarrMovie.makeLookupResult(id: 0, title: "Dune")
        let oppenheimer = RadarrMovie.makeLookupResult(id: 0, title: "Oppenheimer")

        let destinations: Set<ArrMediaDestination> = [.movieLookup(dune), .movieLookup(oppenheimer)]
        #expect(destinations.count == 1)
    }

    @Test("Movie lookup destinations with different ids are not equal")
    func movieLookupDifferentIDNotEqual() {
        let movieA = RadarrMovie.makeLookupResult(id: 1, title: "Same Title")
        let movieB = RadarrMovie.makeLookupResult(id: 2, title: "Same Title")
        #expect(ArrMediaDestination.movieLookup(movieA) != .movieLookup(movieB))
    }

    @Test("Series lookup equality is ID-based, not value-based")
    func seriesLookupEqualityIsIDBased() {
        let seriesA = SonarrSeries.makeLookupResult(id: 55, title: "Series A")
        let seriesB = SonarrSeries.makeLookupResult(id: 55, title: "Series B")

        #expect(ArrMediaDestination.seriesLookup(seriesA) == .seriesLookup(seriesB))
        #expect(ArrMediaDestination.seriesLookup(seriesA).hashValue == ArrMediaDestination.seriesLookup(seriesB).hashValue)
    }

    @Test("Series lookup results Sonarr hasn't added yet all collapse to id 0")
    func unaddedSeriesLookupResultsCollide() {
        let severance = SonarrSeries.makeLookupResult(id: 0, title: "Severance")
        let theBear = SonarrSeries.makeLookupResult(id: 0, title: "The Bear")

        let destinations: Set<ArrMediaDestination> = [.seriesLookup(severance), .seriesLookup(theBear)]
        #expect(destinations.count == 1)
    }

    @Test("Series lookup destinations with different ids are not equal")
    func seriesLookupDifferentIDNotEqual() {
        let seriesA = SonarrSeries.makeLookupResult(id: 1, title: "Same Title")
        let seriesB = SonarrSeries.makeLookupResult(id: 2, title: "Same Title")
        #expect(ArrMediaDestination.seriesLookup(seriesA) != .seriesLookup(seriesB))
    }

    // MARK: - Cross-case identity

    @Test("Different cases with the same underlying id are never equal")
    func differentCasesNeverEqual() {
        let movie = RadarrMovie.makeLookupResult(id: 1, title: "Whatever")
        let series = SonarrSeries.makeLookupResult(id: 1, title: "Whatever")

        #expect(ArrMediaDestination.movie(id: 1) != .series(id: 1))
        #expect(ArrMediaDestination.movie(id: 1) != .movieLookup(movie))
        #expect(ArrMediaDestination.series(id: 1) != .seriesLookup(series))
        #expect(ArrMediaDestination.movieLookup(movie) != .seriesLookup(series))
    }

    @Test("Distinct movies and series with distinct ids all coexist in a Set")
    func distinctValuesCoexistInASet() {
        let destinations: Set<ArrMediaDestination> = [
            .movie(id: 1),
            .movie(id: 2),
            .series(id: 1),
            .series(id: 2),
            .movieLookup(RadarrMovie.makeLookupResult(id: 10, title: "A")),
            .movieLookup(RadarrMovie.makeLookupResult(id: 11, title: "B")),
            .seriesLookup(SonarrSeries.makeLookupResult(id: 10, title: "C")),
            .seriesLookup(SonarrSeries.makeLookupResult(id: 11, title: "D"))
        ]
        #expect(destinations.count == 8)
    }
}

// MARK: - Test fixtures

private extension RadarrMovie {
    /// Minimal, distinctly-titled `RadarrMovie` for exercising `ArrMediaDestination` equality -
    /// deliberately independent of the `#if DEBUG` preview fixtures so these tests don't depend
    /// on their specific ids.
    static func makeLookupResult(id: Int, title: String) -> RadarrMovie {
        RadarrMovie(
            id: id,
            title: title,
            originalTitle: title,
            sortTitle: title.lowercased(),
            sizeOnDisk: nil,
            overview: nil,
            inCinemas: nil,
            physicalRelease: nil,
            digitalRelease: nil,
            status: "announced",
            images: nil,
            website: nil,
            year: nil,
            hasFile: false,
            youTubeTrailerId: nil,
            studio: nil,
            path: nil,
            rootFolderPath: nil,
            qualityProfileId: nil,
            monitored: nil,
            minimumAvailability: nil,
            isAvailable: nil,
            folderName: nil,
            runtime: nil,
            cleanTitle: nil,
            imdbId: nil,
            tmdbId: id,
            titleSlug: nil,
            certification: nil,
            genres: nil,
            tags: nil,
            added: nil,
            ratings: nil,
            movieFile: nil,
            collection: nil,
            popularity: nil,
            statistics: nil,
            alternateTitles: nil
        )
    }
}

private extension SonarrSeries {
    /// Minimal, distinctly-titled `SonarrSeries` for exercising `ArrMediaDestination` equality.
    static func makeLookupResult(id: Int, title: String) -> SonarrSeries {
        SonarrSeries(
            id: id,
            title: title,
            sortTitle: title.lowercased(),
            status: "continuing",
            ended: nil,
            overview: nil,
            network: nil,
            airTime: nil,
            images: nil,
            remotePoster: nil,
            seasons: nil,
            year: nil,
            path: nil,
            qualityProfileId: nil,
            seasonFolder: nil,
            monitored: nil,
            tvdbId: id,
            tvRageId: nil,
            tvMazeId: nil,
            imdbId: nil,
            titleSlug: nil,
            certification: nil,
            genres: nil,
            tags: nil,
            added: nil,
            ratings: nil,
            statistics: nil,
            languageProfileId: nil,
            runtime: nil,
            seriesType: nil,
            cleanTitle: nil,
            rootFolderPath: nil,
            alternateTitles: nil
        )
    }
}
