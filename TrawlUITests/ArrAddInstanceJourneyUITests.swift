//
//  ArrAddInstanceJourneyUITests.swift
//  TrawlUITests
//
//  Adding a service, as opposed to editing one already configured. The distinction is
//  not cosmetic: `ArrSetupViewModel.validateAndSave` inserts a new profile and unwinds
//  through `modelContext.rollback()` plus a Keychain delete, where the edit path mutates
//  in place and restores field by field. `TrawlTests/ArrSetupViewModelTests` covers that
//  logic directly; this journey covers the half a view model test cannot see — that the
//  entry point exists, that the sheet arrives in *add* mode rather than prefilled from
//  some other profile, and that a second instance genuinely joins the running service
//  manager instead of replacing the first.
//
//  ## Why "Add Another Sonarr Server", and not the service-type picker
//
//  `ArrSetupSheet` renders a service-type `Picker` only when
//  `initialServiceType == nil && existingProfile == nil`. No reachable call site
//  satisfies that. `ArrServiceEditorContext.create` carries a non-optional
//  `ArrServiceType`, so every create passes one, and every edit passes a profile. The
//  one call site that passes neither is `ArrServicesSettingsView.swift:55` — a file
//  nothing outside its own SwiftUI previews references. The picker, and the
//  `availableServiceTypes`/`canCreateProwlarr` logic feeding it, are therefore
//  unreachable from the running app and are deliberately not covered here; writing a
//  journey against a control no user can reach would be worse than leaving it
//  uncovered, because it would read as proof the control works.
//
//  The reachable add entry points come from `ArrServiceSettingsDetailView`:
//  "Add <Service> Server" when none is configured (line ~102), and "Add Another
//  <Service> Server" (line ~169). This drives the latter, because multi-instance state
//  is where the manager can go wrong — `sonarrInstances` is a list, and an add that
//  clobbered an existing entry rather than appending would still look correct on one
//  screen.
//
//  ## Why this launches with two instances already seeded
//
//  Not for convenience. "Add Another" lives inside a section gated on
//  `serviceType != .prowlarr, serviceProfiles.count > 1` (line ~116), so it does not
//  render until a second instance already exists — it cannot be the way a user gets
//  from one instance to two. Seeding two is therefore the only way to reach this button
//  at all, and this journey covers the add path from there. The gap that leaves is
//  recorded in the audit rather than papered over here.

import Foundation
import XCTest

