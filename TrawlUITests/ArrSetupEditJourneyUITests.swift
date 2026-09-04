//
//  ArrSetupEditJourneyUITests.swift
//  TrawlUITests
//
//  The Arr family was the last one whose setup/edit form had no validation-failure
//  coverage. qBittorrent and SABnzbd got it in `ServiceSetupEditJourneyUITests`,
//  Jellyfin and Seerr in `JellyfinSeerrSetupEditJourneyUITests`; Sonarr, Radarr,
//  Bazarr and Prowlarr had only the *success* half, through
//  `ArrRepointJourneyUITests` (a host edit that works first time).
//
//  What was missing is the path a user actually hits: a key the server rejects. This
//  journey proves the rejection is visible, non-destructive, and recoverable -
//  the exact production error appears, the editor stays open, the profile is not
//  repointed behind the user's back, and a corrected key then persists and reconnects.
//
//  ## Why one Sonarr journey covers the family
//
//  All four Arr services share a single editor. `Trawl/ArrStack/ArrSetupSheet.swift`
//  is presented for every `ArrServiceType`, its fields and Save action are built once,
//  and `ArrSetupViewModel.validateAndSave` is the only path any of them takes.
//  The service type selects which client `ArrServiceManager.testConnection` builds
//  (`ArrServiceManager.swift:981`) - the failure handling under test here is above
//  that switch, in the shared view model. Duplicating this journey per service would
//  re-run the same production code against a different fixture port.
//
//  ## The traced production path
//
//  Save → `ArrSetupViewModel.validateAndSave` → `ArrServiceManager.testConnection`
//  → `SonarrAPIClient.getSystemStatus()`. `ArrAPIClient`'s error mapper declares
//  `unauthorizedStatusCodes: [401]` with `unauthorized: { ArrError.invalidAPIKey }`
//  (`ArrAPIClient.swift:329-340`), so a 401 becomes `ArrError.invalidAPIKey`, whose
//  `errorDescription` is "Invalid API key. Check your *arr service settings."
//  (`ArrSharedModels.swift:1503`). `validateAndSave`'s `catch let error as ArrError`
//  assigns that to `validationError` and returns false, which `ArrSetupSheet` renders
//  through `ValidationErrorSection` and - critically - returns false to the Save task,
//  so `dismiss()` is never called.
//
//  The rejection happens *before* any persistence: `testConnection` is the first
//  await in `validateAndSave`, ahead of the Keychain write and every profile mutation.
//  That ordering is what the "not repointed" assertions below protect.
//
//  On the corrected retry the same call succeeds, the API key is written to the
//  Keychain, the profile's host is updated in place, `modelContext.save()` runs, and
//  `serviceManager.connectService(profile)` reconnects - so the settings screen shows
//  the new host and server B, not server A, receives the library traffic afterward.

import Foundation
import XCTest

final class ArrSetupEditJourneyUITests: XCTestCase {
    private var serverA: SonarrFixtureServer?
    private var serverB: SonarrFixtureServer?

