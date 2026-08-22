//
//  ArrRepointJourneyUITests.swift
//  TrawlUITests
//
//  UI journey #3 from TRAWL_RELIABILITY_TEST_AUDIT.md's "test system Trawl needs":
//  add and then edit a Sonarr profile with the same ID, and confirm the new server is
//  used. This proves H-01 ("Editing/reconnecting a Sonarr or Radarr profile can leave
//  screens using the old server client") and H-02 ("A failed Arr reconnect leaves a
//  stale client exposed") end to end, through real navigation, rather than only at the
//  unit level (`ArrClientLifecycleTests`).
//
//  Two independent loopback fixture servers stand in for "the old Sonarr" and "the new
//  Sonarr". The app launches seeded against server A (same DEBUG hook as
//  `SonarrConnectedJourneyUITests`: `-TrawlUITestInMemoryStore` +
//  `TRAWL_UITEST_SONARR_BASE_URL`), reaches the tab UI showing A's library over real
//  HTTP, and then the test drives the *real* edit flow — More -> Settings -> the
//  seeded Sonarr row -> "Edit Server" -> the real `ArrSetupSheet` -> a real
//  `testConnection` against server B -> Save — to repoint the same profile ID at B.
//
//  ## The UI path (traced, not guessed)
//
//  `Trawl/Views/ContentView.swift` wires `.environment(\.navigateToSonarrSettings) {
//  morePath.append(.sonarrSettings) }` onto `MoreView`. `Trawl/Views/SettingsView.swift`
//  calls that closure from a `Button(action: navigateToSonarrSettings)` wrapping the
//  Sonarr `serviceRow` (line ~164). `Trawl/Views/MoreView.swift`'s
//  `.navigationDestination(for: MoreDestination.self)` resolves `.sonarrSettings` to
//  `ArrServiceSettingsView(serviceType: .sonarr)`
//  (`Trawl/ArrStack/ArrServiceSettingsDetailView.swift`), whose "Server" section has a
//  `Button("Edit Server", systemImage: "pencil") { editorContext = .edit(profile) }`
//  (line ~97) that presents `ArrSetupSheet(existingProfile: profile, ...)` as a sheet.
//  `ArrSetupViewModel.loadExisting(_:)` pre-fills `hostURL` from the profile and
//  `apiKey` from a real Keychain read — since the DEBUG seeding hook in
//  `Trawl/TrawlApp.swift` already wrote `"uitest-api-key"` under this profile's
//  Keychain key, the API key field arrives pre-filled and does not need re-entry.
//  Only the host field needs editing. Saving calls the real
//  `ArrSetupViewModel.validateAndSave`, which runs a real `testConnection` against
//  whatever host is currently in the field — against fixture server B, that succeeds,
//  updates the *same* `ArrServiceProfile.id`, rotates `ArrServiceManager`'s
//  `clientRevision` for that instance, and invalidates the shared series-library cache
//  entry for that instance ID (`ArrServiceManager.swift:698`,
//  `ArrLibraryCache.invalidate`) so the next load can't serve stale data from A under
//  the appear-time cache window (`ArrLibraryCachePolicy.appearMaxAge`, 120s).
//
//  Reaching the Series tab is reused verbatim from `SonarrConnectedJourneyUITests`'s
//  reasoning: everything before the seeded launch (the welcome gate, live
//  `testConnection`-gated setup sheets) is unreachable from a UI test driving the UI
//  alone, which is why this suite also starts from a seeded profile rather than
//  proving the *initial add* flow.
//
//  ## Why navigating to More and back to Series matters, not just cosmetically
//
//  `Trawl/ArrStack/ArrMediaListView.swift`'s `.task(id:
//  serviceManager.activeInstanceID(serviceType))` is keyed by profile ID, which is
//  unchanged across a same-ID edit — its own comment notes it "restarts on every
//  appear, not just the first, so this runs again on each tab switch". Tapping away
//  to More and back to Series is therefore not incidental UI dressing in this journey:
//  it is what actually causes `SonarrSeriesListView`'s freshly-recreated view model
//  (keyed by `activeSonarrClientRevision`, which *does* change on edit) to load through
//  `ArrMediaListView`'s appear-time task instead of sitting empty.

import Foundation
import XCTest

