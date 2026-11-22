//
//  ConfigurationAuditJourneyUITests.swift
//  TrawlUITests
//
//  The configuration audit reconciles facts that live in different services, and
//  its rules are unit-covered. What those tests cannot show is that the finding
//  reaches the user: the audit runs against live clients, and Setup Check is the
//  only place it surfaces. This walks the real route - More -> System -> Setup
//  Check - against a Sonarr that genuinely has no download client and no indexer.
//

import Foundation
import XCTest

final class ConfigurationAuditJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarr?.stop()
        sonarr = nil
    }

    /// The fixture answers `/api/v3/downloadclient` and `/api/v3/indexer` with an
    /// empty array - a real answer, not a failure - so the audit has two genuine
    /// problems to find. That distinction is the one the audit turns on: "asked, and
    /// there are none" is a fault, "could not ask" has to stay silent.
    @MainActor
    func testSetupCheckSurfacesAServerWithNoDownloadClient() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Audit Fixture Series"}]"#)
        self.sonarr = sonarr
        let app = launchApp(sonarr: sonarr)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        // The two chromes reach Setup Check differently, and deliberately so. On the
        // sidebar chrome the Setup Check *is* the screen - every other row of the
        // System hub was promoted, so a hub there would be one button opening a
        // sheet. On compact the hub is still how you get there, and the row carries
        // the finding before Setup Check is ever opened.
        //
        // Which is why compact stops at the *hub* rather than asking for
        // `.setupCheck`: `openDestination` walks a hub-behind-More destination all
        // the way to its screen, so naming Setup Check here would arrive with the hub
        // already gone - and the row's subtitle, asserted below, is half of what this
        // test is for. The row would still be *found* afterwards, because a TabView
        // keeps the tab it left mounted, but it is off screen and never becomes
        // hittable, so the tap fails several assertions away from the cause.
        if TrawlChrome.isSidebar {
            XCTAssertTrue(openDestination(.setupCheck, in: app), "Setup Check should be reachable.")
            XCTAssertTrue(
                app.navigationBars["Setup Check"].waitForExistence(timeout: 10),
                "The sidebar's Setup Check row should open Setup Check as the screen itself."
            )
        } else {
            XCTAssertTrue(openDestination(.system, in: app), "The System hub should be reachable.")
            let setupCheck = app.buttons["more-setup-check"]
            XCTAssertTrue(
                setupCheck.waitForExistence(in: app, timeout: 10),
                "The System hub should offer Setup Check."
            )

            // The audit runs on appear, so the row's own subtitle is the first place
            // a problem becomes visible - before Setup Check is ever opened.
            let problemSubtitle = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "problem")
            ).firstMatch
            XCTAssertTrue(
                problemSubtitle.waitForExistence(in: app, timeout: 30),
                "A Sonarr with no download client and no indexer should make Setup Check report problems on the hub row itself."
            )

            // Tapped at the row's centre on purpose. On an iPad the row is over a
            // thousand points wide and its middle is empty space beside the text; a
            // plain-styled button hit-tests only what it draws, so this exact tap used
            // to do nothing at all. `.contentShape` inside the label is what makes the
            // whole row the target, and this is the assertion that says so.
            XCTAssertTrue(tapWhenHittable(setupCheck, in: app, timeout: 10), "Setup Check should open.")
            XCTAssertTrue(
                app.navigationBars["Setup Check"].waitForExistence(timeout: 10),
                "The System row should push Setup Check, the same screen the sidebar shows."
            )
            XCTAssertFalse(
                app.buttons["Next"].exists,
                "Setup Check is a list on every chrome now, not the old step-by-step wizard."
            )
        }

        let downloadClientIssue = app.descendants(matching: .any)
            .matching(identifier: "configuration-issue-noDownloadClient")
            .firstMatch
        let issueHeadline = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "no download client")
        ).firstMatch
        XCTAssertTrue(
            downloadClientIssue.waitForExistence(in: app, timeout: 15) || issueHeadline.exists,
            "Setup Check must name the missing download client, which is the fault the fixture actually has."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["setup-check-summary"].waitForExistence(in: app, timeout: 10),
            "The list should open on a summary of where the check stands, not only when it is clean."
        )

        // The same finding screen on both chromes: pushed on a phone, selected into
        // the detail column beside the list.
        XCTAssertTrue(
            tapWhenHittable(downloadClientIssue, in: app, timeout: 10),
            "The finding's row should open it."
        )
        XCTAssertTrue(
            app.buttons["setup-check-fix"].waitForExistence(in: app, timeout: 10),
            "A problem Trawl can route to should offer its fix."
        )

        // The filter only exists beside a detail pane; the phone walks findings one at
        // a time instead. Asserted on the section headers, because they are what the
        // filter actually changes: under Problems neither of the other two sections may
        // be drawn, whatever this fixture happens to produce under All. Waited on, not
        // read once - the list animates between filters.
        if TrawlChrome.isSidebar {
            let problemsSegment = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH[c] %@", "Problems (")
            ).firstMatch
            XCTAssertTrue(
                tapWhenPossible(problemsSegment),
                "The Setup Check filter should offer a Problems segment."
            )
            XCTAssertTrue(
                downloadClientIssue.waitForExistence(in: app, timeout: 10)
                    || issueHeadline.waitForExistence(in: app, timeout: 5),
                "Filtering to Problems must keep the missing download client, which is one."
            )
            for otherSection in ["Could Not Verify (", "Worth Knowing ("] {
                let header = app.staticTexts.matching(
                    NSPredicate(format: "label BEGINSWITH[c] %@", otherSection)
                ).firstMatch
                XCTAssertTrue(
                    header.waitForNonExistence(timeout: 5),
                    "Filtering to Problems should hide the '\(otherSection)...' section."
                )
            }
        }
    }

    /// Ignoring a finding used to drop it for the rest of the session with no way to
    /// see it or take the decision back - `restoreDismissed()` existed and nothing
    /// called it. An ignored finding is now listed under Ignored and can be restored
    /// from its own screen, which this drives through the real buttons on whichever
    /// chrome is running.
    @MainActor
    func testIgnoredFindingIsListedAndCanBeRestored() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Audit Fixture Series"}]"#)
        self.sonarr = sonarr
        let app = launchApp(sonarr: sonarr)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        XCTAssertTrue(openDestination(.setupCheck, in: app), "Setup Check should be reachable.")

        let finding = app.descendants(matching: .any)
            .matching(identifier: "configuration-issue-noDownloadClient")
            .firstMatch
        XCTAssertTrue(finding.waitForExistence(in: app, timeout: 30), "The fixture's missing download client should be listed.")
        XCTAssertTrue(tapWhenHittable(finding, in: app, timeout: 10), "The finding's row should open it.")

        // The triage buttons are the last rows of the finding, which on a phone puts
        // them under the floating Notifications accessory: a tap there opens the
        // notifications sheet instead. Scrolled clear first, as a person would.
        let ignore = app.buttons["setup-check-ignore"]
        XCTAssertTrue(ignore.waitForExistence(in: app, timeout: 10), "An open finding should offer Ignore.")
        app.scroller(for: ignore).swipeUp()
        XCTAssertTrue(tapWhenHittable(ignore, in: app, timeout: 10), "Ignore should be tappable.")

        let ignoredHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Ignored (1)")).firstMatch
        XCTAssertTrue(
            ignoredHeader.waitForExistence(in: app, timeout: 10),
            "An ignored finding should be listed under Ignored rather than disappearing."
        )

        // Still a row, now under Ignored at the foot of the list, and still openable.
        app.scroller(for: finding).swipeUp()
        XCTAssertTrue(tapWhenHittable(finding, in: app, timeout: 10), "The ignored finding should still open.")
        let restore = app.buttons["setup-check-restore"]
        XCTAssertTrue(restore.waitForExistence(in: app, timeout: 10), "An ignored finding should offer Stop Ignoring.")
        app.scroller(for: restore).swipeUp()
        XCTAssertTrue(tapWhenHittable(restore, in: app, timeout: 10), "Stop Ignoring should be tappable.")
        XCTAssertTrue(
            ignore.waitForExistence(in: app, timeout: 10),
            "Once restored the finding is active again and offers Ignore."
        )

        if !TrawlChrome.isSidebar {
            XCTAssertTrue(
                tapWhenHittable(app.navigationBars.buttons["BackButton"], in: app, timeout: 10),
                "The finding should pop back to the list."
            )
        }
        XCTAssertTrue(
            ignoredHeader.waitForNonExistence(timeout: 10),
            "With nothing ignored the Ignored section should be gone."
        )
    }

    /// System wiring is persistent attention, not notification history. The live
    /// card therefore has to appear even when the notification log is empty and
    /// lead to the same Setup Check as the System hub.
    @MainActor
    func testNotificationsSurfaceSetupAttentionAndOpenTheWizard() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Audit Fixture Series"}]"#)
        self.sonarr = sonarr
        let app = launchApp(sonarr: sonarr)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        XCTAssertTrue(
            tapWhenHittable(app.buttons["Notifications"], in: app, timeout: 10),
            "The notification accessory should open the notifications sheet."
        )
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10))

        let setupAttention = app.buttons["notifications-setup-attention"]
        XCTAssertTrue(
            setupAttention.waitForExistence(in: app, timeout: 30),
            "A live setup fault should appear at the top of notifications even with no notification-history entry."
        )
        XCTAssertTrue(
            tapWhenHittable(setupAttention, in: app, timeout: 10),
            "Setup attention should open Setup Check."
        )
        XCTAssertTrue(
            app.navigationBars["Setup Check"].waitForExistence(in: app, timeout: 10),
            "The notifications card should present the shared Setup Check."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "no download client"))
                .firstMatch.waitForExistence(in: app, timeout: 15),
            "Setup Check opened from notifications should retain the live audit finding."
        )
    }

    /// Setup attention has one home: the notifications sheet's Alerts tab.
    ///
    /// There used to be a third surface - a card above Downloads, Requests, Subtitles
    /// and Search on the phone, and one floating above the sidebar's destination list
    /// on iPad and an unfolded Duo. It repeated what the sheet already says, so it is
    /// gone. This launch opts back in to the passive surfaces, which is what used to
    /// draw the card, so it proves the card is gone rather than just hidden in tests.
    @MainActor
    func testSetupAttentionLivesOnlyInTheNotificationsSheet() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Audit Fixture Series"}]"#)
        self.sonarr = sonarr
        let app = launchApp(sonarr: sonarr, showingContextualAttention: true)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        XCTAssertTrue(openDestination(.downloads, in: app), "Downloads should be reachable.")

        // The sheet's card first, so the audit has definitely finished: asserting
        // the banner's absence before anything could have drawn it would pass for
        // the wrong reason.
        // On the phone Downloads *is* the sheet, opened on its Downloads tab, so the
        // Alerts tab is one tap away; on the sidebar the bar opens it.
        let alertsTab = app.tabBars.buttons["Alerts"]
        if alertsTab.waitForExistence(timeout: 3) {
            XCTAssertTrue(tapWhenHittable(alertsTab, in: app, timeout: 5), "The sheet's Alerts tab should be selectable.")
        } else {
            XCTAssertTrue(
                tapWhenHittable(app.buttons["Notifications"], in: app, timeout: 10),
                "The notification bar should open the notifications sheet."
            )
        }
        XCTAssertTrue(
            app.buttons["notifications-setup-attention"].waitForExistence(in: app, timeout: 30),
            "The fixture's missing download client should be reported in the notifications sheet."
        )
        dismissNotificationsSheetIfPresent(in: app)
        XCTAssertTrue(
            app.buttons["notifications-setup-attention"].waitForNonExistence(timeout: 10),
            "The notifications sheet should close."
        )

        let banners = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "configuration-attention-"))
        XCTAssertEqual(
            banners.count, 0,
            "No screen, and not the sidebar, should carry a setup-attention card of its own."
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "other things need attention"))
                .firstMatch.exists,
            "The card's summary line should not be drawn anywhere outside the sheet."
        )
    }

    /// The guard for every other suite in this target, and the reason the opt-in
    /// above exists. Same fixture, same fault, ordinary UI-test launch: silence.
    @MainActor
    func testAnOrdinaryTestLaunchShowsNoContextualBanner() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Audit Fixture Series"}]"#)
        self.sonarr = sonarr
        let app = launchApp(sonarr: sonarr)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        XCTAssertTrue(openDestination(.downloads, in: app), "Downloads should be reachable.")

        // The System hub is visited first so the audit has definitely run: asserting
        // absence before anything could have appeared would pass for the wrong
        // reason.
        XCTAssertTrue(openDestination(.setupCheck, in: app), "Setup Check should be reachable.")
        // The wording differs by chrome and that is the point of visiting: the hub
        // row counts the problems ("2 problems found"), while Setup Check as the screen
        // states one ("Problem 1 of 2"). Either proves the audit has run, which is
        // all this step is here to establish before asserting on an absence.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "problem")).firstMatch
                .waitForExistence(in: app, timeout: 30),
            "The audit should have found the fixture's fault, so a banner had something to show."
        )
        XCTAssertTrue(openDestination(.downloads, in: app), "Downloads should be reachable again.")

        for topic in ["downloads", "search", "requests", "subtitles"] {
            XCTAssertFalse(
                app.buttons["configuration-attention-\(topic)"].exists,
                "A UI-test launch must not draw the \(topic) attention banner, or every suite that asserts on this screen's rows moves."
            )
        }
    }

    /// The nudge on the screen where the answer is already in front of the user.
    ///
    /// Prowlarr proxies every indexer it syncs under its own numeric id, so a Sonarr
    /// whose indexers point at `<host>/<id>/api` is one whose indexers are being
    /// managed somewhere Trawl has never been told about. The Indexers screen is
    /// where a person goes looking for them, so it is where it says so - and the
    /// nudge has to reach Setup Check, or it is a dead end that names a problem and
    /// offers nothing.
    @MainActor
    func testIndexersScreenOffersToAddAProwlarrItCanSee() async throws {
        let sonarr = try await SonarrFixtureServer(
            seriesJSON: #"[{"id":1,"title":"Audit Fixture Series"}]"#,
            indexersJSON: #"""
            [
              {"id":1,"name":"Fixture Indexer A","enableRss":true,"enableAutomaticSearch":true,"enableInteractiveSearch":true,
               "implementation":"Newznab","fields":[{"name":"baseUrl","value":"http://127.0.0.1:9696/1/api"}]},
              {"id":2,"name":"Fixture Indexer B","enableRss":true,"enableAutomaticSearch":true,"enableInteractiveSearch":true,
               "implementation":"Newznab","fields":[{"name":"baseUrl","value":"http://127.0.0.1:9696/2/api"}]}
            ]
            """#
        )
        self.sonarr = sonarr
        let app = launchApp(sonarr: sonarr)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        // Both chromes land on the screen itself. `openDestination` walks a
        // hub-behind-More destination through its hub - More, Integrations &
        // Automation, then Indexers - so by the time it returns there is no hub row
        // left to tap. Reaching for one anyway searched a screen that had already
        // moved on and failed with "the hub should offer Indexers", naming a hub that
        // was not on screen because this had already opened what it leads to.
        XCTAssertTrue(openDestination(.indexers, in: app), "Indexers should be reachable.")
        XCTAssertTrue(
            app.showsScreen(named: "Indexers", timeout: 15),
            "The Indexers screen should present."
        )

        XCTAssertTrue(
            app.staticTexts["Prowlarr Is Managing These"].waitForExistence(in: app, timeout: 20),
            "Indexers served through a `<host>/<id>/api` proxy path are Prowlarr's, and Trawl has no Prowlarr configured - the screen should say so."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "127.0.0.1:9696"))
                .firstMatch.exists,
            "The nudge should name the address it found, which is the part the user cannot work out from this screen."
        )

        let setItUp = app.buttons["Set It Up"]
        XCTAssertTrue(setItUp.waitForExistence(in: app, timeout: 10), "The nudge should offer to set it up.")
        setItUp.tap()

        // Opened about this finding: it comes up first - pushed on a phone, selected
        // beside the list - rather than the check at large.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "managing your indexers"))
                .firstMatch.waitForExistence(in: app, timeout: 30),
            "Setup Check should open on the same finding, so the nudge and the audit cannot disagree about it."
        )
        XCTAssertTrue(
            app.buttons["setup-check-ignore"].waitForExistence(in: app, timeout: 10),
            "The focused finding should be open, with its own actions, not just listed."
        )
    }

    // MARK: Helpers

    @MainActor
    private func launchApp(
        sonarr: SonarrFixtureServer,
        showingContextualAttention: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarr.baseURL
        // Without this a detail screen fires a real TMDb lookup and sits out a 15s
        // timeout against the public internet.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        if showingContextualAttention {
            app.launchEnvironment["TRAWL_UITEST_SHOW_ATTENTION"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

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
            // The list the row is actually in, not `collectionViews.firstMatch`: on
            // iPad the first collection view is the sidebar, and scrolling it leaves
            // the System hub - the screen this is looking at - exactly where it was.
            app.scroller(for: element).swipeUp()
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }
}