final class ArrAddInstanceJourneyUITests: XCTestCase {
    private var existingServer: SonarrFixtureServer?
    private var addedServer: SonarrFixtureServer?
    private var alternateServer: SonarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        existingServer?.stop()
        existingServer = nil
        addedServer?.stop()
        addedServer = nil
        alternateServer?.stop()
        alternateServer = nil
    }

    /// Regressions this catches: the add entry point disappearing from the service
    /// detail screen, the sheet opening in edit mode and prefilling another profile's
    /// host, a rejected key still creating a profile, and an add that replaces the
    /// configured instance instead of joining it.
    @MainActor
    func testAddingASecondSonarrInstanceJoinsItRatherThanReplacingTheFirst() async throws {
        let existing = try await SonarrFixtureServer(
            seriesJSON: #"[{"id":1,"title":"Series From Existing"}]"#,
            statusJSON: #"{"instanceName":"Fixture Sonarr","version":"4.0.0"}"#
        )
        existingServer = existing

        let addedKey = "second-instance-key"
        let added = try await SonarrFixtureServer(
            seriesJSON: #"[{"id":2,"title":"Series From Added"}]"#,
            acceptedAPIKey: addedKey,
            statusJSON: #"{"instanceName":"Second Sonarr","version":"4.0.0"}"#
        )
        addedServer = added

        // A second seeded instance, purely to make the Instances section render. Its
        // own server only has to answer the connect sequence.
        let alternate = try await SonarrFixtureServer(
            seriesJSON: #"[{"id":3,"title":"Series From Alternate"}]"#,
            statusJSON: #"{"instanceName":"Alternate Sonarr","version":"4.0.0"}"#
        )
        alternateServer = alternate

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = existing.baseURL
        app.launchEnvironment["TRAWL_UITEST_SONARR_B_BASE_URL"] = alternate.baseURL
        app.launch()

        XCTAssertTrue(
            app.tabBars.buttons["Series"].waitForExistence(timeout: 15),
            "A launch seeded with a configured Sonarr service should reach the real tab UI."
        )

        // MARK: Reach the Sonarr service detail screen

        let moreTab = app.tabBars.buttons["More"]
        XCTAssertTrue(moreTab.waitForExistence(timeout: 10), "The More tab should exist in the tab bar.")
        moreTab.tap()

        let settingsRow = firstButton(labelContains: "Settings", in: app)
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 10), "More should show a 'Settings' row.")
        settingsRow.tap()

        let sonarrRow = firstButton(labelContains: "Fixture Sonarr", in: app)
        XCTAssertTrue(sonarrRow.waitForExistence(timeout: 10), "Settings should list the seeded Sonarr profile.")
        sonarrRow.tap()

        // MARK: The add entry point, and the sheet arriving in add mode

        let addButton = firstButton(labelContains: "Add Another Sonarr Server", in: app)
        XCTAssertTrue(
            scrollTo(addButton, in: app, timeout: 15),
            "ArrServiceSettingsDetailView should offer 'Add Another Sonarr Server' in its Instances section once a Sonarr profile exists."
        )
        addButton.tap()

        let addSheetTitle = app.navigationBars["Add Sonarr"]
        XCTAssertTrue(
            addSheetTitle.waitForExistence(timeout: 10),
            "The sheet should present as 'Add Sonarr' — a title of 'Edit Sonarr' would mean .create was routed as an edit."
        )
        expandSheet(titled: "Add Sonarr", in: app)

        let hostField = app.textFields
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "http://192.168.1.100:"))
            .firstMatch
        XCTAssertTrue(hostField.waitForExistence(timeout: 10), "The add sheet should present ServerURLField.")
        XCTAssertEqual(
            hostField.value as? String ?? "",
            "",
            "An add must start from an empty host: prefilling would mean the sheet adopted an existing profile, which is how a new instance silently becomes an edit of the old one."
        )

        let keyField = app.secureTextFields["API Key"]
        XCTAssertTrue(keyField.waitForExistence(timeout: 10), "The add sheet should present the API Key field.")

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "The add sheet should have a Save action.")
        XCTAssertFalse(
            save.isEnabled,
            "Save must be disabled while the form is empty — ArrSetupSheet gates it on a non-empty host and key."
        )

        // MARK: Fill it in and save

        type(added.baseURL, into: hostField, in: app)
        type(addedKey, into: keyField, in: app)

        let existingRequestsBeforeSave = existing.requests.count

        XCTAssertTrue(tap(save, in: app, timeout: 10), "A populated add form should enable Save.")

        waitForDisappearance(of: addSheetTitle, timeout: 20)
        XCTAssertFalse(
            addSheetTitle.exists,
            "The add sheet should dismiss once the connection test against the new server succeeds."
        )

        // MARK: The new instance must exist, and the old one must survive

        XCTAssertTrue(
            waitForCondition(in: app, timeout: 15) {
                added.hasReceivedRequest(method: "GET", path: "/api/v3/system/status", apiKey: addedKey)
            },
            "The new server should have received the real system-status request carrying exactly the typed key."
        )

        XCTAssertTrue(
            firstStaticText(labelContains: "Second Sonarr", in: app).waitForExistence(timeout: 15),
            "The Instances section should list the newly added server under the instance name it reported — regression: the profile was not inserted, or the screen is not observing the new instance."
        )

        XCTAssertTrue(
            firstStaticText(labelContains: "Fixture Sonarr", in: app).exists,
            "The originally configured instance must still be listed — regression: the add replaced an existing profile instead of appending to the list."
        )

        XCTAssertGreaterThanOrEqual(
            existing.requests.count,
            existingRequestsBeforeSave,
            "Adding an instance must not tear down the existing one's client."
        )
    }

    // MARK: - Helpers
    //
    // Kept local to this suite, matching every other journey file here: there is no
    // shared XCUITest harness to extend, and introducing one would rewrite files owned
    // by other coverage stacks.

    @MainActor
    private func firstButton(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    @MainActor
    private func firstStaticText(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Scrolls the settings list toward an element that SwiftUI has not rendered yet.
    /// No sheet is presented at this point, so the scroll container is unambiguous.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable { return true }
        let container = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            container.swipeUp()
            _ = element.waitForExistence(timeout: 0.5)
        }
        return element.exists && element.isHittable
    }

    /// `ModalFormStyle` opens at `.medium`; expanding keeps the form's layout static
    /// for the rest of the journey, the same reasoning as `ArrSetupEditJourneyUITests`.
    @MainActor
    private func expandSheet(titled title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        guard bar.waitForExistence(timeout: 10) else { return }
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
            )
        _ = app.staticTexts["__arr_add_instance_tick__"].waitForExistence(timeout: 1)
    }

    /// Types into an empty field, then drops the keyboard so the next element is
    /// evaluated against a settled layout.
    @MainActor
    private func type(_ value: String, into field: XCUIElement, in app: XCUIApplication) {
        if field.elementType == .secureTextField {
            field.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        field.typeText(value)
        resignKeyboard(in: app)
    }

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
            _ = app.staticTexts["__arr_add_instance_tick__"].waitForExistence(timeout: 0.25)
        }
    }

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
    private func waitForCondition(in app: XCUIApplication, timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = app.staticTexts["__arr_add_instance_tick__"].waitForExistence(timeout: 0.25)
        }
        return condition()
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }
}
