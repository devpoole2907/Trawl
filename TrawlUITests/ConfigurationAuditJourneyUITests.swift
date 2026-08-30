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

        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(tapWhenHittable(moreTab, in: app, timeout: 20), "A configured Sonarr launch should reach the tab UI.")

        let systemRow = firstButton(labelContaining: "System", in: app)
        XCTAssertTrue(tapWhenHittable(systemRow, in: app, timeout: 10), "More should expose the System hub.")
        XCTAssertTrue(app.navigationBars["System"].waitForExistence(in: app, timeout: 10))

        let setupCheck = app.buttons["more-setup-check"]
        XCTAssertTrue(
            setupCheck.waitForExistence(in: app, timeout: 10),
            "The System hub should offer Setup Check."
        )

        // The audit runs on appear, so the row's own subtitle is the first place a
        // problem becomes visible - before the wizard is ever opened.
        let problemSubtitle = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "problem")
        ).firstMatch
        XCTAssertTrue(
            problemSubtitle.waitForExistence(in: app, timeout: 30),
            "A Sonarr with no download client and no indexer should make Setup Check report problems on the hub row itself."
        )

        XCTAssertTrue(tapWhenHittable(setupCheck, in: app, timeout: 10), "Setup Check should open the wizard.")
        XCTAssertTrue(
            app.navigationBars["Setup Check"].waitForExistence(in: app, timeout: 10),
            "Setup Check should present the configuration wizard."
        )

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

    // MARK: Helpers

    @MainActor
    private func launchApp(sonarr: SonarrFixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarr.baseURL
        // Without this a detail screen fires a real TMDb lookup and sits out a 15s
        // timeout against the public internet.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
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
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }
}
