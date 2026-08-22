//
//  ArrInstanceSwitchJourneyUITests.swift
//  TrawlUITests
//
//  UI journey #4 from TRAWL_RELIABILITY_TEST_AUDIT.md's "test system Trawl needs":
//  switching between two Sonarr instances shows the selected instance's library.
//
//  This exists because of N-01: `ArrMediaListView`'s load task used to be keyed on
//  the active instance's profile ID, which is unchanged across a same-ID edit or an
//  instance switch, so a freshly recreated view model was never asked to load. The
//  fix (`Trawl/ArrStack/ArrMediaListView.swift`) keys the task on
//  `ObjectIdentifier(viewModel)` instead:
//
//      .task(id: ObjectIdentifier(viewModel)) { [viewModel] in
//          await performInitialLoadAndStartPolling(viewModel: viewModel)
//      }
//
//  `ArrRepointJourneyUITests` already pins this for the *edit-a-profile* route to that
//  same machinery (a same-ID host repoint rotates `clientRevision`, which forces a new
//  view model). This suite pins it for the *other* route into the same code: picking a
//  different Sonarr instance from the toolbar's "Instance" menu, which changes
//  `ArrServiceManager.activeSonarrProfileID` and therefore `activeSonarrInstanceID`
//  (`ArrServiceManager.swift:541`) without ever touching `clientRevision`.
//  `SonarrSeriesListView`'s `viewModelLoadKey` includes `activeSonarrInstanceID`
//  (`SonarrSeriesListView.swift:116`), so an instance switch alone is enough to swap in
//  a brand new `SonarrViewModel` — exactly the case N-01 broke.
//
//  ## Seeding two live instances
//
//  `SonarrConnectedJourneyUITests` and `ArrRepointJourneyUITests` already establish why
//  a UI test can only reach the tab UI by seeding a real `ArrServiceProfile` before
//  the app's normal startup (every setup sheet gates on a live `testConnection`, which
//  a UI test driving the UI alone cannot satisfy deterministically). This suite reuses
//  that DEBUG hook (`Trawl/TrawlApp.swift`,
//  `seedUITestArrServiceIfRequested(into:)`), extended to seed a *second* Sonarr
//  profile from `TRAWL_UITEST_SONARR_B_BASE_URL` alongside the existing
//  `TRAWL_UITEST_SONARR_BASE_URL` one. The two profiles are inserted with fixed,
//  distinct UUIDs and saved strictly in order (first profile's insert+save commits
//  before the second is even constructed), which is what makes the *first* profile the
//  one `ArrServiceManager.initialize(from:)` connects first and therefore the one that
//  becomes `activeSonarrProfileID` by default (`connectService` only sets it `if
//  activeSonarrProfileID == nil`) — see the comment at that seeding site for the full
//  reasoning. That default-active assumption is what lets step one below assert a
//  specific instance's series without having switched anything yet.
//
//  ## The UI path for switching instances (traced, not guessed)
//
//  `Trawl/ArrStack/ArrMediaListView.swift` (~line 377) renders a toolbar `Menu` titled
//  "Instance" whenever more than one enabled profile exists for the current service
//  type (`instanceProfiles.count > 1`):
//
//      if instanceProfiles.count > 1 {
//          Menu {
//              ForEach(instanceProfiles) { profile in
//                  Button {
//                      switch serviceType {
//                      case .sonarr: serviceManager.setActiveSonarr(profile.id)
//                      ...
//
//  Each row's `Label` title is `instanceDisplayName(for: profile)`
//  (`InstanceDisplayNameResolver`), which resolves to the profile's own `displayName`
//  whenever that name is unique and not equal to the service type's name — true for
//  both seeded profiles here ("Fixture Sonarr" and "Alternate Sonarr", both distinct
//  from "Sonarr" and from each other). Each row is `.disabled` until
//  `serviceManager.isConnected(serviceType, profileID:)` is true for that profile, so
//  this suite waits for a row to become enabled before tapping it rather than assuming
//  both instances have finished connecting by the time the menu opens.
//
//  Selecting a row calls `ArrServiceManager.setActiveSonarr(profile.id)`
//  (`ArrServiceManager.swift:568`), which reassigns `activeSonarrProfileID` — the same
//  property `activeSonarrInstanceID` and, downstream, `SonarrSeriesListView`'s
//  `viewModelLoadKey` are derived from.

import XCTest

final class ArrInstanceSwitchJourneyUITests: XCTestCase {
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

