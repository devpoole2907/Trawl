//
//  ConfigurationAuditJourneyUITests.swift
//  TrawlUITests
//
//  The configuration audit reconciles facts that live in different services, and
//  its rules are unit-covered. What those tests cannot show is that the finding
//  reaches the user: the audit runs against live clients, and the wizard is the
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
        XCTAssertTrue(openDestination(.setupCheck, in: app), "Setup Check should be reachable.")

        // The two chromes reach the wizard differently, and deliberately so. On the
        // sidebar chrome the Setup Check *is* the screen - every other row of the
        // System hub was promoted, so a hub there would be one button opening a
        // sheet. On compact the hub is still how you get there, and the row carries
        // the finding before the wizard is ever opened.
        if TrawlChrome.isSidebar {
            XCTAssertTrue(
                app.navigationBars["Setup Check"].waitForExistence(timeout: 10),
                "The sidebar's Setup Check row should open the wizard as the screen itself."
            )
        } else {
            let setupCheck = app.buttons["more-setup-check"]
            XCTAssertTrue(
                setupCheck.waitForExistence(in: app, timeout: 10),
                "The System hub should offer Setup Check."
            )

            // The audit runs on appear, so the row's own subtitle is the first place
            // a problem becomes visible - before the wizard is ever opened.
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
            XCTAssertTrue(tapWhenHittable(setupCheck, in: app, timeout: 10), "Setup Check should open the wizard.")
            XCTAssertTrue(
                app.navigationBars["Setup Check"].waitForExistence(timeout: 10),
                "Setup Check should present the configuration wizard."
            )
        }

        let downloadClientIssue = app.descendants(matching: .any)
            .matching(identifier: "configuration-issue-noDownloadClient")
            .firstMatch
        let issueHeadline = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "no download client")
        ).firstMatch
        XCTAssertTrue(
            downloadClientIssue.exists || issueHeadline.waitForExistence(in: app, timeout: 15),
            "The wizard must name the missing download client, which is the fault the fixture actually has."
        )

        XCTAssertTrue(
            app.buttons["configuration-wizard-fix"].waitForExistence(in: app, timeout: 10),
            "A problem the wizard can route to should offer its fix action."
        )
    }

    /// System wiring is persistent attention, not notification history. The live
    /// card therefore has to appear even when the notification log is empty and
    /// lead to the same repair wizard as the System hub.
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
            "Setup attention should open the repair wizard."
        )
        XCTAssertTrue(
            app.navigationBars["Setup Check"].waitForExistence(in: app, timeout: 10),
            "The notifications card should present the shared configuration wizard."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "no download client"))
                .firstMatch.waitForExistence(in: app, timeout: 15),
            "The wizard opened from notifications should retain the live audit finding."
        )
    }

    /// The third surface: the screen the fault actually breaks.
    ///
    /// Downloads is chosen because the fixture's fault is a download-client one, so
    /// this also pins the topic filter - a banner that showed every finding on every
    /// screen would pass an assertion that only looked for *a* banner.
    ///
    /// The opt-in is deliberate and mirrors the discovery tips: a UI-test launch
    /// hides these banners, because a fixture answering `/downloadclient` with an
    /// empty array is a genuine fault on nearly every suite in this target, and a
    /// banner inset above the content would move the rows those suites assert on.
    @MainActor
    func testDownloadsShowsSetupAttentionForADownloadClientFault() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Audit Fixture Series"}]"#)
        self.sonarr = sonarr
        let app = launchApp(sonarr: sonarr, showingContextualAttention: true)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        XCTAssertTrue(openDestination(.downloads, in: app), "Downloads should be reachable.")

        let banner = app.buttons["configuration-attention-downloads"]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 40),
            "A Sonarr with no download client should say so on the screen whose queue will therefore stay empty."
        )
        let headline = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "no download client"))
            .firstMatch
        XCTAssertTrue(
            headline.waitForExistence(timeout: 15),
            "The banner should name the finding, not just that something is wrong."
        )

        // The headline, not the button. The banner is a top safe-area inset, so its
        // button reports a frame that starts at the window's top edge and takes in
        // the navigation bar - a tap at its centre lands on the title, not on the
        // banner, and the run reports a banner that does not respond.
        XCTAssertTrue(headline.isHittable, "The banner text should be on screen and tappable.")
        headline.tap()
        XCTAssertTrue(
            app.navigationBars["Setup Check"].waitForExistence(in: app, timeout: 10),
            "A contextual banner leads to the same wizard as the System hub, not a second repair flow."
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
        // row counts the problems ("2 problems found"), while the wizard-as-screen
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
    /// nudge has to reach the wizard, or it is a dead end that names a problem and
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
        XCTAssertTrue(openDestination(.indexers, in: app), "Indexers should be reachable.")

        let indexersRow = firstButton(labelContaining: "Indexers", in: app)
        XCTAssertTrue(indexersRow.waitForExistence(in: app, timeout: 15), "The hub should offer Indexers.")
        XCTAssertTrue(tapWhenHittable(indexersRow, in: app, timeout: 10), "Indexers should open.")
        XCTAssertTrue(
            app.navigationBars["Indexers"].waitForExistence(in: app, timeout: 15),
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

        XCTAssertTrue(
            app.navigationBars["Setup Check"].waitForExistence(in: app, timeout: 30),
            "Setting it up should lead to the same wizard the System hub opens, not a second flow."
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "managing your indexers"))
                .firstMatch.waitForExistence(in: app, timeout: 15),
            "The wizard should carry the same finding, so the nudge and the audit cannot disagree about it."
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
