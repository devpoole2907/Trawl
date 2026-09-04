//
//  JellyfinUserEditorJourneyUITests.swift
//  TrawlUITests
//
//  `JellyfinUserEditorView` measured 0.0% across 2,353 executable lines - the largest
//  never-rendered file in the app. It is also the most consequential: it edits a
//  Jellyfin user's *permissions*, so a toggle seeded from the wrong value is a
//  security-relevant defect, not a cosmetic one.
//
//  Deliberately read-only. The journey proves the editor opens and seeds every
//  toggle from the policy the server actually returned; it does not drive a save.
//  A test that flips permissions to prove it can is a test that will one day flip
//  them somewhere it shouldn't, and the seeding is where the real risk lives - a
//  toggle showing the opposite of the server's value invites an administrator to
//  "correct" something that was never wrong.
//

import Foundation
import XCTest

final class JellyfinUserEditorJourneyUITests: XCTestCase {
    private var jellyfin: JellyfinUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        jellyfin?.stop()
        jellyfin = nil
    }

    @MainActor
    func testJellyfinUserEditorSeedsItsTogglesFromTheServersPolicy() async throws {
        let server = try await JellyfinUIFixtureServer()
        jellyfin = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = server.baseURL
        app.launch()

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A seeded Jellyfin launch should reach the app chrome.")

        // Each step asserts where it landed: a label match reports a successful tap
        // even when the coordinate lands somewhere else entirely.
        // Users lives under Requests & Access - it lists Jellyfin *and* Seerr
        // accounts, so it is filed with request management rather than under the
        // media server.
        XCTAssertTrue(openDestination(.users, in: app), "Users should be reachable.")
        XCTAssertTrue(
            app.navigationBars["Requests & Access"].waitForExistence(in: app, timeout: 10),
            "The Requests & Access hub should render."
        )

        let users = firstButton(labelContaining: "Users", in: app)
        XCTAssertTrue(tapWhenHittable(users, in: app, timeout: 12), "Requests & Access should expose the unified Users destination.")
        XCTAssertTrue(app.navigationBars["Users"].waitForExistence(in: app, timeout: 10), "The Users list should render.")

        let userRow = app.staticTexts[JellyfinUIFixtureServer.userName]
        XCTAssertTrue(
            userRow.waitForExistence(in: app, timeout: 15),
            "The list should render the user returned by GET /Users."
        )
        XCTAssertTrue(tapWhenHittable(userRow, in: app, timeout: 10), "Tapping a user should open its detail screen.")

        // The editor is a push from the user's Jellyfin section, not the detail itself.
        let editor = firstButton(labelContaining: "Jellyfin", in: app)
        XCTAssertTrue(
            tapWhenHittable(editor, in: app, timeout: 12),
            "The unified user detail should offer the Jellyfin user editor."
        )
        XCTAssertTrue(
            app.navigationBars[JellyfinUIFixtureServer.userName].waitForExistence(in: app, timeout: 12),
            "The editor is titled with the user's own name."
        )

        // The permission rows, seeded from the policy in GET /Users. The editor opens
        // read-only, so these are `policyRow`s rather than toggles.
        //
        // The fixture's user is an administrator who is not disabled, so these two
        // must disagree - if both read the same, the view is showing a default rather
        // than the server. Their accessibility *value* is what carries the state:
        // the row draws it as a green tick, which says nothing to VoiceOver and
        // nothing to a test.
        let administrator = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Administrator"))
            .firstMatch
        XCTAssertTrue(
            administrator.waitForExistence(in: app, timeout: 15),
            "The editor should render the Administrator permission row."
        )
        XCTAssertEqual(
            administrator.value as? String, "Enabled",
            "Administrator must seed from the server's IsAdministrator: true. A permission row showing the opposite of the server invites an admin to 'correct' something that was never wrong."
        )

        let disabled = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Disabled"))
            .firstMatch
        XCTAssertTrue(disabled.waitForExistence(in: app, timeout: 10), "The editor should render the Disabled permission row.")
        XCTAssertEqual(
            disabled.value as? String, "Disabled",
            "The Disabled permission must seed from the server's IsDisabled: false, and must not track Administrator."
        )

        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/Users"),
            "The policy must have come from a real request rather than a placeholder."
        )

        // Nothing was saved: a read-only journey must not have mutated permissions.
        XCTAssertFalse(
            server.requests.contains { $0.method == "POST" && $0.path.contains("/Policy") },
            "Opening the editor must not write a policy back to Jellyfin."
        )
    }

    // MARK: Helpers

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

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
}
