//
//  MovieQuickActionsJourneyUITests.swift
//  TrawlUITests
//
//  The Movies list's long-press search, against a loopback Radarr.
//

import XCTest

final class MovieQuickActionsJourneyUITests: XCTestCase {
    private var server: RadarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    /// Long-pressing a movie searches it without opening it. The fixture movie has
    /// a file, so the action is offered as an upgrade search.
    @MainActor
    func testMoviesListLongPressSearchesTheMovie() async throws {
        let server = try await RadarrFixtureServer(initiallyMonitored: true)
        self.server = server
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.movies, in: app))

        let row = app.staticTexts[RadarrFixtureServer.movieTitle].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.0)

        let action = app.buttons["Search for Upgrade"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "A downloaded movie's long-press should offer an upgrade search")
        action.tap()

        let predicate = NSPredicate { _, _ in
            server.requests.contains { request in
                guard request.method == "POST", request.path == "/api/v3/command",
                      let json = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
                else { return false }
                return json["name"] as? String == "MoviesSearch"
                    && (json["movieIds"] as? [Int]) == [RadarrFixtureServer.movieId]
            }
        }
        // Fails the test if MoviesSearch for exactly this movie never arrives.
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 15)
        XCTAssertFalse(app.staticTexts[RadarrFixtureServer.movieStudio].exists, "It should not have opened the movie")
    }
}
