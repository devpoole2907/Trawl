//
//  ArrUncoveredScreensJourneyUITests.swift
//  TrawlUITests
//
//  Two screens the full coverage run showed at a flat 0.0%: `ArrEventsView` and
//  `BazarrProvidersView`. Nothing had ever opened either, so a screen that failed to
//  decode its payload, or rendered blank, would look identical to one working - and
//  would only be discovered in use.
//
//  Each journey asserts real content decoded from the fixture's response, not merely
//  that a navigation bar appeared: a screen that pushes and then renders nothing is
//  exactly the failure worth catching here.
//

import Foundation
import XCTest

final class ArrUncoveredScreensJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?
    private var bazarr: BazarrUIFixtureServer?

    private static let logMessage = "Fixture log line for the Events screen"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarr?.stop()
        bazarr?.stop()
        sonarr = nil
        bazarr = nil
    }

    @MainActor
    func testEventsScreenRendersARealServerLogRecord() async throws {
        let logJSON = """
        {"page":1,"pageSize":50,"totalRecords":1,"records":[
          {"id":1,"time":"2026-08-30T12:00:00Z","level":"info","logger":"Fixture.Logger","message":"\(Self.logMessage)"}
        ]}
        """
        let sonarr = try await SonarrFixtureServer(
            seriesJSON: #"[{"id":1,"title":"Fixture Series"}]"#,
            logJSON: logJSON
        )
        self.sonarr = sonarr

        let app = launchApp(sonarrBaseURL: sonarr.baseURL, bazarrBaseURL: nil)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        XCTAssertTrue(openDestination(.logs, in: app), "Logs should be reachable.")

        let logs = firstButton(labelContaining: "Logs", in: app)
        XCTAssertTrue(tapWhenHittable(logs, in: app, timeout: 12), "System should expose Logs.")
        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(in: app, timeout: 10), "The Logs hub should render.")

        let events = firstButton(labelContaining: "Events", in: app)
        XCTAssertTrue(tapWhenHittable(events, in: app, timeout: 12), "Logs should expose the Arr Events screen.")
        XCTAssertTrue(app.navigationBars["Events"].waitForExistence(in: app, timeout: 10), "Events should render its own screen.")

        // The payload, not the chrome. A decode regression in ArrLogPage/ArrLogRecord
        // leaves this screen empty while still pushing correctly.
        XCTAssertTrue(
            app.staticTexts[Self.logMessage].waitForExistence(in: app, timeout: 15),
            "Events should render the log record Sonarr actually returned."
        )
        XCTAssertTrue(
            sonarr.hasReceivedRequest(method: "GET", path: "/api/v3/log"),
            "The screen must have fetched the log over real HTTP."
        )
    }

    @MainActor
    func testBazarrProvidersScreenRendersARealProvider() async throws {
        let bazarr = try await BazarrUIFixtureServer(radarrMovieID: 1, radarrMovieTitle: "Unused")
        self.bazarr = bazarr

        let app = launchApp(sonarrBaseURL: nil, bazarrBaseURL: bazarr.baseURL)

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Bazarr launch should reach the app chrome.")

        // Subtitles lives under Library Management rather than at the top of either
        // chrome. Each step asserts where it landed: a CONTAINS match reports a
        // successful tap even when it hits the wrong row, which is what made this
        // fail three steps later.
        XCTAssertTrue(openDestination(.subtitles, in: app), "Subtitles should be reachable.")

        let subtitles = firstButton(labelContaining: "Subtitles", in: app)
        XCTAssertTrue(tapWhenHittable(subtitles, in: app, timeout: 12), "Library Management should expose the Subtitles area for a configured Bazarr.")
        XCTAssertTrue(app.navigationBars["Subtitles"].waitForExistence(in: app, timeout: 10), "The Subtitles hub should render.")

        let providers = firstButton(labelContaining: "Providers", in: app)
        XCTAssertTrue(tapWhenHittable(providers, in: app, timeout: 12), "Subtitles should expose Bazarr's Providers screen.")
        XCTAssertTrue(app.navigationBars["Providers"].waitForExistence(in: app, timeout: 10), "Providers should render its own screen.")

        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", BazarrUIFixtureServer.providerDisplayName)
            ).firstMatch.waitForExistence(in: app, timeout: 15),
            "Providers should render the provider Bazarr actually returned, not an empty list."
        )
        // A provider Bazarr has enabled that the app's hardcoded catalog does not
        // know. It used to be `compactMap`ped away, so a provider the user had
        // deliberately enabled was invisible with nothing to explain the absence -
        // and the catalog necessarily lags Bazarr's own provider set, so this is the
        // ordinary case rather than an edge one.
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", BazarrUIFixtureServer.unknownProviderDisplayName)
            ).firstMatch.waitForExistence(in: app, timeout: 10),
            "An enabled provider missing from the catalog must still be listed, named from its key, rather than silently dropped."
        )

        XCTAssertTrue(
            bazarr.requests.contains { $0.method == "GET" && $0.path == "/api/providers" },
            "The screen must have fetched providers over real HTTP."
        )
    }

    // MARK: Helpers

    @MainActor
    private func launchApp(sonarrBaseURL: String?, bazarrBaseURL: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        if let sonarrBaseURL { app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarrBaseURL }
        if let bazarrBaseURL { app.launchEnvironment["TRAWL_UITEST_BAZARR_BASE_URL"] = bazarrBaseURL }
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
