//
//  RecentNotificationsJourneyUITests.swift
//  TrawlUITests
//
//  Generates log entries through real user actions, then verifies what the Alerts
//  log keeps, its New since heading, detail, and destructive clear flow. No
//  notification state is installed by the test: the library removal and the
//  Actions tab's rescan raise their events exactly as they do in production.

import XCTest

final class RecentNotificationsJourneyUITests: XCTestCase {
    private var fixtureServer: JellyfinLibrariesUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// Alerts keeps a record of what happened, not an echo of what the user just did.
    ///
    /// A library removal is the user's own tap: it shows as a banner and is not
    /// logged. A rescan run from the Actions tab is the outcome of work on the server,
    /// so it is logged, lands under "New since", opens its detail, survives being read,
    /// and goes only through the destructive Clear confirmation.
    @MainActor
    func testAlertsLogOutcomesNotTapConfirmationsAndCanBeCleared() async throws {
        let server = try await JellyfinLibrariesUIFixtureServer()
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = server.baseURL
        app.launch()

        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(searchTheAppChrome(for: "Jellyfin Libraries", in: app))

        let librariesResult = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Jellyfin Libraries"))
            .firstMatch
        XCTAssertTrue(tapWhenHittable(librariesResult, in: app, timeout: 10))
        XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 10))

        let library = app.staticTexts[JellyfinLibrariesUIFixtureServer.libraryName]
        XCTAssertTrue(library.waitForExistence(in: app, timeout: 15))
        XCTAssertTrue(revealSwipeAction(on: library, buttonLabel: "Remove", in: app))
        let removalConfirmation = app.alerts["Remove Library?"]
        XCTAssertTrue(removalConfirmation.waitForExistence(timeout: 10))
        XCTAssertTrue(tapWhenHittable(removalConfirmation.buttons["Remove"], in: app, timeout: 5))
        XCTAssertTrue(app.staticTexts["No Libraries"].waitForExistence(timeout: 15))
        XCTAssertEqual(server.requestCount(method: "DELETE", path: "/Library/VirtualFolders"), 1)

        let notifications = app.buttons["Notifications"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 10))
        XCTAssertFalse(
            String(describing: notifications.value).contains("Library Removed"),
            "A confirmation of the user's own tap is a banner, not a log entry for the bar to advertise."
        )
        XCTAssertTrue(tapWhenHittable(notifications, in: app, timeout: 10))

        let alerts = app.navigationBars["Alerts"]
        XCTAssertTrue(alerts.waitForExistence(timeout: 10), "With nothing waiting, the sheet opens on Alerts.")
        XCTAssertTrue(app.tabBars.buttons["Alerts"].isSelected)
        XCTAssertFalse(app.staticTexts["Library Removed"].exists, "The removal must not be in the log.")

        XCTAssertTrue(tapWhenHittable(app.tabBars.buttons["Actions"], in: app, timeout: 5))
        XCTAssertTrue(app.navigationBars["Actions"].waitForExistence(timeout: 5))
        XCTAssertTrue(tapWhenHittable(app.buttons["Rescan Libraries"], in: app, timeout: 10))
        let rescanned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requestCount(method: "POST", path: "/Library/Refresh") == 1
        }, object: nil)
        await fulfillment(of: [rescanned], timeout: 10)
        XCTAssertTrue(
            app.descendants(matching: .any)["quick-action-last-run-rescanJellyfinLibraries"]
                .waitForExistence(timeout: 10),
            "A finished action should say when it last ran."
        )

        XCTAssertTrue(tapWhenHittable(app.tabBars.buttons["Alerts"], in: app, timeout: 5))
        let rescanEntry = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Rescanned Jellyfin"))
            .firstMatch
        XCTAssertTrue(
            rescanEntry.waitForExistence(in: app, timeout: 10),
            "The outcome of a quick action belongs in the log."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["notifications-new-since"].exists,
            "An entry newer than the last look sits under the New since heading."
        )

        XCTAssertTrue(tapWhenHittable(rescanEntry, in: app, timeout: 5), "A log row opens its detail.")
        let detail = app.navigationBars["Notification"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        capture(app, "notification-detail")
        XCTAssertTrue(tapWhenHittable(backButton(in: detail), in: app, timeout: 5))
        XCTAssertTrue(alerts.waitForExistence(timeout: 5))

        dismissSheet(alerts, in: app)
        XCTAssertTrue(alerts.waitForNonExistence(timeout: 5))
        XCTAssertTrue(tapWhenHittable(notifications, in: app, timeout: 5))
        XCTAssertTrue(alerts.waitForExistence(timeout: 5), "The sheet reopens on the tab it was left on.")
        XCTAssertTrue(
            rescanEntry.waitForExistence(in: app, timeout: 5),
            "Read history remains in the log after it stops being new."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["notifications-new-since"].exists,
            "Once read, the entry is no longer under New since."
        )
        capture(app, "notification-read-history-retained")

        let clear = alerts.buttons["Clear"]
        XCTAssertTrue(tapWhenHittable(clear, in: app, timeout: 5))
        let clearConfirmation = app.alerts["Clear Notifications?"]
        XCTAssertTrue(clearConfirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(tapWhenHittable(clearConfirmation.buttons["Cancel"], in: app, timeout: 5))
        XCTAssertTrue(rescanEntry.waitForExistence(in: app, timeout: 5), "Cancel must keep the log.")

        XCTAssertTrue(tapWhenHittable(clear, in: app, timeout: 5))
        XCTAssertTrue(clearConfirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(tapWhenHittable(clearConfirmation.buttons["Clear"], in: app, timeout: 5))
        XCTAssertTrue(app.staticTexts["No Notifications Yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(rescanEntry.exists)
        #if os(macOS)
        XCTAssertTrue(tapWhenHittable(alerts.buttons["Close"], in: app, timeout: 5))
        XCTAssertTrue(alerts.waitForNonExistence(timeout: 5))
        #endif
    }

    @discardableResult
    @MainActor
    private func tapWhenHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @MainActor
    private func revealSwipeAction(on row: XCUIElement, buttonLabel: String, in app: XCUIApplication) -> Bool {
        let action = app.buttons[buttonLabel]
        for _ in 0..<4 {
            if action.exists && action.isHittable {
                action.tap()
                return true
            }
            guard row.exists else { return false }
            revealSwipeActions(.trailing, on: row)
            _ = action.waitForExistence(timeout: 2)
        }
        guard action.exists && action.isHittable else { return false }
        action.tap()
        return true
    }

    @MainActor
    private func dismissSheet(_ navigationBar: XCUIElement, in app: XCUIApplication) {
        let start = navigationBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
