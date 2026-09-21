//
//  DownloadsImportIssueJourneyUITests.swift
//  TrawlUITests
//
//  The Issues segment of the Downloads tab, driven against a real loopback Sonarr
//  reporting a stuck season pack.
//
//  ## Why this needs a UI test at all
//
//  `DownloadsBatchSelectionTests` already pins the two pure decisions - which rows
//  collapse (`oneRowPerIssue` / `importIssueSignature`) and which screen a row opens
//  (`DownloadListItem.detailDestination`). What no unit test can reach is everything
//  between those decisions and the person: that the collapsed list is what actually
//  renders, that the row is tappable and lands on the series rather than the torrent,
//  and that the Import Issues card is *open* when it gets there. Those last two are
//  `@State` seeding and a `.task` keyed on data that arrives after first render -
//  invisible to a unit test and, before this suite, verifiable only by eye.
//
//  ## The shape Sonarr really sends
//
//  A season pack is one download, and Sonarr reports it once **per episode**: five
//  queue records sharing a `downloadId` and a release `title`, each carrying its own
//  per-file `statusMessages.title`. Four of them here name one failure and the fifth
//  names a different one, which is the case that makes this a signature rather than a
//  plain download-ID collapse: the repeats must fold together while the genuinely
//  different failure stays on screen. That is why the assertions below are counts of
//  each failure's text and not "is there a row".
//
//  The per-file titles differ on every record deliberately - `importIssueSignature`
//  excludes `ArrStatusMessage.title` precisely because Sonarr puts the individual file
//  there, and a fixture that shared one title would pass even if the exclusion were
//  removed.

import XCTest

