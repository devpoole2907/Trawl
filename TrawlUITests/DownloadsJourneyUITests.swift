//
//  DownloadsJourneyUITests.swift
//  TrawlUITests
//
//  UI journey #2 from TRAWL_RELIABILITY_TEST_AUDIT.md's "test system Trawl needs":
//  pause/resume/delete a torrent through the real UI and verify both the on-screen
//  state and the recorded server-side mutation. `Trawl/Views/TorrentListView.swift`
//  is 1,145 executable lines at 0% coverage - the app's core surface - and reaching
//  any of it needs a connected qBittorrent, which every setup sheet can only reach
//  through a live `testConnection` a UI test can't satisfy deterministically by
//  driving the UI alone (see `TrawlUITests.swift`).
//
//  This suite gets past that wall the same way `SonarrConnectedJourneyUITests` and
//  `SABnzbdUnauthorizedJourneyUITests` do for their services: it seeds one real
//  `ServerProfile` plus its Keychain-stored username/password
//  (`TrawlApp.seedUITestQBittorrentServiceIfRequested(into:)`, gated behind
//  `TRAWL_UITEST_QBITTORRENT_BASE_URL`) before `ContentView` ever evaluates the
//  welcome-vs-tabs gate, pointed at `QBittorrentFixtureServer`, a real loopback HTTP
//  server this test process hosts. From there the app's own startup, connect, and
//  navigation code runs untouched: `ContentView.initializeServices()`,
//  `QBittorrentClientFactory.makeAndLogin`, `AuthService`, and `QBittorrentAPIClient`
//  all make real HTTP requests against the fixture server.
//
//  ## Why this drives `DownloadsView`, not `TorrentListView` directly
//
//  `RootTab.downloads` (the app's default startup tab -
//  `ContentView.tabContent`/`AppStorage("startupTab")`) renders
//  `Trawl/DownloadsStack/DownloadsView.swift`, which is the unified list a real user
//  actually lands on. `TorrentListView` itself is one navigation deeper, behind
//  Downloads' overflow menu ("Downloads Options" → "Client Management" → qBittorrent
//  → torrents), and its row/action code (`.contextMenu`, `.swipeActions` for
//  pause/resume/recheck/delete) is functionally identical to `DownloadsView`'s own
//  torrent row - both ultimately call the same `TorrentService`/`QBittorrentAPIClient`
//  methods this suite asserts against. Testing the mutation through the screen a user
//  actually starts on is the more faithful journey, and it's also the one the audit's
//  "pause/resume/delete a torrent" line describes without requiring an extra,
//  unnecessary navigation hop first.
//
//  ## The real UI affordance (traced from `DownloadsView.swift`, not guessed)
//
//  Each torrent row (`DownloadsView.row(for:)`, the `.torrent` case) is a
//  `NavigationLink` carrying `TorrentRowView`, with:
//  - `.swipeActions(edge: .leading, allowsFullSwipe: true)` offering "Resume" (tint
//    .green) when paused/stopped, else "Pause" (tint .orange) - revealed by swiping
//    the row *right*.
//  - `.swipeActions(edge: .trailing, allowsFullSwipe: false)` offering "Delete"
//    (role: .destructive) and "Recheck" - revealed by swiping the row *left*.
//  - `.contextMenu` offering the same actions, for a long-press alternative.
//
//  This suite drives the swipe actions: XCTest's built-in `swipeLeft()`/`swipeRight()`
//  reliably trigger `List` row swipe-action reveals without the long-press timing
//  fragility a context menu would add.
//
//  `TorrentRowView`'s `TorrentSummaryView` carries `.accessibilityElement(children:
//  .combine)`, merging the torrent's name, status badge, percentage, and size into one
//  label - so this suite matches the row with `label CONTAINS[c] <name>`, never an
//  exact `staticTexts` lookup, per the established pattern in this test target.
//
//  ## Why pausing moves the row out of Active
//
//  `DownloadsViewModel.isWaiting(_:)` routes `.stoppedDL` (qBittorrent v5's paused-
//  while-downloading state - `LiveCapturedShapeContractTests.realTorrentObjectDecodes`)
//  to the Queue segment, not Active. `QBittorrentFixtureServer` is stateful: a real
//  `POST /api/v2/torrents/stop` flips what its `/api/v2/sync/maindata` reports next, so
//  once the app's next poll lands, the row should actually disappear from Active and
//  reappear in Queue - proof the mutation changed real server state, not just a local
//  optimistic flag.

import XCTest

