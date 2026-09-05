//
//  IPadSidebarJourneyUITests.swift
//  TrawlUITests
//
//  Behaviour tests for the iPad chrome, and the counterpart to
//  `IPadSurfaceCaptureUITests` - which photographs these screens and asserts nothing.
//  This suite asserts and takes no photographs.
//
//  What it pins is the part of the iPad work that is invisible until it breaks:
//
//    - the sidebar lists the promoted destinations and does *not* list More
//    - selecting one actually arrives there
//    - a library opens on its first title rather than an empty detail pane
//    - sidebar search reaches a screen that is not itself a sidebar row
//
//  Every one of those is a claim this branch makes and none of them is checked
//  anywhere else. The layout itself - column widths, spacing, where things sit - is
//  deliberately not asserted; that is a judgement call and belongs in the capture
//  suite where a person looks at it.
//
//  The suite skips itself on iPhone rather than failing. The chrome under test does
//  not exist at compact width by design, so a run on a phone destination has nothing
//  to say about it, and a red suite there would be noise rather than signal.

import XCTest

final class IPadSidebarJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?
    private var radarr: RadarrFixtureServer?
    private var sabnzbd: SABnzbdFixtureServer?
    private var qbittorrent: QBittorrentFixtureServer?

    /// The promoted More rows, in sidebar order.
    /// Screens the compact chrome files inside More, each of which is a sidebar row
    /// of its own here.
    ///
    /// These were the seven *hub* names until the sidebar grew sections. A hub is a
    /// screen whose whole job is to list the screens under it, which is what a
    /// sidebar already is - so the hubs became headings and the screens they
    /// introduced became rows. Naming the headings here asserted the arrangement this
    /// replaced, and failed against the one that shipped.
    private static let promotedDestinations = [
        "Missing", "Calendar", "Requests", "Indexers",
        "Download Clients", "Quality Profiles", "Setup Check", "Settings"
    ]

    private static let headlineSeries = "Aurora Reach"
    /// The SABnzbd job `launchOnIPad` seeds, which is the Downloads list's one
    /// openable row.
    private static let headlineDownload = "Sidebar Journey NZB"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The iPad sidebar does not exist at compact width; nothing here applies to a phone."
        )
    }

    override func tearDownWithError() throws {
        sonarr?.stop(); sonarr = nil
        radarr?.stop(); radarr = nil
        sabnzbd?.stop(); sabnzbd = nil
        qbittorrent?.stop(); qbittorrent = nil
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - The sidebar's contents

    /// The central claim of this branch: on iPad, More's rows are destinations of
    /// their own and More itself is gone. Both halves are asserted, because only
    /// checking that the seven appeared would still pass if More were sitting there
    /// alongside them, which is the arrangement this replaced.
    @MainActor
    func testSidebarListsPromotedDestinationsAndDropsMore() async throws {
        let app = try await launchOnIPad()

        for destination in Self.promotedDestinations {
            XCTAssertNotNil(
                sidebarRow(app, destination),
                "The sidebar should offer '\(destination)' directly rather than hiding it inside More."
            )
        }

        XCTAssertNil(
            sidebarRow(app, "More"),
            "More should not be in the iPad sidebar - its rows are the sidebar."
        )
    }

    /// Selecting a promoted destination has to *arrive*, not merely highlight. An
    /// earlier version of this chrome reported taps as successful while the content
    /// column stayed where it was, so the destination's own screen is what is checked.
    @MainActor
    func testSelectingAPromotedDestinationOpensIt() async throws {
        let app = try await launchOnIPad()

        for destination in ["Settings", "Calendar", "Missing"] {
            XCTAssertTrue(
                select(app, destination),
                "Selecting '\(destination)' in the sidebar should open it."
            )
            XCTAssertTrue(
                app.showsScreen(named: destination),
                "'\(destination)' should render its own screen in the content column."
            )
        }
    }

    // MARK: - Libraries open on something

    /// The reason the libraries became selection-driven at all. A three-column layout
    /// that opens on "Select a series" spends half the display saying nothing, so the
    /// first title is selected on arrival - and that is only possible because the
    /// list drives a selection rather than a `NavigationLink`.
    @MainActor
    func testSeriesOpensOnItsFirstTitle() async throws {
        let app = try await launchOnIPad()

        XCTAssertTrue(select(app, "Series"), "The sidebar should offer Series.")

        // The detail column, not the row: the row's title is in the list either way.
        // A navigation bar carrying the series' name means it is what the detail
        // column is actually showing.
        XCTAssertTrue(
            app.navigationBars[Self.headlineSeries].waitForExistence(timeout: 20),
            "Series should open with its first title already in the detail column, not an empty pane."
        )
        XCTAssertFalse(
            app.staticTexts["Select a series"].exists,
            "The placeholder should not be showing once a title has been auto-selected."
        )
    }

    /// A detail column shows the destination you are on, and nothing else.
    ///
    /// The Downloads rows used to be `NavigationLink(destination:)`, and a
    /// destination link in a split view's *content* column presents into the *detail*
    /// column - a presentation that outlives the sidebar selection that made it. So
    /// opening a download and then selecting Series left the download's detail
    /// sitting on top of the Series column: two destinations on screen at once, one
    /// of them the one you just left.
    ///
    /// The fix is the pattern the libraries already use - the list drives the column
    /// through a selection and the detail is that column's *root* - and this is what
    /// says so. Asserted in both directions: the download has to open in the first
    /// place, or the second half would pass against a column that never worked.
    @MainActor
    func testOpeningADownloadDoesNotLeaveItInTheDetailColumnOfTheNextDestination() async throws {
        let app = try await launchOnIPad()

        XCTAssertTrue(select(app, "Downloads"), "The sidebar should offer Downloads.")

        let jobRow = app.cells
            .containing(NSPredicate(format: "label CONTAINS[c] %@", Self.headlineDownload))
            .firstMatch
        XCTAssertTrue(
            jobRow.waitForExistence(in: app, timeout: 20),
            "The seeded SABnzbd job should reach the Downloads list."
        )
        jobRow.tap()

        let downloadDetail = app.navigationBars[Self.headlineDownload]
        XCTAssertTrue(
            downloadDetail.waitForExistence(timeout: 15),
            "Selecting a download should open it in the detail column beside the list."
        )

        XCTAssertTrue(select(app, "Series"), "The sidebar should offer Series.")

        XCTAssertTrue(
            app.navigationBars[Self.headlineSeries].waitForExistence(timeout: 20),
            "Series should arrive in the detail column."
        )
        XCTAssertFalse(
            downloadDetail.exists,
            "The download's detail should not still be on screen after moving to Series - a push into the detail column outlives the destination that made it, which is why the list drives the column by selection instead."
        )
    }

    /// A live Arr queue row is a shortcut to the Downloads tab on iPad, because
    /// that tab and its detail column remain visible in the sidebar chrome. The
    /// earlier link pushed the torrent over the movie detail itself, trapping the
    /// user in a stack that hid the queue it was meant to reveal.
    @MainActor
    func testMovieDetailCurrentDownloadSelectsItInTheDownloadsTab() async throws {
        let torrent = try await QBittorrentFixtureServer(
            torrentName: "Detail Card Handoff Torrent"
        )
        qbittorrent = torrent
        let queueJSON = #"""
        {"page":1,"pageSize":20,"totalRecords":1,"records":[
          {"id":801,"title":"Detail Card Handoff Torrent","status":"downloading",
           "trackedDownloadState":"downloading","downloadId":"\#(torrent.hash)",
           "protocol":"torrent","downloadClient":"qBittorrent","movieId":\#(RadarrFixtureServer.movieId),
           "size":2147483648,"sizeleft":1234567890,"timeleft":"00:07:00"}
        ]}
        """#
        let movieServer = try await RadarrFixtureServer(queueResponseJSON: queueJSON)
        radarr = movieServer

        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = movieServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_QBITTORRENT_BASE_URL"] = torrent.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(select(app, "Movies"), "The sidebar should offer Movies.")
        XCTAssertTrue(
            openLibraryItem(titled: RadarrFixtureServer.movieTitle, in: app, timeout: 20),
            "The fixture movie should open its real detail screen. Requests: \(movieServer.requests)"
        )
        XCTAssertTrue(app.navigationBars[RadarrFixtureServer.movieTitle].waitForExistence(timeout: 15))

        let currentDownload = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Current Download"))
            .firstMatch
        XCTAssertTrue(
            currentDownload.waitForExistence(timeout: 20),
            "A downloading Arr queue row must stay visible on the movie detail card. Requests: \(movieServer.requests)"
        )
        XCTAssertTrue(tapWhenPossible(currentDownload, timeout: 10))

        XCTAssertTrue(
            app.navigationBars[torrent.name].waitForExistence(timeout: 20),
            "Tapping Current Download from movie detail should select it in Downloads' detail column."
        )
        XCTAssertFalse(
            app.navigationBars[RadarrFixtureServer.movieTitle].exists,
            "The movie detail must not remain stacked over the Downloads tab after selecting its download."
        )
    }

    // MARK: - Sidebar search

    /// The sidebar's field is the only search on iPad - More, which used to own one,
    /// is not in this chrome. So it has to reach screens that are *not* sidebar rows,
    /// which is exactly what a filter over the eleven destination names could not do.
    ///
    /// Quality Profiles is the case that matters: it lives two levels down under
    /// Library Management and appears nowhere in the sidebar.
    @MainActor
    func testSidebarSearchReachesAScreenThatIsNotASidebarRow() async throws {
        let app = try await launchOnIPad()

        // `.searchable(placement: .sidebar)` does not always surface as a
        // `searchField`; depending on the chrome it comes through as a plain text
        // field carrying the prompt as its placeholder. Both are accepted rather than
        // assuming which one this build produces.
        let field = sidebarSearchField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The sidebar should offer a search field.")
        field.tap()
        field.typeText("quality")

        let result = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Quality Profiles"))
            .firstMatch
        XCTAssertTrue(
            result.waitForExistence(timeout: 10),
            "Searching the sidebar should find Quality Profiles, which is not a sidebar row."
        )
        result.tap()

        XCTAssertTrue(
            app.showsScreen(named: "Quality Profiles", timeout: 15),
            "Choosing a search result should open that screen."
        )
        XCTAssertNotNil(
            sidebarRow(app, "Quality Profiles"),
            "The result should leave its own sidebar row on screen, so there is a way back."
        )
    }

    // MARK: - Helpers

    /// Finds the sidebar's search field, revealing it first if it is scrolled away.
    ///
    /// `.searchable` inside a `List` sits *above* the first row, so it starts off
    /// screen and has to be pulled into view - it is not missing, it is just not
    /// where a naive query looks. It also does not reliably surface as a
    /// `searchField`; depending on the chrome it arrives as a plain text field
    /// carrying the prompt as its placeholder, so both are accepted.
    @MainActor
    private func sidebarSearchField(_ app: XCUIApplication) -> XCUIElement {
        func candidate() -> XCUIElement {
            let search = app.searchFields.firstMatch
            if search.exists { return search }
            return app.textFields
                .matching(NSPredicate(format: "placeholderValue CONTAINS[c] %@", "Search Trawl"))
                .firstMatch
        }

        if candidate().waitForExistence(timeout: 3) { return candidate() }

        // Pull the sidebar down to bring it in.
        if let downloads = sidebarRow(app, "Downloads") {
            for _ in 0..<3 {
                downloads.swipeDown()
                if candidate().waitForExistence(timeout: 2) { return candidate() }
            }
        }
        return candidate()
    }

    /// Sidebar rows are matched by the `nav.<case>` identifier their `Label` carries,
    /// never by label text. "Downloads" also prefixes the Downloads screen's own
    /// "Downloads, change view" title menu, and matching by text tapped that instead -
    /// opening a popover that swallowed every later tap in the run.
    @MainActor
    /// Finds a sidebar row, scrolling the sidebar to reach it.
    ///
    /// The sidebar lists every destination in the app and only a dozen fit at once,
    /// and a `List` does not put off-screen rows in the accessibility tree at all -
    /// so a plain wait reports Settings, Quality Profiles and everything else below
    /// the fold as missing, against a sidebar that has them. Both directions, because
    /// a caller asking for Missing after Settings is asking to go back up.
    private func sidebarRow(_ app: XCUIApplication, _ displayName: String) -> XCUIElement? {
        guard let suffix = Self.identifierSuffix(for: displayName) else { return nil }
        let match = app.cells
            .containing(NSPredicate(format: "identifier == %@", "nav.\(suffix)"))
            .firstMatch
        if match.waitForExistence(timeout: 5) { return match }

        let sidebar = app.collectionViews["Sidebar"]
        guard sidebar.exists else { return nil }
        for _ in 0..<8 {
            sidebar.swipeUp()
            if match.waitForExistence(timeout: 1) { return match }
        }
        for _ in 0..<10 {
            sidebar.swipeDown()
            if match.waitForExistence(timeout: 1) { return match }
        }
        return nil
    }

    @MainActor
    @discardableResult
    private func select(_ app: XCUIApplication, _ displayName: String) -> Bool {
        guard let row = sidebarRow(app, displayName) else { return false }
        if row.isHittable {
            row.tap()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    private static func identifierSuffix(for displayName: String) -> String? {
        switch displayName {
        case "Downloads": "downloads"
        case "Series": "series"
        case "Movies": "movies"
        case "Search": "search"
        case "More": "more"
        case "Missing": "missing"
        case "Calendar": "calendar"
        case "Requests": "requests"
        case "Indexers": "indexers"
        case "Download Clients": "downloadClients"
        case "Quality Profiles": "qualityProfiles"
        case "Setup Check": "setupCheck"
        case "Settings": "settings"
        default: nil
        }
    }

    /// Launches landscape, where the sidebar is on screen without a toggle.
    ///
    /// Orientation is set *before* launch. Rotating a running app wedged the chrome
    /// badly enough that no destination resolved at all, which is worth not
    /// rediscovering.
    @MainActor
    private func launchOnIPad() async throws -> XCUIApplication {
        let sonarrServer = try await SonarrFixtureServer(
            seriesJSON: Self.seriesJSON,
            statusJSON: #"{"instanceName":"Fixture Sonarr"}"#
        )
        sonarr = sonarrServer
        let radarrServer = try await RadarrFixtureServer()
        radarr = radarrServer
        let sabnzbdServer = try await SABnzbdFixtureServer(queueJobName: "Sidebar Journey NZB")
        sabnzbd = sabnzbdServer

        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarrServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = radarrServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = sabnzbdServer.baseURL
        // Without this, detail screens fire a real TMDb lookup that reaches the public
        // internet and sits out a 15s timeout.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertNotNil(
            sidebarRow(app, "Downloads"),
            "A launch with configured services should reach the sidebar."
        )
        return app
    }

    /// Two titles is enough for every assertion here, and keeps the launch quick.
    /// `Aurora Reach` sorts first, which is what makes it the auto-selected one.
    private static let seriesJSON = #"""
    [
      {
        "id": 1,
        "title": "Aurora Reach",
        "sortTitle": "aurora reach",
        "status": "continuing",
        "year": 2023,
        "network": "Meridian+",
        "monitored": true,
        "images": [],
        "statistics": {"seasonCount": 3, "episodeFileCount": 28, "episodeCount": 28,
                       "totalEpisodeCount": 28, "sizeOnDisk": 412000000000, "percentOfEpisodes": 100}
      },
      {
        "id": 2,
        "title": "Cold Open",
        "sortTitle": "cold open",
        "status": "continuing",
        "year": 2024,
        "network": "Kestrel TV",
        "monitored": true,
        "images": [],
        "statistics": {"seasonCount": 2, "episodeFileCount": 18, "episodeCount": 18,
                       "totalEpisodeCount": 18, "sizeOnDisk": 210000000000, "percentOfEpisodes": 100}
      }
    ]
    """#
}
