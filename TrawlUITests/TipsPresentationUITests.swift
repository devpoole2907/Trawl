//
//  TipsPresentationUITests.swift
//  TrawlUITests
//
//  Where the tips actually appear, and - just as importantly - where they do not.
//
//  Two halves, and the second is the one that protects the rest of this target.
//
//  Every other journey suite asserts against screens a tip could cover. A popover
//  anchored to a toolbar item swallows the taps aimed at that item, and an inline tip
//  pushes the first library row down past where a test expects it. So an ordinary
//  UI-test launch hides all tips, and `testOrdinaryLaunchesShowNoTips` is what keeps
//  that true: without it, adding a fifth tip could quietly break a dozen unrelated
//  suites in a way that reads as those screens being broken.
//
//  The first half opts back in, one tip at a time, through `TRAWL_UITEST_SHOW_TIP`.
//  That override forces a specific tip to display regardless of its rules, which is
//  what makes a presentation test possible at all: the quick-actions tip otherwise
//  needs three real detail openings, and the calendar tip a second launch, neither of
//  which says anything about whether the tip renders in the right place.
//
//  What these tests therefore cover is *placement and wiring* - that the tip is
//  attached to the surface it describes and reachable there. The rules themselves are
//  unit-tested in `TrawlTests/TrawlTipsTests.swift`, where they do not need a
//  simulator.

import XCTest

