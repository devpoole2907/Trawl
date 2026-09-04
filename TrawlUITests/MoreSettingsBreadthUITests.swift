//
//  MoreSettingsBreadthUITests.swift
//  TrawlUITests
//
//  Focused breadth tests for MoreView and SettingsView. The existing navigation
//  smoke walk proves that their top-level hubs push a screen. These journeys take
//  separate fresh launches through four deeper, high-risk routes where a missing
//  environment dependency, a broken navigation closure, or a profile-specific
//  client can otherwise leave a user at a blank/unavailable screen.
//
//  Every service profile is seeded only through TrawlApp's DEBUG UI-test launch
//  hooks. The app then performs its normal SwiftData, Keychain, manager, client,
//  and SwiftUI navigation work against the existing loopback fixture servers.

import Foundation
import XCTest

final class MoreSettingsBreadthUITests: XCTestCase {
    private var sonarrServer: SonarrFixtureServer?
    private var radarrServer: RadarrFixtureServer?
    private var bazarrServer: BazarrUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        bazarrServer?.stop()
        bazarrServer = nil
        radarrServer?.stop()
        radarrServer = nil
        sonarrServer?.stop()
        sonarrServer = nil
    }

    /// Exercises the environment-backed navigation closures that SettingsView uses
    /// for configured Arr service rows. This is deliberately different from the
    /// Sonarr repoint journey: it starts at More → Settings, visits both supported
    /// media service settings screens, and proves their profiles reached the real
    /// managers before their configuration UI renders.
    @MainActor
    func testSettingsRoutesConfiguredSonarrAndRadarrProfiles() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Settings Route Series"}]"#)
        sonarrServer = sonarr
        let radarr = try await RadarrFixtureServer()
        radarrServer = radarr

        let app = launchApp(sonarr: sonarr, radarr: radarr)
        waitForConnectedMediaServices(in: app, seriesTitle: "Settings Route Series")
        openMoreSettings(in: app)

        let sonarrRow = firstButton(labelContaining: "Fixture Sonarr", in: app)
        XCTAssertTrue(
            tapWhenHittable(sonarrRow, in: app),
            "Settings should expose and open the configured Sonarr service row through its injected navigation closure."
        )
        XCTAssertTrue(
            app.navigationBars["Sonarr"].waitForExistence(timeout: 10),
            "The configured Sonarr row should push ArrServiceSettingsView titled Sonarr."
        )
        XCTAssertTrue(
            firstElement(labelContaining: "Fixture Sonarr", in: app).waitForExistence(in: app, timeout: 10),
            "Sonarr settings should render the synchronously seeded profile rather than an unconfigured placeholder."
        )
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                    "Fixture Sonarr",
                    "onnected"
                )
            ).firstMatch.waitForExistence(in: app, timeout: 5),
            "A configured Sonarr settings screen should expose its server as a tappable row - the row itself is the editor entry point, replacing the separate 'Edit Server' button that duplicated it."
        )
        XCTAssertTrue(
            sonarr.hasReceivedRequest(method: "GET", path: "/api/v3/system/status"),
            "The configured Sonarr screen must be backed by the production connection path, not just a seeded display name."
        )
        popBack(app, from: "Sonarr")

        let radarrRow = firstButton(labelContaining: "Fixture Radarr", in: app)
        XCTAssertTrue(
            tapWhenHittable(radarrRow, in: app),
            "Returning to Settings should preserve its Radarr navigation closure and configured service row."
        )
        XCTAssertTrue(
            app.navigationBars["Radarr"].waitForExistence(timeout: 10),
            "The configured Radarr row should push ArrServiceSettingsView titled Radarr."
        )
        XCTAssertTrue(
            firstElement(labelContaining: "Fixture Radarr", in: app).waitForExistence(in: app, timeout: 10),
            "Radarr settings should render the actual configured fixture profile."
        )
        XCTAssertTrue(
            radarr.hasReceivedRequest(method: "GET", path: "/api/v3/system/status"),
            "The configured Radarr screen must be backed by the production connection path."
        )
    }

    /// Covers More → Library Management → Subtitles → Language Profiles. The
    /// language-profile row is distinct data from the movie-detail subtitle card
    /// covered elsewhere, and this route is the normal administration path users
    /// take to change Bazarr's preferred-language rules.
    @MainActor
    func testLibraryManagementReachesBazarrLanguageProfilesWithServerData() async throws {
        let bazarr = try await BazarrUIFixtureServer(
            radarrMovieID: RadarrFixtureServer.movieId,
            radarrMovieTitle: RadarrFixtureServer.movieTitle
        )
        bazarrServer = bazarr

        let app = launchApp(bazarr: bazarr)
        // One call: Subtitles is a sidebar row on iPad and a Library Management row
        // on iPhone, and `openDestination` walks whichever route the chrome provides.
        XCTAssertTrue(
            openDestination(.subtitles, in: app),
            "Subtitles should be reachable after the seeded launch."
        )
        XCTAssertTrue(
            app.navigationBars["Subtitles"].waitForExistence(timeout: 10),
            "The subtitle-administration hub should render its navigation title."
        )

        let languageProfiles = firstButton(labelContaining: "Language Profiles", in: app)
        XCTAssertTrue(
            tapWhenHittable(languageProfiles, in: app),
            "The Subtitles hub should push Bazarr language-profile administration."
        )
        XCTAssertTrue(
            app.navigationBars["Language Profiles"].waitForExistence(timeout: 10),
            "The language-profile screen should render after navigating from the Subtitles hub."
        )
        XCTAssertTrue(
            app.staticTexts[BazarrUIFixtureServer.languageProfileName].waitForExistence(in: app, timeout: 15),
            "BazarrLanguageProfilesView should render the profile decoded from the loopback server, not an empty local placeholder."
        )
        XCTAssertTrue(
            bazarr.requests.contains { request in
                request.method == "GET"
                    && request.path == "/api/system/languages/profiles"
                    && request.headers["x-api-key"] == "uitest-api-key"
            },
            "The visible language profile must come from Bazarr's real authenticated profile request."
        )
    }

    /// Covers More → Integrations & Automation → Remote Path Mappings. This route fans
    /// one screen out to each connected Arr client concurrently, making it a useful
    /// assembly test for client injection and profile-aware routing rather than a
    /// simple title-only navigation check.
    @MainActor
    func testAutomationHubLoadsRemoteMappingsFromEveryConfiguredArrService() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Mappings Route Series"}]"#)
        sonarrServer = sonarr
        let radarr = try await RadarrFixtureServer()
        radarrServer = radarr

        let app = launchApp(sonarr: sonarr, radarr: radarr)
        waitForConnectedMediaServices(in: app, seriesTitle: "Mappings Route Series")
        XCTAssertTrue(
            openDestination(.remotePaths, in: app),
            "Remote Paths should be reachable after the seeded launch."
        )
        XCTAssertTrue(
            app.navigationBars["Remote Path Mappings"].waitForExistence(timeout: 10),
            "Remote Path Mappings should render after the automation hub route is selected."
        )
        XCTAssertTrue(
            app.staticTexts["No Remote Path Mappings"].waitForExistence(in: app, timeout: 15),
            "The empty state should appear only after the real mapping loads finish with the fixture's empty server responses."
        )
        XCTAssertTrue(
            sonarr.hasReceivedRequest(method: "GET", path: "/api/v3/remotepathmapping"),
            "Remote-path mapping loading must ask the connected Sonarr client, rather than using only local state."
        )
        XCTAssertTrue(
            radarr.hasReceivedRequest(method: "GET", path: "/api/v3/remotepathmapping"),
            "Remote-path mapping loading must also fan out to the connected Radarr client."
        )
    }

    /// Covers More → System → Health, including the production health fan-out and
    /// its visible all-clear state. Existing smoke coverage only opens System itself;
    /// this protects the child that reads all configured Arr clients together.
    @MainActor
    func testSystemHealthLoadsConnectedArrChecksAndRendersAllClear() async throws {
        let sonarr = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Health Route Series"}]"#)
        sonarrServer = sonarr
        let radarr = try await RadarrFixtureServer()
        radarrServer = radarr

        let app = launchApp(sonarr: sonarr, radarr: radarr)
        waitForConnectedMediaServices(in: app, seriesTitle: "Health Route Series")
        XCTAssertTrue(
            openDestination(.health, in: app),
            "Health should be reachable after the seeded launch."
        )
        XCTAssertTrue(app.navigationBars["Health"].waitForExistence(timeout: 10), "Health should render after navigation from System.")
        XCTAssertTrue(
            app.staticTexts["No Health Issues"].waitForExistence(in: app, timeout: 15),
            "An empty health response from the real connected services should render the all-clear state rather than a blank screen."
        )
        XCTAssertTrue(
            sonarr.hasReceivedRequest(method: "GET", path: "/api/v3/health"),
            "ArrHealthView should request Sonarr health through ArrServiceManager.loadHealth()."
        )
        XCTAssertTrue(
            radarr.hasReceivedRequest(method: "GET", path: "/api/v3/health"),
            "ArrHealthView should request Radarr health through ArrServiceManager.loadHealth()."
        )
    }

    /// Quality-profile duplication is an action on a specific existing profile,
    /// available from its row's swipe and context menus. The list toolbar should
    /// therefore expose the one global action - creating a new server-shaped
    /// profile - without a second, arbitrary "duplicate the first profile" button.
    @MainActor
    func testQualityProfilesShowsOnlyTheNewProfileToolbarAction() async throws {
        let radarr = try await RadarrFixtureServer()
        radarrServer = radarr

        let app = launchApp(radarr: radarr)
        XCTAssertTrue(openDestination(.movies, in: app), "Movies should be reachable while waiting for Radarr to connect.")
        XCTAssertTrue(
            app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(timeout: 15),
            "The Radarr library must load before its Quality Profiles administration route is exercised."
        )

        XCTAssertTrue(
            openDestination(.qualityProfiles, in: app),
            "Quality Profiles should be reachable after the seeded launch."
        )
        XCTAssertTrue(app.navigationBars["Quality Profiles"].waitForExistence(timeout: 10), "Quality Profiles should render after navigation.")
        XCTAssertTrue(
            app.staticTexts["HD-1080p"].waitForExistence(timeout: 15),
            "The quality-profile list should render the profile supplied by the connected Radarr server."
        )
        XCTAssertTrue(
            app.buttons["New Profile"].waitForExistence(timeout: 5),
            "The toolbar must retain the global New Profile action."
        )
        XCTAssertFalse(
            app.buttons["Duplicate Profile"].exists,
            "Duplicate Profile belongs to an individual row and must not also appear as a toolbar action."
        )
    }

    // MARK: - Launch and navigation helpers

    @MainActor
    private func launchApp(
        sonarr: SonarrFixtureServer? = nil,
        radarr: RadarrFixtureServer? = nil,
        bazarr: BazarrUIFixtureServer? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        if let sonarr {
            app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarr.baseURL
        }
        if let radarr {
            app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = radarr.baseURL
        }
        if let bazarr {
            app.launchEnvironment["TRAWL_UITEST_BAZARR_BASE_URL"] = bazarr.baseURL
        }
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A synchronously seeded test service should bypass the welcome gate and enter the real app chrome."
        )
        return app
    }

    /// Opens one of the hub destinations this suite walks the children of.
    ///
    /// These used to go through More, which is where all seven live on iPhone. On
    /// iPad More does not exist and the same seven are sidebar rows, so the caller
    /// names the hub it wants rather than the container it used to be filed under -
    /// the children below it are identical either way, which is what this suite is
    /// actually about.
    @MainActor
    private func openHub(_ hub: TrawlDestination, in app: XCUIApplication) {
        XCTAssertTrue(
            openDestination(hub, in: app),
            "The \(hub.title) hub should be reachable after the seeded launch."
        )
    }

    @MainActor
    private func openMoreSettings(in app: XCUIApplication) {
        openHub(.settings, in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings should render SettingsView.")
    }

    /// A configured profile exists before its asynchronous connection has completed.
    /// These destinations must exercise connected clients, so wait through the real
    /// Series and Movies lists first rather than racing their startup handshakes.
    @MainActor
    private func waitForConnectedMediaServices(in app: XCUIApplication, seriesTitle: String) {
        XCTAssertTrue(openDestination(.series, in: app), "Series should be reachable while waiting for the real Sonarr connection.")
        XCTAssertTrue(
            app.staticTexts[seriesTitle].waitForExistence(in: app, timeout: 15),
            "The seeded Sonarr title should appear before a route that requires connected Arr clients is exercised."
        )

        XCTAssertTrue(openDestination(.movies, in: app), "Movies should be reachable while waiting for the real Radarr connection.")
        XCTAssertTrue(
            app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(in: app, timeout: 15),
            "The seeded Radarr movie should appear before a route that requires connected Arr clients is exercised."
        )
    }

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func firstElement(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// XCTest can report a SwiftUI row as existing while a push transition or a
    /// below-the-fold List position still makes it unable to receive a touch. Retry
    /// only observable readiness and scroll the actual list when necessary; no
    /// artificial time delay or direct state change is involved.
    @discardableResult
    @MainActor
    private func tapWhenHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else if app.tables.firstMatch.exists {
                app.tables.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    @MainActor
    private func popBack(_ app: XCUIApplication, from title: String) {
        let navigationBar = app.navigationBars[title]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "Expected the \(title) navigation bar before returning.")
        let backButton = backButton(in: navigationBar)
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Expected a back control from \(title).")
        backButton.tap()
    }
}
