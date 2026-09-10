//
//  SplitViewDetailRouteUITests.swift
//  TrawlUITests
//
//  The administration screens converted to `TrawlListDetailPanes` now have two
//  shapes, and the second one is a different branch of code rather than a different
//  layout of the same one. Beside a detail pane a row is a *selection*; with no pane
//  it pushes, expands inline, or renders a compact screen of its own - which shape
//  depends on the screen. `hasDetailPane` / `showsDetailPane` decides, and nothing
//  before this suite asked what happened after a row was chosen.
//
//  What already existed stops short of that. `NavigationSmokeWalkUITests` proves each
//  of these destinations *opens*, which a screen whose rows have gone inert still
//  does. `IPadSurfaceCaptureUITests` photographs them and asserts nothing by design.
//  So a conversion that reached the detail on iPad and quietly stopped reaching it on
//  iPhone - the failure mode a `List(selection:)` sitting over `NavigationLink` rows
//  produces - would have left every suite in this target green.
//
//  Each test therefore asks both chromes the same question: after choosing a row, is
//  content that belongs *only* to the detail on screen? That question has one answer
//  on an iPhone push and on an iPad pane, so these are not compact-only tests; where
//  the two chromes genuinely differ in what a user must do first, the test says so
//  and does the extra step rather than asserting something weaker.
//
//  Seeding is the established pattern: real loopback fixture servers handed to the
//  app through TrawlApp's DEBUG hooks, so the app's own startup, connect, request and
//  navigation code runs unmodified.

import XCTest

