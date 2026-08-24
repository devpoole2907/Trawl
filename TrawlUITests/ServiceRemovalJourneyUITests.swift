//
//  ServiceRemovalJourneyUITests.swift
//  TrawlUITests
//
//  Covers the destructive Settings path through the real app. The loopback
//  fixture is only Cleanuparr; profile lookup, Keychain cleanup, SwiftData
//  deletion, manager disconnect, and every presented view are production code.
//


import XCTest

final class ServiceRemovalJourneyUITests: XCTestCase {
    private var server: CleanuparrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// Regressions this catches: More no longer reaching Settings; a configured
    /// service row routing to the wrong destination; the destructive dialog losing
    /// its action; or removal leaving the SwiftData profile visible and usable.
    @MainActor
    func testRemovingConfiguredServiceThroughSettingsLeavesAnAddableEmptyState() async throws {
        let server = try await CleanuparrUIFixtureServer()
        self.server = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_CLEANUPARR_BASE_URL"] = server.baseURL
        app.launch()

        XCTAssertTrue(
            tap(firstButton(containing: "More", in: app), in: app, timeout: 15),
            "A configured Cleanuparr launch should reach the real tab UI."
        )
        XCTAssertTrue(
            tap(firstButton(containing: "Settings", in: app), in: app, timeout: 10),
            "More should expose Settings as a real navigation destination."
        )
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10),
            "The Settings destination should be pushed before selecting a service."
        )

        let configuredService = firstButton(containing: "Fixture Cleanuparr", in: app)
        XCTAssertTrue(
            tap(configuredService, in: app, timeout: 10),
            "Settings should render the synchronously seeded Cleanuparr profile and route its service row."
        )
        XCTAssertTrue(
            app.navigationBars["Cleanuparr"].waitForExistence(timeout: 10),
            "The configured service row should open CleanuparrSettingsView."
        )
        XCTAssertTrue(
            app.staticTexts[server.baseURL].waitForExistence(in: app, timeout: 10),
            "The settings screen should show the actual seeded profile, not a generic placeholder."
        )
        XCTAssertTrue(
            server.hasReceivedStatsRequest(hours: 168, includeDryRun: false),
            "The profile being removed must have travelled through the real authenticated manager connection first."
        )

        let removeServer = app.buttons["Remove Cleanuparr Server"]
        XCTAssertTrue(
            tap(removeServer, in: app, timeout: 10),
            "The destructive server-removal control should remain reachable below the status sections."
        )
        XCTAssertTrue(
            app.staticTexts["Remove Cleanuparr Server?"].waitForExistence(timeout: 10),
            "Removal must ask for explicit confirmation before deleting credentials and profile state."
        )
        XCTAssertTrue(
            tap(app.buttons["Remove"], in: app, timeout: 10),
            "The confirmation's destructive action should be tappable."
        )

        XCTAssertTrue(
            app.buttons["Add Cleanuparr Server"].waitForExistence(in: app, timeout: 15),
            "After production Keychain/SwiftData removal, the same settings screen should repaint to its unconfigured add-server state."
        )
        XCTAssertFalse(
            app.staticTexts[server.baseURL].exists,
            "The removed profile's host must not remain rendered as stale settings state."
        )
    }

    @MainActor
    private func firstButton(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    @discardableResult
    @MainActor
    private func tap(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
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
