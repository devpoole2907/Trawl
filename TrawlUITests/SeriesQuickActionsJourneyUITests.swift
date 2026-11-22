//
//  SeriesQuickActionsJourneyUITests.swift
//  TrawlUITests
//
//  The newest-episode routes - Up Next, the Episodes section and the Series list's
//  long-press - driven through the real screens against a loopback Sonarr.
//

import XCTest

final class SeriesQuickActionsJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?

    private static let title = "Long Runner"
    /// The newest aired episode, aired yesterday and not on disk.
    private static let latestEpisodeID = 305
    /// Next week's episode.
    private static let upcomingEpisodeID = 306

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        sonarr?.stop()
        sonarr = nil
        super.tearDown()
    }

    /// Three seasons. Seasons 1 and 2 are complete apart from one gap in season 2;
    /// season 3 is running, with episode 5 aired and missing and episode 6 next week.
    @MainActor
    private func launch() async throws -> (XCUIApplication, SonarrFixtureServer) {
        let day: TimeInterval = 86_400
        func iso(_ offset: TimeInterval) -> String { Date.now.addingTimeInterval(offset).ISO8601Format() }

        var episodes: [String] = []
        for season in 1...3 {
            let count = season == 3 ? 6 : 4
            for number in 1...count {
                let id = season * 100 + number
                let offset: TimeInterval
                switch season {
                case 3: offset = Double(number - 5) * 7 * day - day   // E05 yesterday, E06 in six days
                default: offset = -Double((4 - season) * 365) * day + Double(number) * 7 * day
                }
                let hasFile = !(season == 3 && number >= 5) && !(season == 2 && number == 3)
                episodes.append(#"{"id":\#(id),"seriesId":1,"seasonNumber":\#(season),"episodeNumber":\#(number),"title":"Episode \#(number)","airDateUtc":"\#(iso(offset))","hasFile":\#(hasFile),"monitored":true}"#)
            }
        }
        let series = #"""
        [{"id":1,"title":"\#(Self.title)","sortTitle":"long runner","status":"continuing","ended":false,
          "overview":"A fixture standing in for a long-running show.","network":"Comedy Net","year":1997,
          "path":"/tv/Long Runner","qualityProfileId":1,"monitored":true,"runtime":22,"genres":["Comedy"],
          "tags":[],"seriesType":"standard","images":[],
          "seasons":[
            {"seasonNumber":1,"monitored":true,"statistics":{"episodeFileCount":4,"episodeCount":4,"totalEpisodeCount":4}},
            {"seasonNumber":2,"monitored":true,"statistics":{"episodeFileCount":3,"episodeCount":4,"totalEpisodeCount":4}},
            {"seasonNumber":3,"monitored":true,"statistics":{"episodeFileCount":4,"episodeCount":5,"totalEpisodeCount":6,"nextAiring":"\#(iso(6 * day))"}}
          ],
          "statistics":{"seasonCount":3,"episodeFileCount":11,"episodeCount":13,"totalEpisodeCount":14,"sizeOnDisk":1000,"percentOfEpisodes":84}}]
        """#
        let server = try await SonarrFixtureServer(
            seriesJSON: series,
            episodesJSON: "[\(episodes.joined(separator: ","))]"
        )
        sonarr = server
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:9"
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.series, in: app))
        return (app, server)
    }

    /// Whether Sonarr was asked to search exactly these episodes.
    private func receivedEpisodeSearch(_ server: SonarrFixtureServer, episodeIDs: [Int]) -> Bool {
        server.requests.contains { request in
            guard request.method == "POST", request.path == "/api/v3/command",
                  let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  json["name"] as? String == "EpisodeSearch" else { return false }
            return (json["episodeIds"] as? [Int]) == episodeIDs
        }
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Swipes the detail up until `element` can be tapped. Checked before each swipe,
    /// so an element already on screen costs nothing.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        for _ in 0..<attempts {
            if element.exists && element.isHittable { return }
            // The window, not `scroller(for:)`: the element sits inside the season
            // strip's horizontal scroll view, which is what that helper picks, and
            // it cannot be swiped up.
            app.swipeUp(velocity: .slow)
        }
    }

    // MARK: - Up Next

    @MainActor
    func testUpNextSearchesTheNewestAiredEpisode() async throws {
        let (app, server) = try await launch()
        let row = app.staticTexts[Self.title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()

        let upNext = app.descendants(matching: .any)["series-up-next"]
        XCTAssertTrue(upNext.waitForExistence(timeout: 20), "Up Next should lead Series detail")
        XCTAssertTrue(upNext.descendants(matching: .any)["episode-state-missing"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'S03E05'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["series-up-next-next"].exists, "Up Next should say when S03E06 airs")

        let search = app.buttons["series-up-next-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable, "Up Next's search should be on the first screen, with no scrolling")
        search.tap()

        XCTAssertTrue(
            waitFor { self.receivedEpisodeSearch(server, episodeIDs: [Self.latestEpisodeID]) },
            "Up Next should search S03E05 and nothing else"
        )
    }

    /// A phone on its side: the tab bar and the Notifications bar take the bottom
    /// third of the screen until the page scrolls. Up Next moves beside the title
    /// there, so its Search button starts above them rather than under them.
    @MainActor
    func testUpNextSearchClearsTheBarsInLandscape() async throws {
        let (app, server) = try await launch()
        let row = app.staticTexts[Self.title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["series-up-next"].waitForExistence(timeout: 20))

        XCUIDevice.shared.orientation = .landscapeLeft
        let search = app.buttons["series-up-next-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let notifications = app.buttons["Notifications"].firstMatch
        XCTAssertTrue(waitFor { notifications.exists && notifications.frame.minY > search.frame.minY })
        XCTAssertLessThan(
            search.frame.maxY, notifications.frame.minY,
            "In landscape Up Next's Search should start above the bottom bars, not under them"
        )
        search.tap()
        XCTAssertTrue(waitFor { self.receivedEpisodeSearch(server, episodeIDs: [Self.latestEpisodeID]) })
    }

    // MARK: - Episodes section

    @MainActor
    func testEpisodesSectionOpensOnTheNewestSeasonAndSwitchesSeasons() async throws {
        let (app, _) = try await launch()
        let row = app.staticTexts[Self.title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()

        let section = app.descendants(matching: .any)["series-episodes"]
        XCTAssertTrue(section.waitForExistence(timeout: 20))

        // Opens on season 3, newest first, with next week's episode marked as such
        // rather than as missing.
        let upcoming = app.descendants(matching: .any)["season-episode-row-S03E06"]
        reveal(upcoming, in: app)
        XCTAssertTrue(upcoming.waitForExistence(timeout: 10))
        XCTAssertTrue(upcoming.descendants(matching: .any)["episode-state-not-aired"].exists)
        let missing = app.descendants(matching: .any)["season-episode-row-S03E05"]
        XCTAssertTrue(missing.descendants(matching: .any)["episode-state-missing"].exists)
        XCTAssertLessThan(upcoming.frame.minY, missing.frame.minY, "The newest episode should be listed first")

        // Season 2 has a gap; switching to it shows its own episodes.
        let chip = app.buttons["series-season-chip-2"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.contains("missing"), "A season with a gap should say so: \(chip.label)")
        chip.tap()
        let gap = app.descendants(matching: .any)["season-episode-row-S02E03"]
        XCTAssertTrue(gap.waitForExistence(timeout: 10))
        XCTAssertTrue(gap.descendants(matching: .any)["episode-state-missing"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["season-episode-row-S03E06"].exists)
    }

    @MainActor
    func testLongPressingAnEpisodeRowSearchesIt() async throws {
        let (app, server) = try await launch()
        let row = app.staticTexts[Self.title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()

        let chip = app.buttons["series-season-chip-2"]
        reveal(chip, in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        chip.tap()
        let gap = app.descendants(matching: .any)["season-episode-row-S02E03"]
        XCTAssertTrue(gap.waitForExistence(timeout: 10))
        gap.press(forDuration: 1.0)

        let search = app.buttons["Search for S02E03"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(waitFor { self.receivedEpisodeSearch(server, episodeIDs: [203]) })
    }

    // MARK: - Series list

    @MainActor
    func testSeriesListLongPressSearchesTheLatestEpisode() async throws {
        let (app, server) = try await launch()
        let row = app.staticTexts[Self.title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Next '")).firstMatch.exists,
            "The row should say when the next episode airs"
        )

        row.press(forDuration: 1.0)
        let action = app.buttons["Search Latest Episode"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()

        XCTAssertTrue(
            waitFor { self.receivedEpisodeSearch(server, episodeIDs: [Self.latestEpisodeID]) },
            "The long-press should search S03E05 without opening the show"
        )
        XCTAssertFalse(app.descendants(matching: .any)["series-up-next"].exists, "It should not have opened the series")
    }

    // MARK: - Search tab

    /// Typing a show's name into Search is the other way people check on it. A
    /// library hit offers the same action as the Series list's long-press.
    @MainActor
    func testSearchTabLongPressSearchesTheLatestEpisode() async throws {
        let (app, server) = try await launch()
        XCTAssertTrue(openDestination(.search, in: app))
        let field = contentSearchField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // Search opens on Discover, the online lookup; owned shows are under Library.
        // The scope bar shows only while the field is focused and still empty.
        // Not the tab bar's own Library tab, which shares the label: the scope
        // control sits up by the field, so take the highest "Library" on screen.
        let libraryButtons = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "Library"))
        XCTAssertTrue(
            waitFor { libraryButtons.allElementsBoundByIndex.contains { !app.tabBars.buttons["Library"].exists || $0.frame.minY < app.tabBars.firstMatch.frame.minY } },
            "Search's Library scope should show while the field is focused."
        )
        let libraryScope = libraryButtons.allElementsBoundByIndex.min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(libraryScope)
        libraryScope?.tap()
        // No Return: that runs the online Sonarr lookup. Library hits list as you type.
        field.typeText("Long Runner")

        let hit = app.staticTexts[Self.title].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 15))
        hit.press(forDuration: 1.0)
        let action = app.buttons["Search Latest Episode"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()

        XCTAssertTrue(
            waitFor { self.receivedEpisodeSearch(server, episodeIDs: [Self.latestEpisodeID]) },
            "Search's long-press should search S03E05"
        )
    }
}
