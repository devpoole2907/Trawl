//
//  BazarrLinkedAppsJourneyUITests.swift
//  TrawlUITests
//
//  `BazarrLinkedApplicationsView` measured 0% coverage: nothing had ever rendered
//  it. It was then rewritten from a scope bar that swapped one server's settings in
//  and out, to one section per Bazarr with both loaded up front - a change made to
//  stop the page hitching, and to close the window in which a save could write one
//  server's host and API key into the other.
//
//  Neither property is visible from a unit test, because both are about what the
//  screen shows for *which* server. The two fixtures are deliberately given
//  different answers: server A has Sonarr linked and Radarr not, server B the
//  reverse. A section reporting the wrong server therefore fails rather than
//  coincidentally agreeing.
//

import Foundation
import XCTest

final class BazarrLinkedAppsJourneyUITests: XCTestCase {
    private var bazarrA: BazarrUIFixtureServer?
    private var bazarrB: BazarrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        bazarrA?.stop()
        bazarrB?.stop()
        bazarrA = nil
        bazarrB = nil
    }

    @MainActor
    func testLinkedAppsShowsEveryBazarrWithItsOwnSettings() async throws {
        // A: Sonarr linked, Radarr not. B: the mirror image.
        let serverA = try await BazarrUIFixtureServer(
            radarrMovieID: 1,
            radarrMovieTitle: "Unused",
            linkedSonarrHost: "10.0.0.11"
        )
        let serverB = try await BazarrUIFixtureServer(
            radarrMovieID: 1,
            radarrMovieTitle: "Unused",
            linkedRadarrHost: "10.0.0.22"
        )
        bazarrA = serverA
        bazarrB = serverB

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_BAZARR_BASE_URL"] = serverA.baseURL
        app.launchEnvironment["TRAWL_UITEST_BAZARR_B_BASE_URL"] = serverB.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        openLinkedApps(in: app)

        // One section per server, named by the server. With a single Bazarr the
        // header reads "Bazarr"; with a pair each carries its own name, which is the
        // only thing telling the two sets of connection settings apart.
        XCTAssertTrue(
            app.staticTexts["Fixture Bazarr"].waitForExistence(in: app, timeout: 15),
            "With two Bazarr servers, Linked Apps should show a section for the first one, named after it."
        )
        XCTAssertTrue(
            app.staticTexts["Alternate Bazarr"].waitForExistence(in: app, timeout: 10),
            "The second Bazarr must be on the same page - it used to be reachable only by switching a scope bar, which is what made the page hitch."
        )

        // Both servers' settings are on screen at once, so the two hosts prove each
        // section rendered its own server rather than whichever responded last.
        XCTAssertTrue(
            app.staticTexts["http://10.0.0.11:8989"].waitForExistence(in: app, timeout: 10),
            "The first Bazarr's linked Sonarr host should render in its own section."
        )
        XCTAssertTrue(
            app.staticTexts["http://10.0.0.22:7878"].waitForExistence(in: app, timeout: 10),
            "The second Bazarr's linked Radarr host should render in its own section - if one server's settings answered for both, this is what fails."
        )

        // Each server was asked for its own settings: one request per Bazarr, and
        // neither answered on the other's behalf.
        XCTAssertTrue(
            serverA.requests.contains { $0.method == "GET" && $0.path == "/api/system/settings" },
            "The first Bazarr should have been asked for its settings over real HTTP."
        )
        XCTAssertTrue(
            serverB.requests.contains { $0.method == "GET" && $0.path == "/api/system/settings" },
            "The second Bazarr should have been asked for its own settings, not had the first's reused."
        )
    }

    /// The rows are the editor entry points, and the sheet has to seed from the
    /// server whose section was tapped. This is the credential-crossing risk the
    /// rewrite was meant to remove, so it is worth asserting rather than assuming.
    @MainActor
    func testEditingFromASectionSeedsThatServersSettings() async throws {
        let serverA = try await BazarrUIFixtureServer(
            radarrMovieID: 1,
            radarrMovieTitle: "Unused",
            linkedSonarrHost: "10.0.0.11"
        )
        let serverB = try await BazarrUIFixtureServer(
            radarrMovieID: 1,
            radarrMovieTitle: "Unused",
            linkedRadarrHost: "10.0.0.22"
        )
        bazarrA = serverA
        bazarrB = serverB

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_BAZARR_BASE_URL"] = serverA.baseURL
        app.launchEnvironment["TRAWL_UITEST_BAZARR_B_BASE_URL"] = serverB.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        openLinkedApps(in: app)
        XCTAssertTrue(app.staticTexts["http://10.0.0.22:7878"].waitForExistence(in: app, timeout: 15))

        // The second server's Radarr row, identified by the host only it reports.
        let secondServersRadarrRow = app.buttons
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "10.0.0.22"))
            .firstMatch
        XCTAssertTrue(
            tapWhenHittable(secondServersRadarrRow, in: app, timeout: 10),
            "A linked-app row should open its editor."
        )

        // Seeded from the tapped section's server: the host shown is the one that
        // section reported, not the other server's.
        let hostField = app.textFields
            .containing(NSPredicate(format: "value CONTAINS[c] %@", "10.0.0.22"))
            .firstMatch
        XCTAssertTrue(
            hostField.waitForExistence(in: app, timeout: 10),
            "The editor must seed from the server whose section was tapped - seeding from the other Bazarr is how one server's credentials get saved into the other."
        )
    }

    // MARK: Helpers

    @MainActor
    private func openLinkedApps(in app: XCUIApplication) {
        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(tapWhenHittable(moreTab, in: app, timeout: 20), "A seeded Bazarr launch should reach the tab UI.")

        // The real route is three pushes deep, and each step is asserted rather than
        // matched loosely: "Automation & Clients", "Linked Applications" and
        // "Subtitle Sync" all appear as searchable entries too, so a bare CONTAINS
        // match can land on the wrong one and still report a successful tap.
        let automation = firstButton(labelContaining: "Automation & Clients", in: app)
        XCTAssertTrue(
            tapWhenHittable(automation, in: app, timeout: 12),
            "More should expose the Automation & Clients hub."
        )

        let linkedApplications = firstButton(labelContaining: "Linked Applications", in: app)
        XCTAssertTrue(
            tapWhenHittable(linkedApplications, in: app, timeout: 12),
            "Automation & Clients should expose the Linked Applications hub."
        )
        XCTAssertTrue(
            app.navigationBars["Linked Applications"].waitForExistence(in: app, timeout: 10),
            "The Linked Applications hub should render."
        )

        // Bazarr's links are presented as an integration relationship - "Subtitle
        // Sync" - not under a heading containing the word Bazarr. That naming is a
        // fair part of why this screen had never been opened by a test.
        let subtitleSync = firstButton(labelContaining: "Subtitle Sync", in: app)
        XCTAssertTrue(
            tapWhenHittable(subtitleSync, in: app, timeout: 12),
            "Linked Applications should expose Subtitle Sync for a configured Bazarr."
        )
        XCTAssertTrue(
            app.navigationBars["Linked Apps"].waitForExistence(in: app, timeout: 10),
            "Subtitle Sync should push Bazarr's Linked Apps screen."
        )
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