final class ArrRepointJourneyUITests: XCTestCase {
    private var serverA: SonarrFixtureServer?
    private var serverB: SonarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        serverA?.stop()
        serverA = nil
        serverB?.stop()
        serverB = nil
    }

    /// Regressions this catches: H-01 (a retained view model or the service manager
    /// continuing to talk to the old Sonarr host after a same-ID edit), H-02 (a stale
    /// client surviving a reconnect), the edit entry point disappearing from Settings,
    /// `ArrSetupViewModel.loadExisting` failing to pre-fill the host/API key, and the
    /// shared library cache (`ArrLibraryCache`) serving server A's data past its
    /// invalidation.
    @MainActor
    func testEditingSonarrHostRepointsTheLibraryToTheNewServer() async throws {
        let seriesJSONA = #"[{"id":1,"title":"Series From Server A"}]"#
        let seriesJSONB = #"[{"id":2,"title":"Series From Server B"}]"#

        let a = try await SonarrFixtureServer(seriesJSON: seriesJSONA)
        serverA = a
        let b = try await SonarrFixtureServer(seriesJSON: seriesJSONB)
        serverB = b

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = a.baseURL
        app.launch()

        // MARK: Land on the Series tab, connected to server A.

        let seriesTab = app.tabBars.buttons["Series"]
        XCTAssertTrue(
            seriesTab.waitForExistence(timeout: 15),
            "A launch seeded with a configured Sonarr service should reach the real tab UI."
        )
        seriesTab.tap()

        let seriesFromA = app.staticTexts["Series From Server A"]
        XCTAssertTrue(
            seriesFromA.waitForExistence(timeout: 15),
            "The Series tab should show server A's library before any edit happens — if this fails, the baseline connect (not the repoint) is broken."
        )

        // MARK: Navigate to the real edit flow: More -> Settings -> Sonarr -> Edit Server.

        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 10), "The More tab should exist in the tab bar.")
        moreTab.tap()

        let settingsRow = firstElement(labelContains: "Settings", in: app)
        XCTAssertTrue(
            settingsRow.waitForExistence(in: app, timeout: 5),
            "More should show a 'Settings' row (MoreView.swift, MoreDestination.settings) — regression: the row was removed or renamed."
        )
        settingsRow.tap()

        let sonarrRow = firstElement(labelContains: "Fixture Sonarr", in: app)
        XCTAssertTrue(
            sonarrRow.waitForExistence(in: app, timeout: 5),
            "Settings should list the seeded Sonarr profile by its display name 'Fixture Sonarr' (SettingsView.swift serviceRow) — regression: the Sonarr row disappeared or the profile failed to resolve."
        )
        sonarrRow.tap()

        let editServerButton = app.buttons["Edit Server"]
        XCTAssertTrue(
            editServerButton.waitForExistence(in: app, timeout: 5),
            "ArrServiceSettingsView should offer an 'Edit Server' button once a Sonarr profile exists (ArrServiceSettingsDetailView.swift) — regression: the edit entry point is missing."
        )
        editServerButton.tap()

        let editSheetTitle = app.navigationBars["Edit Sonarr"]
        XCTAssertTrue(
            editSheetTitle.waitForExistence(timeout: 10),
            "'Edit Server' should present ArrSetupSheet titled 'Edit Sonarr' for the existing profile — regression: the sheet didn't present, or presented as an 'Add' flow instead of an edit."
        )

        // MARK: Edit the host to point at server B.

        // Find the field by its label (`ServerURLField`'s title), then wait for the
        // value to arrive: `ArrSetupViewModel.loadExisting` pre-fills asynchronously,
        // so the sheet can render before the host URL lands. Matching on `value`
        // up-front would race that and report the field itself as missing.
        // `ArrSetupSheet` overrides `ServerURLField`'s title with an example URL
        // ("http://192.168.1.100:<defaultPort>"), so the field is identified by its
        // placeholder rather than by a fixed label — and by prefix, so the service's
        // default port can change without breaking this.
        let hostField = app.textFields
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "http://192.168.1.100:"))
            .firstMatch
        XCTAssertTrue(
            hostField.waitForExistence(in: app, timeout: 10),
            "The edit sheet should present ServerURLField for the host URL."
        )
        let prefilled = expectation(
            for: NSPredicate(format: "value == %@", a.baseURL),
            evaluatedWith: hostField
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [prefilled], timeout: 10),
            .completed,
            "The edit sheet's host field should be pre-filled with the profile's current host URL (server A) — regression: ArrSetupViewModel.loadExisting isn't pre-filling hostURL."
        )

        clearAndType(b.baseURL, into: hostField)
        XCTAssertEqual(
            hostField.value as? String,
            b.baseURL,
            "The host field should contain exactly server B's URL after editing — a partial clear or a mistyped '://' would corrupt this and the connection test would fail for the wrong reason."
        )

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "The edit sheet should have a Save action (ModalFormStyle primaryTitle).")
        XCTAssertTrue(
            saveButton.isEnabled,
            "Save should already be enabled: the host field is non-empty and the API key was pre-filled from Keychain by ArrSetupViewModel.loadExisting."
        )

        // Snapshot server A's traffic immediately before Save triggers the real
        // reconnect. Everything after this point should go to B, never to A again —
        // that's the H-01 assertion below.
        let serverARequestCountBeforeSave = a.requests.count

        saveButton.tap()

        // Save runs a real `testConnection` against B (a working fixture, so it
        // succeeds), then a real ArrServiceManager.connectService(profile) against B
        // before dismissing. Wait for the sheet to actually close rather than assuming
        // a fixed delay — this is a bounded poll built only from waitForExistence,
        // never sleep()/Thread.sleep(), since XCTest has no built-in
        // "wait for disappearance".
        waitForDisappearance(of: editSheetTitle, timeout: 20)
        XCTAssertFalse(
            editSheetTitle.exists,
            "The edit sheet should dismiss once the real connection test against server B succeeds — regression: validateAndSave never completed, or server B's fixture responses don't satisfy the real Sonarr connect sequence (system status, quality profiles, root folders, tags)."
        )

        // MARK: Back to Series — should now show B, and never show A again.

        seriesTab.tap()

        let seriesFromB = app.staticTexts["Series From Server B"]
        _ = seriesFromB.waitForExistence(timeout: 20)
        print("=====AFTER_TAB_SWITCH=====")
        for t in app.staticTexts.allElementsBoundByIndex { print("TEXT:", t.label) }
        print("=====B_SERIES_REQUESTS:", b.requests.filter { $0.path == "/api/v3/series" }.count)
        print("=====B_ALL:", b.requests.map { $0.path }.joined(separator: ","))
        print("=====END=====")
        XCTAssertTrue(
            seriesFromB.waitForExistence(timeout: 15),
            "H-01 regression: after a same-ID host edit, the Series tab should repoint to server B instead of staying on the old client, showing nothing, or hanging on stale cached data past ArrLibraryCache's invalidation."
        )

        XCTAssertFalse(
            app.staticTexts["Series From Server A"].exists,
            "H-01 regression: server A's series title should not still be on screen once the profile has been repointed to server B — a retained view model or an un-invalidated cache entry would keep showing it."
        )

        XCTAssertTrue(
            b.hasReceivedRequest(method: "GET", path: "/api/v3/series"),
            "Server B should have actually received the series library request over real HTTP — proves the new content came from the new server, not from stale state."
        )

        let serverARequestCountAfterEdit = a.requests.count
        XCTAssertEqual(
            serverARequestCountAfterEdit,
            serverARequestCountBeforeSave,
            "H-01 regression: server A received \(serverARequestCountAfterEdit - serverARequestCountBeforeSave) request(s) after the host was edited to server B — a stale client or a retained view model/service-manager entry is still talking to the old server."
        )
    }

    // MARK: - Helpers

    /// Finds the first element anywhere in the tree whose accessibility label
    /// contains `text`. Used instead of `app.buttons["exact label"]` for rows built
    /// from `NavigationLink(value:)`/`Button` wrapping multiple `Text`/`Image`
    /// children (`NavigationMenuRow`, `SettingsView.serviceRow`): SwiftUI's default
    /// accessibility grouping for interactive controls can either keep those children
    /// separately queryable or merge them into one combined label depending on the
    /// control, and this codebase sets no explicit `accessibilityIdentifier` anywhere
    /// to disambiguate. Searching by substring across every element type is robust to
    /// either behavior without guessing the exact composed label.
    /// These list rows are `Button`s whose accessibility label merges their title and
    /// subtitle — the More tab's Settings row, for instance, reads
    /// "Settings, App and server configuration". Matching `.any` picks up
    /// non-interactive descendants too, and tapping one of those silently does
    /// nothing, so restrict the search to buttons.
    private func firstElement(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Clears an existing value and types `text`, so a URL containing `://` doesn't
    /// get appended to (or interleaved with) whatever was already in the field.
    private func clearAndType(_ text: String, into field: XCUIElement) {
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
            field.typeText(deleteString)
        }
        field.typeText(text)
    }

    /// Polls `element.exists` until it goes false or `timeout` elapses. Built
    /// entirely from `waitForExistence(timeout:)` calls (never `sleep()` /
    /// `Thread.sleep`), since XCTest has no built-in "wait for disappearance" and this
    /// suite's quality bar rules out a fixed sleep.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }
}
