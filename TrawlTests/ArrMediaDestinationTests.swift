import Foundation
import Testing
@testable import Trawl

/// `RadarrMovie`/`SonarrSeries` implement `Hashable` as `(id, instanceID)` - *library*
/// identity, which is right for a row that came from a server and wrong for a lookup result,
/// which has no server (`instanceID == nil`) and whose `id` is `0` until something adds it.
///
/// `ArrMediaDestination` therefore spells its own `Hashable` out rather than synthesizing it,
/// keying the two lookup cases on `lookupIdentity`. Before it did, every un-added lookup result
/// compared equal to every other one, and a `NavigationStack` keyed on those values reused the
/// screen it had already built - tapping a second trending card opened the first card's movie.
/// These tests pin that down at the level the navigation stack actually cares about.
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

    // MARK: - Library-mode cases carry their server

    /// The regression this pins: Radarr and Radarr 4K both issue small integer
    /// library IDs from 1, so the same integer names a different film on each. A
    /// destination that carried only the integer resolved to whichever server's
    /// copy the merged library listed first - adding "The Invite" as id 211 on the
    /// 4K server made every tap on it open the HD server's id 211 instead.
    @Test("Movie destinations on different servers are not equal")
    func movieSameIDDifferentInstanceNotEqual() {
        let hd = UUID()
        let uhd = UUID()

        #expect(ArrMediaDestination.movie(id: 211, instanceID: hd) != .movie(id: 211, instanceID: uhd))
        #expect(ArrMediaDestination.movie(id: 211, instanceID: hd) == .movie(id: 211, instanceID: hd))
    }

    /// An unstamped destination must not silently collapse onto a stamped one:
    /// "id 211, server unknown" and "id 211 on the 4K server" are different
    /// addresses, and treating them as one is exactly the collision above.
    @Test("An unstamped movie destination is distinct from a stamped one")
    func movieUnstampedDistinctFromStamped() {
        #expect(ArrMediaDestination.movie(id: 211) != .movie(id: 211, instanceID: UUID()))
    }

    @Test("Series destinations on different servers are not equal")
    func seriesSameIDDifferentInstanceNotEqual() {
        let hd = UUID()
        let uhd = UUID()

        #expect(ArrMediaDestination.series(id: 7, instanceID: hd) != .series(id: 7, instanceID: uhd))
        #expect(ArrMediaDestination.series(id: 7, instanceID: hd) == .series(id: 7, instanceID: hd))
    }

    // MARK: - Discover-mode cases (.movieLookup / .seriesLookup)

    @Test("Two movies sharing a library id are still distinct destinations")
    func movieLookupDistinguishesTitlesSharingALibraryID() {
        // The models' own `==` compares (id, instanceID), so these two are equal *as
        // movies* - that is library identity and it stays as it is. The destination
        // must not inherit it, or the stack cannot tell the two screens apart.
        let movieA = RadarrMovie.makeLookupResult(id: 99, title: "Movie A")
        let movieB = RadarrMovie.makeLookupResult(id: 99, title: "Movie B")

        #expect(movieA == movieB) // the premise: RadarrMovie equality is library identity.
        #expect(ArrMediaDestination.movieLookup(movieA) != .movieLookup(movieB))
    }

    @Test("A movie lookup destination equals itself")
    func movieLookupEqualsAnIdenticalCopy() {
        let movie = RadarrMovie.makeLookupResult(id: 0, title: "Dune")
        let same = RadarrMovie.makeLookupResult(id: 0, title: "Dune")

        #expect(ArrMediaDestination.movieLookup(movie) == .movieLookup(same))
        #expect(ArrMediaDestination.movieLookup(movie).hashValue == ArrMediaDestination.movieLookup(same).hashValue)
    }

    @Test("Movie lookup results Radarr hasn't added yet stay distinct despite sharing id 0")
    func unaddedMovieLookupResultsStayDistinct() {
        // Radarr's /movie/lookup endpoint reports id 0 for everything not in the library
        // yet, which is the exact shape that used to collapse a whole page of search
        // results onto one destination.
        let dune = RadarrMovie.makeLookupResult(id: 0, title: "Dune")
        let oppenheimer = RadarrMovie.makeLookupResult(id: 0, title: "Oppenheimer")

        let destinations: Set<ArrMediaDestination> = [.movieLookup(dune), .movieLookup(oppenheimer)]
        #expect(destinations.count == 2)
    }

    @Test("Movie lookup destinations with different ids are not equal")
    func movieLookupDifferentIDNotEqual() {
        let movieA = RadarrMovie.makeLookupResult(id: 1, title: "Same Title")
        let movieB = RadarrMovie.makeLookupResult(id: 2, title: "Same Title")
        #expect(ArrMediaDestination.movieLookup(movieA) != .movieLookup(movieB))
    }

    @Test("Two series sharing a library id are still distinct destinations")
    func seriesLookupDistinguishesTitlesSharingALibraryID() {
        let seriesA = SonarrSeries.makeLookupResult(id: 55, title: "Series A")
        let seriesB = SonarrSeries.makeLookupResult(id: 55, title: "Series B")

        #expect(seriesA == seriesB) // the premise: SonarrSeries equality is library identity.
        #expect(ArrMediaDestination.seriesLookup(seriesA) != .seriesLookup(seriesB))
    }

    @Test("Series lookup results Sonarr hasn't added yet stay distinct despite sharing id 0")
    func unaddedSeriesLookupResultsStayDistinct() {
        let severance = SonarrSeries.makeLookupResult(id: 0, title: "Severance")
        let theBear = SonarrSeries.makeLookupResult(id: 0, title: "The Bear")

        let destinations: Set<ArrMediaDestination> = [.seriesLookup(severance), .seriesLookup(theBear)]
        #expect(destinations.count == 2)
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
