//
//  JellyfinLibrariesJourneyUITests.swift
//  TrawlUITests
//
//  Exercises the production More search route to Jellyfin Libraries. Libraries
//  are deliberately indexed as a direct More destination: the Media Server hub
//  currently exposes Sessions, Transcoding, and Plugins, while the Libraries
//  entry is in More's Library Management search index.
//

import XCTest

final class JellyfinLibrariesJourneyUITests: XCTestCase {
    private var fixtureServer: JellyfinLibrariesUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// Proves an existing Jellyfin library is decoded and rendered through the
    /// searchable More route, then deletes it with the view's real destructive
    /// confirmation. The fixture only becomes empty after the exact DELETE arrives.
    @MainActor
    func testLibrariesRenderAndRemoveThroughRealJellyfin() async throws {
        let server = try await JellyfinLibrariesUIFixtureServer()
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = server.baseURL
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A seeded Jellyfin profile should reach the real app chrome rather than the welcome flow."
        )

        // `JellyfinLibrariesView` is intentionally registered in the searchable
        // Library Management index and nowhere else. The Media Server hub has no
        // Libraries row, so searching is the actual user-reachable route rather than a
        // test-only push - which also makes this the one journey that exercises each
        // chrome's search field for real: More's on iPhone, the sidebar's on iPad.
        XCTAssertTrue(
            searchTheAppChrome(for: "Jellyfin Libraries", in: app),
            "The app chrome should expose its production feature search field."
        )

        let librariesResult = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Jellyfin Libraries"))
            .firstMatch
        XCTAssertTrue(
            librariesResult.waitForExistence(in: app, timeout: 10),
            "Searching should return the real Jellyfin Libraries destination."
        )
        XCTAssertTrue(
            tapWhenHittable(librariesResult, in: app),
            "Selecting the Libraries search result should push JellyfinLibrariesView."
        )
        XCTAssertTrue(
            app.navigationBars["Libraries"].waitForExistence(timeout: 10),
            "The search result should show Jellyfin's real Libraries screen."
        )

        let library = app.staticTexts[JellyfinLibrariesUIFixtureServer.libraryName]
        XCTAssertTrue(
            library.waitForExistence(in: app, timeout: 15),
            "JellyfinLibrariesView should render the decoded fixture library name."
        )
        XCTAssertTrue(
            app.staticTexts["Movies"].waitForExistence(in: app, timeout: 5),
            "The library's decoded collection type should render as the user-facing Movies label."
        )
        XCTAssertTrue(
            server.hasReceivedAuthenticatedLibraryList(),
            "The rendered library must come from a real authenticated GET /Library/VirtualFolders request."
        )

        XCTAssertTrue(
            revealSwipeAction(on: library, buttonLabel: "Remove", in: app),
            "Swiping a library should reveal JellyfinLibrariesView's destructive Remove action."
        )
        let confirmation = app.alerts["Remove Library?"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 10),
            "Removing a library should require the production destructive confirmation."
        )
        XCTAssertTrue(
            tapWhenHittable(confirmation.buttons["Remove"], in: app),
            "Confirming library removal should submit the selected library once the destructive button is ready."
        )

        let emptyState = app.staticTexts["No Libraries"]
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 15),
            "After Jellyfin accepts the DELETE and the view reloads, the server-backed empty state should replace the removed library."
        )
        XCTAssertEqual(
            server.requestCount(method: "DELETE", path: "/Library/VirtualFolders"),
            1,
            "The confirmation should issue exactly one production DELETE request."
        )
        XCTAssertTrue(
            server.hasReceivedAuthenticatedRemovalOfFixtureLibrary(),
            "The DELETE must preserve Jellyfin's Token auth and include the exact name plus refreshLibrary=true query values."
        )
        XCTAssertGreaterThanOrEqual(
            server.requestCount(method: "GET", path: "/Library/VirtualFolders"),
            2,
            "Removing a library should re-fetch server state instead of only hiding the row locally."
        )
    }

    /// SwiftUI navigation links can briefly exist during their push animation before
    /// XCTest considers them hittable. This retries only that observable readiness.
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
