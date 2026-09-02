//
//  RecentNotificationsJourneyUITests.swift
//  TrawlUITests
//
//  Generates a notification through a real user mutation, then verifies the
//  notification sheet's log and destructive clear flow. No notification state is
//  installed by the test: JellyfinLibrariesView owns the success event exactly as
//  it does in production.

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

    @MainActor
    func testRealLibraryRemovalAppearsInNotificationsAndCanBeCleared() async throws {
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
        XCTAssertTrue(
            revealSwipeAction(on: library, buttonLabel: "Remove", in: app),
            "The notification must originate from JellyfinLibrariesView's real removal action."
        )

        let removalConfirmation = app.alerts["Remove Library?"]
        XCTAssertTrue(removalConfirmation.waitForExistence(timeout: 10))
        XCTAssertTrue(tapWhenHittable(removalConfirmation.buttons["Remove"], in: app, timeout: 5))
        XCTAssertTrue(
            app.staticTexts["No Libraries"].waitForExistence(timeout: 15),
            "The fixture must accept the DELETE before the resulting success notification is inspected."
        )
        XCTAssertEqual(server.requestCount(method: "DELETE", path: "/Library/VirtualFolders"), 1)

        let notifications = app.buttons["Notifications"]
        XCTAssertTrue(
            tapWhenHittable(notifications, in: app, timeout: 10),
            "The notification accessory should expose the event produced by the library removal."
        )

        let sheet = app.navigationBars["Notifications"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Library Removed"].waitForExistence(timeout: 10),
            "The notification log should contain the exact success title emitted by JellyfinLibrariesView."
        )
        XCTAssertTrue(
            app.staticTexts[JellyfinLibrariesUIFixtureServer.libraryName].waitForExistence(timeout: 5),
            "The logged notification should retain the affected server library as its message."
        )

        let clear = sheet.buttons["Clear"]
        XCTAssertTrue(tapWhenHittable(clear, in: app, timeout: 5))
        let clearConfirmation = app.alerts["Clear Notifications?"]
        XCTAssertTrue(
            clearConfirmation.waitForExistence(timeout: 5),
            "Clearing the notification log must require the production destructive confirmation."
        )
        XCTAssertTrue(tapWhenHittable(clearConfirmation.buttons["Cancel"], in: app, timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Library Removed"].waitForExistence(timeout: 5),
            "Cancelling the destructive confirmation must preserve the notification."
        )

        XCTAssertTrue(tapWhenHittable(clear, in: app, timeout: 5))
        XCTAssertTrue(clearConfirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(tapWhenHittable(clearConfirmation.buttons["Clear"], in: app, timeout: 5))
        XCTAssertTrue(
            app.staticTexts["No Notifications Yet"].waitForExistence(timeout: 10),
            "Confirming Clear should reconcile the real notification center to its empty state."
        )
        XCTAssertFalse(app.staticTexts["Library Removed"].exists)
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
}