final class DownloadsJourneyUITests: XCTestCase {
    private var fixtureServer: QBittorrentFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// Regressions this catches: the welcome gate no longer respecting a configured
    /// qBittorrent service, `ContentView.initializeServices()` or
    /// `QBittorrentAPIClient` breaking against a real (v5-shaped) server, the
    /// Downloads tab failing to render a connected torrent, a pause/resume/delete
    /// action that only changes local state without ever reaching the server, the v5
    /// `/stop`/`/start` paths regressing back to v4's `/pause`/`/resume`, or the delete
    /// confirmation alert wiring `deleteFiles` to the wrong button.
    @MainActor
    func testPauseResumeDeleteTorrentThroughRealUIAndServer() async throws {
        let server = try await QBittorrentFixtureServer()
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_QBITTORRENT_BASE_URL"] = server.baseURL
        // This journey never opens TorrentDetailView, but a real TMDb lookup on a
        // detail screen sits out a 15s timeout with no fixture - set unconditionally
        // so this suite can never regress into that trap if the journey grows to
        // cover the detail screen later.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        // MARK: Step 1 - real connection: Downloads tab shows the seeded torrent.

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A launch with a configured qBittorrent service should reach the real app chrome, not the welcome screen."
        )
        XCTAssertTrue(openDestination(.downloads, in: app), "The Downloads queue should be reachable.")

        let activeRow = torrentRow(in: app, named: server.name)
        XCTAssertTrue(
            activeRow.waitForExistence(in: app, timeout: 15),
            "The seeded torrent should appear in the Downloads tab's Active segment once the real qBittorrent connection finishes and the first sync lands."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v2/sync/maindata"),
            "The fixture server should have actually received a sync/maindata request over real HTTP - proves the row on screen came from the real client, not stale state."
        )

        // MARK: Step 2 - pause through the real UI (leading swipe action).

        let pausedBeforeSwipe = server.hasReceivedRequest(
            method: "POST", path: "/api/v2/torrents/stop", bodyContains: server.hash
        )
        XCTAssertFalse(pausedBeforeSwipe, "Sanity check: no pause request should have been sent yet.")

        let pauseSwiped = performSwipeAction(
            on: activeRow,
            direction: .right,
            buttonLabel: "Pause",
            app: app
        ) {
            server.hasReceivedRequest(method: "POST", path: "/api/v2/torrents/stop", bodyContains: server.hash)
        }
        XCTAssertTrue(
            pauseSwiped,
            "Swiping the torrent row right should reveal and let a 'Pause' action be tapped (DownloadsView.swift's leading swipeActions) - regression: the swipe action disappeared or the row is no longer swipeable."
        )

        // This is the load-bearing assertion: proves the pause actually reached the
        // server, at the exact qBittorrent v5 path with the torrent's own hash in the
        // body - not just a local state flip in TorrentService/SyncService.
        XCTAssertTrue(
            waitForCondition(app: app, timeout: 10) {
                server.hasReceivedRequest(method: "POST", path: "/api/v2/torrents/stop", bodyContains: server.hash)
            },
            "Pausing the torrent should send POST /api/v2/torrents/stop with the torrent's hash in the body (QBittorrentAPIClient.pauseTorrents) - regression: the pause action stopped reaching the real server, or v5's /stop path regressed back to v4's /pause."
        )

        // MARK: Corroborating UI-state assertion - the row should actually move,
        // proving the server's state (not just a client-side flag) changed: a paused
        // torrent is `stoppedDL`, which `DownloadsViewModel.isWaiting` routes to the
        // Queue segment, not Active.

        // `exists` is deliberately not used here. `DownloadsView` keeps its `List`
        // mounted even when the current segment filters down to nothing, so the
        // segment-bar search field does not lose keyboard focus - which leaves a
        // filtered-out row in the accessibility tree, invisible and untappable but
        // still `exists == true`. The empty-state copy is the positive proof, and
        // `isHittable` is the property that tracks what the user can actually reach.
        XCTAssertTrue(
            app.staticTexts["No Active Downloads"].waitForExistence(timeout: 10),
            "Once the only torrent is paused, the Active segment should show its empty state."
        )
        waitForUnreachable(activeRow, timeout: 10)
        XCTAssertFalse(
            activeRow.isHittable,
            "Once paused, the torrent's state becomes stoppedDL, which DownloadsViewModel.isWaiting routes to the Queue segment - it should no longer be reachable under Active."
        )

