//
//  TrawlUITestsLaunchTests.swift
//  TrawlUITests
//
//  Created by James Poole on 05/04/2026.
//

import XCTest

/// Runs the same real assertion once per target application UI configuration
/// (e.g. per supported device/orientation) instead of just capturing a
/// screenshot. See `TrawlUITests` for why the welcome screen is the only
/// content this suite can reach from a genuinely unconfigured launch.
final class TrawlUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Fails if the welcome screen doesn't render its real content on this
    /// configuration — a blank window, a crash, or a stuck spinner would all
    /// fail this, whereas a bare screenshot attachment would not.
    @MainActor
    func testLaunchShowsWelcomeContent() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launch()

        let title = app.staticTexts["Welcome to Trawl"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Welcome title should appear on launch in this configuration.")
        XCTAssertTrue(app.buttons["Get Started"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Welcome Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
