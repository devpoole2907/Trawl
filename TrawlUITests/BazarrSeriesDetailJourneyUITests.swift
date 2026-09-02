//
//  BazarrSeriesDetailJourneyUITests.swift
//  TrawlUITests
//
//  `BazarrSeriesDetailView` is 1,991 executable lines at 0% coverage - nothing had
//  ever opened it. Mapping the route to write this turned up why: its natural entry
//  point, `BazarrBrowserView` (with `BazarrSeriesListView`/`BazarrMovieListView`), is
//  referenced nowhere outside its own file, so the Bazarr series browser cannot be
//  reached from the running app at all. `MoreDestination.bazarrSeriesDetail` is
//  pushed only from that dead screen. The one live route is `ArrWantedView`'s
//  `BazarrWantedSeriesRow`, which is the route this journey drives.
//
//  Every assertion below is on content *derived* from the fixture's own responses
//  rather than served verbatim, because that is the half a blank-screen regression
//  would take with it:
//  - "5 (2 missing)" is composed from two separate fields of the series record.
//  - The status line is `BazarrViewModel.subtitleStatus` rendered through
//    `statusText`, which reads "No Language Profile Assigned" when `profileId` is
//    absent - so asserting the missing-count phrasing also pins that the profile
//    survived decoding.
//  - The language profile *name* comes from a different endpoint
//    (`/api/system/languages/profiles`) joined on `profileId`. When that join
//    fails the screen silently falls back to "Profile 71", which looks plausible
//    enough to pass a laxer assertion - so the name is asserted and the fallback
//    is asserted absent.
//  - Season rows are grouped and pluralised in the view. The fixture gives season 1
//    two episodes and season 2 one, so "2 episodes" and "1 episode" are both
//    rendered and a broken pluralisation cannot hide behind a single case.

import XCTest

final class BazarrSeriesDetailJourneyUITests: XCTestCase {
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

    @MainActor
    func testWantedSubtitleRowOpensTheBazarrSeriesDetailWithRealServerData() async throws {
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
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 20))
        moreTab.tap()

        let wantedRow = app.buttons["Missing"].exists
            ? app.buttons["Missing"]
            : app.staticTexts["Missing"]
        XCTAssertTrue(
            wantedRow.waitForExistence(in: app, timeout: 15),
            "More should offer its Missing row."
        )
        XCTAssertTrue(tapWhenHittable(wantedRow, in: app, timeout: 15))

        // The subtitle section only renders for a series Bazarr reports as missing
        // episodes, so reaching this row already proves the series decoded with a
        // non-zero episodeMissingCount.
        let seriesRow = app.staticTexts[BazarrUIFixtureServer.seriesTitle]
        XCTAssertTrue(
            seriesRow.waitForExistence(in: app, timeout: 20),
            "Missing should list the Bazarr series with outstanding subtitles."
        )
        XCTAssertTrue(
            tapWhenHittable(seriesRow, in: app, timeout: 15),
            "The wanted subtitle row should push the Bazarr series detail."
        )

        XCTAssertTrue(
            app.navigationBars[BazarrUIFixtureServer.seriesTitle].waitForExistence(timeout: 20),
            "The Bazarr series detail should title itself from the series Bazarr returned."
        )

        // `LabeledContent` renders label and value as a *single* accessibility
        // element ("Episodes, 5 (2 missing)"), and season rows are buttons whose
        // label carries both lines. Read off the real hierarchy rather than assumed
        // from the SwiftUI source - the two do not match here, and a locator that
        // guesses fails for a reason that has nothing to do with the screen.
        let episodesLine = "Episodes, \(BazarrUIFixtureServer.seriesEpisodeFileCount) (\(BazarrUIFixtureServer.seriesEpisodeMissingCount) missing)"
        XCTAssertTrue(
            app.staticTexts[episodesLine].waitForExistence(in: app, timeout: 15),
            "The Info section composes its episode line from the series record's file and missing counts."
        )

        XCTAssertTrue(
            app.staticTexts["Status, \(BazarrUIFixtureServer.seriesEpisodeMissingCount) Episode(s) Missing"]
                .waitForExistence(in: app, timeout: 10),
            "A series with a language profile and a non-zero missing count is a partial subtitle status. Without the profile this reads \"No Language Profile Assigned\", so this also pins that profileId survived decoding."
        )

        XCTAssertTrue(
            app.buttons["Language Profile, \(BazarrUIFixtureServer.languageProfileName)"]
                .waitForExistence(in: app, timeout: 10),
            "The language profile must resolve to its name through /api/system/languages/profiles, joined on profileId."
        )
        XCTAssertFalse(
            app.buttons["Language Profile, Profile \(BazarrUIFixtureServer.languageProfileID)"].exists,
            "Falling back to the raw profile id means the cross-endpoint join broke - it renders plausibly and would pass a laxer assertion."
        )

        // Seasons render newest first, and the fixture's two seasons carry
        // different episode counts so both plural forms are exercised in one render.
        XCTAssertTrue(
            app.buttons["Season 2, \(BazarrUIFixtureServer.seasonTwoEpisodeCount) episode"]
                .waitForExistence(in: app, timeout: 10),
            "A one-episode season must read \"1 episode\", not \"1 episodes\"."
        )
        XCTAssertTrue(
            app.buttons["Season 1, \(BazarrUIFixtureServer.seasonOneEpisodeCount) episodes"]
                .waitForExistence(in: app, timeout: 10),
            "A multi-episode season must pluralise, and episodes must be grouped into the right season."
        )

        let episodeRequests = bazarr.requests.filter { $0.method == "GET" && $0.path == "/api/episodes" }
        XCTAssertFalse(
            episodeRequests.isEmpty,
            "The season list must come from a real GET /api/episodes, not from cached or preview data."
        )
    }

    @discardableResult
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                element.tap()
                return true
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }
}
