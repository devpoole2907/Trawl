//
//  LibraryTabJourneyUITests.swift
//  TrawlUITests
//
//  The iPhone tab bar after Series and Movies merged into Library: the scope menu
//  and the tip that points at it, Calendar as a tab, Downloads in the bar above the
//  tabs and the notification sheet's own tab bar, More's flat sections, and "Open …"
//  on a download row. Phone only - the sidebar keeps a row for each.
//

import XCTest

final class LibraryTabJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?
    private var radarr: RadarrFixtureServer?
    private var qbittorrent: QBittorrentFixtureServer?

    private static let seriesTitle = "Library Fixture Show"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(TrawlChrome.isSidebar, "The Library tab is the phone's tab bar; the sidebar keeps Series and Movies rows.")
    }

    override func tearDown() {
        sonarr?.stop(); sonarr = nil
        radarr?.stop(); radarr = nil
        qbittorrent?.stop(); qbittorrent = nil
        super.tearDown()
    }

    @MainActor
    private func launch(
        showingTip tipID: String? = nil,
        withDownloads: Bool = false,
        radarrQueueJSON: String? = nil
    ) async throws -> XCUIApplication {
        let series = #"""
        [{"id":1,"title":"\#(Self.seriesTitle)","sortTitle":"library fixture show","status":"continuing","ended":false,
          "network":"Fixture Net","year":2020,"path":"/tv/Library Fixture Show","qualityProfileId":1,"monitored":true,
          "tags":[],"seriesType":"standard","images":[],
          "seasons":[{"seasonNumber":1,"monitored":true,"statistics":{"episodeFileCount":1,"episodeCount":1,"totalEpisodeCount":1}}],
          "statistics":{"seasonCount":1,"episodeFileCount":1,"episodeCount":1,"totalEpisodeCount":1,"sizeOnDisk":1000,"percentOfEpisodes":100}}]
        """#
        let sonarrServer = try await SonarrFixtureServer(seriesJSON: series, episodesJSON: "[]")
        sonarr = sonarrServer

        var torrent: QBittorrentFixtureServer?
        if withDownloads {
            torrent = try await QBittorrentFixtureServer(torrentName: "Library Fixture Download")
            qbittorrent = torrent
        }
        let queueJSON = radarrQueueJSON.map { json in
            json.replacingOccurrences(of: "{{HASH}}", with: torrent?.hash ?? "")
        } ?? "{}"
        let radarrServer = try await RadarrFixtureServer(queueResponseJSON: queueJSON)
        radarr = radarrServer

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarrServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = radarrServer.baseURL
        if let torrent {
            app.launchEnvironment["TRAWL_UITEST_QBITTORRENT_BASE_URL"] = torrent.baseURL
        }
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:9"
        if let tipID {
            app.launchEnvironment["TRAWL_UITEST_SHOW_TIP"] = tipID
        }
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        return app
    }

    private var titleMenuPredicate: NSPredicate {
        NSPredicate(format: "label ENDSWITH[c] %@", ", change view")
    }

    // MARK: - The tip

    /// The Library tip is a popover whose arrow sits on the title menu.
    ///
    /// Checked by geometry, because "the tip appeared" is not what was asked for:
    /// the bubble has to point at the control it explains. The popover must start
    /// just under the menu, and the menu's centre must fall within the popover's
    /// width - which is where the arrow is drawn - not off to one side of it.
    @MainActor
    func testScopeTipPointsAtTheLibraryTitleMenu() async throws {
        let app = try await launch(showingTip: "trawl.library.scope.v1")

        let menu = app.buttons.matching(titleMenuPredicate).firstMatch
        XCTAssertTrue(menu.waitForExistence(in: app, timeout: 20), "The Library tab should open with its title menu.")
        XCTAssertTrue(menu.label.hasPrefix("Library,"), "Library should open on the whole library. Got \(menu.label).")

        let tipTitle = app.staticTexts["Series and movies live here"]
        XCTAssertTrue(tipTitle.waitForExistence(in: app, timeout: 20), "The scope tip should present on the Library tab.")

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "library-scope-tip"
        attachment.lifetime = .keepAlways
        add(attachment)

        let popover = app.popovers.firstMatch
        let bubble = popover.exists ? popover.frame : tipTitle.frame
        let anchor = menu.frame
        XCTAssertGreaterThanOrEqual(
            bubble.minY, anchor.maxY - 4,
            "The bubble should sit below the title it points at. Bubble \(bubble), title \(anchor)."
        )
        XCTAssertLessThan(
            bubble.minY - anchor.maxY, 48,
            "The bubble should start right under the title, where its arrow meets it. Bubble \(bubble), title \(anchor)."
        )
        XCTAssertTrue(
            bubble.minX <= anchor.midX && anchor.midX <= bubble.maxX,
            "The title's centre should fall within the bubble's width, where the arrow is. Bubble \(bubble), title \(anchor)."
        )
    }

    // MARK: - Scope

    @MainActor
    func testLibraryListsSeriesAndMoviesTogetherAndTheMenuNarrowsIt() async throws {
        let app = try await launch()

        XCTAssertTrue(
            app.staticTexts[Self.seriesTitle].waitForExistence(in: app, timeout: 25),
            "The whole library should list the series."
        )
        XCTAssertTrue(
            app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(in: app, timeout: 25),
            "The whole library should list the movie beside it."
        )
        XCTAssertTrue(
            app.staticTexts["1 movie, 1 series"].waitForExistence(in: app, timeout: 10)
                || app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "1 movie, 1 series")).firstMatch.exists,
            "The title's subtitle should count both kinds."
        )

        XCTAssertTrue(openLibraryScope("Movies", in: app), "The title menu should offer Movies.")
        XCTAssertTrue(app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(in: app, timeout: 20))
        XCTAssertFalse(app.staticTexts[Self.seriesTitle].exists, "Movies should not list the series.")

        XCTAssertTrue(openLibraryScope("Series", in: app), "The title menu should offer Series.")
        XCTAssertTrue(app.staticTexts[Self.seriesTitle].waitForExistence(in: app, timeout: 20))
        XCTAssertFalse(app.staticTexts[RadarrFixtureServer.movieTitle].exists, "Series should not list the movie.")

        XCTAssertTrue(openLibraryScope("Library", in: app), "The title menu should return to the whole library.")
        XCTAssertTrue(app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(in: app, timeout: 20))
    }

    @MainActor
    func testARowInTheWholeLibraryOpensItsDetail() async throws {
        let app = try await launch()
        XCTAssertTrue(
            openLibraryItem(titled: RadarrFixtureServer.movieTitle, in: app, timeout: 25),
            "A movie row in the whole library should open."
        )
        XCTAssertTrue(app.navigationBars[RadarrFixtureServer.movieTitle].waitForExistence(timeout: 20))
    }

    // MARK: - The other tabs

    @MainActor
    func testTheTabBarIsLibraryCalendarMoreAndSearch() async throws {
        let app = try await launch()
        for title in ["Library", "Calendar", "More"] {
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 10), "\(title) should be a tab.")
        }
        for title in ["Downloads", "Series", "Movies"] {
            XCTAssertFalse(app.tabBars.buttons[title].exists, "\(title) should no longer be a tab on the phone.")
        }

        XCTAssertTrue(openDestination(.calendar, in: app))
        XCTAssertTrue(app.showsScreen(named: "Calendar", timeout: 15), "The Calendar tab should open Calendar.")
    }

    @MainActor
    func testMoreListsSectionsInsteadOfHubs() async throws {
        let app = try await launch()
        XCTAssertTrue(openDestination(.system, in: app), "More should open.")
        XCTAssertTrue(app.buttons["more-setup-check"].waitForExistence(in: app, timeout: 10), "Setup Check should be a row of More itself.")
        XCTAssertFalse(app.buttons["Requests & Access, Seerr requests, issues, and users"].exists, "Requests & Access should not be a hub row.")

        XCTAssertTrue(openDestination(.health, in: app), "Health should be one tap into More.")
        XCTAssertTrue(openDestination(.indexers, in: app), "A row in a folded section should still be reachable.")
    }

    // MARK: - Downloads

    @MainActor
    func testTheBarShowsTheDownloadAndOpensDownloads() async throws {
        let app = try await launch(withDownloads: true)

        let bar = app.buttons["notification-accessory"]
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        let showsDownload = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] %@", "Library Fixture Download"),
            object: bar
        )
        await fulfillment(of: [showsDownload], timeout: 25)
        XCTAssertTrue(
            (bar.value as? String)?.contains("Library Fixture Download") == true,
            "The bar should name the download in progress. Value: \(String(describing: bar.value))"
        )

        XCTAssertTrue(tapWhenPossible(bar))
        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10), "The sheet should have a Downloads tab.")
        XCTAssertTrue(downloadsTab.isSelected, "A tap while downloading should open the sheet on Downloads.")
        XCTAssertTrue(
            app.staticTexts["Library Fixture Download"].waitForExistence(in: app, timeout: 20),
            "Downloads in the sheet should list the torrent."
        )
        XCTAssertTrue(app.tabBars.buttons["Alerts"].exists)
        XCTAssertTrue(app.tabBars.buttons["Actions"].exists)
    }

    @MainActor
    func testADownloadRowOpensItsMovieFromTheLongPressMenu() async throws {
        let queue = #"""
        {"page":1,"pageSize":20,"totalRecords":1,"records":[
          {"id":801,"title":"Library Fixture Download","status":"downloading",
           "trackedDownloadState":"downloading","downloadId":"{{HASH}}",
           "protocol":"torrent","downloadClient":"qBittorrent","movieId":\#(RadarrFixtureServer.movieId),
           "size":2147483648,"sizeleft":1234567890,"timeleft":"00:07:00"}
        ]}
        """#
        let app = try await launch(withDownloads: true, radarrQueueJSON: queue)
        // The library has to have loaded for the menu to name the film.
        XCTAssertTrue(app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(in: app, timeout: 25))

        XCTAssertTrue(openDestination(.downloads, in: app), "Downloads should open in the sheet.")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Library Fixture Download")).firstMatch
        XCTAssertTrue(row.waitForExistence(in: app, timeout: 20), "The queue row should be listed.")
        row.press(forDuration: 1.2)

        let open = app.buttons["Open \(RadarrFixtureServer.movieTitle)"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "The row's long-press menu should offer to open the film.")
        open.tap()
        XCTAssertTrue(
            app.navigationBars[RadarrFixtureServer.movieTitle].waitForExistence(timeout: 20),
            "Open should push the film's detail."
        )
    }

    // MARK: - Deep links

    /// Every `trawl://` link the widgets and the push worker send, opened for real.
    ///
    /// The phone lost its Downloads, Series and Movies tabs, so each of these had a
    /// route that could have quietly started landing nowhere.
    @MainActor
    func testDeepLinksLandOnTheirScreens() async throws {
        let app = try await launch(withDownloads: true)

        app.open(URL(string: "trawl://calendar")!)
        XCTAssertTrue(app.tabBars.buttons["Calendar"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Calendar"].isSelected, "trawl://calendar should select the Calendar tab.")

        app.open(URL(string: "trawl://downloads")!)
        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10), "trawl://downloads should open the sheet.")
        XCTAssertTrue(downloadsTab.isSelected, "trawl://downloads should open the sheet on Downloads.")

        app.open(URL(string: "trawl://downloads?section=issues")!)
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10))
        XCTAssertTrue(downloadsTab.isSelected, "An Issues link should land on Downloads too.")
        dismissNotificationsSheetIfPresent(in: app)

        app.open(URL(string: "trawl://health")!)
        XCTAssertTrue(app.showsScreen(named: "Health", timeout: 15), "trawl://health should open Health.")

        app.open(URL(string: "trawl://seerr-issue")!)
        XCTAssertTrue(app.showsScreen(named: "Issues", timeout: 15), "trawl://seerr-issue should open Issues.")

        app.open(URL(string: "trawl://seerr-requests")!)
        XCTAssertTrue(
            app.tabBars.buttons["Alerts"].waitForExistence(timeout: 10),
            "trawl://seerr-requests should open the notification sheet, where approvals are."
        )
        XCTAssertTrue(app.tabBars.buttons["Alerts"].isSelected)
    }
}
