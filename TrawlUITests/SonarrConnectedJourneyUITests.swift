//
//  SonarrConnectedJourneyUITests.swift
//  TrawlUITests
//
//  The one end-to-end journey described in TRAWL_RELIABILITY_TEST_AUDIT.md: real
//  navigation, real view models, real SwiftData persistence, and real HTTP requests
//  against a deterministic loopback fixture server, seeding only external state.
//
//  `TrawlUITests.swift` documents why an unconfigured launch can only ever reach
//  WelcomeFlowView: every setup sheet requires a live `testConnection` to succeed
//  before it persists a profile, which a UI test has no deterministic way to satisfy
//  by driving the UI alone. This test gets past that wall a different way - it seeds
//  one real `ArrServiceProfile` (see `TrawlApp.seedUITestArrServiceIfRequested(into:)`,
//  gated behind the `TRAWL_UITEST_SONARR_BASE_URL` launch environment variable) and
//  points it at `SonarrFixtureServer`, a real loopback HTTP server this test process
//  hosts. From there the app's own startup, connect, and navigation code runs
//  untouched: `ContentView` sees the seeded profile and skips the welcome gate,
//  `ArrServiceManager.connectService(_:)` makes real requests to the fixture server,
//  and the Series tab renders whatever `SonarrAPIClient` actually decoded from those
//  responses.

import XCTest

final class SonarrConnectedJourneyUITests: XCTestCase {
    private var fixtureServer: SonarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixtureServer?.stop()
        fixtureServer = nil
    }

    /// Regressions this catches: the welcome gate no longer respecting a configured
    /// service (stuck on WelcomeFlowView forever), `ArrServiceManager.connectService`
    /// or `SonarrAPIClient` breaking against a real server, the Series tab failing to
    /// render a connected library, or `SonarrSeriesListView`/`SonarrSeriesRow` no
    /// longer surfacing a series' title as on-screen text.
    @MainActor
    func testConfiguredSonarrReachesSeriesTabWithRealData() async throws {
        let seriesJSON = #"[{"id":1,"title":"Fixture Series Alpha"}]"#
        let server = try await SonarrFixtureServer(seriesJSON: seriesJSON)
        fixtureServer = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        app.launch()

        // Past the welcome gate: seeding a real ArrServiceProfile before the app's
        // normal startup makes ContentView.hasConfiguredAnyService true immediately,
        // so launch should land directly in the tab UI instead of WelcomeFlowView.
        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(
            seriesTab.waitForExistence(timeout: 15),
            "A launch with a configured Sonarr service should reach the real tab UI, not the welcome screen."
        )
        XCTAssertFalse(
            app.staticTexts["Welcome to Trawl"].exists,
            "The welcome screen should not still be on screen once a service is configured."
        )

        seriesTab.tap()

        // The real connect path (ArrServiceManager.connectService -> SonarrAPIClient)
        // has to complete several real HTTP round-trips over loopback - system
        // status, quality profiles, root folders, tags, then the series library -
        // before the Series tab renders the real library instead of its
        // "Connecting to Sonarr" placeholder. Loopback is fast, but this allows
        // generous time rather than assuming near-instant completion.
        let seriesRow = app.staticTexts["Fixture Series Alpha"]
        XCTAssertTrue(
            seriesRow.waitForExistence(timeout: 15),
            "The seeded series' title should appear once the real Sonarr connection finishes and the library loads."
        )

        // Proves the title on screen came over real HTTP through the real client,
        // not from a stub: the fixture server itself has to have logged the request.
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v3/series"),
            "The fixture server should have actually received the series library request."
        )
    }
}
