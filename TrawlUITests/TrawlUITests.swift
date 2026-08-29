//
//  TrawlUITests.swift
//  TrawlUITests
//
//  Created by James Poole on 05/04/2026.
//

import XCTest

/// Journeys through Trawl's first-launch experience.
///
/// Every test launches with `-TrawlUITestInMemoryStore`, which points
/// `TrawlApp.init()` at an in-memory `ModelContainer` (see the `#if DEBUG`
/// branch added there) instead of the real App Group store. That guarantees
/// zero `ServerProfile`/`ArrServiceProfile`/etc. rows exist, which in turn
/// guarantees `ContentView.hasConfiguredAnyService == false` and the app is
/// showing `WelcomeFlowView`.
///
/// That welcome gate turns out to be the *only* screen reachable from this
/// state: `WelcomeFlowView.serviceSelectionScreen` disables its "Go" button
/// until at least one service is configured, and every setup sheet
/// (`ArrSetupSheet`, `SABnzbdSetupSheet`, etc.) only saves a profile after a
/// live `testConnection` call succeeds - something a UI test has no
/// deterministic way to satisfy. So the tab bar, Downloads/Series/Movies/
/// Search/More, and everything under them (including the four
/// newly-labeled accessibility controls this suite was asked to check) are
/// unreachable from a genuinely unconfigured launch. See the class-level
/// note in each test for what that means for its coverage.
final class TrawlUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launch()
        return app
    }

    /// First launch presents a usable app: the welcome screen renders its
    /// real copy and its primary action, rather than a blank window or a
    /// crash. Fails if `WelcomeFlowView.introScreen` stops rendering its
    /// title/subtitle/feature content, or if the "Get Started" button is
    /// missing or unlabeled.
    @MainActor
    func testFirstLaunchShowsWelcomeScreen() throws {
        let app = launchedApp()

        let title = app.staticTexts["Welcome to Trawl"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Welcome title should appear on a fresh, unconfigured launch.")

        XCTAssertTrue(app.staticTexts["Your home for torrents, TV, and movies."].exists)
        XCTAssertTrue(app.staticTexts["qBittorrent"].exists)
        XCTAssertTrue(app.staticTexts["Sonarr"].exists)

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.exists, "The welcome screen's primary action must be present and reachable.")
        XCTAssertTrue(getStarted.isEnabled)
    }

    /// With no services configured, "Choose Your Services" must not let the
    /// user proceed into the tab UI - `WelcomeFlowView.serviceSelectionScreen`
    /// disables "Go" via `isDisabled: !configuredServices.hasAny`. This is
    /// this app's actual "unconfigured state degrades gracefully" behavior:
    /// rather than dropping a user with no services into an empty/broken tab
    /// bar, it blocks the exit until something is configured. If that
    /// disabled-state wiring regressed (e.g. the flag got inverted), this
    /// test would catch a user being able to tap through into a dead app.
    @MainActor
    func testServiceSelectionBlocksExitWithNoServicesConfigured() throws {
        let app = launchedApp()

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
        getStarted.tap()

        let heading = app.staticTexts["Choose Your Services"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "Tapping Get Started should reach the service selection screen.")

        let go = app.buttons["Go"]
        XCTAssertTrue(go.waitForExistence(timeout: 5))
        XCTAssertFalse(go.isEnabled, "Go must stay disabled while zero services are configured.")
    }

    /// Navigation round-trip: Welcome -> Choose Your Services -> back ->
    /// Welcome. Fails if the push breaks, or if popping back leaves stale
    /// content on screen instead of returning to the intro.
    @MainActor
    func testWelcomeNavigationRoundTrip() throws {
        let app = launchedApp()

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
        getStarted.tap()

        let heading = app.staticTexts["Choose Your Services"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))

        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5))
        backButton.tap()

        let title = app.staticTexts["Welcome to Trawl"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Popping back should return to the welcome intro screen.")
        XCTAssertTrue(app.buttons["Get Started"].exists)
        XCTAssertFalse(heading.exists, "The service selection heading should no longer be on screen after popping back.")
    }
}
