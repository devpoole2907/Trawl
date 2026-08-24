//
//  CleanuparrJourneyUITests.swift
//  TrawlUITests
//
//  Tier-1 coverage for the configured Cleanuparr dashboard. The fixture is the
//  remote service only: launch seeding, Keychain lookup, CleanuparrServiceManager,
//  CleanuparrAPIClient, HTTPTransport, decoding, navigation, and view state are all
//  production code.
//

import XCTest

final class CleanuparrJourneyUITests: XCTestCase {
    private var server: CleanuparrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// Regressions this catches: a seeded Cleanuparr profile no longer clearing the
    /// welcome gate; `CleanuparrServiceManager` failing to connect through the real
    /// client; dashboard navigation rendering blank; documented Stats fields or
    /// Health rows failing to reach the UI; or the Include Dry Runs control changing
    /// only local UI state rather than issuing its real parameterised refresh.
    @MainActor
    func testDashboardRendersRealStatsAndHealthThenRefreshesForDryRuns() async throws {
        let server = try await CleanuparrUIFixtureServer()
        self.server = server

        let app = launchApp(using: server)
        openCleanuparrDashboard(in: app)

        let eventTotal = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                "Events",
                "7"
            ))
            .firstMatch
        XCTAssertTrue(
            eventTotal.waitForExistence(in: app, timeout: 10),
            "The Activity section should render the fixture's seven events, proving a decoded Stats value reached the user rather than only a successful navigation title."
        )
        XCTAssertTrue(
            app.staticTexts["Fixture qBittorrent"].waitForExistence(in: app, timeout: 15),
            "The dashboard should render the download-client health name decoded from Cleanuparr's real Stats response — regression: the configured profile did not connect, the stats request failed, or the Health section stopped rendering."
        )
        XCTAssertTrue(
            app.staticTexts["Fixture Radarr is unavailable"].waitForExistence(in: app, timeout: 10),
            "The dashboard should render Cleanuparr's unhealthy Arr service error, not merely a generic connected state — regression: Health.Service.errorMessage stopped reaching healthRow(_:)."
        )
        let readiness = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                "Cleanuparr Readiness",
                "Ready"
            ))
            .firstMatch
        XCTAssertTrue(
            readiness.waitForExistence(in: app, timeout: 10),
            "Cleanuparr Readiness should report Ready after the production client receives the fixture's successful GET /health/ready response."
        )
        XCTAssertTrue(
            server.hasReceivedStatsRequest(hours: 168, includeDryRun: false),
            "The app should request GET /api/v2/stats with hours=168, includeDryRun=false, and the seeded X-Api-Key before rendering dashboard content — proves this is a production HTTP path, not installed state."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/health/ready"),
            "The real Cleanuparr connection path should check GET /health/ready before reporting readiness."
        )

        let includeDryRuns = app.switches["Include Dry Runs"]
        XCTAssertTrue(
            tapControlAtTop(includeDryRuns, in: app, timeout: 10),
            "The dashboard should expose a tappable Include Dry Runs control so a user can request the expanded stats window."
        )

        XCTAssertEqual(
            includeDryRuns.value as? String,
            "1",
            "The Include Dry Runs control should visibly remain enabled after the user changes it."
        )
        XCTAssertTrue(
            server.hasReceivedStatsRequest(hours: 168, includeDryRun: true),
            "Toggling Include Dry Runs should send a real follow-up GET /api/v2/stats with includeDryRun=true and the same seeded authentication header."
        )
    }

    /// The dashboard is the screen that owns Cleanuparr's failure presentation.
    /// This follows the same public navigation route as the healthy journey, then
    /// makes the real stats endpoint return a documented HTTP failure from launch so
    /// no previously-loaded state can accidentally satisfy the assertion.
    @MainActor
    func testDashboardShowsTheRealStatsFailureToTheUser() async throws {
        let server = try await CleanuparrUIFixtureServer(statsAvailability: .unavailable)
        self.server = server

        let app = launchApp(using: server)
        openCleanuparrDashboard(in: app)

        let unavailableTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Cleanuparr Unavailable"))
            .firstMatch
        XCTAssertTrue(
            unavailableTitle.waitForExistence(timeout: 15),
            "A real 503 from Cleanuparr's Stats API should render the dashboard's Cleanuparr Unavailable state instead of a blank dashboard or stale healthy content."
        )
        XCTAssertTrue(
            app.staticTexts["Cleanuparr returned 503: Fixture stats service unavailable"].waitForExistence(in: app, timeout: 10),
            "The dashboard should expose CleanuparrAPIError's server message, so a user can distinguish a service outage from an unconfigured server."
        )
        XCTAssertTrue(
            server.hasReceivedStatsRequest(hours: 168, includeDryRun: false),
            "The unavailable state must follow the production stats request with its default query and seeded X-Api-Key, not a test-installed error state."
        )
    }

    // MARK: - Navigation and interaction helpers

    @MainActor
    private func launchApp(using server: CleanuparrUIFixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_CLEANUPARR_BASE_URL"] = server.baseURL
        app.launch()
        return app
    }

    /// Drives the public route More → Automation & Clients → Cleanuparr. A seeded
    /// profile clears the welcome gate but does not select this destination, so the
    /// journey verifies the app's real navigation assembly as well as the dashboard.
    @MainActor
    private func openCleanuparrDashboard(in app: XCUIApplication) {
        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(
            tapWhenHittable(moreTab, in: app, timeout: 15),
            "A launch with the seeded Cleanuparr profile should reach the real tab UI, allowing the user to open More instead of remaining in the welcome flow."
        )

        let automationRow = firstButton(labelContaining: "Automation & Clients", in: app)
        XCTAssertTrue(
            tapWhenHittable(automationRow, in: app, timeout: 10),
            "More should expose its Automation & Clients destination, which owns the configured Cleanuparr dashboard route."
        )
        XCTAssertTrue(
            app.navigationBars["Automation & Clients"].waitForExistence(timeout: 10),
            "Tapping Automation & Clients should push its hub before the Cleanuparr dashboard is selected."
        )

        let cleanuparrRow = firstButton(labelContaining: "Cleanuparr", in: app)
        XCTAssertTrue(
            tapWhenHittable(cleanuparrRow, in: app, timeout: 10),
            "The Automation & Clients hub should expose Cleanuparr's dashboard destination."
        )
        XCTAssertTrue(
            app.navigationBars["Cleanuparr"].waitForExistence(timeout: 10),
            "Tapping Cleanuparr should push CleanuparrDashboardView rather than leaving the user on the Automation & Clients hub."
        )
    }

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Matches the established UI-test pattern: wait for real existence, then use a
    /// bounded hittability check before sending a coordinate tap. This avoids the
    /// silent dropped taps SwiftUI rows can produce under load, without sleeps or
    /// timing assumptions.
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

    /// Dashboard assertions intentionally inspect rows below the controls first.
    /// Return the list to its top before looking for the toggle; scrolling farther
    /// down would make an existing control permanently undiscoverable.
    @discardableResult
    @MainActor
    private func tapControlAtTop(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.exists, element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                return true
            }
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeDown()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeDown()
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

}