    /// The key `TrawlApp.swift`'s DEBUG seeding hook writes to the Keychain for the
    /// fixture profile, so `loadExisting` pre-fills the editor with it.
    private let seededAPIKey = "uitest-api-key"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        serverA?.stop()
        serverA = nil
        serverB?.stop()
        serverB = nil
    }

    /// Regressions this catches: a rejected API key silently dismissing the editor as
    /// though it had worked; the production error text being swallowed, replaced with a
    /// generic message, or shown only in a log; a failed validation still repointing or
    /// disabling the profile; and the corrected retry failing to persist or to
    /// reconnect the service manager to the new host.
    @MainActor
    func testEditingSonarrWithARejectedKeyKeepsTheEditorOpenThenPersistsACorrectedKey() async throws {
        let seriesJSONA = #"[{"id":1,"title":"Series From Server A"}]"#
        let seriesJSONB = #"[{"id":2,"title":"Series From Server B"}]"#

        // Server A stands in for the already-configured Sonarr and accepts whatever key
        // the seeded profile carries. Server B is the replacement, and it accepts
        // exactly one key - so a wrong key produces a real 401 from a real socket
        // rather than a stubbed error.
        let a = try await SonarrFixtureServer(seriesJSON: seriesJSONA)
        serverA = a
        let acceptedKeyForB = "server-b-real-key"
        let rejectedKeyForB = "server-b-wrong-key"
        let b = try await SonarrFixtureServer(seriesJSON: seriesJSONB, acceptedAPIKey: acceptedKeyForB)
        serverB = b

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = a.baseURL
        app.launch()

        // MARK: Baseline - connected to server A

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A launch seeded with a configured Sonarr service should reach the real app chrome."
        )
        XCTAssertTrue(openDestination(.series, in: app), "The Series library should be reachable.")

        XCTAssertTrue(
            app.staticTexts["Series From Server A"].waitForExistence(timeout: 15),
            "The Series tab should show server A's library before any edit - if this fails the baseline connect is broken, not the edit path under test."
        )

        // MARK: Reach the real editor

        openSonarrEditor(in: app)

        let editSheetTitle = app.navigationBars["Edit Sonarr"]
        XCTAssertTrue(
            editSheetTitle.waitForExistence(timeout: 10),
            "Tapping the configured server row should present ArrSetupSheet titled 'Edit Sonarr' for that profile."
        )
        // `ModalFormStyle` declares `.presentationDetents([.medium, .large])`, so this
        // editor opens at medium - with the keyboard up, the ValidationErrorSection
        // that this journey asserts on sits below the fold. Expanding first is what a
        // user does with a cramped sheet, and it keeps the form's layout static for the
        // rest of the journey. (The Seerr editor could not be handled this way: its
        // form was too short to scroll while its primary button sat off-screen, which
        // was a production defect rather than a harness problem - see 5a90128.)
        expandSheet(titled: "Edit Sonarr", in: app)

        // MARK: Pre-fill

        // `ArrSetupSheet` overrides `ServerURLField`'s title with an example URL, so
        // the field is identified by placeholder prefix and the service's default port
        // can change without breaking this.
        let hostField = app.textFields
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "http://192.168.1.100:"))
            .firstMatch
        XCTAssertTrue(
            hostField.waitForExistence(timeout: 10),
            "The edit sheet should present ServerURLField for the host URL."
        )
        // `loadExisting` pre-fills asynchronously, so the sheet can render before the
        // host arrives; wait for the value rather than reading it once.
        waitForValue(hostField, expected: a.baseURL, timeout: 10)

        let keyField = app.secureTextFields["API Key"]
        XCTAssertTrue(
            keyField.waitForExistence(timeout: 10),
            "The edit sheet should present the API Key field."
        )

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "The edit sheet should have a Save action (ModalFormStyle primaryTitle).")
        XCTAssertTrue(
            save.isEnabled,
            "Save should arrive enabled: ArrSetupViewModel.loadExisting pre-fills both the host and the Keychain-held API key, and Save is disabled only when one of them is empty."
        )

        // MARK: Repoint at server B with a key it rejects

        replace(b.baseURL, in: hostField, deleting: a.baseURL.count, in: app)
        replace(rejectedKeyForB, in: keyField, deleting: seededAPIKey.count, in: app)

        // Snapshot A's traffic before Save: a *failed* validation must not disturb the
        // existing connection either.
        let serverARequestsBeforeRejectedSave = a.requests.count

        XCTAssertTrue(tap(save, in: app, timeout: 5), "A populated host and key should leave Save enabled.")

        // MARK: The rejection must be visible, and the editor must stay open

        XCTAssertTrue(
            // `waitForExistence(in:)`: the error section is the last thing in the form,
            // and on iPad the sheet is a form sheet with far less height than an
            // iPhone's - so the row is below the fold and, SwiftUI rendering `Form`
            // rows lazily, absent from the tree entirely rather than merely off screen.
            app.staticTexts["Invalid API key. Check your *arr service settings."].waitForExistence(in: app, timeout: 20),
            "The exact ArrError.invalidAPIKey description should be shown in the editor's ValidationErrorSection - regression: the 401 was swallowed, mapped to a different case, or replaced with a generic 'connection failed' message."
        )

        XCTAssertTrue(
            editSheetTitle.exists,
            "The editor must stay open after a rejected key so the user can correct it - regression: validateAndSave returned true, or the Save task dismissed without checking its result."
        )

        XCTAssertTrue(
            b.hasReceivedRequest(method: "GET", path: "/api/v3/system/status", apiKey: rejectedKeyForB),
            "Server B should have received the real system-status request carrying exactly the rejected key - proves the typed key reached the socket through the production client rather than being validated locally."
        )

        XCTAssertEqual(
            a.requests.count,
            serverARequestsBeforeRejectedSave,
            "A failed validation must not touch the existing server A connection - regression: the profile was repointed or reconnected before the connection test succeeded."
        )

        // MARK: Correct the key - the same editor, no reopening

        replace(acceptedKeyForB, in: keyField, deleting: rejectedKeyForB.count, in: app)

        let serverARequestsBeforeAcceptedSave = a.requests.count

        XCTAssertTrue(tap(save, in: app, timeout: 5), "Save should still be available after correcting the key.")

        waitForDisappearance(of: editSheetTitle, timeout: 20)
        XCTAssertFalse(
            editSheetTitle.exists,
            "The editor should dismiss once the corrected key validates against server B - regression: validateAndSave never completed, or B's fixture responses don't satisfy the real Sonarr connect sequence."
        )

        XCTAssertTrue(
            b.hasReceivedRequest(method: "GET", path: "/api/v3/system/status", apiKey: acceptedKeyForB),
            "Server B should have received a system-status request carrying the corrected key."
        )

        // MARK: The replacement must be persisted and actually in use

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 15) { b.hasReceivedRequest(method: "GET", path: "/api/v3/series") },
            "After a successful edit the service manager should reconnect and load the library from server B - regression: connectService was never called, or a stale client kept serving the old host."
        )

        XCTAssertEqual(
            a.requests.count,
            serverARequestsBeforeAcceptedSave,
            "Server A received \(a.requests.count - serverARequestsBeforeAcceptedSave) request(s) after the profile was repointed to B - a retained view model or service-manager entry is still talking to the old server."
        )

        XCTAssertTrue(
            app.staticTexts[b.baseURL].waitForExistence(timeout: 10),
            "The Sonarr settings screen should display the persisted replacement host - regression: modelContext.save() didn't run, or the screen is still bound to the old profile values."
        )
    }

    // MARK: - Navigation

    /// More → Settings → the seeded Sonarr profile → Edit Server. The path is the one
    /// traced in `ArrRepointJourneyUITests`: `ContentView` wires
    /// `\.navigateToSonarrSettings` onto `MoreView`, `SettingsView`'s service row calls
    /// it, and `ArrServiceSettingsView`'s "Server" section presents `ArrSetupSheet`.
    @MainActor
    private func openSonarrEditor(in app: XCUIApplication) {
        XCTAssertTrue(
            openDestination(.settings, in: app),
            "Settings should be reachable from the root chrome (MoreView.swift, MoreDestination.settings)."
        )

        let sonarrRow = firstElement(labelContains: "Fixture Sonarr", in: app)
        XCTAssertTrue(
            sonarrRow.waitForExistence(timeout: 10),
            "Settings should list the seeded Sonarr profile by its display name 'Fixture Sonarr' (SettingsView.swift serviceRow)."
        )
        sonarrRow.tap()

        XCTAssertTrue(
            app.navigationBars["Sonarr"].waitForExistence(timeout: 10),
            "Tapping the Settings row should push the Sonarr service screen before its own rows are queried."
        )

        // The configured server row *is* the editor entry point - there is no
        // separate "Edit Server" button. A row that shows a server and does nothing
        // when tapped, next to a button that edits it, was the redundancy this
        // replaced.
        //
        // Matched on the connection state as well as the name: the Notifications
        // section further down carries "Fixture Sonarr" too, and a name-only
        // predicate taps that instead and then waits for a sheet that never opens.
        let serverRow = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                "Fixture Sonarr",
                "onnected"
            )
        ).firstMatch
        XCTAssertTrue(
            serverRow.waitForExistence(in: app, timeout: 10),
            "ArrServiceSettingsView should list the configured Sonarr server as a tappable row (ArrServiceSettingsDetailView.swift)."
        )
        serverRow.tap()
    }

    // MARK: - Helpers
    //
    // These mirror the helpers already proven in `ArrRepointJourneyUITests` and
    // `ServiceSetupEditJourneyUITests`. This suite keeps its own copies because every
    // journey file here does - there is no shared harness to extend, and introducing
    // one would rewrite files owned by other coverage stacks.

    /// Finds the first *button* whose accessibility label contains `text`. List rows
    /// built from `NavigationLink`/`Button` wrapping several `Text`s expose a merged
    /// label, and this codebase sets no accessibility identifiers to disambiguate.
    /// Restricting to buttons matters: matching any element type also picks up
    /// non-interactive descendants, and tapping one of those silently does nothing.
    @MainActor
    private func firstElement(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Clears `characterCount` characters and types `value`. The count is passed in
    /// rather than read from the field because a `SecureField` reports a masked value,
    /// so its contents cannot be measured from the element.
    @MainActor
    private func replace(_ value: String, in field: XCUIElement, deleting characterCount: Int, in app: XCUIApplication) {
        focus(field, in: app)
        if characterCount > 0 {
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: characterCount))
        }
        app.typeText(value)
        resignKeyboard(in: app)
    }

    /// Dismisses the software keyboard by pressing its submit key, so the form below
    /// the fields is measured against a settled layout. The label differs by keyboard
    /// type (the host field uses a URL keyboard), so the known variants are tried.
    @MainActor
    private func resignKeyboard(in app: XCUIApplication) {
        guard app.keyboards.element.exists else { return }
        for label in ["return", "Return", "Go", "go", "Done", "done"] {
            let key = app.keyboards.buttons[label]
            guard key.exists, key.isHittable else { continue }
            key.tap()
            break
        }
        let deadline = Date().addingTimeInterval(5)
        while app.keyboards.element.exists && Date() < deadline {
            _ = app.staticTexts["__arr_setup_edit_tick__"].waitForExistence(timeout: 0.25)
        }
    }

    /// Drags the presented editor up to its large detent. A no-op once it is large.
    @MainActor
    private func expandSheet(titled title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        guard bar.waitForExistence(timeout: 10) else { return }
        // Compact only. `ModalFormStyle`'s `.presentationDetents([.medium, .large])`
        // is an iPhone affordance; on iPad the same sheet is a form sheet with no
        // detents to expand, and dragging its navigation bar to the top of the screen
        // there is not a resize - it is a drag of the sheet itself, which left the
        // form in a state where nothing could take keyboard focus and every later
        // `typeText` failed pointing at a field that was plainly on screen.
        guard !TrawlChrome.isSidebar else { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            )
        _ = app.staticTexts["__arr_setup_edit_tick__"].waitForExistence(timeout: 1)
    }

    /// Taps once the element is present and hittable, so a tap is never dropped on an
    /// element that has not settled - a dropped tap fails a later, unrelated assertion.
    @MainActor
    @discardableResult
    private func tap(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
        guard element.isHittable else { return false }
        element.tap()
        return true
    }

    @MainActor
    private func waitForValue(_ element: XCUIElement, expected: String, timeout: TimeInterval) {
        let matched = expectation(
            for: NSPredicate(format: "value == %@", expected),
            evaluatedWith: element
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [matched], timeout: timeout),
            .completed,
            "Expected the field to hold \(expected) - regression: ArrSetupViewModel.loadExisting isn't pre-filling it."
        )
    }

    /// Bounded poll on a condition owned by the test process (fixture-server state),
    /// built only from `waitForExistence`, so it never sleeps.
    @MainActor
    private func waitForCondition(in app: XCUIApplication, timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.staticTexts["__arr_setup_edit_tick__"].waitForExistence(timeout: 0.25)
        }
        return condition()
    }

    /// XCTest has no built-in "wait for disappearance", and this suite's quality bar
    /// rules out a fixed sleep.
    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }
}
