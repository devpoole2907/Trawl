import XCTest

/// Real service failures exercise the shared presentation and its recovery actions.
/// The capture attachments also make the two layouts reviewable across surfaces.
final class ServiceUnavailableJourneyUITests: XCTestCase {
    private var seerr: SeerrUIFixtureServer?
    private var sabnzbd: SABnzbdFixtureServer?
    private var qbittorrent: QBittorrentFixtureServer?

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        seerr?.stop()
        sabnzbd?.stop()
        qbittorrent?.stop()
        seerr = nil
        sabnzbd = nil
        qbittorrent = nil
    }

    @MainActor
    func testDisconnectedSonarrOffersAnEditableCenteredState() throws {
        let app = application()
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = "http://127.0.0.1:1"
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.series, in: app))
        XCTAssertTrue(app.staticTexts["Sonarr Unreachable"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Retry Connection"].exists)
        capture(app, "01-sonarr-unreachable-centered")

        app.buttons["Edit Server"].tap()
        XCTAssertTrue(app.navigationBars["Sonarr"].waitForExistence(timeout: 10), "Recovery must open the real server settings, not just render an inert button.")
    }

    @MainActor
    func testFailedSeerrRequestsDoNotClaimEmptyAndRetryReachesServer() async throws {
        let server = try await SeerrUIFixtureServer()
        seerr = server
        let app = application()
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = server.baseURL
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.requests, in: app))
        XCTAssertTrue(app.staticTexts["Requests Unavailable"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["No Requests"].exists, "A failed request cannot establish that the server has no requests.")
        capture(app, "02-seerr-requests-failed-centered")

        let before = server.requests.filter { $0.path == "/api/v1/request" }.count
        XCTAssertGreaterThan(before, 0)
        app.buttons["Retry"].firstMatch.tap()
        let sentAgain = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requests.filter { $0.path == "/api/v1/request" }.count > before
        }, object: nil)
        await fulfillment(of: [sentAgain], timeout: 10)
        XCTAssertTrue(app.staticTexts["Requests Unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No Requests"].exists)
    }

    @MainActor
    func testSABnzbdFailureKeepsQBittorrentContentAndOffersRetry() async throws {
        let torrentServer = try await QBittorrentFixtureServer()
        qbittorrent = torrentServer
        let newsServer = try await SABnzbdFixtureServer(queueJobName: "Unavailable SAB job")
        sabnzbd = newsServer
        newsServer.setUnauthorized()
        let app = application()
        app.launchEnvironment["TRAWL_UITEST_QBITTORRENT_BASE_URL"] = torrentServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = newsServer.baseURL
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.downloads, in: app))
        XCTAssertTrue(app.staticTexts["SABnzbd Unavailable"].waitForExistence(timeout: 15))
        let holdsTorrent = NSPredicate(format: "label CONTAINS[c] %@", torrentServer.name)
        let torrent = TrawlChrome.isSidebar
            ? app.cells.containing(holdsTorrent).firstMatch
            : app.buttons.matching(holdsTorrent).firstMatch
        XCTAssertTrue(torrent.waitForExistence(in: app, timeout: 15), "The compact error card must preserve the other client's working downloads.")
        XCTAssertTrue(app.buttons["Retry"].exists)
        capture(app, "03-downloads-partial-failure-card")
    }

    @MainActor
    func testRequestSelectionKeepsListUsable() async throws {
        let server = try await SeerrUIFixtureServer(includesRequests: true)
        seerr = server
        let app = application()
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = server.baseURL
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.requests, in: app))
        let movie = app.cells.containing(.staticText, identifier: "Fixture Requested Movie").firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 15))
        movie.tap()
        XCTAssertTrue(app.staticTexts["Movie details loaded from the fixture."].waitForExistence(timeout: 15))
        capture(app, "04-request-movie-selected")
        if TrawlChrome.isSidebar {
            XCTAssertTrue(app.showsScreen(named: "Requests", timeout: 5))
            let series = app.cells.containing(.staticText, identifier: "Fixture Requested Series").firstMatch
            XCTAssertTrue(series.isHittable, "The request list must remain available beside the selected movie.")
            series.tap()
            XCTAssertTrue(app.staticTexts["Series details loaded from the fixture."].waitForExistence(timeout: 15))
            XCTAssertTrue(movie.isHittable, "Selecting another request must preserve the list.")
            capture(app, "05-request-series-selected")
        }
    }

    @MainActor
    func testRequestDecisionsTakeOneTapAndWaitForSuccess() async throws {
        let server = try await SeerrUIFixtureServer(includesRequests: true)
        seerr = server
        let app = application()
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = server.baseURL
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.requests, in: app))

        let movie = app.cells.containing(.staticText, identifier: "Fixture Requested Movie").firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 15))
        movie.tap()
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        approve.tap()

        let approved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/801/approve" }.count == 1
        }, object: nil)
        await fulfillment(of: [approved], timeout: 10)
        XCTAssertEqual(
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/801/approve" }.count,
            1,
            "One Approve tap must send exactly one decision."
        )

        let series = app.cells.containing(.staticText, identifier: "Fixture Requested Series").firstMatch
        XCTAssertTrue(series.waitForExistence(timeout: 10), "A successful compact decision should pop; a split decision should preserve the list.")
        series.tap()
        let decline = app.buttons["Decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 15))
        decline.tap()

        let declined = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/802/decline" }.count == 1
        }, object: nil)
        await fulfillment(of: [declined], timeout: 10)
        XCTAssertEqual(
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/802/decline" }.count,
            1,
            "One Decline tap must send exactly one decision."
        )
        XCTAssertTrue(app.staticTexts["No Requests"].waitForExistence(timeout: 10))
        capture(app, "06-request-decisions-complete")
    }

    @MainActor
    func testFailedRequestDecisionKeepsDetailAndShowsError() async throws {
        let server = try await SeerrUIFixtureServer(includesRequests: true, failsRequestDecisions: true)
        seerr = server
        let app = application()
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = server.baseURL
        app.launch()
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.requests, in: app))

        let movie = app.cells.containing(.staticText, identifier: "Fixture Requested Movie").firstMatch
        XCTAssertTrue(movie.waitForExistence(timeout: 15))
        movie.tap()
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        approve.tap()

        let actionError = app.descendants(matching: .any)["request-action-error"]
        XCTAssertTrue(
            actionError.waitForExistence(timeout: 10),
            "A failed decision must remain in detail and explain the failure instead of dismissing it."
        )
        XCTAssertTrue(app.buttons["Approve"].exists)
        if TrawlChrome.isSidebar {
            XCTAssertTrue(app.staticTexts["Request Action Failed"].exists)
            XCTAssertFalse(
                app.staticTexts["Requests Unavailable"].exists,
                "A failed decision must not relabel an already-loaded queue as unavailable."
            )
        }
        XCTAssertEqual(
            server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/request/801/approve" }.count,
            1
        )
        capture(app, "07-request-decision-failed")
    }

    @MainActor
    private func application() -> XCUIApplication {
        if TrawlChrome.isSidebar { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
