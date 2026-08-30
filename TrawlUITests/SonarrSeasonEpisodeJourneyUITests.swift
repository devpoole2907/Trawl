//
//  SonarrSeasonEpisodeJourneyUITests.swift
//  TrawlUITests
//
//  `SonarrSeriesSearchViews.swift` was the single largest coverage gap in the app:
//  3,616 executable lines at 12.7%. Most of that is the season and episode
//  drill-down - `SonarrSeasonSearchView` and `SonarrEpisodeSearchView` - which no
//  test had ever opened with real episodes, because no journey had ever given the
//  Sonarr fixture an episode list to serve.
//
//  These are the screens a user reaches to chase a single missing episode, so a
//  decode or rendering regression here is invisible until exactly the moment someone
//  is trying to fix something.
//

import Foundation
import XCTest

final class SonarrSeasonEpisodeJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?

    private static let seriesTitle = "Fixture Drilldown Series"
    private static let downloadedEpisodeTitle = "The Downloaded One"
    private static let missingEpisodeTitle = "The Missing One"

    /// One season, two episodes: one with a file and one without. The pair matters -
    /// the season screen renders those two states differently, and a fixture with
    /// only one of them exercises half the view.
    private static let episodesJSON = """
    [
      {"id":101,"seriesId":1,"seasonNumber":1,"episodeNumber":1,"title":"\(downloadedEpisodeTitle)",
       "airDateUtc":"2026-01-01T00:00:00Z","hasFile":true,"monitored":true,"episodeFileId":9001},
      {"id":102,"seriesId":1,"seasonNumber":1,"episodeNumber":2,"title":"\(missingEpisodeTitle)",
       "airDateUtc":"2026-01-08T00:00:00Z","hasFile":false,"monitored":true,"episodeFileId":0}
    ]
    """

    private static let seriesJSON = """
    [{"id":1,"title":"\(seriesTitle)","tvdbId":700,"titleSlug":"fixture-drilldown",
      "monitored":true,"path":"/tv/Fixture",
      "seasons":[{"seasonNumber":1,"monitored":true}],
      "statistics":{"seasonCount":1,"episodeCount":2,"episodeFileCount":1}}]
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarr?.stop()
        sonarr = nil
    }

    @MainActor
    func testSeasonAndEpisodeScreensRenderRealEpisodes() async throws {
        let sonarr = try await SonarrFixtureServer(
            seriesJSON: Self.seriesJSON,
            episodesJSON: Self.episodesJSON
        )
        self.sonarr = sonarr

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarr.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(tapWhenHittable(seriesTab, in: app, timeout: 20), "A configured Sonarr launch should reach the Series tab.")

        let seriesRow = app.staticTexts[Self.seriesTitle]
        XCTAssertTrue(seriesRow.waitForExistence(in: app, timeout: 15), "The library should render the fixture series.")
        XCTAssertTrue(tapWhenHittable(seriesRow, in: app, timeout: 10), "Tapping the series should open its detail screen.")

        // MARK: Season screen

        let seasonRow = firstButton(labelContaining: "Season 1", in: app)
        XCTAssertTrue(
            tapWhenHittable(seasonRow, in: app, timeout: 15),
            "The series detail should list Season 1 for a series whose episodes decoded."
        )
        XCTAssertTrue(
            app.navigationBars["Season 1"].waitForExistence(in: app, timeout: 10),
            "Tapping a season should push SonarrSeasonSearchView titled for that season."
        )

        // Both episodes, decoded from the server's own response. Asserting only the
        // navigation bar would pass on a screen that pushed and then rendered nothing.
        XCTAssertTrue(
            app.staticTexts[Self.downloadedEpisodeTitle].waitForExistence(in: app, timeout: 15),
            "The season screen should render the episode that has a file."
        )
        XCTAssertTrue(
            app.staticTexts[Self.missingEpisodeTitle].waitForExistence(in: app, timeout: 10),
            "The season screen should also render the episode with no file - the two states render differently, and only showing one of them hides half the view."
        )
        XCTAssertTrue(
            sonarr.hasReceivedRequest(method: "GET", path: "/api/v3/episode"),
            "The episodes must have come over real HTTP rather than from a cache."
        )

        // MARK: Episode screen

        // The episode's own title text, not a `buttons` match on its label.
        //
        // Matching buttons by label found something whose centre coordinate landed on
        // the notification pill pinned at the bottom of the window, which opened the
        // Notifications sheet - a tap that "succeeded" while going somewhere else
        // entirely. Tapping the title's own element keeps the coordinate inside the
        // row it names.
        let episodeRow = app.staticTexts[Self.missingEpisodeTitle]
        XCTAssertTrue(
            tapWhenHittable(episodeRow, in: app, timeout: 12),
            "An episode row should open its own search screen - this is the route for chasing a single missing episode."
        )
        // Titled by `episodeIdentifier`, which is derived rather than served: a
        // formatting regression there renames every episode screen in the app.
        XCTAssertTrue(
            app.navigationBars["S01E02"].waitForExistence(in: app, timeout: 12),
            "The episode screen should be titled with its S/E identifier, which is derived rather than served - a formatting regression there renames every episode screen in the app."
        )
        XCTAssertTrue(
            app.staticTexts[Self.missingEpisodeTitle].waitForExistence(in: app, timeout: 10),
            "The episode screen should render the episode it was opened for."
        )
    }

    // MARK: Helpers

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @discardableResult
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }
}
