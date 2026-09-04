import Foundation
import XCTest

/// Protects Trawl's primary existing-library acquisition workflow through the
/// public UI: automatic search, interactive release discovery, release detail,
/// and the final grab. Remote services are real loopback HTTP fixtures; the app's
/// views, managers, clients, persistence, and notification feedback are unchanged.
final class ArrReleaseAcquisitionJourneyUITests: XCTestCase {
    private var sonarrServer: ArrSearchAddFixtureServer?
    private var radarrServer: RadarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        sonarrServer?.stop()
        radarrServer?.stop()
        sonarrServer = nil
        radarrServer = nil
    }

    @MainActor
    func testSonarrAutomaticThenInteractiveSearchDownloadsSelectedRelease() async throws {
        let seriesID = 701
        let seriesTitle = "Fixture Acquisition Series"
        let releaseTitle = "Fixture Acquisition Series S01 1080p"
        let releaseGuid = "  sonarr-acquisition-guid  "
        let releaseIndexerID = 17
        let seriesJSON = #"""
        {
          "id": \#(seriesID),
          "title": "\#(seriesTitle)",
          "titleSlug": "fixture-acquisition-series",
          "monitored": true,
          "seasons": [
            {
              "seasonNumber": 1,
              "monitored": true,
              "statistics": {"episodeCount": 1, "episodeFileCount": 0, "totalEpisodeCount": 1}
            }
          ],
          "statistics": {"seasonCount": 1, "episodeCount": 1, "episodeFileCount": 0}
        }
        """#
        let releaseJSON = #"""
        [{
          "guid": "\#(releaseGuid)",
          "indexerId": \#(releaseIndexerID),
          "title": "\#(releaseTitle)",
          "indexer": "Fixture Sonarr Indexer",
          "protocol": "usenet",
          "size": 2147483648,
          "ageHours": 4,
          "approved": true,
          "rejected": false,
          "downloadAllowed": true,
          "fullSeason": true,
          "quality": {"quality": {"name": "WEBDL-1080p"}}
        }]
        """#

        let server = try await ArrSearchAddFixtureServer(
            librarySeriesJSON: "[\(seriesJSON)]",
            lookupResponseJSON: "[]",
            addedSeriesJSON: seriesJSON,
            releaseResponseJSON: releaseJSON
        )
        sonarrServer = server

        let app = launchApp(serviceEnvironmentKey: "TRAWL_UITEST_SONARR_BASE_URL", baseURL: server.baseURL)
        try openLibraryItem(
            library: .series,
            title: seriesTitle,
            in: app,
            diagnostics: { "Requests: \(server.requests)" }
        )

        let automatic = firstButton(labelContains: "Automatic", in: app)
        XCTAssertTrue(
            automatic.waitForExistence(in: app, timeout: 15),
            "An in-library Sonarr series should expose its real Automatic search action."
        )
        XCTAssertTrue(tapWhenHittable(automatic, in: app, timeout: 10))
        XCTAssertTrue(
            element(labelContains: "Search Queued", in: app).waitForExistence(timeout: 15),
            "A successful Sonarr command should produce the user-visible Search Queued confirmation."
        )

        let command = try XCTUnwrap(
            server.requests.last { $0.method == "POST" && $0.path == "/api/v3/command" },
            "Automatic Search must reach Sonarr's command endpoint."
        )
        let commandBody = try jsonObject(command.body)
        XCTAssertEqual(commandBody["name"] as? String, "SeriesSearch")
        XCTAssertEqual(commandBody["seriesId"] as? Int, seriesID)

        let interactive = firstButton(labelContains: "Interactive", in: app)
        XCTAssertTrue(interactive.waitForExistence(in: app, timeout: 15))
        XCTAssertTrue(tapWhenHittable(interactive, in: app, timeout: 10))

        let releaseRow = app.staticTexts[releaseTitle]
        XCTAssertTrue(
            releaseRow.waitForExistence(in: app, timeout: 20),
            "Interactive Search should render the release returned through the real Sonarr client. Requests: \(server.requests)"
        )
        let releaseLookup = try XCTUnwrap(
            server.requests.last { $0.method == "GET" && $0.path == "/api/v3/release" }
        )
        XCTAssertEqual(queryValues(releaseLookup.rawQuery)["seriesId"], String(seriesID))
        XCTAssertEqual(queryValues(releaseLookup.rawQuery)["seasonNumber"], "1")
        XCTAssertTrue(tapWhenHittable(releaseRow, in: app, timeout: 10))

        let download = app.buttons["Download Release"]
        XCTAssertTrue(
            download.waitForExistence(in: app, timeout: 15),
            "Selecting a release should open its production detail screen and download action."
        )
        XCTAssertTrue(tapWhenHittable(download, in: app, timeout: 10))
        XCTAssertTrue(
            element(labelContains: "Grabbed", in: app).waitForExistence(timeout: 15),
            "A successful release grab should produce the visible Grabbed confirmation."
        )

        let grab = try XCTUnwrap(
            server.requests.last { $0.method == "POST" && $0.path == "/api/v3/release" }
        )
        let grabBody = try jsonObject(grab.body)
        XCTAssertEqual(grabBody["guid"] as? String, releaseGuid.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(grabBody["indexerId"] as? Int, releaseIndexerID)
        XCTAssertFalse(app.navigationBars["Release"].exists, "A successful grab should dismiss the interactive-search sheet.")
    }

    @MainActor
    func testRadarrAutomaticThenInteractiveSearchDownloadsSelectedRelease() async throws {
        let releaseTitle = "Fixture Movie Trawl Signal 1080p"
        let releaseGuid = "radarr-acquisition-guid"
        let releaseIndexerID = 23
        let releaseJSON = #"""
        [{
          "guid": "\#(releaseGuid)",
          "indexerId": \#(releaseIndexerID),
          "title": "\#(releaseTitle)",
          "indexer": "Fixture Radarr Indexer",
          "protocol": "torrent",
          "size": 4294967296,
          "seeders": 42,
          "leechers": 3,
          "approved": true,
          "rejected": false,
          "downloadAllowed": true,
          "quality": {"quality": {"name": "Bluray-1080p"}}
        }]
        """#

        let server = try await RadarrFixtureServer(releaseResponseJSON: releaseJSON)
        radarrServer = server

        let app = launchApp(serviceEnvironmentKey: "TRAWL_UITEST_RADARR_BASE_URL", baseURL: server.baseURL)
        try openLibraryItem(
            library: .movies,
            title: RadarrFixtureServer.movieTitle,
            in: app,
            diagnostics: { "Requests: \(server.requests)" }
        )

        let automatic = firstButton(labelContains: "Automatic", in: app)
        XCTAssertTrue(
            automatic.waitForExistence(in: app, timeout: 15),
            "An in-library Radarr movie should expose its real Automatic search action."
        )
        XCTAssertTrue(tapWhenHittable(automatic, in: app, timeout: 10))
        XCTAssertTrue(
            element(labelContains: "Search Queued", in: app).waitForExistence(timeout: 15),
            "A successful Radarr command should produce the user-visible Search Queued confirmation."
        )

        let command = try XCTUnwrap(
            server.requests.last { $0.method == "POST" && $0.path == "/api/v3/command" },
            "Automatic Search must reach Radarr's command endpoint."
        )
        let commandBody = try jsonObject(command.body)
        XCTAssertEqual(commandBody["name"] as? String, "MoviesSearch")
        XCTAssertEqual(commandBody["movieIds"] as? [Int], [RadarrFixtureServer.movieId])

        let interactive = firstButton(labelContains: "Interactive", in: app)
        XCTAssertTrue(interactive.waitForExistence(in: app, timeout: 15))
        XCTAssertTrue(tapWhenHittable(interactive, in: app, timeout: 10))

        let releaseRow = app.staticTexts[releaseTitle]
        XCTAssertTrue(
            releaseRow.waitForExistence(in: app, timeout: 20),
            "Interactive Search should render the release returned through the real Radarr client. Requests: \(server.requests)"
        )
        let releaseLookup = try XCTUnwrap(
            server.requests.last { $0.method == "GET" && $0.path == "/api/v3/release" }
        )
        XCTAssertEqual(queryValues(releaseLookup.rawQuery)["movieId"], String(RadarrFixtureServer.movieId))
        XCTAssertTrue(tapWhenHittable(releaseRow, in: app, timeout: 10))

        let download = app.buttons["Download Release"]
        XCTAssertTrue(download.waitForExistence(in: app, timeout: 15))
        XCTAssertTrue(tapWhenHittable(download, in: app, timeout: 10))
        XCTAssertTrue(
            element(labelContains: "Grabbed", in: app).waitForExistence(timeout: 15),
            "A successful Radarr release grab should produce the visible Grabbed confirmation."
        )

        let grab = try XCTUnwrap(
            server.requests.last { $0.method == "POST" && $0.path == "/api/v3/release" }
        )
        let grabBody = try jsonObject(grab.body)
        XCTAssertEqual(grabBody["guid"] as? String, releaseGuid)
        XCTAssertEqual(grabBody["indexerId"] as? Int, releaseIndexerID)
        XCTAssertFalse(app.navigationBars["Release"].exists, "A successful grab should dismiss the interactive-search sheet.")
    }

    @MainActor
    private func launchApp(serviceEnvironmentKey: String, baseURL: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment[serviceEnvironmentKey] = baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()
        return app
    }

    @MainActor
    private func openLibraryItem(
        library: TrawlDestination,
        title: String,
        in app: XCUIApplication,
        diagnostics: () -> String
    ) throws {
        XCTAssertTrue(ensureRootChromeIsReady(in: app), "The configured service should reach the real app chrome.")
        XCTAssertTrue(openDestination(library, in: app), "The \(library.title) library should be reachable.")

        XCTAssertTrue(
            app.staticTexts[title].waitForExistence(timeout: 20),
            "The fixture's library item should arrive through the real service connection. \(diagnostics())"
        )
        // `openLibraryItem`, not a tap on the title: on iPad the row is a selection
        // `Cell` and the title appears twice, once in the list and once as the detail
        // column's decorative header - and it is the header that `staticTexts[title]`
        // returns, which reports itself unhittable forever.
        XCTAssertTrue(openLibraryItem(titled: title, in: app, timeout: 15))
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
    }

    @MainActor
    private func firstButton(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    private func element(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    @MainActor
    @discardableResult
    private func tapWhenHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        guard element.waitForExistence(in: app, timeout: timeout) else { return false }
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if element.isHittable {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                return true
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return false
    }

    private func jsonObject(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
            "Expected a JSON object request body."
        )
    }

    private func queryValues(_ rawQuery: String?) -> [String: String] {
        guard let rawQuery,
              let items = URLComponents(string: "http://fixture.invalid/?\(rawQuery)")?.queryItems else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}