    /// Regressions this catches: N-01 (switching the active Sonarr instance leaves the
    /// Series tab showing the previous instance's library, or empty, because a
    /// recreated view model was never asked to load), the "Instance" menu disappearing
    /// or failing to list both profiles, `setActiveSonarr` not actually repointing
    /// `activeSonarrProfileID`, and a one-way switch (works A -> B but not back to A)
    /// that a single-direction test would miss.
    @MainActor
    func testSwitchingSonarrInstanceShowsSelectedInstancesLibrary() async throws {
        let seriesJSONOne = #"[{"id":1,"title":"Series On Instance One"}]"#
        let seriesJSONTwo = #"[{"id":2,"title":"Series On Instance Two"}]"#

        let one = try await SonarrFixtureServer(seriesJSON: seriesJSONOne)
        serverOne = one
        let two = try await SonarrFixtureServer(seriesJSON: seriesJSONTwo)
        serverTwo = two

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = one.baseURL
        app.launchEnvironment["TRAWL_UITEST_SONARR_B_BASE_URL"] = two.baseURL
        app.launch()

        // MARK: Land on the Series tab, showing the first (default-active) instance.

        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(
            seriesTab.waitForExistence(timeout: 15),
            "A launch seeded with two configured Sonarr services should still reach the real tab UI."
        )
        seriesTab.tap()

        let seriesFromOne = app.staticTexts["Series On Instance One"]
        XCTAssertTrue(
            seriesFromOne.waitForExistence(timeout: 15),
            "The Series tab should default to the first-seeded instance's library — if this fails, the baseline two-instance connect (not the switch) is broken."
        )

        // MARK: Open the "Instance" switcher and select the second instance.

        let instanceMenuButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Instance"))
            .firstMatch
        XCTAssertTrue(
            instanceMenuButton.waitForExistence(in: app, timeout: 10),
            "ArrMediaListView should show an 'Instance' toolbar menu once more than one Sonarr profile is configured — regression: the switcher disappeared or instanceProfiles.count > 1 stopped gating it."
        )
        instanceMenuButton.tap()

        let switchToTwoButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Alternate Sonarr"))
            .firstMatch
        XCTAssertTrue(
            switchToTwoButton.waitForExistence(in: app, timeout: 10),
            "The Instance menu should list the second seeded profile ('Alternate Sonarr') — regression: instanceProfiles isn't picking up the second profile, or InstanceDisplayNameResolver stopped resolving its name."
        )
        XCTAssertTrue(
            waitForEnabled(switchToTwoButton, timeout: 10),
            "The second instance's menu row should become enabled once ArrServiceManager finishes connecting it — regression: the second profile never connected, so isConnected(serviceType, profileID:) stayed false."
        )
        switchToTwoButton.tap()

        // MARK: Series tab should now show the second instance, and never the first.

        let seriesFromTwo = app.staticTexts["Series On Instance Two"]
        XCTAssertTrue(
            seriesFromTwo.waitForExistence(timeout: 15),
            "N-01 regression: after switching the active Sonarr instance, the Series tab should show the newly selected instance's library — a view model recreated on instance switch but never asked to load would leave this blank instead."
        )
        XCTAssertFalse(
            app.staticTexts["Series On Instance One"].exists,
            "N-01 regression: the first instance's series title should not still be on screen once the active instance has switched to the second — a retained view model would keep showing it."
        )
        XCTAssertTrue(
            two.hasReceivedRequest(method: "GET", path: "/api/v3/series"),
            "The second fixture server should have actually received the series library request over real HTTP — proves the switched-to content came from the newly selected instance, not stale state."
        )

        // MARK: Switch back to the first instance — proves the fix isn't one-way.

        instanceMenuButton.tap()

        let switchBackToOneButton = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (label CONTAINS[c] %@)", "Fixture Sonarr", "Alternate"))
            .firstMatch
        XCTAssertTrue(
            switchBackToOneButton.waitForExistence(in: app, timeout: 10),
            "The Instance menu should still list the first seeded profile ('Fixture Sonarr') after switching away from it."
        )
        XCTAssertTrue(
            waitForEnabled(switchBackToOneButton, timeout: 10),
            "The first instance's menu row should remain enabled — it was connected before the switch and nothing about selecting the second instance should disconnect it."
        )
        switchBackToOneButton.tap()

        XCTAssertTrue(
            seriesFromOne.waitForExistence(timeout: 15),
            "N-01 regression (one-way switch): switching back to the first instance should show its library again — a fix that only works in one direction (e.g. relying on a load that already ran once) would fail here even though the forward switch above passed."
        )
        XCTAssertFalse(
            app.staticTexts["Series On Instance Two"].exists,
            "The second instance's series title should not still be on screen once the active instance has switched back to the first."
        )
    }

    // MARK: - Helpers

    /// Polls `element.isEnabled` until it goes true or `timeout` elapses. Built
    /// entirely from `waitForExistence(timeout:)` calls (never `sleep()` /
    /// `Thread.sleep`), matching `ArrRepointJourneyUITests`'s `waitForDisappearance`
    /// pattern for the same reason: XCTest has no built-in "wait for a property",
    /// and this suite's quality bar rules out a fixed sleep.
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isEnabled { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.isEnabled
    }
}
