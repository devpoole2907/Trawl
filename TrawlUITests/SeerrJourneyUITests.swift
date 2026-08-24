//
//  SeerrJourneyUITests.swift
//  TrawlUITests
//
//  Seed only the Seerr profile and session-cookie external state. Navigation,
//  connection, decoding, issue state, and mutations remain production code.
//

import XCTest

final class SeerrJourneyUITests: XCTestCase {
    private var fixtureServer: SeerrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// Covers the authenticated Seerr startup path and More → Requests & Access →
    /// Issues → detail navigation. Resolving the issue proves the detail view's real
    /// mutation response updates user-visible state as well as reaching the fixture.
    @MainActor
    func testAuthenticatedSeerrIssueJourneyLoadsDetailAndResolvesIssue() async throws {
        let server = try await SeerrUIFixtureServer()
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = server.baseURL
        app.launch()

        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(
            moreTab.waitForExistence(timeout: 15),
            "A synchronously seeded Seerr profile should take the app past the welcome gate into the real tab UI."
        )
        moreTab.tap()

        let requestsAndAccess = button(labelContaining: "Requests & Access", in: app)
        XCTAssertTrue(
            requestsAndAccess.waitForExistence(in: app, timeout: 10),
            "More should expose the real Requests & Access navigation hub for a configured Seerr profile."
        )
        requestsAndAccess.tap()

        let issuesRow = button(labelContaining: "Issues", in: app)
        XCTAssertTrue(
            issuesRow.waitForExistence(in: app, timeout: 10),
            "Requests & Access should expose the Issues route for the configured Seerr service."
        )
        issuesRow.tap()

        let issueTitle = app.staticTexts[SeerrUIFixtureServer.issueTitle]
        XCTAssertTrue(
            issueTitle.waitForExistence(in: app, timeout: 15),
            "The real issue list should decode and render the fixture issue returned by Seerr."
        )
        issueTitle.tap()

        XCTAssertTrue(
            app.navigationBars["Issue #\(SeerrUIFixtureServer.issueID)"].waitForExistence(timeout: 10),
            "Selecting the issue should push its real detail screen."
        )
        XCTAssertTrue(
            app.staticTexts[SeerrUIFixtureServer.detailComment].waitForExistence(in: app, timeout: 15),
            "The detail-only comment should render after the production client fetches /api/v1/issue/{id}."
        )

        let resolveButton = app.buttons["Resolve Issue"]
        XCTAssertTrue(resolveButton.waitForExistence(timeout: 5), "An open fixture issue should offer the Resolve Issue action.")
        resolveButton.tap()

        XCTAssertTrue(
            app.buttons["Reopen Issue"].waitForExistence(timeout: 10),
            "The visible action should change to Reopen Issue only after the production mutation response decodes as resolved."
        )

        XCTAssertTrue(
            server.hasReceivedAuthenticatedRequest(method: "GET", path: "/api/v1/auth/me"),
            "SeerrServiceManager must authenticate the seeded profile through the real /auth/me request."
        )
        XCTAssertTrue(
            server.hasReceivedAuthenticatedRequest(method: "GET", path: "/api/v1/issue"),
            "The rendered issue title must have arrived through the real authenticated issue-list request."
        )
        XCTAssertTrue(
            server.hasReceivedAuthenticatedRequest(method: "GET", path: "/api/v1/issue/\(SeerrUIFixtureServer.issueID)"),
            "The detail-only comment must have arrived through the real authenticated issue-detail request."
        )
        XCTAssertTrue(
            server.hasReceivedAuthenticatedRequest(method: "POST", path: "/api/v1/issue/\(SeerrUIFixtureServer.issueID)/resolved"),
            "Resolving the issue must send the production POST mutation to Seerr."
        )
    }

    @MainActor
    private func button(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }
}
