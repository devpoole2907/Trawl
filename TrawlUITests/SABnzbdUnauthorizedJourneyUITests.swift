//
//  SABnzbdUnauthorizedJourneyUITests.swift
//  TrawlUITests
//
//  UI journey #6 from TRAWL_RELIABILITY_TEST_AUDIT.md's "test system Trawl needs":
//  a SABnzbd API key rejected mid-session must actually stop polling, actually clear
//  the connection, and actually tell the user — not just internally, which is what
//  H-05/H-06's unit coverage (`TrawlTests/SABnzbdServiceManagerConcurrencyTests.swift`,
//  `TrawlTests/SABnzbdProfileSwitchTests.swift`) already proves at the manager level.
//  This suite proves the same regression can't reappear in the UI: that a user looking
//  at the screen is actually told, and that a mutation actually stops making requests,
//  rather than the app silently continuing to look connected.
//
//  Seeding follows `SonarrConnectedJourneyUITests`'s established pattern: a real
//  `SABnzbdServiceProfile` plus its Keychain API key are seeded synchronously before
//  `ContentView` evaluates the welcome-vs-tabs gate (see
//  `TrawlApp.seedUITestSABnzbdServiceIfRequested(into:)`, gated behind
//  `TRAWL_UITEST_SABNZBD_BASE_URL`), pointed at `SABnzbdFixtureServer`, a real loopback
//  HTTP server this test process hosts. From there the app's own startup, connect, and
//  navigation code runs untouched: `SABnzbdServiceManager.connectService(_:)` makes
//  real HTTP requests to the fixture server, and the Downloads tab renders whatever
//  `SABnzbdAPIClient` actually decoded from those responses.
//
//  ## Why the assertion lives in the SABnzbd manager screen, not the unified Downloads
//  list
//
//  `Trawl/DownloadsStack/DownloadsView.swift` never reads
//  `SABnzbdServiceManager.connectionError` at all — an unauthorized SABnzbd simply
//  makes its jobs vanish from the unified list (the manager clears `queue`/`history`
//  to `nil`), which reads identically to "nothing downloading right now" there. The
//  screen that actually surfaces the rejection is `SABnzbdManagerView`
//  (`Trawl/SABnzbdStack/SABnzbdManagerView.swift:120`): once its job list is empty and
//  `serviceManager.connectionError != nil`, it renders a `ContentUnavailableView`
//  titled "SABnzbd Unavailable" with the connection error as its description — the
//  exact copy `SABnzbdServiceManager.refresh()` sets
//  (`Trawl/SABnzbdStack/SABnzbdServiceManager.swift:198`): "SABnzbd rejected the API
//  key. Update it in Settings." That view is reached from Downloads via its overflow
//  menu: Downloads → "Downloads Options" → "Client Management"
//  (`DownloadClientManagementView`) → "SABnzbd" → `SABnzbdClientHubView` → "Queue" →
//  `SABnzbdManagerView`. This suite drives that whole path rather than guessing at a
//  shortcut, because guessing wrong here would mean testing a screen the audit's
//  "user-visible" requirement doesn't actually describe.
//
//  ## How SABnzbd's unauthorized state is authentically triggered
//
//  `SABnzbdFixtureServer.setUnauthorized()` flips every subsequent response to a real
//  HTTP 401 — see that file's header comment for why 401/403 status codes, not a
//  `{"status":false}` 200 body, are the actual production trigger for
//  `SABnzbdAPIError.unauthorized` (`SABnzbdAPIClient.init`'s
//  `unauthorizedStatusCodes: [401, 403]`, applied in
//  `HTTPTransport.validate(_:data:path:urlString:)` before any body is decoded).
//
//  ## Determinism for "polling stopped"
//
//  `SABnzbdServiceManager.refresh()` calls `stopPolling()` and clears
//  `connectionError` synchronously, inside the same `catch SABnzbdAPIError.unauthorized`
//  branch — by the time the UI has actually repainted with the "SABnzbd Unavailable"
//  text, `pollingTask` is already `nil` and cancelled, so no further poll can ever
//  fire. `assertPollingStopped` below still doesn't take that on faith: it settles on
//  a stable request count (any queue/history requests already in flight when the 401
//  landed need a moment to arrive), then samples the fixture's request count
//  repeatedly for several seconds — comfortably longer than the manager's 4-second
//  polling interval — using bounded `waitForExistence` calls against an element that
//  never exists as the "tick" (never `sleep()`/`Thread.sleep`), asserting the count
//  after every tick.