final class TipsPresentationUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?
    private var sonarrB: SonarrFixtureServer?
    private var sabnzbd: SABnzbdFixtureServer?
    private var qbittorrent: QBittorrentFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarr?.stop(); sonarr = nil
        sonarrB?.stop(); sonarrB = nil
        sabnzbd?.stop(); sabnzbd = nil
        qbittorrent?.stop(); qbittorrent = nil
    }

    // MARK: - The tips appear where they are anchored

    /// The Downloads title switcher tip, on a setup that actually has two queues.
    ///
    /// Both clients are seeded deliberately: the tip's own rule is that there is more
    /// than one destination to switch between, and a single-client setup must not see
    /// it. The `showTipsForTesting` override forces display past that rule, so the
    /// two-client fixture is what keeps this test honest about the surface it claims
    /// to cover - the popover has to have a title menu to attach to.
    @MainActor
    func testDownloadsTitleSwitcherTipAppearsOnTheTitleMenu() async throws {
        let app = try await launch(showing: "trawl.downloads.switch-queues.v1", withTwoDownloadClients: true)

        XCTAssertTrue(openDestination(.downloads, in: app), "Downloads should be reachable.")
        XCTAssertTrue(
            app.staticTexts["Switch download queues"].waitForExistence(in: app, timeout: 20),
            "The queue-switching tip should present on the Downloads title menu."
        )
    }

    /// The blended-library tip, on a genuinely blended library.
    ///
    /// Two Sonarr instances, through the existing `TRAWL_UITEST_SONARR_B_BASE_URL`
    /// hook - the same seeding `ArrBlendedLibraryJourneyUITests` uses. The tip is
    /// about what the per-server badges mean, so a one-server library would be the
    /// wrong screen to prove it renders on.
    @MainActor
    func testBlendedLibraryTipAppearsInlineAboveTheLibraryRows() async throws {
        let app = try await launch(showing: "trawl.arr.blended-library.v1", withTwoSonarrInstances: true)

        XCTAssertTrue(openDestination(.series, in: app), "Series should be reachable.")
        XCTAssertTrue(
            app.staticTexts["Your libraries are blended"].waitForExistence(in: app, timeout: 25),
            "The blended-library tip should present inline in the Series library."
        )
    }

    /// The quick-actions tip, in the same inline slot.
    ///
    /// Shown here on a *single* Sonarr instance on purpose. That is the case the
    /// `.firstAvailable` grouping exists for: a single-instance user can never qualify
    /// for the blended-library tip, and an ordered group would leave them never seeing
    /// this one either. If the group is ever changed to `.ordered`, this test is what
    /// notices.
    @MainActor
    func testQuickActionsTipAppearsForASingleInstanceLibrary() async throws {
        let app = try await launch(showing: "trawl.arr.library-quick-actions.v1")

        XCTAssertTrue(openDestination(.series, in: app), "Series should be reachable.")
        XCTAssertTrue(
            app.staticTexts["Quick library changes"].waitForExistence(in: app, timeout: 25),
            "The quick-actions tip should present for a single-instance library, which never qualifies for the blended-library tip."
        )
    }

    /// The Calendar subscribe tip, on the button it points at.
    @MainActor
    func testCalendarSubscribeTipAppearsOnTheSubscribeButton() async throws {
        let app = try await launch(showing: "trawl.calendar.subscribe.v1")

        XCTAssertTrue(openDestination(.series, in: app), "Series should be reachable.")
        XCTAssertTrue(
            app.staticTexts[Self.seriesTitle].waitForExistence(in: app, timeout: 20),
            "The library should connect before the Calendar is opened, since the tip only shows for a connected service."
        )
        XCTAssertTrue(tapWhenPossible(app.buttons["Calendar"], timeout: 15), "The Series toolbar should offer Calendar.")
        XCTAssertTrue(
            app.showsScreen(named: "Calendar", timeout: 20),
            "Calendar should present before its tip is looked for."
        )
        XCTAssertTrue(
            app.staticTexts["Add releases to Calendar"].waitForExistence(in: app, timeout: 20),
            "The subscribe tip should present on the Calendar's Subscribe button."
        )
    }

    // MARK: - And nowhere else

    /// The guard for every other suite in this target.
    ///
    /// Seeds the richest configuration these tips care about - two download clients
    /// and two Sonarr instances - so that every state rule is satisfied, then asserts
    /// that nothing appears anyway. Without the `TRAWL_UITEST_SHOW_TIP` override, a
    /// UI-test launch calls `Tips.hideAllTipsForTesting()` and stays silent.
    ///
    /// Deliberately checks all four titles rather than one: the failure this prevents
    /// is a *new* tip appearing over a screen some unrelated journey is asserting on,
    /// and that journey would fail somewhere confusing rather than here.
    @MainActor
    func testOrdinaryLaunchesShowNoTips() async throws {
        let app = try await launch(showing: nil, withTwoDownloadClients: true, withTwoSonarrInstances: true)

        XCTAssertTrue(openDestination(.downloads, in: app), "Downloads should be reachable.")
        assertNoTipIsShowing(in: app, at: "Downloads")

        XCTAssertTrue(openDestination(.series, in: app), "Series should be reachable.")
        XCTAssertTrue(
            app.staticTexts[Self.seriesTitle].waitForExistence(in: app, timeout: 25),
            "The library should finish loading, so this is a screen where a tip could have appeared."
        )
        assertNoTipIsShowing(in: app, at: "Series")
    }

    @MainActor
    private func assertNoTipIsShowing(
        in app: XCUIApplication,
        at screen: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for title in Self.everyTipTitle {
            XCTAssertFalse(
                app.staticTexts[title].exists,
                "A UI-test launch should hide every tip, but '\(title)' is showing on \(screen).",
                file: file,
                line: line
            )
        }
    }

    /// Every tip's title, so a newly added tip that forgets the testing hide is caught
    /// here rather than in whichever unrelated journey it happens to cover.
    private static let everyTipTitle = [
        "Switch download queues",
        "Your libraries are blended",
        "Quick library changes",
        "Add releases to Calendar"
    ]

    private static let seriesTitle = "Tip Fixture Series"

    // MARK: - Launch

    /// Launches with the fixtures a tip's rules need, and optionally forces one tip.
    ///
    /// `showing` carries the tip's own stable ID rather than a test-only name, so a
    /// test names a tip the way the datastore does. Passing `nil` is the ordinary
    /// launch every other suite gets.
    @MainActor
    private func launch(
        showing tipID: String?,
        withTwoDownloadClients: Bool = false,
        withTwoSonarrInstances: Bool = false
    ) async throws -> XCUIApplication {
        let primary = try await SonarrFixtureServer(
            seriesJSON: Self.seriesJSON,
            statusJSON: #"{"instanceName":"Fixture Sonarr"}"#
        )
        sonarr = primary

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = primary.baseURL
        // Detail screens fire a real TMDb lookup otherwise, which reaches the public
        // internet and sits out a 15s timeout.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"

        if let tipID {
            app.launchEnvironment["TRAWL_UITEST_SHOW_TIP"] = tipID
        }

        if withTwoSonarrInstances {
            let secondary = try await SonarrFixtureServer(
                seriesJSON: Self.secondarySeriesJSON,
                statusJSON: #"{"instanceName":"Alternate Sonarr"}"#
            )
            sonarrB = secondary
            app.launchEnvironment["TRAWL_UITEST_SONARR_B_BASE_URL"] = secondary.baseURL
        }

        if withTwoDownloadClients {
            let sab = try await SABnzbdFixtureServer(queueJobName: "Tip Fixture NZB")
            sabnzbd = sab
            app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = sab.baseURL

            let qbit = try await QBittorrentFixtureServer()
            qbittorrent = qbit
            app.launchEnvironment["TRAWL_UITEST_QBITTORRENT_BASE_URL"] = qbit.baseURL
        }

        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A seeded launch should reach the app chrome.")
        return app
    }

    private static let seriesJSON = #"""
    [
      {
        "id": 1,
        "title": "Tip Fixture Series",
        "sortTitle": "tip fixture series",
        "status": "continuing",
        "year": 2024,
        "monitored": true,
        "images": [],
        "statistics": {"seasonCount": 1, "episodeFileCount": 6, "episodeCount": 6,
                       "totalEpisodeCount": 6, "sizeOnDisk": 60000000000, "percentOfEpisodes": 100}
      }
    ]
    """#

    /// A different title on the second server, so the merged library genuinely has
    /// more than one instance contributing rather than one title on two servers.
    private static let secondarySeriesJSON = #"""
    [
      {
        "id": 2,
        "title": "Tip Fixture Alternate",
        "sortTitle": "tip fixture alternate",
        "status": "continuing",
        "year": 2023,
        "monitored": true,
        "images": [],
        "statistics": {"seasonCount": 2, "episodeFileCount": 12, "episodeCount": 12,
                       "totalEpisodeCount": 12, "sizeOnDisk": 90000000000, "percentOfEpisodes": 100}
      }
    ]
    """#
}
