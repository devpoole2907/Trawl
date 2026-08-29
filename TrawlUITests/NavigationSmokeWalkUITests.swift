//
//  NavigationSmokeWalkUITests.swift
//  TrawlUITests
//
//  The systemic risk behind N-02: a view reading a non-optional
//  `@Environment(SomeType.self)` traps at runtime the moment SwiftUI can't resolve it,
//  and nothing catches that until a real navigation reaches the screen. N-02 crashed
//  the app outright opening the SABnzbd queue screen - four navigations deep, and no
//  test had ever gone there. Every other journey suite in this target asserts business
//  behavior on a handful of screens; this suite is deliberately different: it is a
//  breadth-first walk that visits as much of the real navigation surface as it can
//  reach with the fixtures available, and proves each screen renders real content and
//  can be navigated away from and back to. It does not assert business behavior.
//
//  Seeding follows the established pattern from `SonarrConnectedJourneyUITests` and
//  `SABnzbdUnauthorizedJourneyUITests`: one real `SonarrFixtureServer` and one real
//  `SABnzbdFixtureServer`, seeded through `TrawlApp`'s DEBUG hooks
//  (`TRAWL_UITEST_SONARR_BASE_URL`, `TRAWL_UITEST_SABNZBD_BASE_URL`), so the app's own
//  startup, connect, and navigation code runs unmodified. `TRAWL_UITEST_TMDB_BASE_URL`
//  is always pointed at an unreachable loopback address (`http://127.0.0.1:1/tmdb`) -
//  without it, detail screens fire a real TMDb lookup that reaches the public internet
//  and sits out a 15s timeout.
//
//  Radarr, Prowlarr, Bazarr, Seerr, Jellyfin, and Cleanuparr are deliberately left
//  unconfigured. Visiting their screens anyway is still valuable: every one of them is
//  written to render a real "not set up" / "no services configured" empty state rather
//  than crash or render blank, and that is exactly the kind of screen N-02 proves can't
//  be taken on faith. Where a screen genuinely cannot be reached without live service
//  data the fixtures can't provide (a real qBittorrent WebUI handshake, in particular -
//  no loopback fixture for that protocol exists anywhere in this test target), it is
//  skipped, and that is called out in this suite's own report rather than asserted
//  against.
//
//  Split into several focused test methods grouped by area (tab bar, More's top-level
//  rows, Downloads' management routes, Automation & Clients / System's children,
//  Calendar + Settings) rather than one long walk, so a failure names the screen that
//  broke instead of an opaque "step 17" failure in one giant method.

import XCTest

