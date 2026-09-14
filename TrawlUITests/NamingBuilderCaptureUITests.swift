//
//  NamingBuilderCaptureUITests.swift
//  TrawlUITests
//
//  Photographs the naming block builder for visual review and asserts only that each
//  screen arrived, like `IPadSurfaceCaptureUITests`. The same test runs on both
//  chromes; appearance and text size come from the simulator (`xcrun simctl ui`),
//  so one test covers light, dark and large text across runs.
//
//  Behaviour - drags, saves, guards - is `NamingBuilderJourneyUITests` and
//  `IPadSidebarJourneyUITests`.
//

import XCTest

final class NamingBuilderCaptureUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        sonarr?.stop()
        super.tearDown()
    }

    @MainActor
    func testCaptureNamingBuilder() async throws {
        let server = try await SonarrFixtureServer(
            seriesJSON: "[]",
            namingJSON: #"{"id":1,"renameEpisodes":true,"replaceIllegalCharacters":true,"colonReplacementFormat":4,"standardEpisodeFormat":"{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} - {Quality Full}{-Release Group}","dailyEpisodeFormat":"{Series TitleYear} - {Air-Date}","seriesFolderFormat":"{Series TitleYear}","seasonFolderFormat":"Season {season:00}"}"#
        )
        sonarr = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))

        XCTAssertTrue(openDestination(.naming, in: app))
        let standard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Standard,")).firstMatch
        XCTAssertTrue(standard.waitForExistence(timeout: 20))
        capture(app, "1-list")

        standard.tap()
        XCTAssertTrue(app.navigationBars["Standard Episode Format"].waitForExistence(timeout: 10))
        let preview = app.descendants(matching: .any).matching(identifier: "naming.preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        capture(app, "2-builder")

        let episodeNumber = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "naming.block", "Episode number"))
            .firstMatch
        XCTAssertTrue(episodeNumber.waitForExistence(timeout: 10))
        episodeNumber.tap()
        XCTAssertTrue(app.buttons["Move Earlier"].waitForExistence(timeout: 10))
        capture(app, "3-options")

        // The options are a confirmation dialog, whose Cancel iOS 26 leaves out when it
        // presents as a popover; it closes from outside there.
        let cancel = app.buttons["Cancel"]
        if cancel.exists, cancel.isHittable {
            cancel.tap()
        } else {
            app.otherElements["PopoverDismissRegion"].coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.05)).tap()
        }
        XCTAssertTrue(app.buttons["Move Earlier"].waitForNonExistence(timeout: 10), "The options must close back to the builder.")

        // The tray grid is lazy, so its blocks join the accessibility tree only once
        // scrolled into view.
        let tray = app.descendants(matching: .any).matching(identifier: "naming.tray.quality").firstMatch
        for _ in 0..<4 where !(tray.exists && tray.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(tray.waitForExistence(timeout: 10), "The tray should be reachable by scrolling.")
        capture(app, "4-tray")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "naming-\(TrawlChrome.isSidebar ? "ipad" : "iphone")-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
