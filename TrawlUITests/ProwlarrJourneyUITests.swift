//
//  ProwlarrJourneyUITests.swift
//  TrawlUITests
//
//  Tier-1 Prowlarr journeys. The app uses its real ArrServiceManager,
//  ProwlarrAPIClient, SwiftData profile, navigation, and view models against the
//  loopback ProwlarrUIFixtureServer. The only seed is the external Prowlarr URL and
//  its normal API-key Keychain entry, supplied by TrawlApp's DEBUG launch hook.

import XCTest

final class ProwlarrJourneyUITests: XCTestCase {
    private var fixtureServer: ProwlarrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    @MainActor
    func testProwlarrIndexersLoadAndTestThroughDetailScreen() async throws {
        let server = try await ProwlarrUIFixtureServer()
        fixtureServer = server
        let app = launchApp(server: server)

        openIndexers(in: app)

        let indexer = app.staticTexts[ProwlarrUIFixtureServer.indexerName]
        XCTAssertTrue(
            indexer.waitForExistence(in: app, timeout: 15),
            "The real Prowlarr indexer list should render the decoded fixture indexer."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v1/indexer", header: "X-Api-Key", equals: "uitest-api-key"),
            "The indexer visible on screen must come from a real authenticated ProwlarrAPIClient request."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v1/indexerstatus"),
            "The production indexer load concurrently fetches Prowlarr's status resource."
        )

        indexer.tap()
        XCTAssertTrue(
            app.navigationBars[ProwlarrUIFixtureServer.indexerName].waitForExistence(timeout: 10),
            "Tapping an indexer should push its real Prowlarr detail screen."
        )
        XCTAssertTrue(
            app.staticTexts["Base URL"].waitForExistence(in: app, timeout: 10),
            "The detail screen should display a field decoded from the indexer payload."
        )
        XCTAssertTrue(
            app.staticTexts[ProwlarrUIFixtureServer.tagName].waitForExistence(in: app, timeout: 10),
            "The detail screen should resolve the indexer's decoded tag through the real tag load."
        )

        let testButton = app.buttons["Test Indexer"]
        XCTAssertTrue(testButton.waitForExistence(in: app, timeout: 10), "The indexer detail action should be available.")
        testButton.tap()
        XCTAssertTrue(
            app.alerts["Test Result"].waitForExistence(timeout: 10),
            "A successful production indexer test should present its result, rather than silently doing nothing."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "POST", path: "/api/v1/indexer/test", bodyContains: ProwlarrUIFixtureServer.indexerName),
            "Testing from the detail screen must send the decoded indexer back through ProwlarrAPIClient."
        )
    }

    @MainActor
    func testProwlarrLinkedApplicationsLoadThroughRealNavigation() async throws {
        let server = try await ProwlarrUIFixtureServer()
        fixtureServer = server
        let app = launchApp(server: server)

        XCTAssertTrue(openDestination(.linkedApplications, in: app), "Linked Applications should be reachable.")

        if !TrawlChrome.isSidebar {
            let linkedApplications = button(containing: "Linked Applications", in: app)
            XCTAssertTrue(linkedApplications.waitForExistence(in: app, timeout: 10), "Integrations & Automation should expose Linked Applications.")
            linkedApplications.tap()
        }

        // The Indexer Sync row selects beside a detail pane and pushes without one,
        // so it is a Cell on one chrome and a Button on the other.
        let indexerSync = row(containing: "Indexer Sync", in: app)
        XCTAssertTrue(indexerSync.waitForExistence(in: app, timeout: 10), "The linked-applications screen should expose Prowlarr's Indexer Sync route.")
        indexerSync.tap()

        XCTAssertTrue(app.navigationBars["Linked Apps"].waitForExistence(timeout: 10), "Indexer Sync should push Prowlarr's linked-app list.")
        XCTAssertTrue(
            app.staticTexts[ProwlarrUIFixtureServer.applicationName].waitForExistence(in: app, timeout: 15),
            "The linked-app screen should render the decoded Prowlarr application fixture."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v1/applications"),
            "The linked app on screen must arrive through ProwlarrAPIClient.getApplications()."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v1/applications/schema"),
            "The real screen should also load Prowlarr's application schema for its add/edit path."
        )
    }

    @MainActor
    func testProwlarrProxiesAndTagsLoadAndCreateTag() async throws {
        let server = try await ProwlarrUIFixtureServer()
        fixtureServer = server
        let app = launchApp(server: server)

        openIndexers(in: app)

        let proxies = button(containing: "Proxies", in: app)
        XCTAssertTrue(proxies.waitForExistence(in: app, timeout: 10), "The Prowlarr indexer screen should expose proxy management.")
        proxies.tap()
        XCTAssertTrue(app.navigationBars["Proxies"].waitForExistence(timeout: 10), "Proxies should push Prowlarr's proxy list.")
        XCTAssertTrue(
            app.staticTexts[ProwlarrUIFixtureServer.proxyName].waitForExistence(in: app, timeout: 15),
            "The proxy list should render the decoded fixture proxy."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v1/indexerProxy"),
            "The proxy visible on screen must come from ProwlarrAPIClient.getIndexerProxies()."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v1/indexerProxy/schema"),
            "The real proxy screen should load its schema for the add/edit menu."
        )

        popBack(app, from: "Proxies")
        let tags = button(containing: "Tags", in: app)
        XCTAssertTrue(tags.waitForExistence(in: app, timeout: 10), "The Prowlarr indexer screen should expose tag management.")
        tags.tap()
        XCTAssertTrue(app.navigationBars["Tags"].waitForExistence(timeout: 10), "Tags should push Prowlarr's tag list.")
        XCTAssertTrue(
            app.staticTexts[ProwlarrUIFixtureServer.tagName].waitForExistence(in: app, timeout: 15),
            "The tag list should render the decoded Prowlarr tag fixture."
        )

        let addTag = app.buttons["Add Tag"]
        XCTAssertTrue(addTag.waitForExistence(timeout: 5), "The tag screen should expose its Add Tag action once Prowlarr is connected.")
        addTag.tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Adding a Prowlarr tag should present its input field.")
        nameField.tap()
        nameField.typeText("Fixture Added Tag")
        app.buttons["Add"].tap()

        XCTAssertTrue(
            app.staticTexts["Fixture Added Tag"].waitForExistence(in: app, timeout: 10),
            "Creating a tag should render the tag returned by the real POST response."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "POST", path: "/api/v1/tag", bodyContains: "Fixture Added Tag"),
            "The Add Tag action must send the entered label to Prowlarr, not merely append local UI state."
        )
    }

    // MARK: - Navigation helpers

    @MainActor
    private func launchApp(server: ProwlarrUIFixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_PROWLARR_BASE_URL"] = server.baseURL
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "The Prowlarr launch seed should bypass the welcome gate and reach the real app chrome."
        )
        return app
    }

    @MainActor
    private func openIndexers(in app: XCUIApplication) {
        XCTAssertTrue(openDestination(.indexers, in: app), "Indexers should be reachable.")

        // Compact only: there the destination is the Integrations hub and this is the
        // row that opens Indexers. On the sidebar chrome Indexers *is* the
        // destination, and a CONTAINS query for a button called "Indexers" against a
        // screen that is already open matches something else on it and taps that.
        if !TrawlChrome.isSidebar {
            let indexers = button(containing: "Indexers", in: app)
            XCTAssertTrue(indexers.waitForExistence(in: app, timeout: 10), "Integrations & Automation should expose Indexers.")
            indexers.tap()
        }
        XCTAssertTrue(app.showsScreen(named: "Indexers"), "Indexers should push ProwlarrIndexerListView.")
    }

    @MainActor
    private func button(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// A row, whichever element the chrome makes of it: a `Button` where it pushes,
    /// a `Cell` where it selects beside a detail pane.
    @MainActor
    private func row(containing text: String, in app: XCUIApplication) -> XCUIElement {
        let button = button(containing: text, in: app)
        if button.exists { return button }
        return app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func popBack(_ app: XCUIApplication, from title: String) {
        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "Expected the \(title) navigation bar before returning.")
        let backButton = backButton(in: navigationBar)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Expected a back control from \(title).")
        backButton.tap()
    }
}
