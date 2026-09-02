//
//  LibraryImportScanJourneyUITests.swift
//  TrawlUITests
//
//  Real UI journeys for Library Import's high-risk boundary: a server scan is
//  grouped locally, checked against the live Sonarr library, and then reviewed
//  before any irreversible import command is issued.

import Foundation
import XCTest

final class LibraryImportScanJourneyUITests: XCTestCase {
    private var fixture: LibraryImportScanUIFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        fixture?.stop()
        fixture = nil
    }

    /// Proves the ordinary Library Import path, not an isolated view model:
    /// More -> Library Management -> Library Import -> root folder -> scan. The
    /// fixture deliberately returns one episode already present in Sonarr and one
    /// new episode, so the visible count chips must be the result of both a manual
    /// import scan and the separate in-library status request.
    @MainActor
    func testLibraryScanGroupsOwnedAndNewFilesThenReviewsTheSelection() async throws {
        let fixture = try await LibraryImportScanUIFixtureServer(scenario: .groupedSelection)
        self.fixture = fixture
        let app = launchConfiguredSonarrApp(using: fixture)

        openLibraryImportRoot(in: app)

        let folderTitle = app.navigationBars["import-library"]
        XCTAssertTrue(
            folderTitle.waitForExistence(in: app, timeout: 15),
            "Selecting the configured Sonarr root should push LibraryImportScanView titled with the root folder name."
        )

        XCTAssertTrue(
            app.staticTexts["1 ready"].waitForExistence(in: app, timeout: 15),
            "The scan should show one file ready to import after decoding the fixture's manual-import response."
        )
        XCTAssertTrue(
            app.staticTexts["1 extra"].waitForExistence(in: app, timeout: 10),
            "The second scanned file should be marked as an extra copy only after loadInLibraryStatus() compares it with Sonarr's existing episode file."
        )
        XCTAssertTrue(
            app.staticTexts[LibraryImportScanUIFixtureServer.seriesTitle].waitForExistence(in: app, timeout: 10),
            "The decoded manual-import items should be grouped under their real Sonarr series title."
        )
        XCTAssertTrue(
            firstButton(labelContaining: LibraryImportScanUIFixtureServer.readyFileName, in: app).waitForExistence(in: app, timeout: 10),
            "The ready group should expose the new server-decoded file; the existing episode belongs only in the separate extra-copy count."
        )

        let scanRequests = fixture.requests.filter {
            $0.method == "GET" && $0.path == "/api/v3/manualimport"
        }
        XCTAssertEqual(scanRequests.count, 1, "Opening the scan should make exactly one manual-import GET.")
        guard let scanRequest = scanRequests.first else { return }
        XCTAssertEqual(scanRequest.body, "", "Library scanning is a bodyless GET request.")
        XCTAssertEqual(scanRequest.values(for: "folder"), [LibraryImportScanUIFixtureServer.rootFolderPath])
        XCTAssertEqual(scanRequest.values(for: "filterExistingFiles"), ["true"])
        XCTAssertEqual(scanRequest.queryItems.count, 2, "The library scan must not accidentally carry a manual-import seriesId query.")

        let episodeStatusRequests = fixture.requests.filter {
            $0.method == "GET" && $0.path == "/api/v3/episode"
        }
        XCTAssertEqual(episodeStatusRequests.count, 1, "loadInLibraryStatus() should query Sonarr once for the scanned series.")
        guard let episodeStatusRequest = episodeStatusRequests.first else { return }
        XCTAssertEqual(episodeStatusRequest.body, "")
        XCTAssertEqual(episodeStatusRequest.values(for: "seriesId"), [String(LibraryImportScanUIFixtureServer.seriesID)])
        XCTAssertEqual(episodeStatusRequest.queryItems.count, 1)

        let selectButton = app.buttons["Select"]
        XCTAssertTrue(tapWhenHittable(selectButton, in: app, timeout: 10), "The scan should provide selection mode once decoded content exists.")

        let selectAllButton = app.buttons["Select All"]
        XCTAssertTrue(tapWhenHittable(selectAllButton, in: app, timeout: 10), "Selection mode should let the user select every scanned import candidate.")

        let importButton = app.buttons["Import"]
        XCTAssertTrue(tapWhenHittable(importButton, in: app, timeout: 10), "A selected scan should open its review sheet before any import POST is possible.")

        let reviewTitle = app.navigationBars["Review Selection"]
        XCTAssertTrue(reviewTitle.waitForExistence(in: app, timeout: 10), "Import must present the selection review sheet, not immediately mutate the Sonarr library.")
        XCTAssertTrue(
            app.staticTexts["Ready to Import · 1 series · 2 files"].waitForExistence(in: app, timeout: 10),
            "The review must retain the single decoded series group and both selected files, including the upgrade candidate."
        )
        XCTAssertTrue(
            app.staticTexts[LibraryImportScanUIFixtureServer.seriesTitle].waitForExistence(in: app, timeout: 10),
            "The review sheet should visibly carry the selected server-decoded series group forward."
        )
        XCTAssertTrue(
            reviewTitle.buttons["Close"].waitForExistence(in: app, timeout: 5),
            "Review Selection should offer a non-destructive exit before an import is confirmed."
        )

        XCTAssertFalse(
            fixture.requests.contains { $0.method == "POST" && $0.path == "/api/v3/command" },
            "Opening Review Selection must not submit a ManualImport command; only the explicit sheet confirmation may do that."
        )
    }

    /// Reaches the real identify sheet from a server-rejected scan item, then uses
    /// its search field. This executes `searchCatalog(term:)` over the real
    /// SonarrAPIClient rather than only proving the sheet can be presented.
    @MainActor
    func testBlockedScanCanSearchTheSonarrCatalogBeforeAnyImport() async throws {
        let fixture = try await LibraryImportScanUIFixtureServer(scenario: .blockedCatalogSearch)
        self.fixture = fixture
        let app = launchConfiguredSonarrApp(using: fixture)

        openLibraryImportRoot(in: app)

        XCTAssertTrue(
            app.staticTexts["1 blocked"].waitForExistence(in: app, timeout: 15),
            "A server rejection should appear in Library Import's blocked grouping rather than being silently discarded."
        )
        let blockedDisclosure = app.buttons["library-import-blocked-disclosure"]
        XCTAssertTrue(
            blockedDisclosure.waitForExistence(in: app, timeout: 10),
            "The blocked section should expose an accessible disclosure control for the initially hidden server-rejected group."
        )
        XCTAssertEqual(blockedDisclosure.value as? String, "Collapsed")
        XCTAssertTrue(tapWhenHittable(blockedDisclosure, in: app, timeout: 5))
        XCTAssertEqual(blockedDisclosure.value as? String, "Expanded")
        let blockedGroup = firstButton(labelContaining: "Fixture Catalog Candidate", in: app)
        XCTAssertTrue(tapWhenHittable(blockedGroup, in: app, timeout: 10), "Tapping a blocked group should open its real review sheet.")

        let blockedReview = app.navigationBars["Fixture Catalog Candidate"]
        XCTAssertTrue(blockedReview.waitForExistence(in: app, timeout: 10), "The blocked group should present a review sheet with its inferred title.")

        let blockedFile = firstButton(labelContaining: LibraryImportScanUIFixtureServer.blockedFileName, in: app)
        XCTAssertTrue(tapWhenHittable(blockedFile, in: app, timeout: 10), "Tapping the rejected file should open the real Identify File sheet.")

        let identifyTitle = app.navigationBars["Identify File"]
        XCTAssertTrue(identifyTitle.waitForExistence(in: app, timeout: 10), "A blocked file should be recoverable through LibraryImportIdentifySheet.")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(in: app, timeout: 10), "Identify File should expose the catalog search field.")
        searchField.tap()
        searchField.typeText("Fixture Catalog")

        XCTAssertTrue(
            app.staticTexts[LibraryImportScanUIFixtureServer.catalogTitle].waitForExistence(in: app, timeout: 15),
            "Typing a catalog term should render the real Sonarr lookup result, not only local filename suggestions."
        )

        let catalogRequests = fixture.requests.filter {
            $0.method == "GET" && $0.path == "/api/v3/series/lookup" && $0.values(for: "term") == ["Fixture Catalog"]
        }
        XCTAssertEqual(catalogRequests.count, 1, "The explicit catalog search should issue exactly one lookup request for the entered term.")
        guard let catalogRequest = catalogRequests.first else { return }
        XCTAssertEqual(catalogRequest.body, "", "Sonarr catalog lookup is a bodyless GET.")
        XCTAssertEqual(catalogRequest.queryItems.count, 1, "The catalog lookup must contain only the entered term.")

        XCTAssertFalse(
            fixture.requests.contains { $0.method == "POST" && $0.path == "/api/v3/command" },
            "Searching and selecting an identification candidate must not submit an import command before the user explicitly confirms an import."
        )
    }

    /// The Owned tab exists to answer "what of this folder is already in my
    /// library?". The fixture's series lives under the scanned root, so
    /// `computeOwnedTitlesInFolder()` finds it - and the tab has to actually render
    /// that title, not merely count it in a section header the user cannot open.
    @MainActor
    func testOwnedTabRendersTheInLibraryTitlesItCounts() async throws {
        let fixture = try await LibraryImportScanUIFixtureServer(scenario: .groupedSelection)
        self.fixture = fixture
        let app = launchConfiguredSonarrApp(using: fixture)

        openLibraryImportRoot(in: app)

        XCTAssertTrue(
            app.staticTexts["1 ready"].waitForExistence(in: app, timeout: 15),
            "The scan has to finish before the Owned tab has anything to show."
        )

        XCTAssertTrue(
            tapWhenHittable(app.buttons["Owned"], in: app, timeout: 10),
            "The scan screen should offer the Owned segment."
        )

        let ownedRow = app.descendants(matching: .any)
            .matching(identifier: "library-import-owned-\(LibraryImportScanUIFixtureServer.seriesID)")
            .firstMatch
        XCTAssertTrue(
            ownedRow.waitForExistence(in: app, timeout: 10),
            "The Owned tab counted a library title from this folder, so it must show that title's row rather than hiding it behind a section the user can't expand."
        )
        XCTAssertTrue(
            ownedRow.label.contains(LibraryImportScanUIFixtureServer.seriesTitle),
            "The rendered owned row should be the fixture's library series, got: \(ownedRow.label)"
        )

        // The section had a collapse binding with no control to work it, so being
        // expanded by default is only half the fix - the user has to be able to
        // close it and open it again.
        let disclosure = app.buttons["library-import-in-library-disclosure"]
        XCTAssertTrue(disclosure.waitForExistence(in: app, timeout: 10), "The In Library section should expose a disclosure control.")
        XCTAssertEqual(disclosure.value as? String, "Expanded")

        XCTAssertTrue(tapWhenHittable(disclosure, in: app, timeout: 5))
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        XCTAssertFalse(ownedRow.exists, "Collapsing In Library should hide its rows.")

        XCTAssertTrue(tapWhenHittable(disclosure, in: app, timeout: 5))
        XCTAssertEqual(disclosure.value as? String, "Expanded")
        XCTAssertTrue(ownedRow.waitForExistence(in: app, timeout: 5), "Re-expanding In Library should bring its rows back.")
    }

    /// The reported regression: leaving a folder and coming back re-scanned it and
    /// re-ran Auto Match, so every match the user had already watched land was
    /// thrown away. The scan describes the folder, so it must survive the pop -
    /// proven here by the identified file still being counted with no second
    /// manual-import scan and no second catalog lookup.
    @MainActor
    func testAutoMatchResultsSurviveNavigatingAwayAndBack() async throws {
        let fixture = try await LibraryImportScanUIFixtureServer(scenario: .autoMatchPersistence)
        self.fixture = fixture
        let app = launchConfiguredSonarrApp(using: fixture)

        openLibraryImportRoot(in: app)

        let identifiedChip = app.staticTexts["1 identified"]
        XCTAssertTrue(
            identifiedChip.waitForExistence(in: app, timeout: 30),
            "Auto Match should resolve the unknown-series file against the Sonarr catalog lookup and move it into the identified bucket."
        )

        let scansAfterFirstVisit = fixture.requests.filter { $0.method == "GET" && $0.path == "/api/v3/manualimport" }.count
        let lookupsAfterFirstVisit = fixture.requests.filter { $0.method == "GET" && $0.path == "/api/v3/series/lookup" }.count
        XCTAssertEqual(scansAfterFirstVisit, 1, "Opening the folder should scan it exactly once.")
        XCTAssertEqual(lookupsAfterFirstVisit, 1, "Auto Match should look the one unidentified group up exactly once.")

        let backButton = backButton(in: app.navigationBars["import-library"])
        XCTAssertTrue(tapWhenHittable(backButton, in: app, timeout: 10), "The scan should be dismissable back to the import location list.")
        XCTAssertTrue(
            app.navigationBars["Library Import"].waitForExistence(in: app, timeout: 10),
            "Going back should land on the Library Import location list."
        )

        let rootFolder = firstButton(labelContaining: LibraryImportScanUIFixtureServer.rootFolderPath, in: app)
        XCTAssertTrue(tapWhenHittable(rootFolder, in: app, timeout: 10), "The root folder should still be selectable on the way back in.")
        XCTAssertTrue(
            app.navigationBars["import-library"].waitForExistence(in: app, timeout: 10),
            "Re-selecting the root folder should push the scan view again."
        )

        XCTAssertTrue(
            identifiedChip.waitForExistence(in: app, timeout: 15),
            "Returning to the folder must show the file Auto Match already identified, not an empty or re-scanning screen."
        )
        XCTAssertEqual(
            fixture.requests.filter { $0.method == "GET" && $0.path == "/api/v3/manualimport" }.count,
            1,
            "Returning to a folder already scanned this session must not re-scan it."
        )
        XCTAssertEqual(
            fixture.requests.filter { $0.method == "GET" && $0.path == "/api/v3/series/lookup" }.count,
            1,
            "Returning must not re-run Auto Match over a file it already matched."
        )
    }

    // MARK: Navigation and UI helpers

    @MainActor
    private func launchConfiguredSonarrApp(using fixture: LibraryImportScanUIFixtureServer) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = fixture.baseURL
        app.launch()
        return app
    }

    /// Public assembly path: More -> Library Management -> Library Import -> the
    /// root folder returned from the real Sonarr `GET /rootfolder` response.
    @MainActor
    private func openLibraryImportRoot(in app: XCUIApplication) {
        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")
        XCTAssertTrue(openDestination(.libraryManagement, in: app), "Library Management should be reachable.")

        let libraryImport = firstButton(labelContaining: "Library Import", in: app)
        XCTAssertTrue(tapWhenHittable(libraryImport, in: app, timeout: 10), "Library Management should expose Library Import.")
        XCTAssertTrue(app.navigationBars["Library Import"].waitForExistence(in: app, timeout: 10))

        let rootFolder = firstButton(labelContaining: LibraryImportScanUIFixtureServer.rootFolderPath, in: app)
        XCTAssertTrue(tapWhenHittable(rootFolder, in: app, timeout: 10), "Library Import should present the root folder decoded from Sonarr.")
    }

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @discardableResult
    @MainActor
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }
}
