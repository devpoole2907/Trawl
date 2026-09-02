//
//  BazarrJourneyUITests.swift
//  TrawlUITests
//
//  A tier-1 Bazarr journey: real Radarr navigation reaches the real Bazarr
//  subtitle-status card, whose missing-subtitle result comes over loopback HTTP.

import XCTest

final class BazarrJourneyUITests: XCTestCase {
    private var radarrServer: RadarrFixtureServer?
    private var bazarrServer: BazarrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        bazarrServer?.stop()
        bazarrServer = nil
        radarrServer?.stop()
        radarrServer = nil
    }

    /// Regressions this catches: Bazarr no longer connects from a seeded profile,
    /// the Radarr detail route no longer assembles BazarrSubtitleStatusCard, a
    /// tracked missing language decoding as an empty/unknown state, or detail
    /// content being shown without the real Bazarr request reaching the server.
    @MainActor
    func testRadarrDetailShowsBazarrTrackedMissingSubtitleFromRealServerData() async throws {
        let radarr = try await RadarrFixtureServer(initiallyMonitored: true)
        radarrServer = radarr
        let bazarr = try await BazarrUIFixtureServer(
            radarrMovieID: RadarrFixtureServer.movieId,
            radarrMovieTitle: RadarrFixtureServer.movieTitle
        )
        bazarrServer = bazarr

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = radarr.baseURL
        app.launchEnvironment["TRAWL_UITEST_BAZARR_BASE_URL"] = bazarr.baseURL
        // The Radarr detail also starts a TMDb cast lookup. Keep this journey
        // hermetic; the lookup is non-critical and fails immediately on this port.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A launch with seeded Radarr and Bazarr profiles should pass the welcome gate into the real app chrome."
        )
        XCTAssertTrue(openDestination(.movies, in: app), "The Movies library should be reachable.")

        XCTAssertTrue(
            app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(timeout: 15),
            "Movies should render the fixture movie through the real Radarr connection before its detail route is opened."
        )
        XCTAssertTrue(
            openLibraryItem(titled: RadarrFixtureServer.movieTitle, in: app),
            "The fixture movie row should open so the test uses the production Movies-to-detail navigation path."
        )

        let subtitleCard = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Subtitles"))
            .firstMatch
        XCTAssertTrue(
            subtitleCard.waitForExistence(in: app, timeout: 15),
            "A Radarr library detail should include BazarrSubtitleStatusCard when Bazarr is connected."
        )
        XCTAssertTrue(
            tapWhenHittable(subtitleCard, in: app, timeout: 15),
            "The Subtitles card should expand to reveal the tracked Bazarr state."
        )

        let missingSummary = app.staticTexts["1 language missing."]
        XCTAssertTrue(
            missingSummary.waitForExistence(in: app, timeout: 15),
            "Bazarr's assigned language profile and missing-language payload should render the tracked missing-subtitle summary, not an untracked or unknown state."
        )
        XCTAssertTrue(
            app.staticTexts["MISSING"].waitForExistence(in: app, timeout: 5),
            "The expanded card should identify the missing-language section."
        )
        XCTAssertTrue(
            app.staticTexts[BazarrUIFixtureServer.missingLanguageCode].waitForExistence(in: app, timeout: 5),
            "The missing language chip should display the exact ISO-639 code decoded from Bazarr's response."
        )

        XCTAssertTrue(
            bazarr.receivedTrackedMovieRequest(apiKey: "uitest-api-key"),
            "The visible missing-subtitle state must come from a real GET /api/movies?radarrid[]=\(RadarrFixtureServer.movieId) carrying Bazarr's X-API-KEY, not from cached preview data or a mocked app method."
        )
    }

    @discardableResult
    @MainActor
    private func tapWhenHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            } else if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }
}
