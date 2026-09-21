//
//  SABnzbdBackgroundMonitorJourneyUITests.swift
//  TrawlUITests
//
//  Drives the Monitor action end to end against a real loopback SABnzbd that
//  actually drains.
//
//  **This suite cannot witness a running session on the Simulator, and that is
//  not a gap in the test.** `BGTaskScheduler` refuses every submission there
//  with `BGTaskSchedulerErrorCodeUnavailable`; Apple's own header lists "The app
//  is running on Simulator which doesn't support background processing" as a
//  cause. So the property pinned here is the one that is true on both:
//  **whatever the scheduler actually did, the app's recorded state matches it.**
//  A refusal must be reported in words the person can act on and must leave no
//  session behind; an acceptance must leave the row offering Stop Monitoring.
//
//  That refusal path is not Simulator-only trivia - it is exactly what a device
//  does when Background App Refresh is switched off for Trawl.
//
//  Where the scheduler does accept (a real device), the journey carries on and
//  checks the thing the feature exists for: that SABnzbd is still being polled
//  once Trawl is off screen. The system's progress UI itself is out of process
//  and unreadable by XCTest - the boundary `WidgetInstalledProcessUITests`
//  documents for widget bodies - so it is captured as an attachment for the eye.

import XCTest

final class SABnzbdBackgroundMonitorJourneyUITests: XCTestCase {
    private var fixtureServer: SABnzbdFixtureServer?

    override func tearDown() async throws {
        fixtureServer?.stop()
        fixtureServer = nil
        try await super.tearDown()
    }

    @MainActor
    func testMonitoringAQueuedJobLeavesTheAppAgreeingWithTheScheduler() async throws {
        let jobName = "Fixture NZB Alpha"
        // Slow enough that the job outlasts the whole journey. At 20 MB a poll
        // the fixture drained to zero in 29 polls, which a device reached before
        // the Stop step - the session had already finished by itself, correctly,
        // and the stop path went untested. 5 MB a poll leaves ample headroom.
        let server = try await SABnzbdFixtureServer(queueJobName: jobName, drainsPerPoll: 5)
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = server.baseURL
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A launch with a configured SABnzbd service should reach the real app chrome."
        )
        XCTAssertTrue(openDestination(.downloads, in: app), "The Downloads queue should be reachable.")

        let jobRow = app.staticTexts[jobName]
        XCTAssertTrue(
            jobRow.waitForExistence(in: app, timeout: 20),
            "The seeded SABnzbd job should reach the Downloads list before anything is monitored."
        )
        capture(app, "1-downloads-row")

        // Presses go to the row *inside the list*, not to `app.staticTexts[name]`.
        // Starting a session raises a banner carrying the job's name as its
        // message, so the unscoped query matches twice the moment the feature
        // works and the press fails with "Multiple matching elements found".
        let rowTarget = app.collectionViews.staticTexts[jobName].firstMatch

        // MARK: The action is offered on a queued SABnzbd job.

        rowTarget.press(forDuration: 1.2)

        let monitorAction = app.buttons["Monitor in Background"]
        XCTAssertTrue(
            monitorAction.waitForExistence(timeout: 10),
            "A queued SABnzbd job should offer background monitoring. Torrent rows deliberately do not."
        )
        capture(app, "2-context-menu")
        monitorAction.tap()

        // MARK: The attempt resolves one way or the other, and says which.