final class DownloadsImportIssueJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarr?.stop()
        sonarr = nil
    }

    private static let seriesTitle = "Harbour Lights"
    private static let seriesJSON = #"[{"id":3,"title":"Harbour Lights","statistics":{"episodeCount":10,"episodeFileCount":6}}]"#

    private static let sharedFailure = "One or more episodes expected in this release were not imported"
    private static let distinctFailure = "Episode file already exists on disk"

    /// Five records of one stuck pack: four reporting `sharedFailure`, one reporting
    /// `distinctFailure`, all on `downloadId` `pack-abc` and series 3.
    private static var packQueueJSON: String {
        let repeats = (1...4).map { episode in
            """
            {"id":10\(episode),"title":"Harbour.Lights.S02.1080p.WEB","status":"completed",\
            "trackedDownloadStatus":"warning","trackedDownloadState":"importPending",\
            "downloadId":"pack-abc","seriesId":3,"seasonNumber":2,"episodeId":\(episode),\
            "size":1000,"sizeleft":0,"downloadClient":"qBittorrent",\
            "statusMessages":[{"title":"Harbour.Lights.S02E0\(episode).1080p.WEB.mkv",\
            "messages":["\(sharedFailure)"]}]}
            """
        }
        let distinct = """
        {"id":105,"title":"Harbour.Lights.S02.1080p.WEB","status":"completed",\
        "trackedDownloadStatus":"warning","trackedDownloadState":"importPending",\
        "downloadId":"pack-abc","seriesId":3,"seasonNumber":2,"episodeId":5,\
        "size":1000,"sizeleft":0,"downloadClient":"qBittorrent",\
        "statusMessages":[{"title":"Harbour.Lights.S02E05.1080p.WEB.mkv",\
        "messages":["\(distinctFailure)"]}]}
        """
        let records = (repeats + [distinct]).joined(separator: ",")
        return #"{"page":1,"pageSize":20,"totalRecords":5,"records":[\#(records)]}"#
    }

    /// Regressions this catches: `issueItems` losing its `oneRowPerIssue` call, so one
    /// stuck pack lists itself once per episode again; `importIssueSignature` widening
    /// to include the per-file title, which silently turns the collapse into a no-op;
    /// or the signature narrowing to the download ID alone, which would hide the second
    /// failure entirely - the outcome Issues was deliberately left un-collapsed to
    /// avoid, and the one a "there is a row" assertion would never notice.
    @MainActor
    func testStuckSeasonPackCollapsesToOneRowPerDistinctFailure() async throws {
        let app = try await launchWithStuckPack()

        XCTAssertTrue(openDestination(.downloads, in: app), "The Downloads tab should be reachable.")
        selectSegment("Issues", app: app)

        let shared = app.staticTexts[Self.sharedFailure].firstMatch
        XCTAssertTrue(
            shared.waitForExistence(in: app, timeout: 20),
            "The stuck pack's failure should reach the Issues segment over real HTTP."
        )

        XCTAssertEqual(
            matches(of: Self.sharedFailure, in: app), 1,
            """
            Sonarr reported this one failure on four episode records of a single \
            download. Issues must show it once - four identical rows, every one \
            opening the same screen, is the bug this collapse exists for.
            """
        )
        XCTAssertEqual(
            matches(of: Self.distinctFailure, in: app), 1,
            """
            The fifth record of the same pack failed for a different reason and must \
            survive the collapse. A key of download ID alone would swallow it, which \
            is a worse bug than the repetition it fixes.
            """
        )
    }

    /// Regressions this catches: the import-issue branch in
    /// `DownloadListItem.detailDestination` / `DownloadsView.arrQueueRow` being
    /// reordered behind the client links, so the row dead-ends in the download's
    /// detail screen; the `scrollToImportIssues` hint being dropped from the
    /// destination; or `ArrDetailImportIssuesCard` losing `initiallyExpanded`, which
    /// lands the person on a closed disclosure having asked to resolve an issue.
    @MainActor
    func testTappingAnImportIssueOpensTheSeriesWithItsIssuesCardOpen() async throws {
        let app = try await launchWithStuckPack()

        XCTAssertTrue(openDestination(.downloads, in: app), "The Downloads tab should be reachable.")
        selectSegment("Issues", app: app)

        let row = app.staticTexts[Self.sharedFailure].firstMatch
        XCTAssertTrue(
            row.waitForExistence(in: app, timeout: 20),
            "The stuck pack's issue row should render before it can be opened."
        )
        // A tap on a row that exists but is not yet hittable is dropped silently, and
        // the failure then lands on whatever is asserted next rather than here.
        XCTAssertTrue(waitUntilHittable(row, app: app, timeout: 10), "The issue row should become tappable.")
        row.tap()

        // The destination is the *series*, not the download: this is the whole point
        // of the route, and the title is what tells the two screens apart.
        let seriesTitle = app.staticTexts[Self.seriesTitle].firstMatch
        XCTAssertTrue(
            seriesTitle.waitForExistence(in: app, timeout: 20),
            """
            An import-issue row must open the film or series that owns it - where \
            Edit, Resolve, Remove and Blocklist live - and not the download's own \
            detail screen, which offers nothing that resolves an import.
            """
        )

        // `ArrDetailImportIssuesCard` renders its rows only while expanded, so the
        // failure text being present *is* the assertion that the card opened itself.
        // The header alone would appear either way.
        let issuesHeader = app.staticTexts["Import Issues"].firstMatch
        XCTAssertTrue(
            issuesHeader.waitForExistence(in: app, timeout: 15),
            "The series detail should carry an Import Issues card for a queue in this state."
        )
        XCTAssertTrue(
            app.staticTexts[Self.sharedFailure].firstMatch.waitForExistence(in: app, timeout: 15),
            """
            The card must arrive open. Its rows are built only when expanded, so a \
            collapsed card shows the header and hides every control the person came \
            here to use - one more tap for the thing they already asked for.
            """
        )
    }

    // MARK: - Harness

    @MainActor
    private func launchWithStuckPack() async throws -> XCUIApplication {
        let server = try await SonarrFixtureServer(
            seriesJSON: Self.seriesJSON,
            queueJSON: Self.packQueueJSON
        )
        sonarr = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        // The series detail resolves cast credits through TMDb. Without a fixture that
        // lookup sits out a 15s timeout on a screen this suite asserts against, which
        // reads as a flaky failure rather than a missing stub.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(
            ensureRootChromeIsReady(in: app),
            "A launch with a configured Sonarr should reach the app chrome, not the welcome screen."
        )
        return app
    }

    /// Counts the elements carrying exactly this text. A count, not an existence
    /// check: the collapse is only observable as "how many times does this appear".
    @MainActor
    private func matches(of text: String, in app: XCUIApplication) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count
    }

    /// Taps a `TrawlSegmentBar` segment by title, retrying until it is hittable.
    /// Mirrors `DownloadsJourneyUITests.selectSegment`, which is private to that suite.
    @MainActor
    private func selectSegment(_ title: String, app: XCUIApplication) {
        let button = app.buttons[title]
        for _ in 0..<6 {
            if button.exists && button.isHittable {
                button.tap()
                return
            }
            _ = button.waitForExistence(timeout: 1)
        }
        if button.exists { button.tap() }
    }

    /// Bounded ticks against an element that never exists - never `sleep()`, matching
    /// the technique the rest of this target uses.
    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let neverExists = app.staticTexts["__import_issue_fixture_probe__"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            _ = neverExists.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.isHittable
    }
}