final class SplitViewDetailRouteUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?
    private var jellyfin: JellyfinUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarr?.stop()
        sonarr = nil
        jellyfin?.stop()
        jellyfin = nil
    }

    // MARK: - Disk Space

    /// Disk Space renders a dedicated compact screen rather than the list column, so
    /// its iPhone rows are `NavigationLink`s that exist nowhere else in the file. The
    /// inspector is the only thing that names the mount path as a field, which is what
    /// separates "the drive's own screen" from the row that merely repeats its label.
    @MainActor
    func testDiskSpaceRowReachesTheDriveInspector() async throws {
        let app = try await launchWithSonarr()

        XCTAssertTrue(openDestination(.diskSpace, in: app), "Disk Space should open.")
        XCTAssertTrue(
            app.staticTexts["Media NVMe"].waitForExistence(in: app, timeout: 15),
            "Disk Space should list the drive label Sonarr reports, not an empty state."
        )
        XCTAssertTrue(
            chooseRow(labelContaining: "Media NVMe", in: app),
            "Choosing a drive should be possible on whichever chrome is running."
        )

        XCTAssertTrue(
            app.staticTexts["Storage Capacity"].waitForExistence(in: app, timeout: 10),
            "Choosing a drive should reach ArrDiskDetailView, which is the only place the capacity breakdown is rendered."
        )
        XCTAssertTrue(
            app.staticTexts["Mount Path"].waitForExistence(in: app, timeout: 5),
            "The drive inspector should name the volume's mount path as a field of its own."
        )
    }

    // MARK: - Root Folders

    /// Root Folders renders a compact screen of its own rather than the list column,
    /// and the two shapes disagree about what a row *is*: beside a detail pane the
    /// rows are servers and the folders live in the pane; without one the folders are
    /// the rows, grouped under a section per server. Asking for the folder paths
    /// answers the same question on both, and it is the folders - not the server
    /// names - that came from `GET /rootfolder`.
    @MainActor
    func testRootFoldersRendersEveryFolderTheServerReports() async throws {
        let app = try await launchWithSonarr()

        XCTAssertTrue(openDestination(.rootFolders, in: app), "Root Folders should open.")

        XCTAssertTrue(
            app.staticTexts["/media/tv"].waitForExistence(in: app, timeout: 15),
            "Root Folders should render the first path Sonarr returned from /api/v3/rootfolder."
        )
        XCTAssertTrue(
            app.staticTexts["/media/anime"].waitForExistence(in: app, timeout: 10),
            "A server's second root folder must render too - a screen that shows only the first looks correct on a one-folder setup."
        )
    }

    // MARK: - Updates

    /// Updates has no compact screen of its own: the same list column renders release
    /// notes inline when there is no pane beside it, and a selectable version list
    /// when there is. Losing the inline branch would leave an iPhone reader with a
    /// list of version numbers and no way to read what changed in any of them.
    @MainActor
    func testUpdatesKeepsTheChangelogReachableOnBothChromes() async throws {
        let app = try await launchWithSonarr()

        XCTAssertTrue(openDestination(.updates, in: app), "Updates should open.")
        // Matched loosely: the version is a section header on iPhone and a row on
        // iPad, and a list style is free to case it however it likes.
        let version = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "4.0.12.2823"))
            .firstMatch
        XCTAssertTrue(
            version.waitForExistence(in: app, timeout: 20),
            "Updates should render the version Sonarr reports from /api/v3/update."
        )

        // The genuine difference between the chromes: with a pane beside it the list
        // is version numbers only, and the notes live in the detail column. Without
        // one they are already on screen, and a tap would be a tap on nothing.
        if TrawlChrome.current == .sidebar {
            XCTAssertTrue(
                chooseRow(labelContaining: "4.0.12.2823", in: app),
                "A release should be selectable in the content column."
            )
        }

        XCTAssertTrue(
            app.staticTexts["Support for modern split views"].waitForExistence(in: app, timeout: 10),
            "The release notes Sonarr returned should be readable, inline on iPhone and in the detail pane on iPad."
        )
    }

    // MARK: - Jellyfin plugins

    /// Plugins is the shape most at risk: one `List(selection:)` serves both chromes,
    /// and its rows swap between a tagged row and a `NavigationLink` on
    /// `showsDetailPane`. If the selection binding ever swallows the compact tap, the
    /// row stays put and nothing else in the target notices.
    @MainActor
    func testJellyfinPluginRowReachesThePluginDetail() async throws {
        let app = try await launchWithJellyfin()

        XCTAssertTrue(openDestination(.jellyfinPlugins, in: app), "Plugins should open.")
        XCTAssertTrue(
            app.staticTexts["TMDb Box Sets"].waitForExistence(in: app, timeout: 15),
            "Plugins should render the plugin the fixture server returns from GET /Plugins."
        )
        XCTAssertTrue(
            chooseRow(labelContaining: "TMDb Box Sets", in: app),
            "Choosing a plugin should be possible on whichever chrome is running."
        )

        XCTAssertTrue(
            app.staticTexts["Configuration"].waitForExistence(in: app, timeout: 10),
            "Choosing a plugin should reach JellyfinPluginDetailView, whose Configuration section the row does not carry."
        )
        // `LabeledContent` publishes its field name as the element's label and the
        // value beside it as the element's *value*, so a query for the file name as
        // a label finds nothing while it is plainly on screen.
        let configFile = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "tmdbboxsets.xml", "tmdbboxsets.xml"))
            .firstMatch
        XCTAssertTrue(
            configFile.waitForExistence(in: app, timeout: 5),
            "The plugin detail should render the decoded configuration file name."
        )
    }

    // MARK: - Jellyfin sessions

    /// Sessions shares the plugins shape, and adds hoisted polling: the list and the
    /// detail read one `JellyfinSessionBrowserState` rather than fetching separately.
    /// Reaching the diagnostics proves the chosen session arrived with the playback
    /// detail attached, not just its row label.
    @MainActor
    func testJellyfinSessionRowReachesTheSessionDetail() async throws {
        let app = try await launchWithJellyfin()

        XCTAssertTrue(openDestination(.jellyfinSessions, in: app), "Sessions should open.")
        XCTAssertTrue(
            app.staticTexts[JellyfinUIFixtureServer.episodeName].waitForExistence(in: app, timeout: 15),
            "Sessions should render the active playback the fixture server reports."
        )
        XCTAssertTrue(
            chooseRow(labelContaining: JellyfinUIFixtureServer.episodeName, in: app),
            "Choosing a session should be possible on whichever chrome is running."
        )

        XCTAssertTrue(
            app.staticTexts["Client & Device"].waitForExistence(in: app, timeout: 10),
            "Choosing a session should reach JellyfinSessionDetailView and its client section."
        )
        XCTAssertTrue(
            app.staticTexts["Stream Diagnostics"].waitForExistence(in: app, timeout: 5),
            "The session detail should render the stream diagnostics that only the detail carries."
        )
    }

    // MARK: - Helpers

    @MainActor
    private func launchWithSonarr() async throws -> XCUIApplication {
        let server = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Split View Series"}]"#)
        sonarr = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        // Without this, detail screens fire a real TMDb lookup and sit out its timeout.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A seeded Sonarr profile should reach the real app chrome rather than the welcome flow."
        )
        return app
    }

    @MainActor
    private func launchWithJellyfin() async throws -> XCUIApplication {
        let server = try await JellyfinUIFixtureServer()
        jellyfin = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A seeded Jellyfin profile should reach the real app chrome rather than the welcome flow."
        )
        return app
    }

    /// Taps the row carrying `text`, whatever element the running chrome made of it.
    ///
    /// The same row is a `Button` where it pushes and a selectable cell where a pane
    /// is beside it, and only one of those queries finds it in either case - so both
    /// are tried before the row is reported unreachable. The row is also allowed to be
    /// below the fold: `waitForExistence(in:)` scrolls the screen's own list rather
    /// than the sidebar next to it.
    @MainActor
    private func chooseRow(labelContaining text: String, in app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        for query in [app.buttons, app.cells] {
            let row = query.matching(predicate).firstMatch
            guard row.waitForExistence(in: app, timeout: 5) else { continue }
            if tapWhenHittable(row) { return true }
        }
        // Last resort: the label itself. A `Button`'s text is inside its own element,
        // and a tap on it lands on the button.
        let label = app.staticTexts.matching(predicate).firstMatch
        guard label.waitForExistence(in: app, timeout: 5) else { return false }
        return tapWhenHittable(label)
    }

    /// SwiftUI rows exist in the tree before they can receive a tap, and a tap
    /// synthesized too early is dropped silently - the failure then lands on the
    /// detail that never appeared rather than on the tap that never took.
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            _ = element.waitForExistence(timeout: 0.5)
        }
        return false
    }
}