        let startedBanner = app.staticTexts["Monitoring"]
        let failureBanner = app.staticTexts["Couldn't Monitor Download"]
        let resolved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in startedBanner.exists || failureBanner.exists },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [resolved], timeout: 15), .completed,
            "Tapping Monitor should report an outcome rather than appearing to do nothing."
        )
        capture(app, "3-after-start")

        guard !failureBanner.exists else {
            try assertRefusalIsHonest(in: app, jobRow: rowTarget)
            return
        }

        // MARK: Accepted - the row records the session.

        rowTarget.press(forDuration: 1.2)
        let stopAction = app.buttons["Stop Monitoring"]
        XCTAssertTrue(
            stopAction.waitForExistence(timeout: 10),
            "Once a session is running, its row should offer Stop Monitoring instead of starting a second one."
        )
        capture(app, "4-stop-offered")
        dismissMenu(in: app)

        // MARK: Background the app; the session has to keep polling without it.

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "The app should reach the background.")

        // Waiting on the fixture's own request count is an explicit barrier, not
        // a sleep: a session that died on backgrounding fails here rather than
        // producing a pretty screenshot of nothing.
        for round in 1...3 {
            let target = server.requestCount(forMode: "queue") + 2
            let polled = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in server.requestCount(forMode: "queue") >= target },
                object: nil
            )
            XCTAssertEqual(
                XCTWaiter().wait(for: [polled], timeout: 40), .completed,
                "A backgrounded monitor session should still be polling SABnzbd (round \(round))."
            )

            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "5-backgrounded-\(round)"
            screen.lifetime = .keepAlways
            add(screen)
        }

        // MARK: Coming back to Trawl ends the session, and the row says so.
        //
        // Measured on an iPhone 15 Pro Max (iOS 27.0): polling survived every
        // background round above and then stopped within a second of the app
        // returning to the foreground, with the app resumed rather than
        // relaunched (one `Launch` at t=0, an `Activate` at t≈60). The system
        // appears to end a continued-processing task once its app is frontmost
        // again, which is coherent - the task exists to carry work *past*
        // backgrounding, and a visible Downloads tab polls on its own anyway.
        //
        // Whatever the cause, the invariant the app owes the person is the same
        // one this suite pins throughout: the row's affordance matches whether a
        // session is actually running. A row still offering Stop for a session
        // that has ended would lock monitoring out for the rest of the launch.
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The app should come back to the foreground.")

        // Retried, because a long press issued while the app is still settling
        // after `activate()` is swallowed and opens nothing - which reads as
        // "the action is missing" and invites a conclusion about the session
        // that the screenshot flatly contradicts.
        XCTAssertTrue(
            openMenu(on: rowTarget, in: app),
            "The row's context menu should open once Trawl is back in the foreground."
        )
        capture(app, "6-menu-on-return")

        let offersStart = app.buttons["Monitor in Background"].exists
        let offersStop = app.buttons["Stop Monitoring"].exists
        XCTAssertNotEqual(
            offersStart, offersStop,
            "The row should offer exactly one of Monitor/Stop - never both, never neither."
        )

        // The session survives coming back to the foreground, so Stop is the
        // expected branch; the other is taken only if the download finished
        // while the app was away, which the slow drain above makes unlikely.
        guard offersStop else {
            dismissMenu(in: app)
            return
        }

        // MARK: Stopping releases the session.

        app.buttons["Stop Monitoring"].tap()
        XCTAssertTrue(
            openMenu(on: rowTarget, in: app),
            "The row's context menu should still open after stopping."
        )
        XCTAssertTrue(
            app.buttons["Monitor in Background"].exists,
            "Stopping should release the session so another can be started."
        )
        XCTAssertFalse(
            app.buttons["Stop Monitoring"].exists,
            "A stopped session should not still be offering to stop."
        )
        dismissMenu(in: app)

        // The system's half of a deliberate stop: the task is completed with
        // success, so no red "Task failed" card is left behind. Captured rather
        // than asserted - that card belongs to the system, not to Trawl, and
        // XCTest cannot read it.
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 10)
        let afterStop = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        afterStop.name = "7-after-stop"
        afterStop.lifetime = .keepAlways
        add(afterStop)
    }

    /// Long-presses until the row's context menu is actually up, and reports
    /// whether it ever appeared.
    @MainActor
    private func openMenu(on row: XCUIElement, in app: XCUIApplication, attempts: Int = 5) -> Bool {
        for _ in 1...attempts {
            guard row.waitForExistence(timeout: 5) else { continue }
            row.press(forDuration: 1.2)
            let appeared = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.buttons["Monitor in Background"].exists || app.buttons["Stop Monitoring"].exists
                },
                object: nil
            )
            if XCTWaiter().wait(for: [appeared], timeout: 5) == .completed { return true }
        }
        return false
    }

    /// A refusal has to be legible and has to leave nothing behind. Both halves
    /// have been wrong in this feature: the raw error read "The operation
    /// couldn't be completed. (BGTaskSchedulerErrorDomain error 1.)", and a
    /// session recorded before the submit threw would have locked every row out
    /// of monitoring for the rest of the launch.
    @MainActor
    private func assertRefusalIsHonest(in app: XCUIApplication, jobRow: XCUIElement) throws {
        let shown = visibleText(in: app)
        XCTAssertFalse(
            shown.contains("BGTaskSchedulerErrorDomain"),
            "A refusal should be translated into something the person can act on, not the raw error domain. On screen: \(shown)"
        )

        jobRow.press(forDuration: 1.2)
        XCTAssertTrue(
            app.buttons["Monitor in Background"].waitForExistence(timeout: 10),
            "A refused submission must leave no session behind - the row should still offer to start one."
        )
        XCTAssertFalse(
            app.buttons["Stop Monitoring"].exists,
            "A refused submission must not record a session the scheduler never accepted."
        )
        capture(app, "4-refusal-leaves-no-session")
        dismissMenu(in: app)
    }

    /// A context menu on iOS 26 is a popover, so it is dismissed by its own
    /// backdrop; tapping the app would land on a menu item.
    @MainActor
    private func dismissMenu(in app: XCUIApplication) {
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if dismissRegion.waitForExistence(timeout: 5) {
            dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.05)).tap()
        }
    }

    /// Every label currently on screen, so a failure carries the banner's own
    /// wording instead of sending the reader to the device log.
    @MainActor
    private func visibleText(in app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex
            .prefix(40)
            .map(\.label)
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "monitor-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