final class NavigationSmokeWalkUITests: XCTestCase {
    private var sonarrServer: SonarrFixtureServer?
    private var sabnzbdServer: SABnzbdFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarrServer?.stop()
        sonarrServer = nil
        sabnzbdServer?.stop()
        sabnzbdServer = nil
    }

    // MARK: - 1. Tab bar

    /// Regressions this catches: any of the five root tabs failing to render once
    /// services are configured, or losing its content after navigating away and back
    /// (a screen that renders once but can't be returned to is its own bug).
    @MainActor
    func testTabBarReachesEveryTabWithRealContent() async throws {
        let seriesJSON = #"[{"id":1,"title":"Smoke Walk Series"}]"#
        let sonarr = try await SonarrFixtureServer(seriesJSON: seriesJSON)
        sonarrServer = sonarr
        let jobName = "Smoke Walk NZB"
        let sab = try await SABnzbdFixtureServer(queueJobName: jobName)
        sabnzbdServer = sab

        let app = launchApp(sonarr: sonarr, sabnzbd: sab)
        waitForTabUI(app)

        let downloadsTab = app.tabBars.buttons["Downloads"]
        downloadsTab.tap()
        XCTAssertTrue(
            app.staticTexts[jobName].waitForExistence(in: app, timeout: 15),
            "Screen: Downloads tab should show the seeded SABnzbd job once the real connection finishes."
        )

        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(seriesTab.waitForExistence(timeout: 5), "Screen: Series tab bar button should exist.")
        seriesTab.tap()
        XCTAssertTrue(
            app.staticTexts["Smoke Walk Series"].waitForExistence(in: app, timeout: 15),
            "Screen: Series tab should show the seeded Sonarr library."
        )

        let moviesTab = app.tabBars.buttons["Movies"]
        XCTAssertTrue(moviesTab.waitForExistence(timeout: 5), "Screen: Movies tab bar button should exist.")
        moviesTab.tap()
        XCTAssertTrue(
            app.staticTexts["Add a Radarr server in Settings to manage your movies."].waitForExistence(in: app, timeout: 10),
            "Screen: Movies tab (no Radarr configured) should render its real unconfigured empty state rather than crash or render blank."
        )

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5), "Screen: Search tab bar button should exist.")
        searchTab.tap()
        XCTAssertTrue(
            app.navigationBars["Search"].waitForExistence(timeout: 10),
            "Screen: Search tab should render its own navigation title."
        )

        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 5), "Screen: More tab bar button should exist.")
        moreTab.tap()
        XCTAssertTrue(
            firstElement(labelContains: "Settings", in: app).waitForExistence(in: app, timeout: 10),
            "Screen: More tab should list its Settings row."
        )

        // Getting back matters: return to Downloads and confirm real content survived
        // the round trip through every other tab.
        downloadsTab.tap()
        XCTAssertTrue(
            app.staticTexts[jobName].waitForExistence(in: app, timeout: 10),
            "Screen: returning to the Downloads tab after visiting every other tab should still show its real content."
        )
    }

    // MARK: - 2. More's top-level rows

    /// Regressions this catches: any of More's seven top-level rows (Wanted/Missing,
    /// Library Management, Requests & Access, Media Server, Automation & Clients,
    /// System, Settings) failing to push to a real screen, or failing to pop back to
    /// More once pushed.
    @MainActor
    func testMoreTopLevelDestinationsPopBackCleanly() async throws {
        let app = try await launchWithSonarrAndSABnzbd()
        waitForTabUI(app)
        app.tabBars.buttons["More"].tap()

        assertRowPushesAndPops(app, rowLabel: "Wanted / Missing", expectedTitle: "Wanted / Missing")
        assertRowPushesAndPops(app, rowLabel: "Library Management", expectedTitle: "Library Management")
        assertRowPushesAndPops(app, rowLabel: "Requests & Access", expectedTitle: "Requests & Access")
        assertRowPushesAndPops(app, rowLabel: "Media Server", expectedTitle: "Media Server")
        assertRowPushesAndPops(app, rowLabel: "Automation & Clients", expectedTitle: "Automation & Clients")
        assertRowPushesAndPops(app, rowLabel: "System", expectedTitle: "System")
        assertRowPushesAndPops(app, rowLabel: "Settings", expectedTitle: "Settings")
    }

    // MARK: - 3. Downloads' management routes, including the SABnzbd client hub

    /// This is the direct regression test for N-02: Downloads -> Downloads Options ->
    /// Client Management -> SABnzbd -> Queue is the exact path that used to crash the
    /// app outright on a bare `@Environment(SyncService.self)` read in
    /// `SABnzbdManagerView` that nothing on this path injected. Also walks the rest of
    /// the SABnzbd client hub (Categories & Scripts, News Servers, SABnzbd Settings)
    /// and the Blocklist route, since all of them sit behind the same overflow menu and
    /// none of them had ever been opened by a test either.
    @MainActor
    func testDownloadsClientManagementAndSABnzbdHubRenderWithoutCrashing() async throws {
        let jobName = "Hub Walk NZB"
        let sab = try await SABnzbdFixtureServer(queueJobName: jobName)
        sabnzbdServer = sab
        let seriesJSON = #"[{"id":1,"title":"Hub Walk Series"}]"#
        let sonarr = try await SonarrFixtureServer(seriesJSON: seriesJSON)
        sonarrServer = sonarr

        let app = launchApp(sonarr: sonarr, sabnzbd: sab)
        waitForTabUI(app)

        let downloadsTab = app.tabBars.buttons["Downloads"]
        downloadsTab.tap()
        XCTAssertTrue(
            app.staticTexts[jobName].waitForExistence(in: app, timeout: 15),
            "Screen: Downloads tab should show the seeded SABnzbd job before management routes are exercised."
        )

        openDownloadsOptions(app)
        tapMenuItem(app.buttons["Client Management"], named: "Client Management")
        XCTAssertTrue(
            app.navigationBars["Download Clients"].waitForExistence(timeout: 10),
            "Screen: 'Client Management' should push DownloadClientManagementView titled 'Download Clients'."
        )

        let sabnzbdRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "SABnzbd")).firstMatch
        XCTAssertTrue(
            sabnzbdRow.waitForExistence(in: app, timeout: 10),
            "Screen: 'Download Clients' should list the configured SABnzbd client."
        )
        sabnzbdRow.tap()
        XCTAssertTrue(
            app.navigationBars["SABnzbd"].waitForExistence(timeout: 10),
            "Screen: tapping the SABnzbd row should push SABnzbdClientHubView titled 'SABnzbd'."
        )

        let categoriesRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Categories & Scripts")).firstMatch
        XCTAssertTrue(
            categoriesRow.waitForExistence(in: app, timeout: 10),
            "Screen: the SABnzbd hub should list 'Categories & Scripts'."
        )
        categoriesRow.tap()
        XCTAssertTrue(
            app.navigationBars["Categories"].waitForExistence(timeout: 10),
            "Screen: 'Categories & Scripts' should push SABnzbdCategoriesView."
        )
        popBack(app, fromTitle: "Categories")

        let newsServersRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "News Servers")).firstMatch
        XCTAssertTrue(newsServersRow.waitForExistence(in: app, timeout: 10), "Screen: the SABnzbd hub should list 'News Servers' again after popping back.")
        newsServersRow.tap()
        XCTAssertTrue(
            app.navigationBars["News Servers"].waitForExistence(timeout: 10),
            "Screen: 'News Servers' should push SABnzbdNewsServersView."
        )
        popBack(app, fromTitle: "News Servers")

        let sabSettingsRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "SABnzbd Settings")).firstMatch
        XCTAssertTrue(sabSettingsRow.waitForExistence(in: app, timeout: 10), "Screen: the SABnzbd hub should list 'SABnzbd Settings' again after popping back.")
        sabSettingsRow.tap()
        XCTAssertTrue(
            app.buttons["Edit Server"].waitForExistence(timeout: 10),
            "Screen: 'SABnzbd Settings' should render the configured server's Edit Server control."
        )
        // Two pops, not one: `SABnzbdSettingsView` and `SABnzbdClientHubView` both
        // use `.navigationTitle("SABnzbd")`, so popping once lands back on the hub -
        // which still matches that title - rather than at Client Management.
        popBack(app, fromTitle: "SABnzbd")
        popBack(app, fromTitle: "SABnzbd")

        // Back at Client Management, then all the way back to Downloads.
        popBack(app, fromTitle: "Download Clients")
        XCTAssertTrue(
            app.staticTexts[jobName].waitForExistence(in: app, timeout: 10),
            "Screen: popping all the way back from Client Management should return to Downloads still showing its real content."
        )

        // N-02 regression, by its new route. The SABnzbd queue is no longer a push
        // under Client Management - it is one of the Downloads tab's own lists,
        // chosen from the title menu. What the assertion protects is unchanged:
        // `SABnzbdManagerView` reads SyncService, TorrentService and
        // SABnzbdServiceManager, and used to trap on whichever route failed to hand
        // it one of them. Reaching it from the tab root exercises a different set of
        // hand-overs than the old push did, so this is worth keeping.
        let titleMenu = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "change view")
        ).firstMatch
        XCTAssertTrue(
            titleMenu.waitForExistence(in: app, timeout: 10),
            "Screen: with a SABnzbd client configured, Downloads should offer its title menu."
        )
        titleMenu.tap()

        let sabnzbdOption = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "SABnzbd")
        ).firstMatch
        XCTAssertTrue(sabnzbdOption.waitForExistence(timeout: 10), "Screen: the Downloads title menu should list SABnzbd.")
        sabnzbdOption.tap()

        XCTAssertTrue(
            app.staticTexts[jobName].waitForExistence(in: app, timeout: 15),
            "N-02 regression: SABnzbdManagerView should render the seeded job (proving SyncService/TorrentService/SABnzbdServiceManager all resolved) instead of trapping on a missing @Environment value."
        )

        // Back to the unified list, so the Blocklist walk below starts where it
        // expects to.
        titleMenu.tap()
        let downloadsOption = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Downloads")
        ).firstMatch
        if downloadsOption.waitForExistence(timeout: 10) { downloadsOption.tap() }

        // Blocklist, the overflow menu's other route.
        //
        // Wait for the item before tapping. The menu is still presenting when
        // `openDownloadsOptions` returns, and a tap dispatched at an element that is
        // not there yet is silently dropped - the walk then fails on the *next*
        // assertion, blaming the destination screen for a tap that never landed.
        openDownloadsOptions(app)
        let blocklistItem = app.buttons["Blocklist"]
        XCTAssertTrue(
            blocklistItem.waitForExistence(timeout: 10),
            "Screen: the Downloads overflow menu should offer a 'Blocklist' route."
        )
        blocklistItem.tap()
        XCTAssertTrue(
            app.navigationBars["Blocked & Excluded"].waitForExistence(timeout: 10),
            "Screen: 'Blocklist' should push ArrBlocklistView titled 'Blocked & Excluded'."
        )
        popBack(app, fromTitle: "Blocked & Excluded")
        XCTAssertTrue(
            app.staticTexts[jobName].waitForExistence(in: app, timeout: 10),
            "Screen: popping back from Blocklist should return to Downloads still showing its real content."
        )
    }

    // MARK: - 4. Automation & Clients and System's children

    /// Regressions this catches: any child screen under the Automation & Clients or
    /// System hubs failing to render or failing to pop back - none of these had ever
    /// been opened by a test before either. Sonarr is configured, so
    /// `AutomationAndClientsHubView`'s "Indexers"/"Download Clients"/"Tasks" rows and
    /// `TasksHubView`'s "Arr Tasks" row render their real (non-empty-state) content,
    /// exercising the same environment-dependent code path N-02 broke.
    @MainActor
    func testAutomationAndSystemHubChildrenRenderWithoutCrashing() async throws {
        let app = try await launchWithSonarrAndSABnzbd()
        waitForTabUI(app)
        app.tabBars.buttons["More"].tap()

        let automationRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Automation & Clients")).firstMatch
        XCTAssertTrue(automationRow.waitForExistence(in: app, timeout: 10), "Screen: More should show an 'Automation & Clients' row.")
        automationRow.tap()
        XCTAssertTrue(
            app.navigationBars["Automation & Clients"].waitForExistence(timeout: 10),
            "Screen: 'Automation & Clients' should push AutomationAndClientsHubView."
        )

        assertRowPushesAndPops(app, rowLabel: "Indexers", expectedTitle: "Indexers")
        assertRowPushesAndPops(app, rowLabel: "Cleanuparr", expectedTitle: "Cleanuparr")
        assertRowPushesAndPops(app, rowLabel: "Linked Applications", expectedTitle: "Linked Applications")
        assertRowPushesAndPops(app, rowLabel: "Download Clients", expectedTitle: "Download Clients")
        assertRowPushesAndPops(app, rowLabel: "Remote Path Mappings", expectedTitle: "Remote Path Mappings")
        assertRowPushesAndPops(app, rowLabel: "Tasks", expectedTitle: "Tasks")

        // One level deeper: Tasks -> Arr Tasks, visible because Sonarr is configured.
        let tasksRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Tasks")).firstMatch
        XCTAssertTrue(tasksRow.waitForExistence(in: app, timeout: 10), "Screen: Automation & Clients should list 'Tasks' again.")
        tasksRow.tap()
        XCTAssertTrue(app.navigationBars["Tasks"].waitForExistence(timeout: 10), "Screen: 'Tasks' should push TasksHubView.")
        assertRowPushesAndPops(app, rowLabel: "Arr Tasks", expectedTitle: "Tasks")
        popBack(app, fromTitle: "Tasks")

        popBack(app, fromTitle: "Automation & Clients")
        let systemRow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "System")).firstMatch
        XCTAssertTrue(systemRow.waitForExistence(in: app, timeout: 10), "Screen: More should show a 'System' row again after returning from Automation & Clients.")
        systemRow.tap()
        XCTAssertTrue(app.navigationBars["System"].waitForExistence(timeout: 10), "Screen: 'System' should push SystemHubView.")

        assertRowPushesAndPops(app, rowLabel: "Health", expectedTitle: "Health")
        assertRowPushesAndPops(app, rowLabel: "Disk Space", expectedTitle: "Disk Space")
        assertRowPushesAndPops(app, rowLabel: "Logs", expectedTitle: "Logs")
        assertRowPushesAndPops(app, rowLabel: "Updates", expectedTitle: "Updates")
        assertRowPushesAndPops(app, rowLabel: "Backups", expectedTitle: "Backups")
    }

    // MARK: - 5. Arr calendar (from the Series toolbar) and Settings' service rows

    /// Regressions this catches: the Calendar sheet reachable from the Series/Movies
    /// toolbars failing to render or dismiss, and any of Settings' service rows
    /// (configured or not) failing to render or pop back.
    @MainActor
    func testCalendarSheetAndSettingsServiceRowsRenderWithoutCrashing() async throws {
        let app = try await launchWithSonarrAndSABnzbd()
        waitForTabUI(app)

        let seriesTab = app.tabBars.buttons["Series"]
        seriesTab.tap()
        XCTAssertTrue(
            app.staticTexts["Fixture Series Alpha"].waitForExistence(in: app, timeout: 15),
            "Screen: Series tab should show the seeded Sonarr library before opening Calendar."
        )

        app.buttons["Calendar"].tap()
        XCTAssertTrue(
            app.navigationBars["Calendar"].waitForExistence(timeout: 15),
            "Screen: the Series toolbar's Calendar button should present ArrCalendarView."
        )
        XCTAssertTrue(
            app.buttons["Today"].waitForExistence(timeout: 10),
            "Screen: Calendar should render its connected (not 'No Services Configured'/'Services Unreachable') content, including the 'Today' control."
        )
        app.buttons["Close"].tap()
        XCTAssertTrue(
            app.staticTexts["Fixture Series Alpha"].waitForExistence(in: app, timeout: 10),
            "Screen: dismissing Calendar should return to the Series tab still showing its real content."
        )

        app.tabBars.buttons["More"].tap()
        let settingsRow = firstElement(labelContains: "Settings", in: app)
        XCTAssertTrue(settingsRow.waitForExistence(in: app, timeout: 10), "Screen: More should show a 'Settings' row.")
        settingsRow.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Screen: 'Settings' should push SettingsView.")

        // Sonarr: configured and connected.
        let sonarrRow = firstElement(labelContains: "Fixture Sonarr", in: app)
        XCTAssertTrue(sonarrRow.waitForExistence(in: app, timeout: 10), "Screen: Settings should list the seeded Sonarr profile.")
        sonarrRow.tap()
        XCTAssertTrue(app.navigationBars["Sonarr"].waitForExistence(timeout: 10), "Screen: the Sonarr row should push ArrServiceSettingsView titled 'Sonarr'.")
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                    "Fixture Sonarr",
                    "onnected"
                )
            ).firstMatch.waitForExistence(timeout: 10),
            "Screen: a configured Sonarr should expose its server as a tappable row - the row is the editor entry point now, replacing the separate 'Edit Server' button."
        )
        popBack(app, fromTitle: "Sonarr")

        // SABnzbd: configured and connected.
        let sabnzbdRow = firstElement(labelContains: "Fixture SABnzbd", in: app)
        XCTAssertTrue(sabnzbdRow.waitForExistence(in: app, timeout: 10), "Screen: Settings should list the seeded SABnzbd profile.")
        sabnzbdRow.tap()
        XCTAssertTrue(app.navigationBars["SABnzbd"].waitForExistence(timeout: 10), "Screen: the SABnzbd row should push SABnzbdSettingsView.")
        XCTAssertTrue(app.buttons["Edit Server"].waitForExistence(timeout: 10), "Screen: a configured SABnzbd should offer 'Edit Server'.")
        popBack(app, fromTitle: "SABnzbd")

        // Radarr: never configured - the unconfigured-service settings path.
        let radarrRow = firstElement(labelContains: "Radarr", in: app)
        XCTAssertTrue(radarrRow.waitForExistence(in: app, timeout: 10), "Screen: Settings should still list a Radarr row even though it's not configured.")
        radarrRow.tap()
        XCTAssertTrue(app.navigationBars["Radarr"].waitForExistence(timeout: 10), "Screen: the Radarr row should push ArrServiceSettingsView titled 'Radarr'.")
        XCTAssertTrue(
            app.buttons["Add Radarr Server"].waitForExistence(timeout: 10),
            "Screen: an unconfigured Radarr should render its real 'Add Radarr Server' state rather than crash or render blank."
        )
        popBack(app, fromTitle: "Radarr")
    }

    // MARK: - Launch helpers

    private func launchApp(sonarr: SonarrFixtureServer?, sabnzbd: SABnzbdFixtureServer?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        if let sonarr {
            app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarr.baseURL
        }
        if let sabnzbd {
            app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = sabnzbd.baseURL
        }
        // Detail screens fire a real TMDb lookup otherwise, which reaches the public
        // internet and sits out a 15s timeout.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()
        return app
    }

    /// Shared seeding for methods that just need a generically-configured, connected
    /// Sonarr + SABnzbd to reach the tab UI - the exact fixture content doesn't matter
    /// to these methods, only that both services are configured and reachable.
    private func launchWithSonarrAndSABnzbd() async throws -> XCUIApplication {
        let seriesJSON = #"[{"id":1,"title":"Fixture Series Alpha"}]"#
        let sonarr = try await SonarrFixtureServer(seriesJSON: seriesJSON)
        sonarrServer = sonarr
        let sab = try await SABnzbdFixtureServer(queueJobName: "Fixture NZB Alpha")
        sabnzbdServer = sab
        return launchApp(sonarr: sonarr, sabnzbd: sab)
    }

    private func waitForTabUI(_ app: XCUIApplication) {
        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(
            downloadsTab.waitForExistence(timeout: 15),
            "A launch with configured services should reach the real tab UI, not the welcome screen."
        )
    }

    /// Taps an item in a just-opened menu, once it is actually hittable.
    ///
    /// A menu item exists in the hierarchy before it can receive a tap, and a tap
    /// synthesized too early is dropped silently - the failure then lands on the
    /// screen that never appeared rather than on the tap that never took. Retrying
    /// the tap is not an option either: tapping a `Menu` toggles it, so a retry can
    /// close a menu that had in fact opened.
    private func tapMenuItem(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND isHittable == true"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [hittable], timeout: 10),
            .completed,
            "Menu item '\(name)' never became tappable after its menu was opened.",
            file: file,
            line: line
        )
        element.tap()
    }

    private func openDownloadsOptions(_ app: XCUIApplication) {
        let downloadsOptionsButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Downloads Options"))
            .firstMatch
        XCTAssertTrue(
            downloadsOptionsButton.waitForExistence(in: app, timeout: 10),
            "Downloads should show its overflow 'Downloads Options' menu once a client is configured."
        )
        downloadsOptionsButton.tap()
    }

    // MARK: - Navigation helpers

    /// Finds the first `Button` anywhere in the tree whose accessibility label contains
    /// `text`. Rows built from `NavigationLink`/`Button` wrapping multiple `Text`/`Image`
    /// children (`NavigationMenuRow`, `SettingsView.serviceRow`) merge their title and
    /// subtitle into one accessibility label, so an exact match is fragile - this
    /// mirrors the pattern already established in `ArrRepointJourneyUITests`. Restricted
    /// to `.buttons` deliberately: matching `.any` picks up non-interactive descendants
    /// too, and tapping one of those silently does nothing.
    private func firstElement(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Taps the leading (back) button on the named navigation bar. None of the screens
    /// this suite visits define a custom leading toolbar item, so the back chevron is
    /// reliably the first button in that bar.
    private func popBack(
        _ app: XCUIApplication,
        fromTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bar = app.navigationBars[fromTitle]
        XCTAssertTrue(
            bar.waitForExistence(timeout: 5),
            "Expected the '\(fromTitle)' navigation bar to still be on screen before popping back from it.",
            file: file,
            line: line
        )
        let backButton = bar.buttons.element(boundBy: 0)
        XCTAssertTrue(
            backButton.waitForExistence(timeout: 5),
            "Screen: '\(fromTitle)' should offer a back control to return to the previous screen.",
            file: file,
            line: line
        )
        backButton.tap()
    }

    /// Taps a row (matched by `rowLabel` substring) that's expected to push a screen
    /// titled `expectedTitle`, asserts that screen actually rendered, pops back via its
    /// back button, and asserts the original row is visible again - proving both that
    /// the screen renders real content and that it can actually be navigated away from,
    /// not just pushed to.
    private func assertRowPushesAndPops(
        _ app: XCUIApplication,
        rowLabel: String,
        expectedTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", rowLabel)).firstMatch
        XCTAssertTrue(
            row.waitForExistence(in: app, timeout: 10),
            "Expected a '\(rowLabel)' row to exist.",
            file: file,
            line: line
        )
        row.tap()

        XCTAssertTrue(
            app.navigationBars[expectedTitle].waitForExistence(timeout: 10),
            "Screen: '\(rowLabel)' should push to a screen titled '\(expectedTitle)' instead of crashing or rendering blank.",
            file: file,
            line: line
        )

        popBack(app, fromTitle: expectedTitle, file: file, line: line)

        XCTAssertTrue(
            row.waitForExistence(in: app, timeout: 10),
            "Screen: popping back from '\(expectedTitle)' should return to a screen showing '\(rowLabel)' again.",
            file: file,
            line: line
        )
    }
}
