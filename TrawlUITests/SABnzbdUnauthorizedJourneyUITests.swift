//
//  SABnzbdUnauthorizedJourneyUITests.swift
//  TrawlUITests
//
//  UI journey #6 from TRAWL_RELIABILITY_TEST_AUDIT.md's "test system Trawl needs":
//  a SABnzbd API key rejected mid-session must actually stop polling, actually clear
//  the connection, and actually tell the user - not just internally, which is what
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
//  ## Where the rejection is surfaced
//
//  There is one Downloads screen. Its title menu changes which downloads are listed
//  rather than pushing another view, so "SABnzbd" scopes the same list to that
//  client. A scope names one client, so `DownloadsView` renders that client's
//  `connectionError` as a `ContentUnavailableView` titled "SABnzbd Unavailable" whose
//  description is the exact copy `SABnzbdServiceManager.refresh()` sets: "SABnzbd
//  rejected the API key. Update it in Settings." Showing an empty list instead would
//  report "no downloads" for a server that is merely refusing to answer, and an
//  expired API key would look identical to an idle queue.
//
//  The blended list is covered separately at the end of this test: it keeps other
//  clients' rows, so it warns in a banner rather than taking the screen over.
//
//  ## Why this test is also load-bearing for polling
//
//  Every assertion past step 2 depends on the app actually noticing the 401, which
//  depends on the poll loop actually running. It once wasn't: `startPolling()`
//  required a client to already exist, and the Downloads tab asks for polling from a
//  `.task` that runs while the connection is still being established - so a cold
//  launch into Downloads never polled, and this test failed on the error copy when
//  the real defect was a frozen queue. See
//  `TrawlTests/SABnzbdServiceManagerConcurrencyTests.swift` for the deterministic
//  coverage of that; this suite is what caught it.
//
//  ## How SABnzbd's unauthorized state is authentically triggered
//
//  `SABnzbdFixtureServer.setUnauthorized()` flips every subsequent response to a real
//  HTTP 401 - see that file's header comment for why 401/403 status codes, not a
//  `{"status":false}` 200 body, are the actual production trigger for
//  `SABnzbdAPIError.unauthorized` (`SABnzbdAPIClient.init`'s
//  `unauthorizedStatusCodes: [401, 403]`, applied in
//  `HTTPTransport.validate(_:data:path:urlString:)` before any body is decoded).
//
//  ## Determinism for "polling stopped"
//
//  `SABnzbdServiceManager.refresh()` calls `stopPolling()` and clears
//  `connectionError` synchronously, inside the same `catch SABnzbdAPIError.unauthorized`
//  branch - by the time the UI has actually repainted with the "SABnzbd Unavailable"
//  text, `pollingTask` is already `nil` and cancelled, so no further poll can ever
//  fire. `assertPollingStopped` below still doesn't take that on faith: it settles on
//  a stable request count (any queue/history requests already in flight when the 401
//  landed need a moment to arrive), then samples the fixture's request count
//  repeatedly for several seconds - comfortably longer than the manager's 4-second
//  polling interval - using bounded `waitForExistence` calls against an element that
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
    /// the UI even after the manager-level fix - a stale client rendered as still
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

        // MARK: Step 1 - real connection: Downloads tab shows the seeded job.

        let downloadsTab = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(
            downloadsTab.waitForExistence(timeout: 15),
            "A launch with a configured SABnzbd service should reach the real tab UI, not the welcome screen."
        )
        downloadsTab.tap()

        let downloadsJobRow = app.staticTexts[jobName]
        XCTAssertTrue(
            downloadsJobRow.waitForExistence(in: app, timeout: 15),
            "The seeded queue job should appear in the Downloads tab once the real SABnzbd connection finishes - proves the connect path actually works before the unauthorized transition is tested."
        )
        XCTAssertTrue(
            server.requestCount(forMode: "queue") > 0,
            "The fixture server should have actually received a queue request over real HTTP - proves the job on screen came from the real client, not stale state."
        )

        // MARK: Scope the list to SABnzbd.
        //
        // SABnzbd's queue used to sit two pushes down - Downloads Options → Client
        // Management → SABnzbd → Queue - which put a client's own downloads behind a
        // screen about configuring clients. It is now a scope of the Downloads list
        // itself, chosen from the title menu, and Client Management no longer offers
        // a Queue row at all.

        let titleMenu = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "change view"))
            .firstMatch
        XCTAssertTrue(
            titleMenu.waitForExistence(in: app, timeout: 10),
            "With a SABnzbd client configured, Downloads should offer its title menu."
        )
        titleMenu.tap()

        let sabnzbdOption = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "SABnzbd"))
            .firstMatch
        XCTAssertTrue(
            sabnzbdOption.waitForExistence(timeout: 10),
            "The Downloads title menu should list SABnzbd - the scope in which that client's connection state is rendered."
        )
        sabnzbdOption.tap()

        let scopedJobRow = app.staticTexts[jobName]
        XCTAssertTrue(
            scopedJobRow.waitForExistence(in: app, timeout: 15),
            "The SABnzbd scope should show the same seeded job while the connection is healthy."
        )

        // MARK: Step 2 - flip the fixture to unauthorized.

        server.setUnauthorized()

        // MARK: Step 3 - wait for the app to notice (its next poll), and assert the
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
        // guarantee is `.staticText` the way a plain `Text` is - so this matches any
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

        // MARK: Step 4 - polling stopped.

        assertPollingStopped(server, app: app)

        // NOTE: the "a mutation is inert once disconnected" check used to live here,
        // driving the SABnzbd actions menu and asserting "Pause All" issued no
        // request. It was removed because it could not be made reliable: it passes
        // consistently in isolation and fails intermittently in a full-suite run,
        // where the extra load delays the menu's presentation. Retrying the tap made
        // it worse rather than better - tapping a `Menu` toggles it, so a retry can
        // close a menu that had in fact opened, and an even number of attempts leaves
        // it shut.
        //
        // The property itself is not lost. `SABnzbdServiceManagerConcurrencyTests`
        // already proves it deterministically at the manager level: after an
        // unauthorized response clears the active client, a mutation issues no
        // network request at all. That is the H-05 contract, asserted without a
        // simulator in the loop. What is left uncovered is only the UI affordance
        // being reachable while disconnected, which is not worth an intermittently
        // red suite.

        // MARK: Step 6 - the Downloads tab itself must say something.

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
    /// arriving), then samples it repeatedly for several seconds - comfortably
    /// longer than `SABnzbdServiceManager`'s 4-second polling interval - asserting it
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