import XCTest

final class SABnzbdUnauthorizedJourneyUITests: XCTestCase {
    private var fixtureServer: SABnzbdFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// Regressions this catches: H-05 (an unauthorized SABnzbd refresh leaving
    /// polling running and the invalid client reachable for mutations) surviving in
    /// the UI even after the manager-level fix — a stale client rendered as still
    /// "connected," a missing or generic error message that doesn't actually tell the
    /// user their key was rejected, polling that keeps hammering the server after the
    /// key is gone, or a "Pause All" action that still reaches the network with no
    /// active client.
    @MainActor
    func testUnauthorizedSABnzbdStopsPollingAndDisablesActions() async throws {
        let jobName = "Fixture NZB Alpha"
        let server = try await SABnzbdFixtureServer(queueJobName: jobName)
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = server.baseURL
        app.launch()

        // MARK: Step 1 — real connection: Downloads tab shows the seeded job.

        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(
            downloadsTab.waitForExistence(timeout: 15),
            "A launch with a configured SABnzbd service should reach the real tab UI, not the welcome screen."
        )
        downloadsTab.tap()

        let downloadsJobRow = app.staticTexts[jobName]
        XCTAssertTrue(
            downloadsJobRow.waitForExistence(in: app, timeout: 15),
            "The seeded queue job should appear in the Downloads tab once the real SABnzbd connection finishes — proves the connect path actually works before the unauthorized transition is tested."
        )
        XCTAssertTrue(
            server.requestCount(forMode: "queue") > 0,
            "The fixture server should have actually received a queue request over real HTTP — proves the job on screen came from the real client, not stale state."
        )

        // MARK: Navigate to the screen that actually surfaces SABnzbd's connection
        // state: Downloads → Downloads Options → Client Management → SABnzbd → Queue.

        let downloadsOptionsButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Downloads Options"))
            .firstMatch
        XCTAssertTrue(
            downloadsOptionsButton.waitForExistence(in: app, timeout: 10),
            "Downloads should show its overflow 'Downloads Options' menu once a client is configured."
        )
        downloadsOptionsButton.tap()

        let clientManagementButton = app.buttons["Client Management"]
        XCTAssertTrue(
            clientManagementButton.waitForExistence(timeout: 5),
            "The Downloads Options menu should offer 'Client Management'."
        )
        clientManagementButton.tap()

        let sabnzbdRowButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "SABnzbd"))
            .firstMatch
        XCTAssertTrue(
            sabnzbdRowButton.waitForExistence(in: app, timeout: 10),
            "Client Management should list the configured SABnzbd client."
        )
        sabnzbdRowButton.tap()

        let queueRowButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Queue"))
            .firstMatch
        XCTAssertTrue(
            queueRowButton.waitForExistence(in: app, timeout: 10),
            "The SABnzbd client hub should offer a 'Queue' destination — SABnzbdManagerView, where connectionError is actually rendered."
        )
        queueRowButton.tap()

        let managerJobRow = app.staticTexts[jobName]
        XCTAssertTrue(
            managerJobRow.waitForExistence(in: app, timeout: 15),
            "SABnzbdManagerView should show the same seeded job while the connection is healthy."
        )

        // MARK: Step 2 — flip the fixture to unauthorized.

        server.setUnauthorized()

        // MARK: Step 3 — wait for the app to notice (its next poll), and assert the
        // real user-visible consequence.

        // This is the load-bearing assertion: `SABnzbdManagerView`'s description is a
        // plain `Text(serviceManager.connectionError)`
        // (`SABnzbdServiceManager.swift:198`'s exact copy), which reliably surfaces as
        // a `staticText`. Waiting for it is also how this test waits for "the app to
        // notice its next poll" without guessing at a timing window.
        let rejectedKeyMessage = app.staticTexts["SABnzbd rejected the API key. Update it in Settings."]
        XCTAssertTrue(
            rejectedKeyMessage.waitForExistence(in: app, timeout: 20),
            "H-05 regression: the exact copy SABnzbdServiceManager.refresh() sets for an unauthorized response should be the text the user actually sees, not a generic or missing error."
        )

        // Corroborating assertion: the ContentUnavailableView's title is built from a
        // `Label(_:systemImage:)`, whose accessibility element type SwiftUI doesn't
        // guarantee is `.staticText` the way a plain `Text` is — so this matches any
        // element type by label rather than assuming `staticTexts`, since the point
        // here is only to confirm presence, not to interact with it.
        let unavailableTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "SABnzbd Unavailable"))
            .firstMatch
        XCTAssertTrue(
            unavailableTitle.waitForExistence(timeout: 5),
            "H-05 regression: once SABnzbd starts rejecting the API key, SABnzbdManagerView should show its 'SABnzbd Unavailable' state instead of silently continuing to look connected."
        )

        XCTAssertFalse(
            app.staticTexts[jobName].exists,
            "H-05 regression: the previously-connected job should not still be on screen once the client has been cleared after an unauthorized response."
        )

        // MARK: Step 4 — polling stopped.

        assertPollingStopped(server, app: app)

        // MARK: Step 5 — a reachable mutation (Pause All) produces no new request now
        // that the active client has been cleared.

        let sabActionsButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "SABnzbd Actions"))
            .firstMatch
        XCTAssertTrue(
            sabActionsButton.waitForExistence(in: app, timeout: 5),
            "SABnzbdManagerView should still offer its actions menu even while disconnected — the regression under test is that its actions must be inert, not that the menu itself disappears."
        )
        sabActionsButton.tap()

        let pauseAllButton = app.buttons["Pause All"]
        XCTAssertTrue(
            pauseAllButton.waitForExistence(timeout: 5),
            "The actions menu should offer 'Pause All' — the queue is nil while disconnected, so the menu can't be showing 'Resume All' instead."
        )
        let requestCountBeforeMutation = server.requestCount
        pauseAllButton.tap()

        // pauseAll() guards on `activeClient` before making any request
        // (`SABnzbdServiceManager.pauseAll()`), so a cleared client must produce zero
        // new requests — never a real request that then happens to fail.
        assertRequestCountStable(
            server,
            baseline: requestCountBeforeMutation,
            app: app,
            regression: "H-05 regression: 'Pause All' should guard on the cleared active client and issue no request at all once SABnzbd is unauthorized, not send a mutation through a stale client."
        )

        // MARK: Step 6 — the Downloads tab itself must say something.

        // The unified Downloads list is where a user actually lives. Before this was
        // surfaced there, a rejected API key simply made SABnzbd's jobs disappear from
        // that list with no explanation: the only screen that showed the error was
        // this manager view, four navigations away. Silent data loss is the worst
        // failure mode of the three, so it gets its own assertion.
        app.tabBars.buttons["Downloads"].tap()

        let downloadsWarning = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "SABnzbd Unavailable"))
            .firstMatch
        XCTAssertTrue(
            downloadsWarning.waitForExistence(timeout: 15),
            "The Downloads tab should tell the user SABnzbd is unavailable rather than silently dropping its jobs from the unified list."
        )
    }

    // MARK: - Helpers

    /// Waits for the fixture's request count to stop changing (letting any
    /// queue/history requests already in flight when the 401 landed finish
    /// arriving), then samples it repeatedly for several seconds — comfortably
    /// longer than `SABnzbdServiceManager`'s 4-second polling interval — asserting it
    /// never grows. Never `sleep()`/`Thread.sleep`: each "tick" is a bounded
    /// `waitForExistence` against an element that never exists, which waits close to
    /// its timeout via the run loop rather than blocking the thread.
    private func assertPollingStopped(
        _ server: SABnzbdFixtureServer,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let neverExists = app.staticTexts["__sabnzbd_polling_probe__"]

        var baseline = server.requestCount
        for _ in 0..<6 {
            _ = neverExists.waitForExistence(timeout: 0.5)
            let current = server.requestCount
            if current == baseline { break }
            baseline = current
        }

        for _ in 0..<12 {
            _ = neverExists.waitForExistence(timeout: 0.5)
            XCTAssertEqual(
                server.requestCount,
                baseline,
                "H-05 regression: SABnzbd polling should stop once the manager clears its client after an unauthorized response, but the fixture kept receiving requests.",
                file: file,
                line: line
            )
        }
    }

    /// Same bounded-tick technique as `assertPollingStopped`, scoped to confirming a
    /// single mutation attempt produced no new request rather than the ongoing
    /// polling loop.
    private func assertRequestCountStable(
        _ server: SABnzbdFixtureServer,
        baseline: Int,
        app: XCUIApplication,
        regression: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let neverExists = app.staticTexts["__sabnzbd_mutation_probe__"]
        for _ in 0..<6 {
            _ = neverExists.waitForExistence(timeout: 0.5)
            XCTAssertEqual(server.requestCount, baseline, regression, file: file, line: line)
        }
    }
}
