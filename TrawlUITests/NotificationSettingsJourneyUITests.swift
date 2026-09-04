//
//  NotificationSettingsJourneyUITests.swift
//  TrawlUITests
//
//  Real iPhone journeys for the notification-webhook settings users reach from
//  the Notifications sheet. The launch hook supplies only a deterministic APNs
//  token; all profile loading, manager state, draft construction, navigation, and
//  mutation requests continue through production Trawl code.
//

import XCTest

final class NotificationSettingsJourneyUITests: XCTestCase {
    private var server: NotificationSettingsUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// Starts from the user-facing Notifications accessory, loads the existing
    /// Sonarr webhook and real tags, changes one trigger plus one tag, and saves.
    /// The fixture accepts the update only when the app emits the exact production
    /// PUT payload, including the APNs token header field and original resource ID.
    @MainActor
    func testSonarrNotificationSettingsLoadEditAndSaveThroughTheRealUI() async throws {
        let server = try await NotificationSettingsUIFixtureServer()
        self.server = server
        let app = launchApp(using: server)

        openSonarrNotifications(in: app)

        let seriesAdded = app.switches["Series Added"]
        XCTAssertTrue(
            seriesAdded.waitForExistence(in: app, timeout: 15),
            "The real Sonarr notification form should expose its service-specific Series Added trigger."
        )
        XCTAssertEqual(
            seriesAdded.value as? String,
            "0",
            "The toggle should begin with the false value decoded from GET /api/v3/notification."
        )
        XCTAssertTrue(
            tapSwitchWhenHittable(seriesAdded, in: app, timeout: 10),
            "Series Added should become hittable before the test changes the real notification draft."
        )
        let switchedOn = expectation(
            for: NSPredicate(format: "value == %@", "1"),
            evaluatedWith: seriesAdded
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [switchedOn], timeout: 5),
            .completed,
            "Tapping Series Added should change the production draft before Save serializes it."
        )

