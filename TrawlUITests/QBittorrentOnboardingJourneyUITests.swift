//
//  QBittorrentOnboardingJourneyUITests.swift
//  TrawlUITests
//
//  UI journey #1 from TRAWL_RELIABILITY_TEST_AUDIT.md: first launch, a failed
//  qBittorrent login, a successful qBittorrent login, and the torrent list
//  appearing — all driven through Trawl's real onboarding UI and answered by a
//  real loopback HTTP fixture (`QBittorrentFixtureServer`), not a stub.
//
//  Unlike `SonarrConnectedJourneyUITests`, nothing is seeded via launch
//  environment here: `TrawlUITests.swift` already establishes that
//  `-TrawlUITestInMemoryStore` alone guarantees an unconfigured launch showing
//  `WelcomeFlowView`. This test drives the real "Add Server" sheet
//  (`OnboardingSheet` / `OnboardingViewModel`) exactly as a user would: type a host
//  and credentials, tap Connect, and let `OnboardingViewModel.validateAndSave`
//  perform a real login and a real `getAppVersion()` connection check against the
//  fixture over loopback HTTP. Once saved, `ContentView.initializeServices()`
//  builds the full `AppServices` graph (`QBittorrentClientFactory.makeAndLogin`,
//  then `SyncService`) against the same fixture, and the Downloads tab renders
//  whatever `SyncService` actually decoded from `/api/v2/sync/maindata`.

import XCTest

final class QBittorrentOnboardingJourneyUITests: XCTestCase {
    private var fixtureServer: QBittorrentFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// Regressions this catches: a rejected qBittorrent login silently being treated
    /// as success and letting onboarding proceed (audit finding M-03's exact class of
    /// bug), the failure copy in `OnboardingViewModel.validateAndSave` regressing or
    /// disappearing, the welcome gate failing to unblock once qBittorrent is actually
    /// configured, `AppServices.build` / `QBittorrentClientFactory` breaking against a
    /// real server, or the Downloads tab / `TorrentSummaryView` no longer surfacing a
    /// torrent's name as on-screen text.
    @MainActor
    func testFailedThenSuccessfulQBittorrentLoginReachesTorrentList() async throws {
        let server = try await QBittorrentFixtureServer()
        fixtureServer = server
        // Starts rejecting: covers the failure half first, matching the audit's
        // journey ("first launch, failed qBittorrent login, successful login...").

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launch()

        // MARK: Welcome -> Choose Your Services -> Add Server sheet

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "First launch should show the welcome screen's primary action.")
        getStarted.tap()

        let servicesHeading = app.staticTexts["Choose Your Services"]
        XCTAssertTrue(servicesHeading.waitForExistence(timeout: 15), "Tapping Get Started should reach the service selection screen.")

