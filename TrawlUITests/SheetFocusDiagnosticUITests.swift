//
//  SheetFocusDiagnosticUITests.swift
//  TrawlUITests
//
//  TEMPORARY. Why will a setup-sheet text field not take keyboard focus on iPad?
//  Delete once the cause is known.

import XCTest

final class SheetFocusDiagnosticUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?

    override func tearDownWithError() throws {
        sonarr?.stop(); sonarr = nil
    }

    @MainActor
    func testDiagnoseSetupSheetFocus() async throws {
        let server = try await SonarrFixtureServer(seriesJSON: #"[{"id":1,"title":"Focus Series"}]"#)
        sonarr = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.settings, in: app))

        let sonarrRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Fixture Sonarr"))
            .firstMatch
        XCTAssertTrue(sonarrRow.waitForExistence(in: app, timeout: 15))
        _ = tapWhenPossible(sonarrRow, timeout: 10)

        let serverRow = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "Fixture Sonarr", "onnected"))
            .firstMatch
        if serverRow.waitForExistence(in: app, timeout: 15) {
            _ = tapWhenPossible(serverRow, timeout: 10)
        }

        XCTAssertTrue(app.navigationBars["Edit Sonarr"].waitForExistence(timeout: 15), "The editor should present.")

        print("=== KEYBOARDS: count=\(app.keyboards.count) exists=\(app.keyboards.element.exists) ===")

        print("=== TEXT FIELDS ===")
        for (i, f) in app.textFields.allElementsBoundByIndex.enumerated() {
            print("[\(i)] placeholder=\(f.placeholderValue ?? "nil") value=\(String(describing: f.value)) frame=\(f.frame) hittable=\(f.isHittable)")
        }
        print("=== SECURE FIELDS ===")
        for (i, f) in app.secureTextFields.allElementsBoundByIndex.enumerated() {
            print("[\(i)] id=\(f.identifier) frame=\(f.frame) hittable=\(f.isHittable)")
        }

        let host = app.textFields
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "http://192.168.1.100:"))
            .firstMatch
        guard host.exists else { print("!! no host field"); return }

        print("--- tap host field centre ---")
        host.tap()
        print("keyboards after tap: count=\(app.keyboards.count)")
        print("host value after tap: \(String(describing: host.value))")

        // Does the *sheet* have focus at all? Try typing into the app.
        if app.keyboards.count > 0 {
            app.typeText("Z")
            print("host value after app.typeText: \(String(describing: host.value))")
        }

        // Try the enclosing cell instead of the field itself - in a Form the row is
        // often what owns the tap.
        let cell = app.cells.containing(
            NSPredicate(format: "placeholderValue BEGINSWITH %@", "http://192.168.1.100:")
        ).firstMatch
        print("enclosing cell exists=\(cell.exists) hittable=\(cell.exists ? "\(cell.isHittable)" : "n/a")")
        if cell.exists {
            cell.tap()
            print("keyboards after cell tap: count=\(app.keyboards.count)")
            print("host value after cell tap: \(String(describing: host.value))")
        }

        print("=== SHEET TREE ===")
        print(app.sheets.firstMatch.exists ? app.sheets.firstMatch.debugDescription : "(no sheet element)")
        print("=== END ===")
    }
}
