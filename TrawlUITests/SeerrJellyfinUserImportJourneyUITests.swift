//
//  SeerrJellyfinUserImportJourneyUITests.swift
//  TrawlUITests
//
//  The Jellyfin -> Seerr user import sheet, end to end. Only the two servers are
//  fixtures: navigation, the real UnifiedUserViewModel, SeerrAPIClient and the
//  import sheet's own selection all run as shipped.
//
//  The sheet picks users with `List(selection:)` and a pinned edit mode rather than a
//  checkmark drawn per row, so what needs pinning is that ticking rows still turns
//  into exactly the right payload: the POST must carry the ticked IDs and nothing
//  else. A picker that silently imported a row the user never ticked - or dropped one
//  they did - would look identical on screen.
//

import XCTest

final class SeerrJellyfinUserImportJourneyUITests: XCTestCase {
    private var seerrServer: SeerrUIFixtureServer?
    private var jellyfinServer: JellyfinUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        seerrServer?.stop()
        jellyfinServer?.stop()
        seerrServer = nil
        jellyfinServer = nil
    }

    /// More -> Requests & Access -> Users -> Import Jellyfin Users, ticking two of the
    /// three offered accounts. The Users screen needs both services, so both are
    /// seeded and both are real loopback servers.
    @MainActor
    func testImportingJellyfinUsersSendsOnlyTheTickedAccounts() async throws {
        let seerr = try await SeerrUIFixtureServer()
        let jellyfin = try await JellyfinUIFixtureServer()
        seerrServer = seerr
        jellyfinServer = jellyfin

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = seerr.baseURL
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = jellyfin.baseURL
        app.launch()

        openUsersScreen(in: app)

        let userActions = app.buttons["User Actions"]
        XCTAssertTrue(
            tapWhenHittable(userActions, in: app, timeout: 10),
            "A configured Seerr profile should expose the user-actions menu on the Users screen."
        )

        let importMenuItem = firstButton(labelContaining: "Import Jellyfin Users", in: app)
        XCTAssertTrue(
            tapWhenHittable(importMenuItem, in: app, timeout: 10),
            "The user-actions menu should offer the Jellyfin import route."
        )

        XCTAssertTrue(
            app.navigationBars["Import from Jellyfin"].waitForExistence(timeout: 15),
            "Choosing Import Jellyfin Users should present SeerrJellyfinImportSheet."
        )

        // Every offered account renders, including the one Seerr returns with no
        // username - the row falls back to the email rather than showing a raw ID.
        for user in SeerrUIFixtureServer.importableUsers {
            XCTAssertTrue(
                app.staticTexts[user.displayName].waitForExistence(in: app, timeout: 10),
                "The sheet should render \(user.displayName) from the real /settings/jellyfin/users response."
            )
        }

        XCTAssertTrue(
            tapWhenHittable(userRow(labelled: "Fixture Ada", in: app), in: app, timeout: 10),
            "A row in the import sheet should be tickable."
        )
        XCTAssertTrue(
            tapWhenHittable(userRow(labelled: "grace@fixture.test", in: app), in: app, timeout: 10),
            "A second row should tick without clearing the first."
        )

        XCTAssertTrue(
            app.staticTexts["2 selected"].waitForExistence(timeout: 10),
            "The sheet's subtitle should report both ticked rows, not one - selection is the List's now, so this is the visible half of the binding."
        )

        let importButton = app.buttons["Import"]
        XCTAssertTrue(
            tapWhenHittable(importButton, in: app, timeout: 10),
            "Import should be enabled once accounts are ticked."
        )

        // The imported row appearing is the barrier: it can only render after the real
        // POST returned and UnifiedUserViewModel applied the response.
        XCTAssertTrue(
            app.staticTexts["Fixture Grace"].waitForExistence(in: app, timeout: 20),
            "The Users list should show the accounts Seerr returned for the import."
        )

        let importRequests = seerr.jellyfinImportRequests
        XCTAssertEqual(
            importRequests.count,
            1,
            "Confirming the sheet should issue exactly one import request."
        )
        XCTAssertEqual(
            importRequests.first?.jellyfinUserIDs?.sorted(),
            ["jf-ada", "jf-grace"],
            "The import must carry exactly the ticked accounts - the untouched third account must not be imported."
        )
        XCTAssertTrue(
            seerr.hasReceivedAuthenticatedRequest(method: "GET", path: "/api/v1/settings/jellyfin/users"),
            "The sheet should load its accounts from Seerr over the authenticated session."
        )
    }

    /// Cancelling is the other half of the contract: a sheet that had ticked rows must
    /// not import anything when it is dismissed instead of confirmed.
    @MainActor
    func testDismissingTheImportSheetImportsNothing() async throws {
        let seerr = try await SeerrUIFixtureServer()
        let jellyfin = try await JellyfinUIFixtureServer()
        seerrServer = seerr
        jellyfinServer = jellyfin

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = seerr.baseURL
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = jellyfin.baseURL
        app.launch()

        openUsersScreen(in: app)

        XCTAssertTrue(tapWhenHittable(app.buttons["User Actions"], in: app, timeout: 10))
        XCTAssertTrue(
            tapWhenHittable(firstButton(labelContaining: "Import Jellyfin Users", in: app), in: app, timeout: 10)
        )

        let sheet = app.navigationBars["Import from Jellyfin"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))

        XCTAssertTrue(
            tapWhenHittable(userRow(labelled: "Fixture Ada", in: app), in: app, timeout: 10),
            "A row should tick before the sheet is dismissed."
        )
        XCTAssertTrue(
            app.staticTexts["1 selected"].waitForExistence(timeout: 10),
            "The tick should register before dismissal, so the assertion below is about cancelling rather than about nothing having been selected."
        )

        let cancel = sheet.buttons["Cancel"]
        XCTAssertTrue(tapWhenHittable(cancel, in: app, timeout: 10), "The sheet should offer a non-destructive exit.")

        // Back on the Users screen - the barrier that the dismissal completed.
        XCTAssertTrue(
            app.navigationBars["Users"].waitForExistence(timeout: 15),
            "Dismissing the sheet should return to the Users screen."
        )
        XCTAssertTrue(
            seerr.jellyfinImportRequests.isEmpty,
            "Dismissing the sheet must not import the ticked account."
        )
    }

    // MARK: - Helpers

    @MainActor
    private func openUsersScreen(in app: XCUIApplication) {
        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "Seeded Jellyfin and Seerr profiles should take the app past the welcome gate into the real app chrome."
        )
        XCTAssertTrue(openDestination(.users, in: app), "Users should be reachable.")

        let usersRow = firstButton(labelContaining: "Jellyfin and Seerr accounts", in: app)
        XCTAssertTrue(
            tapWhenHittable(usersRow, in: app, timeout: 15),
            "Requests & Access should expose the Users route once Jellyfin is configured."
        )

        XCTAssertTrue(
            app.staticTexts[JellyfinUIFixtureServer.userName].waitForExistence(in: app, timeout: 20),
            "The Users screen should merge and render the real Jellyfin account list."
        )
    }

    /// In edit mode the row is a cell rather than a button, so selection is driven by
    /// tapping the cell that contains the label.
    @MainActor
    private func userRow(labelled text: String, in app: XCUIApplication) -> XCUIElement {
        let cell = app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        return cell.exists ? cell : app.staticTexts[text]
    }

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Wait for existence, then for hittability, before tapping: a tap sent to a row
    /// that is not yet hittable is dropped silently and blames the wrong screen.
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
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }
}
