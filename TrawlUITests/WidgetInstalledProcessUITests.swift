import XCTest

/// A real WidgetKit integration check. This drives SpringBoard's widget gallery,
/// installs Trawl's widget, and opens the host app through the widget's deep link.
///
/// It deliberately asserts on SpringBoard-owned elements only. A home-screen widget's
/// content is rendered by `com.apple.chrono.WidgetRenderer`, a separate process, and
/// XCTest cannot read into it — driving the earlier version of this test, every query
/// for the widget's inner labels logged `Error getting main window kAXErrorServerNotFound`
/// and timed out. SpringBoard does expose the widget itself: an icon element carrying
/// `value: Widget`, which the plain app icon does not have. That element is the honest
/// boundary to assert on, and tapping it exercises the same deep link a user would.
final class WidgetInstalledProcessUITests: XCTestCase {
    private let hostBundleIdentifier = "com.poole.james.Trawl"

    /// A home-screen widget. The app icon shares the label but carries no value.
    private var trawlWidgetIcons: XCUIElementQuery {
        springboard.icons.matching(
            NSPredicate(format: "label == %@ AND value CONTAINS %@", "Trawl", "Widget")
        )
    }

    /// The app icon specifically, excluding any installed widget of the same label.
    private var trawlAppIcon: XCUIElement {
        springboard.icons.matching(
            NSPredicate(format: "label == %@ AND NOT (value CONTAINS %@)", "Trawl", "Widget")
        ).firstMatch
    }

    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInstalledWidgetRendersAndOpensTrawl() throws {
        let app = XCUIApplication(bundleIdentifier: hostBundleIdentifier)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCUIDevice.shared.press(.home)
        let springboard = self.springboard
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))

        let widgetsBefore = trawlWidgetIcons.count

        try enterWidgetGallery()
        try installTrawlWidget()

        // WidgetKit registered the extension and SpringBoard created a widget for it.
        let installed = trawlWidgetIcons.firstMatch
        XCTAssertTrue(
            installed.waitForExistence(timeout: 15),
            "SpringBoard exposed no Trawl widget icon after installation"
        )
        XCTAssertGreaterThan(
            trawlWidgetIcons.count, widgetsBefore,
            "The gallery flow did not add a new Trawl widget to the Home Screen"
        )

        // A widget that laid out has a real frame; a placeholder on another page is zero-sized.
        XCTAssertTrue(try waitUntilHittable(installed, timeout: 15), "The installed Trawl widget never became hittable")
        XCTAssertFalse(installed.frame.isEmpty, "The installed Trawl widget rendered with an empty frame")

        installed.tap()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 15),
            "The installed widget's trawl://downloads deep link did not open Trawl"
        )
    }

    // MARK: - Flow steps

    @MainActor
    private func enterWidgetGallery() throws {
        let appIcon = trawlAppIcon
        XCTAssertTrue(
            appIcon.waitForExistence(timeout: 10),
            "Trawl must be installed before its Widget extension can be exercised"
        )
        XCTAssertTrue(try waitUntilHittable(appIcon, timeout: 10))
        appIcon.press(forDuration: 1.2)

        let editHomeScreen = springboard.buttons["Edit Home Screen"].firstMatch
        XCTAssertTrue(editHomeScreen.waitForExistence(timeout: 10))
        XCTAssertTrue(try waitUntilHittable(editHomeScreen, timeout: 10))
        editHomeScreen.tap()

        // iOS 26 and later nests widget insertion under the edit-mode menu.
        let editMenu = springboard.buttons["Edit"].firstMatch
        XCTAssertTrue(editMenu.waitForExistence(timeout: 10), "SpringBoard did not enter Home Screen edit mode")
        XCTAssertTrue(try waitUntilHittable(editMenu, timeout: 10))
        editMenu.tap()

        let addWidget = springboard.buttons["Add Widget"].firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 10), "SpringBoard did not expose the Widget gallery button")
        XCTAssertTrue(try waitUntilHittable(addWidget, timeout: 10))
        addWidget.tap()
    }

    @MainActor
    private func installTrawlWidget() throws {
        let searchField = springboard.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        XCTAssertTrue(try waitUntilHittable(searchField, timeout: 10))
        searchField.tap()
        searchField.typeText("Trawl")

        let trawlResult = springboard.cells.containing(.staticText, identifier: "Trawl").firstMatch
        XCTAssertTrue(
            trawlResult.waitForExistence(timeout: 10),
            "WidgetKit did not register the TrawlWidgets extension in the gallery"
        )
        XCTAssertTrue(try waitUntilHittable(trawlResult, timeout: 10))
        trawlResult.tap()

        let installButton = springboard.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Add Widget")
        ).firstMatch
        XCTAssertTrue(
            installButton.waitForExistence(timeout: 10),
            "Trawl's widget gallery page did not render an installable preview"
        )
        XCTAssertTrue(try waitUntilHittable(installButton, timeout: 10))
        installButton.tap()

        // Placing the widget leaves the Home Screen in edit ("jiggle") mode on some
        // iOS versions; dismiss it so the widget is tappable rather than draggable.
        let done = springboard.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3), done.isHittable {
            done.tap()
        }
    }

    // MARK: - Helpers

    /// A tap on an element that exists but is not yet hittable is silently dropped and
    /// the failure surfaces later against an unrelated element, so every tap waits.
    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) throws -> Bool {
        let predicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