        let tag = firstButton(labelContaining: NotificationSettingsUIFixtureServer.tagLabel, in: app)
        XCTAssertTrue(
            tapWhenHittable(tag, in: app, timeout: 10),
            "The tag decoded during ArrServiceManager connection should be selectable in the notification form."
        )

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "The configuration screen should expose Save in its toolbar.")
        XCTAssertTrue(save.isEnabled, "A connected profile with the deterministic APNs token should permit saving.")
        save.tap()

        XCTAssertTrue(
            waitForExactSave(on: server, in: app, timeout: 15),
            "Save must update the existing notification with the exact ID, trigger, tag, webhook URL, APNs header, and API-key-authenticated PUT shape. Requests: \(server.requests)"
        )
        waitForDisappearance(of: app.navigationBars["Sonarr Notifications"], in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars["Sonarr Notifications"].exists,
            "A successful notification save should visibly dismiss the configuration screen back to Notification Settings."
        )
        XCTAssertTrue(
            app.navigationBars["Notification Settings"].waitForExistence(timeout: 5),
            "After saving, the user should return to the real Notification Settings hub rather than remain on a stale editing screen."
        )
        XCTAssertEqual(
            server.requestCount(method: "PUT", path: "/api/v3/notification/91"),
            1,
            "One Save tap must issue exactly one notification update, not a duplicate POST or retry loop."
        )
        XCTAssertEqual(
            server.requestCount(method: "POST", path: "/api/v3/notification"),
            0,
            "Editing an existing Trawl webhook must not create a duplicate notification."
        )
        XCTAssertTrue(
            server.unexpectedRequestDescriptions.isEmpty,
            "Every production request made by this journey must be deliberately scripted. Unexpected routes: \(server.unexpectedRequestDescriptions)"
        )
    }

    /// The configuration view must surface a server-side notification-read failure,
    /// leave the user on a visible error state, and avoid mutating webhook state.
    /// This is intentionally a real HTTP 500 through ArrAPIClient rather than a
    /// fabricated local error or a direct final-state install.
    @MainActor
    func testSonarrNotificationSettingsShowLoadFailureWithoutMutation() async throws {
        let server = try await NotificationSettingsUIFixtureServer(notificationListBehavior: .failing)
        self.server = server
        let app = launchApp(using: server)

        openSonarrNotifications(in: app)

        let error = firstElement(labelContaining: "Server error (500): \(NotificationSettingsUIFixtureServer.failureMessage)", in: app)
        XCTAssertTrue(
            error.waitForExistence(in: app, timeout: 15),
            "A real GET /api/v3/notification failure should remain user-visible in Sonarr Notifications instead of silently presenting an empty configuration."
        )
        XCTAssertTrue(
            app.navigationBars["Sonarr Notifications"].exists,
            "A load failure should keep the user on the actual configuration screen so they can see and recover from the error."
        )
        XCTAssertTrue(
            server.receivedAuthenticatedNotificationRead(),
            "The error must originate from the authenticated production notification read, not from a test-side injected view model state."
        )
        XCTAssertEqual(
            server.requestCount(method: "PUT", path: "/api/v3/notification/91"),
            0,
            "Loading a failed notification configuration must not mutate an existing webhook."
        )
        XCTAssertEqual(
            server.requestCount(method: "POST", path: "/api/v3/notification"),
            0,
            "Loading a failed notification configuration must not create a webhook."
        )
        XCTAssertTrue(
            server.unexpectedRequestDescriptions.isEmpty,
            "A failure journey should remain hermetic too. Unexpected routes: \(server.unexpectedRequestDescriptions)"
        )
    }

    // MARK: - Launch and real navigation helpers

    @MainActor
    private func launchApp(using server: NotificationSettingsUIFixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_APNS_TOKEN"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func openSonarrNotifications(in app: XCUIApplication) {
        // The accessory is rendered by both chromes - a tab bar accessory on iPhone,
        // a bottom safe-area inset on iPad - so it is the same button either way. The
        // wait is still needed: it only exists once the app is past the welcome gate.
        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A seeded Sonarr profile should reach the real app chrome before its notification accessory is used."
        )

        let notifications = app.buttons["Notifications"]
        XCTAssertTrue(
            tapWhenHittable(notifications, in: app, timeout: 15),
            "The app-wide Notifications accessory should be available after the seeded Sonarr profile reaches the normal app chrome."
        )
        XCTAssertTrue(
            app.navigationBars["Notifications"].waitForExistence(timeout: 10),
            "Tapping the accessory should present the real Notifications sheet."
        )

        let notificationSettings = app.buttons["Notification Settings"]
        XCTAssertTrue(
            tapWhenHittable(notificationSettings, in: app, timeout: 10),
            "The Notifications sheet gear should navigate to the production Notification Settings hub."
        )
        XCTAssertTrue(
            app.navigationBars["Notification Settings"].waitForExistence(timeout: 10),
            "The gear destination should show the Notification Settings hub."
        )

        let sonarr = firstButton(labelContaining: "Sonarr", in: app)
        XCTAssertTrue(
            tapWhenHittable(sonarr, in: app, timeout: 10),
            "The hub should offer the connected Sonarr notification configuration row."
        )
        XCTAssertTrue(
            app.navigationBars["Sonarr Notifications"].waitForExistence(timeout: 10),
            "Selecting Sonarr should push ArrWebhookNotificationConfigView."
        )
    }

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func firstElement(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    @discardableResult
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                element.tap()
                return true
            }
            // `scroller(for:)`, not `collectionViews.firstMatch`: on iPad the sidebar,
            // the content column and the keyboard are all scrollable and all on
            // screen, and the first one in the hierarchy is never the screen under
            // test.
            app.scroller(for: element).swipeUp()
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @discardableResult
    @MainActor
    private func tapSwitchWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                // SwiftUI exposes the whole Toggle row as the switch element.
                // Target the trailing control rather than its leading Label.
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                return true
            }
            // `scroller(for:)`, not `collectionViews.firstMatch`: on iPad the sidebar,
            // the content column and the keyboard are all scrollable and all on
            // screen, and the first one in the hierarchy is never the screen under
            // test.
            app.scroller(for: element).swipeUp()
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @MainActor
    private func waitForExactSave(
        on server: NotificationSettingsUIFixtureServer,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let tick = app.otherElements["trawl-tests-only-notification-save-wait-tick"]
        while Date() < deadline {
            if server.receivedExactSave() {
                return true
            }
            _ = tick.waitForExistence(timeout: 0.25)
        }
        return server.receivedExactSave()
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, element.exists {
            _ = app.otherElements["trawl-tests-only-notification-dismiss-wait-tick"].waitForExistence(timeout: 0.25)
        }
    }
}
