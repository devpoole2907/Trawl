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

    /// The promoted More rows, in sidebar order.
    private static let promotedDestinations = [
        "Missing", "Library Management", "Requests & Access",
        "Media Server", "Integrations & Automation", "System", "Settings"
    ]

    private static let headlineSeries = "Aurora Reach"

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

        for destination in ["Settings", "System", "Missing"] {
            XCTAssertTrue(
                select(app, destination),
                "Selecting '\(destination)' in the sidebar should open it."
            )
            XCTAssertTrue(
                app.navigationBars[destination].waitForExistence(timeout: 10),
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
            app.navigationBars["Quality Profiles"].waitForExistence(timeout: 15),
            "Choosing a search result should open that screen."
        )
        XCTAssertNotNil(
            sidebarRow(app, "Library Management"),
            "The result should land on the hub that owns it, so there is a way back."
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
    private func sidebarRow(_ app: XCUIApplication, _ displayName: String) -> XCUIElement? {
        guard let suffix = Self.identifierSuffix(for: displayName) else { return nil }
        let match = app.cells
            .containing(NSPredicate(format: "identifier == %@", "nav.\(suffix)"))
            .firstMatch
        return match.waitForExistence(timeout: 5) ? match : nil
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
        case "Library Management": "libraryManagement"
        case "Requests & Access": "requestsAndAccess"
        case "Media Server": "mediaServer"
        case "Integrations & Automation": "automation"
        case "System": "system"
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
