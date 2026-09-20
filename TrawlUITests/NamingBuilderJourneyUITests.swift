//
//  NamingBuilderJourneyUITests.swift
//  TrawlUITests
//
//  The naming block builder on the compact chrome, where it is pushed from the
//  Naming list rather than filling a detail column. Everything here goes through
//  production navigation and production save paths against loopback Sonarr and
//  Radarr fixtures, and asserts what the servers actually received.
//
//  The sidebar chrome's builder - selection restoration, the detail placeholder,
//  column propagation and server isolation - is `IPadSidebarJourneyUITests`.
//

import XCTest

final class NamingBuilderJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?
    private var radarr: RadarrFixtureServer?

    private static let sonarrNamingJSON = #"{"id":1,"renameEpisodes":true,"replaceIllegalCharacters":true,"colonReplacementFormat":4,"multiEpisodeStyle":5,"standardEpisodeFormat":"{Series TitleYear} - S{season:00}E{episode:00}","dailyEpisodeFormat":"{Series TitleYear} - {Air-Date}","animeEpisodeFormat":"{Series TitleYear} - {absolute:000}","seriesFolderFormat":"{Series TitleYear}","seasonFolderFormat":"Season {season:00}","specialsFolderFormat":"Specials"}"#

    private static let standardPath = "/api/v3/config/naming/1"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(TrawlChrome.isSidebar, "The pushed builder is the compact route; the sidebar builder is covered by IPadSidebarJourneyUITests.")
    }

    override func tearDown() {
        sonarr?.stop()
        radarr?.stop()
        super.tearDown()
    }

    /// Tap-only construction, the options sheet's reorder and customise actions, and
    /// both answers to the unsaved-changes question on Back. Nothing may be written.
    @MainActor
    func testBuilderEditsLocallyAndBackOffersKeepOrDiscard() async throws {
        let server = try await SonarrFixtureServer(seriesJSON: "[]", namingJSON: Self.sonarrNamingJSON)
        sonarr = server
        let app = launch()

        let builder = openFormat("Standard", title: "Standard Episode Format", in: app)
        let preview = element("naming.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(previewText(in: app).contains("Example Show (2026) - S02E03"), "The builder must open on the server's own format. Preview: \(previewText(in: app))")
        XCTAssertFalse(builder.buttons["Save"].isEnabled, "An untouched draft has nothing to save.")

        // Add from the tray.
        XCTAssertTrue(tapWhenHittable(element("naming.tray.episodeTitle", in: app)))
        XCTAssertTrue(waitForPreview(containing: "S02E03 - Pilot", in: app), "Adding Episode title must append it. Preview: \(previewText(in: app))")

        // Reorder through the block's options dialog.
        XCTAssertTrue(tapWhenHittable(block(titled: "Episode title", in: app)))
        XCTAssertTrue(tapWhenHittable(app.buttons["Move Earlier"]))
        XCTAssertTrue(waitForPreview(containing: "(2026) - Pilot - S02E03", in: app), "Move Earlier must reorder. Preview: \(previewText(in: app))")

        // Customise with a choice labelled by its output, not its syntax.
        XCTAssertTrue(tapWhenHittable(block(titled: "Episode number", in: app)))
        XCTAssertTrue(tapWhenHittable(app.buttons["2x03"]))
        XCTAssertTrue(waitForPreview(containing: "Pilot - 2x03", in: app), "Choosing 1x02 style must change only the episode number. Preview: \(previewText(in: app))")
        XCTAssertTrue(builder.buttons["Save"].isEnabled)

        // Back with edits asks; keeping editing leaves everything in place.
        XCTAssertTrue(tapWhenHittable(builder.buttons["Back"]))
        XCTAssertTrue(keepEditing(in: app), "Back with edits must ask before leaving.")
        XCTAssertTrue(builder.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForPreview(containing: "Pilot - 2x03", in: app), "Keep Editing must not touch the draft.")

        // Discard leaves, and the next visit starts from the server's value.
        XCTAssertTrue(tapWhenHittable(builder.buttons["Back"]))
        XCTAssertTrue(tapWhenHittable(app.buttons["Discard Changes"]))
        XCTAssertTrue(app.navigationBars["Naming"].waitForExistence(timeout: 10))
        let reopened = openFormat("Standard", title: "Standard Episode Format", in: app)
        XCTAssertTrue(waitForPreview(containing: "Example Show (2026) - S02E03", in: app))
        XCTAssertFalse(previewText(in: app).contains("Pilot"), "A discarded draft must not come back.")
        XCTAssertFalse(reopened.buttons["Save"].isEnabled)

        XCTAssertFalse(server.hasReceivedRequest(method: "PUT", path: Self.standardPath), "Local edits, Keep Editing and Discard must never write.")
    }

    /// A rejected save keeps the pushed builder and its whole draft; the retry is
    /// accepted, the builder pops, and the list shows the server's response. Both
    /// writes carry the same format and every other naming field unchanged.
    @MainActor
    func testRejectedSaveKeepsTheDraftAndTheAcceptedRetryReturnsToTheList() async throws {
        let server = try await SonarrFixtureServer(seriesJSON: "[]", namingJSON: Self.sonarrNamingJSON, rejectFirstEditorSave: true)
        sonarr = server
        let app = launch()

        let builder = openFormat("Standard", title: "Standard Episode Format", in: app)
        XCTAssertTrue(tapWhenHittable(element("naming.tray.episodeTitle", in: app)))
        XCTAssertTrue(waitForPreview(containing: "S02E03 - Pilot", in: app))

        confirmSave(from: builder, naming: "Sonarr", in: app)
        XCTAssertTrue(app.staticTexts["Save Failed"].waitForExistence(timeout: 15))
        XCTAssertTrue(builder.exists, "A rejected save must not leave the builder.")
        XCTAssertTrue(waitForPreview(containing: "S02E03 - Pilot", in: app), "A rejected save must keep the draft for a retry.")
        XCTAssertEqual(server.requests.filter { $0.method == "PUT" && $0.path == Self.standardPath }.count, 1)

        confirmSave(from: builder, naming: "Sonarr", in: app)
        XCTAssertTrue(app.navigationBars["Naming"].waitForExistence(timeout: 15), "An accepted save returns to the list.")
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Standard,", "S02E03 - Pilot")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The list must show the accepted format.")

        let saves = server.requests.filter { $0.method == "PUT" && $0.path == Self.standardPath }
        XCTAssertEqual(saves.count, 2)
        for save in saves {
            let config = try XCTUnwrap(JSONSerialization.jsonObject(with: save.body) as? [String: Any])
            XCTAssertEqual(config["standardEpisodeFormat"] as? String, "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle}")
            XCTAssertEqual(config["dailyEpisodeFormat"] as? String, "{Series TitleYear} - {Air-Date}")
            XCTAssertEqual(config["colonReplacementFormat"] as? Int, 4)
            XCTAssertEqual(config["multiEpisodeStyle"] as? Int, 5)
            XCTAssertEqual(config["renameEpisodes"] as? Bool, true)
        }
    }

    /// Radarr's builder writes to Radarr, changes only the movie file format, and
    /// keeps a file-handling setting Radarr v6 sends as a string.
    @MainActor
    func testRadarrMovieFormatSavesOnlyThatFieldToRadarr() async throws {
        let sonarrServer = try await SonarrFixtureServer(seriesJSON: "[]", namingJSON: Self.sonarrNamingJSON)
        sonarr = sonarrServer
        let radarrServer = try await RadarrFixtureServer(
            namingJSON: #"{"id":1,"renameMovies":true,"replaceIllegalCharacters":false,"colonReplacementFormat":"smart","standardMovieFormat":"{Movie Title} ({Release Year})","movieFolderFormat":"{Movie CleanTitle} ({Release Year})"}"#
        )
        radarr = radarrServer
        let app = launch()

        XCTAssertTrue(openDestination(.naming, in: app))
        XCTAssertTrue(tapWhenHittable(app.buttons["Radarr"]), "Sonarr and Radarr should both be offered in the server scope bar.")
        let builder = openFormat("Standard", containing: "Example Movie (2026)", title: "Movie File Format", in: app, alreadyOnList: true)
        XCTAssertTrue(tapWhenHittable(element("naming.tray.quality", in: app)))
        XCTAssertTrue(waitForPreview(containing: "Example Movie (2026) WEBDL-1080p Proper", in: app), "Preview: \(previewText(in: app))")

        confirmSave(from: builder, naming: "Radarr", in: app)
        XCTAssertTrue(app.navigationBars["Naming"].waitForExistence(timeout: 15))

        let write = try XCTUnwrap(radarrServer.requests.first { $0.method == "PUT" && $0.path == "/api/v3/config/naming/1" }, "Radarr must receive the write. Radarr: \(radarrServer.requests.map(\.path))")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(write.body.utf8)) as? [String: Any])
        XCTAssertEqual(config["standardMovieFormat"] as? String, "{Movie Title} ({Release Year}) {Quality Full}")
        XCTAssertEqual(config["movieFolderFormat"] as? String, "{Movie CleanTitle} ({Release Year})", "The folder format must go back untouched.")
        XCTAssertEqual(config["replaceIllegalCharacters"] as? Bool, false)
        XCTAssertEqual(config["colonReplacementFormat"] as? Int, 4, "Radarr's string colon setting must survive as the value it decoded to.")
        XCTAssertFalse(sonarrServer.hasReceivedRequest(method: "PUT", path: Self.standardPath), "Nothing may be written to Sonarr.")
    }

    /// Real drag and drop, not its accessibility alternatives: a tray block dropped at
    /// the front of the board leads the filename, a placed block dragged to the front
    /// reorders it, and each drop is exactly one undo step. Nothing is written.
    @MainActor
    func testDraggingFromTheTrayAndReorderingOnTheBoardUpdatesThePreview() async throws {
        let server = try await SonarrFixtureServer(seriesJSON: "[]", namingJSON: Self.sonarrNamingJSON)
        sonarr = server
        let app = launch()

        openFormat("Standard", title: "Standard Episode Format", in: app)
        XCTAssertTrue(waitForPreview(containing: "Example Show (2026) - S02E03", in: app))

        // Two equal columns filled in reading order.
        let showName = block(titled: "Show name", in: app)
        let episodeNumber = block(titled: "Episode number", in: app)
        XCTAssertTrue(showName.waitForExistence(timeout: 10) && episodeNumber.waitForExistence(timeout: 10))
        XCTAssertEqual(showName.frame.width, episodeNumber.frame.width, accuracy: 1, "Blocks share equal column widths.")
        XCTAssertEqual(showName.frame.minY, episodeNumber.frame.minY, accuracy: 1, "The second block sits beside the first.")
        XCTAssertLessThan(showName.frame.maxX, episodeNumber.frame.minX, "Reading order runs left to right.")

        drag(element("naming.tray.year", in: app), toLeadingEdgeOf: block(titled: "Show name", in: app))
        XCTAssertTrue(
            waitForPreview(containing: "(2026) - Example Show (2026) - S02E03", in: app, timeout: 10),
            "A tray block dropped before the first block must lead the filename. Preview: \(previewText(in: app))"
        )

        drag(block(titled: "Episode number", in: app), toLeadingEdgeOf: block(titled: "Year", in: app))
        XCTAssertTrue(
            waitForPreview(containing: "S02E03 - (2026) - Example Show (2026)", in: app, timeout: 10),
            "Dragging a placed block to the front must reorder it. Preview: \(previewText(in: app))"
        )

        XCTAssertTrue(tapWhenHittable(app.buttons["Undo"]))
        XCTAssertTrue(
            waitForPreview(containing: "(2026) - Example Show (2026) - S02E03", in: app),
            "One drop is one undo step. Preview: \(previewText(in: app))"
        )
        XCTAssertFalse(server.hasReceivedRequest(method: "PUT", path: Self.standardPath), "Dragging edits the local draft only.")
    }

    /// At accessibility text sizes the board is one column, and drops follow it: a
    /// block dragged onto the top of another goes above it, and a tray block dropped on
    /// the top of the last block lands just before it. Each drop is one undo step.
    @MainActor
    func testOneColumnAtAccessibilitySizesPlacesDropsTopToBottom() async throws {
        let server = try await SonarrFixtureServer(seriesJSON: "[]", namingJSON: Self.sonarrNamingJSON)
        sonarr = server
        let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])

        openFormat("Standard", title: "Standard Episode Format", in: app)
        let showName = block(titled: "Show name", in: app)
        let episodeNumber = block(titled: "Episode number", in: app)
        XCTAssertTrue(showName.waitForExistence(timeout: 10) && episodeNumber.waitForExistence(timeout: 10))
        XCTAssertEqual(showName.frame.minX, episodeNumber.frame.minX, accuracy: 1, "Accessibility sizes use one column.")
        XCTAssertGreaterThanOrEqual(episodeNumber.frame.minY, showName.frame.maxY, "The second block sits below the first.")

        drag(episodeNumber, toLeadingEdgeOf: showName)
        XCTAssertTrue(
            waitForPreview(containing: "S02E03 - Example Show (2026)", in: app, timeout: 10),
            "A block dropped on the top of the first block must move above it. Preview: \(previewText(in: app))"
        )

        let trayShowName = element("naming.tray.showName", in: app)
        let lastBlock = block(titled: "Show name", in: app)
        XCTAssertTrue(scrollUntilHittable([trayShowName, lastBlock], in: app), "The last block and the tray should fit on screen together.")
        drag(trayShowName, toLeadingEdgeOf: lastBlock)
        XCTAssertTrue(
            waitForPreview(containing: "S02E03 - Example Show - Example Show (2026)", in: app, timeout: 10),
            "A tray block dropped on the top of the last block must land before it. Preview: \(previewText(in: app))"
        )

        XCTAssertTrue(tapWhenHittable(app.buttons["Undo"]))
        XCTAssertTrue(waitForPreview(containing: "S02E03 - Example Show (2026)", in: app), "One drop is one undo step.")
        XCTAssertFalse(server.hasReceivedRequest(method: "PUT", path: Self.standardPath))
    }

    // MARK: - Helpers

    /// Scrolls the builder a short step at a time until every element can be hit, for
    /// layouts too tall to show the board and the tray together. The quick press does
    /// not lift a block, so it scrolls even when it starts over one.
    @MainActor
    private func scrollUntilHittable(_ elements: [XCUIElement], in app: XCUIApplication) -> Bool {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if elements.allSatisfy({ $0.exists && $0.isHittable }) { return true }
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.65))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return elements.allSatisfy { $0.exists && $0.isHittable }
    }

    /// A real touch drag: a long press lifts the block, then it travels slowly to just
    /// inside the target's top leading corner - before it in columns and in a single
    /// column alike - and is held there so the board can settle its slot before the drop.
    @MainActor
    private func drag(_ source: XCUIElement, toLeadingEdgeOf target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(source.waitForExistence(timeout: 10), "The drag source should be on screen.", file: file, line: line)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "The drop target should be on screen.", file: file, line: line)
        XCTAssertTrue(source.wait(for: \.isHittable, toEqual: true, timeout: 5), file: file, line: line)
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2))
        start.press(forDuration: 0.8, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
    }


    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"] + arguments
        if let sonarr { app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarr.baseURL }
        if let radarr { app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = radarr.baseURL }
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        return app
    }

    /// Opens a format's builder through Naming and proves it arrived.
    @MainActor
    @discardableResult
    private func openFormat(
        _ rowTitle: String,
        containing example: String? = nil,
        title: String,
        in app: XCUIApplication,
        alreadyOnList: Bool = false
    ) -> XCUIElement {
        if !alreadyOnList {
            XCTAssertTrue(openDestination(.naming, in: app))
        }
        let predicate = example.map { NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "\(rowTitle),", $0) }
            ?? NSPredicate(format: "label BEGINSWITH %@", "\(rowTitle),")
        let row = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(tapWhenHittable(row, timeout: 20), "The \(rowTitle) row should be offered once the server has answered.")
        let builder = app.navigationBars[title]
        XCTAssertTrue(builder.waitForExistence(timeout: 10), "\(rowTitle) must push its builder.")
        XCTAssertFalse(builder.buttons["Save"].exists, "An existing naming format must open read-only.")
        XCTAssertTrue(tapWhenHittable(builder.buttons["Edit"]), "Edit should unlock the naming draft.")
        return builder
    }

    @MainActor
    private func confirmSave(from builder: XCUIElement, naming serverName: String, in app: XCUIApplication) {
        let save = builder.buttons["Save"]
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 10), "Save must be offered for an edited draft.")
        XCTAssertTrue(tapWhenHittable(save))
        let alert = app.alerts["Save Format?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", serverName)).firstMatch.exists,
            "The confirmation must name the server being written."
        )
        XCTAssertTrue(tapWhenHittable(alert.buttons["Save"]))
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func block(titled title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "naming.block", title))
            .firstMatch
    }

    @MainActor
    private func previewText(in app: XCUIApplication) -> String {
        let preview = element("naming.preview", in: app)
        return preview.exists ? preview.label : ""
    }

    /// Waits on the preview's own text, the one evidence every edit shares.
    @MainActor
    private func waitForPreview(containing text: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "naming.preview", text))
            .firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// Answers the unsaved-changes alert with Keep Editing. A confirmation dialog on
    /// iOS 26 would leave that cancel-role button out, so a tap outside stays as the
    /// fallback should the question ever be presented that way again.
    @MainActor
    private func keepEditing(in app: XCUIApplication) -> Bool {
        guard app.buttons["Discard Changes"].waitForExistence(timeout: 10) else { return false }
        let keepEditing = app.buttons["Keep Editing"]
        if keepEditing.exists { return tapWhenHittable(keepEditing) }
        let outside = app.otherElements["PopoverDismissRegion"]
        guard outside.exists else { return false }
        outside.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.1)).tap()
        return app.buttons["Discard Changes"].waitForNonExistence(timeout: 5)
    }

    /// A tap on an element that exists but is not yet hittable is dropped silently,
    /// so wait for hittability first.
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        guard element.waitForExistence(timeout: timeout),
              element.wait(for: \.isHittable, toEqual: true, timeout: timeout) else { return false }
        element.tap()
        return true
    }
}
