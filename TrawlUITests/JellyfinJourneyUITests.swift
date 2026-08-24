//
//  JellyfinJourneyUITests.swift
//  TrawlUITests
//
//  Tier-1 Jellyfin journey: a seeded, real profile clears the welcome gate; the
//  real manager/client connects to a loopback Jellyfin server; More → Media Server
//  → Sessions renders decoded playback data; and Stop Playback drives a real POST
//  plus a server-backed re-render of the empty session state.
//

import XCTest

final class JellyfinJourneyUITests: XCTestCase {
    private var fixtureServer: JellyfinUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    @MainActor
    func testMediaServerSessionsRenderAndStopPlaybackThroughRealJellyfin() async throws {
        let server = try await JellyfinUIFixtureServer()
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = server.baseURL
        app.launch()

        // The configured profile must get past the welcome gate before any path can
        // be exercised. The profile and token are seeded by TrawlApp's DEBUG-only
        // hook, while this fixture remains the only external dependency.
        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(
            moreTab.waitForExistence(timeout: 15),
            "A launch with a seeded Jellyfin profile should enter the real tab UI instead of the welcome flow."
        )
        XCTAssertTrue(tapWhenHittable(moreTab, in: app), "The More tab should be available after the seeded launch.")

        let mediaServer = firstButton(labelContaining: "Media Server", in: app)
        XCTAssertTrue(
            mediaServer.waitForExistence(in: app, timeout: 10),
            "More should expose the Media Server destination for a configured Jellyfin profile."
        )
        XCTAssertTrue(tapWhenHittable(mediaServer, in: app), "The Media Server row should navigate when tapped.")
        XCTAssertTrue(
            app.navigationBars["Media Server"].waitForExistence(timeout: 10),
            "The More destination should present the Jellyfin Media Server hub."
        )

        let sessions = firstButton(labelContaining: "Sessions", in: app)
        XCTAssertTrue(
            sessions.waitForExistence(in: app, timeout: 10),
            "The configured Media Server hub should expose its Sessions administration path."
        )
        XCTAssertTrue(tapWhenHittable(sessions, in: app), "Tapping Sessions should push the real Jellyfin session list.")

        // These are independently decoded fields from the live session response, not
        // labels present on the Media Server hub. Together they prove the session row
        // rendered its user and current playback content from the production client.
        let user = app.staticTexts[JellyfinUIFixtureServer.userName]
        XCTAssertTrue(
            user.waitForExistence(timeout: 15),
            "JellyfinSessionsView should render the user from GET /Sessions through the real production decoder."
        )
        XCTAssertTrue(
            app.staticTexts[JellyfinUIFixtureServer.episodeName].waitForExistence(timeout: 10),
            "JellyfinSessionsView should render the now-playing episode from the decoded session payload."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/System/Info"),
            "JellyfinServiceManager should validate the seeded profile with GET /System/Info over the loopback socket."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/Users"),
            "JellyfinServiceManager should complete its normal post-connect user prefetch rather than bypassing startup state."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/Sessions"),
            "The rendered session row must be backed by a real GET /Sessions request."
        )
        XCTAssertTrue(
            server.requests.contains { request in
                request.path == "/Sessions" && request.authorization?.contains("Token=\"uitest-api-key\"") == true
            },
            "The session request should carry the seeded API key through JellyfinAuthHeader, proving the real authenticated request path was used."
        )

        // `JellyfinSessionsView` exposes Stop through a trailing swipe action, then
        // requires a destructive confirmation. The fixture changes the next GET
        // /Sessions response only after the confirmed POST arrives.
        XCTAssertTrue(
            revealSwipeAction(on: user, buttonLabel: "Stop", in: app),
            "Swiping the active session should reveal its Stop action while the server reports remote-control playback."
        )
        let confirmation = app.alerts["Stop Playback?"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 10),
            "Choosing Stop should present JellyfinSessionsView's destructive playback confirmation."
        )
        XCTAssertTrue(
            tapWhenHittable(confirmation.buttons["Stop"], in: app),
            "The destructive confirmation should submit the selected session only after its Stop button is ready to receive the tap."
        )

        let emptyState = app.staticTexts["No Active Sessions"]
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 15),
            "After the fixture accepts Stop Playback and the view reloads GET /Sessions, the user-visible empty state should replace the active session."
        )
        XCTAssertEqual(
            server.requestCount(method: "POST", path: "/Sessions/\(JellyfinUIFixtureServer.sessionID)/Playing/Stop"),
            1,
            "Confirming Stop Playback should send exactly one real Jellyfin stop request for the rendered session."
        )
        XCTAssertGreaterThanOrEqual(
            server.requestCount(method: "GET", path: "/Sessions"),
            2,
            "Stopping playback should reload sessions from Jellyfin rather than only removing the row from local UI state."
        )
    }

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// A SwiftUI button can exist while its push animation is still making it unable
    /// to receive a tap. Retry only the observable readiness state; this does not
    /// sleep or manufacture a navigation result.
    @discardableResult
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) -> Bool {
        guard element.waitForExistence(in: app, timeout: 5) else { return false }
        for _ in 0..<attempts {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            _ = element.waitForExistence(timeout: 0.5)
        }
        return false
    }

    /// Mirrors the established Downloads journey's bounded swipe-action handling.
    /// The button is tapped only after XCTest reports it interactable, so a partially
    /// presented action cannot turn into a silently dropped tap.
    @MainActor
    private func revealSwipeAction(on row: XCUIElement, buttonLabel: String, in app: XCUIApplication) -> Bool {
        let action = app.buttons[buttonLabel]
        for _ in 0..<4 {
            if action.exists && action.isHittable {
                action.tap()
                return true
            }
            guard row.exists else { return false }
            row.swipeLeft()
            _ = action.waitForExistence(timeout: 2)
        }
        guard action.exists && action.isHittable else { return false }
        action.tap()
        return true
    }
}