        let qbittorrentRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "qBittorrent")
        ).firstMatch
        XCTAssertTrue(qbittorrentRow.waitForExistence(timeout: 15), "The qBittorrent setup row should be present on the service selection screen.")
        qbittorrentRow.tap()

        let hostField = app.textFields["Server address"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 15), "The Add Server sheet should present ServerURLField, labeled \"Server address\".")

        let usernameField = app.textFields["Username"]
        let passwordField = app.secureTextFields["Password"]
        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(usernameField.waitForExistence(in: app, timeout: 5), "CredentialsSection should present a \"Username\" field.")
        XCTAssertTrue(passwordField.waitForExistence(in: app, timeout: 5), "CredentialsSection should present a \"Password\" secure field.")
        XCTAssertTrue(connectButton.waitForExistence(in: app, timeout: 5), "ModalFormStyle should present the \"Connect\" primary action.")

        replaceText(in: hostField, with: server.baseURL)
        XCTAssertEqual(
            hostField.value as? String,
            server.baseURL,
            "Typing the fixture's baseURL into the server address field should produce an exact match; a mismatch here (e.g. a dropped \"://\") would explain any later connection failure rather than a real login rejection."
        )
        replaceText(in: usernameField, with: "wrong-user")
        replaceText(in: passwordField, with: "wrong-pass")

        // MARK: Failure half — the fixture is still rejecting every login.

        connectButton.tap()

        let authFailedMessage = app.staticTexts["Authentication failed. Check your credentials."]
        XCTAssertTrue(
            authFailedMessage.waitForExistence(timeout: 15),
            "A rejected login must surface OnboardingViewModel's QBError.authFailed copy (\"Authentication failed. Check your credentials.\") rather than silently succeeding — this is exactly the class of bug audit finding M-03 described."
        )

        // The sheet must still be up: a failed login is not allowed to have saved a
        // profile or dismissed onboarding. "Connect" being present again (rather than
        // the services screen underneath) is the on-screen proof of that. This check
        // is safe immediately after the wait above: `validateAndSave`'s catch block
        // sets `validationError` and flips `isValidating` back to false in the same
        // statement group, so by the time the error text exists, the toolbar has
        // already swapped its `ProgressView` back for the "Connect" button.
        XCTAssertTrue(
            connectButton.exists,
            "A failed login must not dismiss the Add Server sheet or proceed past onboarding."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "POST", path: "/api/v2/auth/login"),
            "The fixture should have actually received the rejected login request over real HTTP, proving the failure came from a real round trip and not a client-side short-circuit."
        )

        // MARK: Success half — flip the fixture, correct the credentials, resubmit.

        server.setAcceptsLogins(true)
        replaceText(in: usernameField, with: "correct-user")
        replaceText(in: passwordField, with: "correct-pass")
        connectButton.tap()

        // A presented `.sheet` removes the presenting view's controls from the
        // accessibility tree while it's up, so "Go" only starts existing again once
        // the sheet has actually dismissed — this waits for the real dismiss to
        // happen rather than assuming a fixed delay.
        let goButton = app.buttons["Go"]
        XCTAssertTrue(
            goButton.waitForExistence(timeout: 15),
            "A successful login should save the server profile and dismiss the Add Server sheet, returning to the service selection screen."
        )
        XCTAssertTrue(goButton.isEnabled, "With qBittorrent now configured, \"Go\" must no longer be disabled — WelcomeFlowView gates it on configuredServices.hasAny.")

        // The sheet has only just dismissed, and a tap that lands while SwiftUI is
        // still settling that transition is silently swallowed — the app stays on
        // "Choose Your Services" and every later assertion fails for the wrong
        // reason. Tap until the welcome flow actually goes away, bounded, with no
        // sleeps: `waitForExistence` on the tab bar is the settle signal.
        let downloadsTab = app.tabBars.buttons["Downloads"]
        var goTapAttempts = 0
        while !downloadsTab.exists && goTapAttempts < 5 {
            if goButton.exists && goButton.isHittable {
                goButton.tap()
            }
            _ = downloadsTab.waitForExistence(timeout: 5)
            goTapAttempts += 1
        }
        XCTAssertTrue(
            downloadsTab.exists,
            "Tapping \"Go\" with a configured qBittorrent server should leave the welcome flow for the real tab UI."
        )

        // MARK: Real tab UI with the real torrent list

        // TorrentSummaryView (Trawl/Views/TorrentPillView.swift:102) applies
        // `.accessibilityElement(children: .combine)` to the whole row, merging the
        // title with the status badge, percentage, and size into one accessibility
        // label — so this deliberately matches by substring across any element type
        // rather than an exact `staticTexts["Fixture Torrent Alpha"]` lookup, which
        // the combined label would not equal.
        let torrentRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Fixture Torrent Alpha")
        ).firstMatch
        XCTAssertTrue(
            torrentRow.waitForExistence(timeout: 15),
            "The seeded torrent's name should appear in the Downloads tab once the real qBittorrent connection finishes and syncs."
        )

        // Proves the torrent on screen came over real HTTP through the real client
        // stack, not from a stub: the fixture server itself has to have logged both
        // the successful login and the sync request that produced it.
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v2/sync/maindata"),
            "The fixture server should have actually received the sync/maindata request that produced the on-screen torrent."
        )
    }

    // MARK: - Helpers

    /// Selects any existing text in `field` and types over it, which SwiftUI/UIKit
    /// text fields treat as a replace — more reliable than counting characters to
    /// backspace, especially for the secure password field (whose `.value` is a
    /// bullet placeholder, not the real password) and for URLs typed with "://",
    /// where stray autocomplete characters could otherwise survive a
    /// backspace-based clear.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        field.typeText(text)
    }
}
