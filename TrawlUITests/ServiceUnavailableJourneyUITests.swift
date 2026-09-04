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
