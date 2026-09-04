//
//  ArrDownloadClientsJourneyUITests.swift
//  TrawlUITests
//
//  `ArrDownloadClientListView` measured 0.2% coverage - effectively never rendered -
//  while being the screen the configuration wizard now sends people to when it finds
//  a server with no download client. Routing users into an unexercised screen is how
//  a fix path turns into a dead end, so this opens it against a real Sonarr and
//  asserts it renders the client the server actually reported.
//

import Foundation
import XCTest

final class ArrDownloadClientsJourneyUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?

    static let clientName = "Fixture qBittorrent"
    static let clientHost = "10.0.0.5"
    static let clientPort = "8080"

    /// The shape Sonarr returns from `GET /api/v3/downloadclient`, including the
    /// `fields` array the row reads its host and port out of.
    static let downloadClientsJSON = """
    [{
      "id": 1,
      "name": "\(clientName)",
      "implementation": "QBittorrent",
      "implementationName": "qBittorrent",
      "configContract": "QBittorrentSettings",
      "enable": true,
      "priority": 1,
      "protocol": "torrent",
      "fields": [
        {"name": "host", "value": "\(clientHost)"},
        {"name": "port", "value": "\(clientPort)"}
      ]
    }]
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarr?.stop()
        sonarr = nil
    }

    @MainActor
    func testSonarrDownloadClientsRenderTheServersOwnClient() async throws {
        let sonarr = try await SonarrFixtureServer(
            seriesJSON: #"[{"id":1,"title":"Fixture Series"}]"#,
            downloadClientsJSON: Self.downloadClientsJSON
        )
        self.sonarr = sonarr

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarr.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(ensureRootChromeIsReady(in: app), "A configured Sonarr launch should reach the app chrome.")

        // Each step asserts where it landed. A CONTAINS match reports a successful
        // tap even when it hits the wrong row, so without this the failure surfaces
        // several assertions later pointing at the wrong thing.
        XCTAssertTrue(
            openDestination(.downloadClients, in: app),
            "The Integrations & Automation hub should be reachable."
        )

        // Compact only. `openDestination` lands on the Integrations hub there and
        // this is the row that opens the screen; on the sidebar chrome the screen
        // *is* the destination and there is no hub in between, so looking for a row
        // to tap fails against a screen that is already open.
        if !TrawlChrome.isSidebar {
            let downloadClients = firstButton(labelContaining: "Download Clients", in: app)
            XCTAssertTrue(tapWhenHittable(downloadClients, in: app, timeout: 12), "Integrations & Automation should expose Download Clients.")
        }
        XCTAssertTrue(
            app.showsScreen(named: "Download Clients"),
            "The Download Clients hub should render."
        )

        let sonarrClients = firstRow(labelContaining: "Sonarr Download Clients", in: app)
        XCTAssertTrue(
            tapWhenHittable(sonarrClients, in: app, timeout: 12),
            "The hub should offer Sonarr's own download clients - this is where the setup check routes a server that has none."
        )

        // Decoded from the server's real response, not from anything the app holds:
        // the name, the implementation and the host:port all come off the wire.
        XCTAssertTrue(
            app.staticTexts[Self.clientName].waitForExistence(in: app, timeout: 15),
            "The list should render the download client Sonarr actually reported."
        )
        XCTAssertTrue(
            app.staticTexts["\(Self.clientHost):\(Self.clientPort)"].waitForExistence(in: app, timeout: 10),
            "The row's host and port are read out of the client's `fields` array - a decode regression there leaves the row blank rather than failing loudly."
        )

        XCTAssertTrue(
            sonarr.hasReceivedRequest(method: "GET", path: "/api/v3/downloadclient"),
            "The screen must have fetched the clients over real HTTP rather than rendering from a cache."
        )
    }

    // MARK: Helpers

    @MainActor
    private func firstButton(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// A row, whichever element the chrome makes of it.
    ///
    /// These rows push at compact width, where a row is a `Button`. Beside a detail
    /// pane they select instead, and a selecting row is a `Cell` - so a query for
    /// buttons finds nothing and reports a list that is plainly on screen as empty.
    @MainActor
    private func firstRow(labelContaining text: String, in app: XCUIApplication) -> XCUIElement {
        let button = firstButton(labelContaining: text, in: app)
        // Waited for, not merely asked about: the row this wants is
        // usually the Button, and testing `exists` the instant the screen
        // opens finds it absent and falls through to a Cell that wraps it -
        // which is a different element, and tapping it does not always push.
        if button.waitForExistence(timeout: 3) { return button }
        return app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
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
