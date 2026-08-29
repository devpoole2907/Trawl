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
//  the selected instance's library. That menu is gone by design - a per-instance
//  library view is the thing an HD/4K pair is meant to remove, not something to
//  navigate between. Keeping the old assertions would have pinned the behaviour the
//  blended library exists to replace.
//
//  N-01 - the regression the original suite was written for, where
//  `ArrMediaListView`'s load task was keyed on the active profile ID and so a
//  recreated view model was never asked to load - is still covered. The fix (keying
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
//  and saved strictly in order, which makes the first the older profile - and therefore
//  the default half of the pair, since an untiered pair is split by profile age.
//
//  ## Why both halves have to be asserted from real servers
//
//  A merged list that quietly dropped one server would still look like a working
//  library - that is the failure mode this whole feature has to be protected against.
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
        // - and this test then sees only one title.
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
            "The Series tab should list the first server's library - if this fails, the baseline two-instance connect is broken, not the merge."
        )

        let seriesFromTwo = app.staticTexts["Redwood Files"]
        XCTAssertTrue(
            seriesFromTwo.waitForExistence(timeout: 15),
            "The Series tab should list the second server's library in the same list - regression: the blended library fell back to reading one instance, which shows half a library while claiming to be all of it."
        )
        XCTAssertTrue(
            seriesFromOne.exists,
            "Both servers' series must be on screen at once - regression: the list is still showing one instance at a time rather than the union."
        )

        // MARK: Each row says which server it came from.

        // The badges now carry availability in their accessibility label as well as
        // their fill, which is the only way this distinction is testable - and the
        // only way it reaches anyone who cannot see the fill.
        let defaultBadge = app.staticTexts["On Default, downloaded"]
        let fourKBadge = app.staticTexts["On 4K, not downloaded"]
        XCTAssertTrue(
            defaultBadge.waitForExistence(timeout: 10),
            "Rows from the older (default) server should carry its badge - a merged list without provenance cannot be read, since the same title can exist on both servers."
        )
        XCTAssertTrue(
            fourKBadge.waitForExistence(timeout: 10),
            "Rows from the 4K server should carry its badge, hollow because that server has no files - regression: the untiered pair was not split on launch, the badge stopped rendering, or availability stopped reaching the badge and every server now reads as downloaded."
        )

        // MARK: Both servers were actually asked, over real HTTP.

        XCTAssertTrue(
            one.hasReceivedRequest(method: "GET", path: "/api/v3/series"),
            "The first fixture server should have received its own series request - proves its half of the list came from it rather than from cache."
        )
        XCTAssertTrue(
            two.hasReceivedRequest(method: "GET", path: "/api/v3/series"),
            "The second fixture server should have received its own series request - regression: a configured server that is never asked for its library is exactly how half a library goes missing silently."
        )

        // MARK: The title menu filters the union - it does not switch servers.

        // An earlier draft offered a per-instance *switcher*: it changed which
        // server was "active", so the list showed one server at a time while
        // presenting itself as the library. That concept is gone from the app.
        // What replaced it is a filter over the union - it opens on everything,
        // and narrowing is an explicit choice the same menu undoes. The
        // distinction is the whole point, so it is asserted rather than assumed:
        // a filter that defaulted to one server would be the old switcher wearing
        // a new name.
        let titleMenu = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "change view"))
            .firstMatch
        XCTAssertTrue(
            titleMenu.waitForExistence(timeout: 10),
            "With two Sonarr servers configured, the Series tab should offer its title menu."
        )
        XCTAssertTrue(
            titleMenu.label.hasPrefix("Series"),
            "The menu must open on the union rather than on a server: a tab that starts filtered shows half a library while looking like all of it."
        )

        // Narrow to the second server. Its own series stays; the first server's goes.
        titleMenu.tap()
        let alternateOption = app.buttons["Alternate Sonarr"]
        XCTAssertTrue(
            alternateOption.waitForExistence(timeout: 10),
            "The title menu should list each configured server by the name the user gave it - 'Default'/'4K' names a tier, not a server."
        )
        alternateOption.tap()

        XCTAssertTrue(
            waitForDisappearance(of: seriesFromOne, timeout: 10),
            "Filtering to the second server should drop the first server's series - regression: the menu changes its own label but the library ignores the filter."
        )
        XCTAssertTrue(
            seriesFromTwo.exists,
            "Filtering to a server must keep that server's own series."
        )

        // And back: the filter has to be undoable from the same control, or a
        // user who narrows the library has no way to widen it again.
        let narrowedMenu = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "change view"))
            .firstMatch
        XCTAssertTrue(
            narrowedMenu.label.hasPrefix("Alternate Sonarr"),
            "While filtered, the title should name the server being shown."
        )
        narrowedMenu.tap()

        // "Series" is also the tab bar's label, so the union option is identified
        // by position rather than by label alone: the menu is presented above the
        // tab bar, so the match that is not the tab is the one higher up the screen.
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        let unionOption = app.buttons
            .matching(NSPredicate(format: "label == %@", "Series"))
            .allElementsBoundByIndex
            .first { $0.frame.minY < tabBarTop }
        let union = try XCTUnwrap(
            unionOption,
            "The menu should offer the union as an option - without it a narrowed library cannot be widened again."
        )
        union.tap()

        XCTAssertTrue(
            seriesFromOne.waitForExistence(timeout: 10),
            "Clearing the filter should bring the other server's library back."
        )
    }

    /// Bounded wait for an element to go away. Uses a predicate expectation rather
    /// than polling `exists` in a loop, which would spin the CPU rather than wait.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
