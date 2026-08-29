//
//  ArrBlendedLibraryJourneyUITests.swift
//  TrawlUITests
//
//  Two Sonarr servers, one library. This drives the product decision that replaced
//  instance switching: the Series tab is the *union* of every configured server's
//  library, with each row naming the server it came from, rather than one server's
//  library at a time behind a picker.
//
//  ## What this used to be, and why it changed
//
//  This suite was `ArrInstanceSwitchJourneyUITests`, and it asserted the opposite:
//  that an "Instance" toolbar menu in `ArrMediaListView` switched
//  `ArrServiceManager.activeSonarrProfileID` and the Series tab then showed *only*
//  the selected instance's library. That menu is gone by design — a per-instance
//  library view is the thing an HD/4K pair is meant to remove, not something to
//  navigate between. Keeping the old assertions would have pinned the behaviour the
//  blended library exists to replace.
//
//  N-01 — the regression the original suite was written for, where
//  `ArrMediaListView`'s load task was keyed on the active profile ID and so a
//  recreated view model was never asked to load — is still covered. The fix (keying
//  on `ObjectIdentifier(viewModel)`) is pinned through the *edit-a-profile* route by
//  `ArrRepointJourneyUITests`, where a same-ID host repoint rotates `clientRevision`
//  and forces a new view model. What is no longer reachable is the second route into
//  that machinery, because there is no longer a UI that switches active instance
//  from the library screen.
//
//  ## Seeding two live instances
//
//  `SonarrConnectedJourneyUITests` and `ArrRepointJourneyUITests` establish why a UI
//  test can only reach the tab UI by seeding a real `ArrServiceProfile` before normal
//  startup: every setup sheet gates on a live `testConnection`, which a UI test
//  driving the UI alone cannot satisfy deterministically. This suite reuses that DEBUG
//  hook (`Trawl/TrawlApp.swift`, `seedUITestArrServiceIfRequested(into:)`), which seeds
//  a second Sonarr profile from `TRAWL_UITEST_SONARR_B_BASE_URL` alongside the
//  `TRAWL_UITEST_SONARR_BASE_URL` one. The two are inserted with fixed, distinct UUIDs
//  and saved strictly in order, which makes the first the older profile — and therefore
//  the default half of the pair, since an untiered pair is split by profile age.
//
//  ## Why both halves have to be asserted from real servers
//
//  A merged list that quietly dropped one server would still look like a working
//  library — that is the failure mode this whole feature has to be protected against.
//  So the union is asserted from both directions: both titles on screen, and both
//  fixture servers having actually received their own `/api/v3/series` request over
//  real HTTP. Neither assertion alone rules out a list fed from one server plus stale
//  or duplicated state.

import XCTest

final class ArrBlendedLibraryJourneyUITests: XCTestCase {
    private var serverOne: SonarrFixtureServer?
    private var serverTwo: SonarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        serverOne?.stop()
        serverOne = nil
        serverTwo?.stop()
        serverTwo = nil
    }

    /// Regressions this catches: the Series tab showing one server's library while
    /// presenting it as the whole thing (the exact bug the dual-instance unit suite
    /// caught in `loadLibraryItems`, here proven through the real UI); a server that
    /// is configured but never asked for its library; rows losing the badge that says
    /// which server they came from, which would make a merged list unreadable; and the
    /// per-instance library switcher coming back.
    @MainActor
    func testSeriesTabShowsBothServersLibrariesAsOneBadgedList() async throws {
        // The default server's series has files; the 4K server's has none. That is
        // what makes the badge fill testable: one row should read as downloaded and
        // the other as in-the-library-only.
        let seriesJSONOne = #"[{"id":1,"title":"Bluebird Chronicles","statistics":{"episodeCount":10,"episodeFileCount":10}}]"#
        // Deliberately the same library ID on the second server. Two *arr servers
        // number their libraries from the same sequence, so an implementation that
        // keys rows on the ID alone collapses these two distinct series into one row
        // — and this test then sees only one title.
        let seriesJSONTwo = #"[{"id":1,"title":"Redwood Files","statistics":{"episodeCount":8,"episodeFileCount":0}}]"#

        let one = try await SonarrFixtureServer(seriesJSON: seriesJSONOne)
        serverOne = one
        let two = try await SonarrFixtureServer(
            seriesJSON: seriesJSONTwo,
            statusJSON: #"{"instanceName":"Alternate Sonarr","version":"4.0.0"}"#
        )
        serverTwo = two

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = one.baseURL
        app.launchEnvironment["TRAWL_UITEST_SONARR_B_BASE_URL"] = two.baseURL
        app.launch()

        // MARK: Land on the Series tab.

        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(
            seriesTab.waitForExistence(timeout: 15),
            "A launch seeded with two configured Sonarr services should still reach the real tab UI."
        )
        seriesTab.tap()

        // MARK: Both servers' libraries, in one list.

        let seriesFromOne = app.staticTexts["Bluebird Chronicles"]
        XCTAssertTrue(
            seriesFromOne.waitForExistence(timeout: 15),
            "The Series tab should list the first server's library — if this fails, the baseline two-instance connect is broken, not the merge."
        )

        let seriesFromTwo = app.staticTexts["Redwood Files"]
        XCTAssertTrue(
            seriesFromTwo.waitForExistence(timeout: 15),
            "The Series tab should list the second server's library in the same list — regression: the blended library fell back to reading one instance, which shows half a library while claiming to be all of it."
        )
        XCTAssertTrue(
            seriesFromOne.exists,
            "Both servers' series must be on screen at once — regression: the list is still showing one instance at a time rather than the union."
        )

        // MARK: Each row says which server it came from.

        // The badges now carry availability in their accessibility label as well as
        // their fill, which is the only way this distinction is testable — and the
        // only way it reaches anyone who cannot see the fill.
        let defaultBadge = app.staticTexts["On Default, downloaded"]
        let fourKBadge = app.staticTexts["On 4K, not downloaded"]
        XCTAssertTrue(
            defaultBadge.waitForExistence(timeout: 10),
            "Rows from the older (default) server should carry its badge — a merged list without provenance cannot be read, since the same title can exist on both servers."
        )
        XCTAssertTrue(
            fourKBadge.waitForExistence(timeout: 10),
            "Rows from the 4K server should carry its badge, hollow because that server has no files — regression: the untiered pair was not split on launch, the badge stopped rendering, or availability stopped reaching the badge and every server now reads as downloaded."
        )

        // MARK: Both servers were actually asked, over real HTTP.

        XCTAssertTrue(
            one.hasReceivedRequest(method: "GET", path: "/api/v3/series"),
            "The first fixture server should have received its own series request — proves its half of the list came from it rather than from cache."
        )
        XCTAssertTrue(
            two.hasReceivedRequest(method: "GET", path: "/api/v3/series"),
            "The second fixture server should have received its own series request — regression: a configured server that is never asked for its library is exactly how half a library goes missing silently."
        )

        // MARK: The per-instance switcher must not come back.

        // Neither fixture title contains "Instance", so this cannot match a series
        // row: a NavigationLink renders as a button labelled with its own title, and
        // an earlier draft of this test caught its own fixtures instead of the menu.
        let instanceMenuButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Instance"))
            .firstMatch
        XCTAssertFalse(
            instanceMenuButton.exists,
            "ArrMediaListView must not offer an 'Instance' switcher: the library is the union of both servers, so a control that picks one of them contradicts the list it sits above."
        )
    }
}