        selectSegment("Queue", app: app)
        let queueRow = torrentRow(in: app, named: server.name)
        XCTAssertTrue(
            queueRow.waitForExistence(in: app, timeout: 10),
            "The paused torrent should now be listed in the Queue segment - regression: the fixture's next sync/maindata poll didn't actually report the stoppedDL state, or DownloadsViewModel stopped routing it there."
        )

        // MARK: Step 3 - resume through the real UI.

        let resumeSwiped = performSwipeAction(
            on: queueRow,
            direction: .right,
            buttonLabel: "Resume",
            app: app
        ) {
            server.hasReceivedRequest(method: "POST", path: "/api/v2/torrents/start", bodyContains: server.hash)
        }
        XCTAssertTrue(
            resumeSwiped,
            "Swiping the paused row right should reveal and let a 'Resume' action be tapped - regression: DownloadsView's isPaused(_:) branch stopped recognizing stoppedDL, so the leading action never switched from 'Pause' to 'Resume'."
        )
        XCTAssertTrue(
            waitForCondition(app: app, timeout: 10) {
                server.hasReceivedRequest(method: "POST", path: "/api/v2/torrents/start", bodyContains: server.hash)
            },
            "Resuming the torrent should send POST /api/v2/torrents/start with the torrent's hash in the body (QBittorrentAPIClient.resumeTorrents) - regression: the resume action stopped reaching the real server, or v5's /start path regressed back to v4's /resume."
        )

        selectSegment("Active", app: app)
        let activeRowAgain = torrentRow(in: app, named: server.name)
        XCTAssertTrue(
            activeRowAgain.waitForExistence(in: app, timeout: 10),
            "Once resumed, the torrent's state goes back to downloading, which should route it back into the Active segment."
        )

        // MARK: Step 4 - delete through the real UI, including the confirmation flow.

        let deleteSwiped = performSwipeAction(
            on: activeRowAgain,
            direction: .left,
            buttonLabel: "Delete",
            app: app
        ) {
            // Trailing swipe actions here use allowsFullSwipe: false, so unlike the
            // leading actions above, a full swipe can never auto-trigger this one -
            // the confirmation alert always has to appear first.
            false
        }
        XCTAssertTrue(
            deleteSwiped,
            "Swiping the torrent row left should reveal and let a 'Delete' action be tapped (DownloadsView.swift's trailing swipeActions)."
        )

        // Confirmation flow: DownloadsView presents a "Delete Torrent?" alert with
        // three choices before anything is actually sent to the server.
        let deleteTorrentOnlyButton = app.buttons["Delete Torrent Only"]
        XCTAssertTrue(
            deleteTorrentOnlyButton.waitForExistence(timeout: 5),
            "Tapping 'Delete' should present the confirmation alert (DownloadsView's 'Delete Torrent?' alert, offering 'Delete and Remove Files' / 'Delete Torrent Only' / 'Cancel') before anything is sent to the server - regression: the alert stopped appearing, or delete now fires immediately without confirmation."
        )
        XCTAssertTrue(
            app.buttons["Delete and Remove Files"].exists && app.buttons["Cancel"].exists,
            "The delete confirmation alert should offer all three of its documented choices."
        )
        deleteTorrentOnlyButton.tap()

