import Foundation
import Testing
@testable import Trawl

@Suite("Search recently viewed history")
struct SearchRecentlyViewedTests {
    @Test("Library destinations retain server identity across persistence")
    func libraryDestinationRoundTrips() throws {
        let instanceID = UUID()
        var movie = try Self.movie(id: 42, tmdbID: 550, title: "Fight Club")
        movie.instanceID = instanceID
        let item = SearchRecentlyViewedItem(movie: movie, presentation: .library)

        let decoded = try #require(
            SearchRecentlyViewedHistory.decode(
                SearchRecentlyViewedHistory.encode([item])
            ).first
        )

        #expect(decoded.title == "Fight Club")
        #expect(decoded.id == "movie-tmdb-550")
        guard case .movie(let id, let decodedInstanceID, _) = decoded.destination else {
            Issue.record("Expected a library movie destination")
            return
        }
        #expect(id == 42)
        #expect(decodedInstanceID == instanceID)
    }

    @Test("Movie and series entries share one persisted shelf")
    func mixedMediaRoundTrips() throws {
        let movie = SearchRecentlyViewedItem(
            movie: try Self.movie(id: 0, tmdbID: 550, title: "Fight Club"),
            presentation: .lookup
        )
        let series = SearchRecentlyViewedItem(
            series: try Self.series(id: 0, tvdbID: 371980, title: "Severance"),
            presentation: .lookup
        )

        let decoded = SearchRecentlyViewedHistory.decode(
            SearchRecentlyViewedHistory.encode([series, movie])
        )

        #expect(decoded.map(\.id) == ["series-tvdb-371980", "movie-tmdb-550"])
        #expect(decoded.map(\.kindLabel) == ["Series", "Movie"])
        guard case .seriesLookup(let restoredSeries) = decoded.first?.destination else {
            Issue.record("Expected a series lookup destination")
            return
        }
        #expect(restoredSeries.title == "Severance")
    }

    @Test("Revisiting a title moves it to the front without duplicating it")
    func revisitMovesToFront() throws {
        let first = SearchRecentlyViewedItem(
            movie: try Self.movie(id: 0, tmdbID: 100, title: "First"),
            presentation: .lookup
        )
        let second = SearchRecentlyViewedItem(
            movie: try Self.movie(id: 0, tmdbID: 200, title: "Second"),
            presentation: .lookup
        )
        let revisited = SearchRecentlyViewedItem(
            movie: try Self.movie(id: 7, tmdbID: 100, title: "First — Refreshed"),
            presentation: .library
        )

        let initial = SearchRecentlyViewedHistory.inserting(second, into: [first])
        let updated = SearchRecentlyViewedHistory.inserting(revisited, into: initial)

        #expect(updated.map(\.id) == ["movie-tmdb-100", "movie-tmdb-200"])
        #expect(updated.first?.title == "First — Refreshed")
    }

    @Test("The shelf shows every retained item while persistence stays bounded")
    func historyIsBounded() throws {
        var history: [SearchRecentlyViewedItem] = []
        for id in 1...(SearchRecentlyViewedHistory.maximumCount + 5) {
            history = SearchRecentlyViewedHistory.inserting(
                SearchRecentlyViewedItem(
                    movie: try Self.movie(id: 0, tmdbID: id, title: "Movie \(id)"),
                    presentation: .lookup
                ),
                into: history
            )
        }

        #expect(history.count == SearchRecentlyViewedHistory.maximumCount)
        #expect(history.first?.title == "Movie 25")
        #expect(history.last?.title == "Movie 6")
    }

    @Test("Invalid saved history fails closed to an absent shelf")
    func corruptStorageIsEmpty() {
        #expect(SearchRecentlyViewedHistory.decode("not json").isEmpty)
    }

    private static func movie(id: Int, tmdbID: Int, title: String) throws -> RadarrMovie {
        let json = #"{"id":\#(id),"title":"\#(title)","tmdbId":\#(tmdbID),"year":2026}"#
        return try JSONDecoder().decode(RadarrMovie.self, from: Data(json.utf8))
    }

    private static func series(id: Int, tvdbID: Int, title: String) throws -> SonarrSeries {
        let json = #"{"id":\#(id),"title":"\#(title)","tvdbId":\#(tvdbID),"year":2026}"#
        return try JSONDecoder().decode(SonarrSeries.self, from: Data(json.utf8))
    }
}