        XCTAssertTrue(
            waitForCondition(app: app, timeout: 10) {
                server.hasReceivedRequest(method: "POST", path: "/api/v2/torrents/delete", bodyContains: server.hash)
            },
            "Confirming deletion should send POST /api/v2/torrents/delete with the torrent's hash in the body (QBittorrentAPIClient.deleteTorrents) - regression: the delete action stopped reaching the real server."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "POST", path: "/api/v2/torrents/delete", bodyContains: "deleteFiles=false"),
            "'Delete Torrent Only' should send deleteFiles=false - regression: DownloadsView.deletePendingTorrent(deleteFiles:) mismapped which alert button sends which value."
        )

        // Scoped to the list rather than `app.buttons`, which would also match the
        // success banner InAppNotificationCenter raises after a delete - that banner
        // names the torrent, so an app-wide match would fail on the confirmation of
        // the very thing being asserted.
        // Asserted as the *positive* empty state the user actually sees, rather than
        // by trying to prove the row is absent.
        //
        // `DownloadsView` keeps its `List` mounted even when the segment filters down
        // to nothing, so removed rows stay in the accessibility tree indefinitely:
        // `exists` stays true, `count` still reports them, and `isHittable` throws
        // outright ("Activation point invalid...") because their frames have
        // collapsed to zero. None of those three can distinguish "gone" from
        // "mounted but invisible". The empty state can, and it is what the user sees.
        //
        // The load-bearing proof that the delete really happened is the recorded
        // server request asserted just above, not this.
        XCTAssertTrue(
            app.staticTexts["No Active Downloads"].waitForExistence(timeout: 15),
            "Once the only torrent is deleted and the next sync lands, Downloads should show its empty state - regression: the deletion never reached the torrent list, or a full_update with no torrents key stopped clearing local state."
        )
    }

    /// Waits for an element to stop being *reachable*, which is not the same as it
    /// ceasing to exist.
    ///
    /// `DownloadsView` keeps its `List` mounted even when the current segment filters
    /// down to nothing, so a filtered-out row stays in the accessibility tree with
    /// `exists == true` while being invisible and untappable. `isHittable` is the
    /// property that tracks what the user can actually see and reach. Built only from
    /// `waitForExistence` ticks - no sleeps.
    private func waitForUnreachable(_ element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.isHittable && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }

    // MARK: - Helpers

    /// The torrent's row, as whichever element the running chrome renders it as.
    ///
    /// A `Cell` on iPad and a `Button` on iPhone. Beside a detail column the row is
    /// not a `NavigationLink` at all - the List owns the tap and the selection drives
    /// the column - so it stops surfacing as a button, and a query for one reports
    /// that the seeded torrent never arrived.
    private func torrentRow(in app: XCUIApplication, named name: String) -> XCUIElement {
        let holdsName = NSPredicate(format: "label CONTAINS[c] %@", name)
        return TrawlChrome.isSidebar
            ? app.cells.containing(holdsName).firstMatch
            : app.buttons.matching(holdsName).firstMatch
    }

    private enum SwipeDirection {
        case left
        case right
    }

    /// Reveals a row's swipe action and taps it, retrying the swipe itself a bounded
    /// number of times. A tap dispatched on a button that `exists` but isn't yet
    /// `isHittable` (still mid-reveal animation) is silently dropped - bitten
    /// elsewhere in this suite - so this only taps once the button reports hittable,
    /// and re-swipes if it doesn't appear in time.
    ///
    /// `alreadySucceeded` covers the leading actions' `allowsFullSwipe: true`: a fast,
    /// full-length `swipeRight()` can auto-trigger the first action without the button
    /// ever becoming individually tappable, so this treats the fixture having already
    /// recorded the expected request as success too, rather than looping uselessly
    /// waiting for a button that already did its job.
    @MainActor
    private func performSwipeAction(
        on row: XCUIElement,
        direction: SwipeDirection,
        buttonLabel: String,
        app: XCUIApplication,
        maxAttempts: Int = 4,
        alreadySucceeded: () -> Bool
    ) -> Bool {
        let button = app.buttons[buttonLabel]

        for _ in 0..<maxAttempts {
            if alreadySucceeded() { return true }
            if button.exists && button.isHittable {
                button.tap()
                return true
            }
            guard row.exists else { break }
            switch direction {
            case .left: revealSwipeActions(.trailing, on: row)
            case .right: revealSwipeActions(.leading, on: row)
            }
            _ = button.waitForExistence(timeout: 2)
        }

        if alreadySucceeded() { return true }
        if button.exists && button.isHittable {
            button.tap()
            return true
        }
        return false
    }

    /// Taps a `TrawlSegmentBar` segment by its title (`TrawlSegmentBarButton`'s label
    /// is exactly `item.title`, e.g. "Active"/"Queue"), retrying until the button is
    /// hittable rather than assuming it always is on the first try.
    private func selectSegment(_ title: String, app: XCUIApplication) {
        let button = app.buttons[title]
        for _ in 0..<6 {
            if button.exists && button.isHittable {
                button.tap()
                return
            }
            _ = button.waitForExistence(timeout: 1)
        }
        if button.exists { button.tap() }
    }

    /// Polls `condition` until it goes true or `timeout` elapses. Never `sleep()` /
    /// `Thread.sleep`: each tick is a bounded `waitForExistence` against an element
    /// that never exists, matching the technique already established in
    /// `SABnzbdUnauthorizedJourneyUITests`.
    private func waitForCondition(app: XCUIApplication, timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let neverExists = app.staticTexts["__qbittorrent_fixture_probe__"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = neverExists.waitForExistence(timeout: 0.25)
        }
        return condition()
    }

    /// Same bounded-tick technique as `waitForCondition`, scoped to waiting for an
    /// element to leave the accessibility tree rather than for an arbitrary condition.
    /// Mirrors `ArrRepointJourneyUITests.waitForDisappearance`.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }
}
