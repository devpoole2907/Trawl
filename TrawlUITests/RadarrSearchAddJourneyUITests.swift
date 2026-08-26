import Foundation
import XCTest

/// Covers Radarr's primary acquisition entry point: Search -> lookup result ->
/// Add to Radarr -> persisted library state. The fixture is a real loopback server,
/// so the assertions protect both SwiftUI assembly and the production request body.
final class RadarrSearchAddJourneyUITests: XCTestCase {
    private var server: RadarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    @MainActor
    func testSearchingAndAddingAMovieSendsTheAddRequestAndShowsLibraryActions() async throws {
        let title = "Fixture New Radarr Movie"
        let tmdbID = 888_888
        let lookupJSON = #"""
        [{
          "id": 0,
          "title": "\#(title)",
          "sortTitle": "fixture new radarr movie",
          "tmdbId": \#(tmdbID),
          "year": 2026,
          "runtime": 104,
          "monitored": true,
          "qualityProfileId": 4,
          "rootFolderPath": "/movies",
          "status": "announced"
        }]
        """#
        let addedMovieJSON = #"""
        {
          "id": 888,
          "title": "\#(title)",
          "sortTitle": "fixture new radarr movie",
          "tmdbId": \#(tmdbID),
          "year": 2026,
          "runtime": 104,
          "monitored": true,
          "qualityProfileId": 4,
          "rootFolderPath": "/movies",
          "path": "/movies/Fixture New Radarr Movie (2026)",
          "status": "released",
          "hasFile": false,
          "minimumAvailability": "released"
        }
        """#

        let server = try await RadarrFixtureServer(
            lookupResponseJSON: lookupJSON,
            addedMovieJSON: addedMovieJSON
        )
        self.server = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15))
        searchTab.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("\(title)\n")

        let result = app.staticTexts[title]
        XCTAssertTrue(
            result.waitForExistence(in: app, timeout: 15),
            "The real GET /api/v3/movie/lookup result should render in Search. Requests: \(server.requests)"
        )
        let lookup = try XCTUnwrap(
            server.requests.last { $0.method == "GET" && $0.path == "/api/v3/movie/lookup" }
        )
        XCTAssertEqual(queryValues(lookup.rawQuery)["term"], title)
        result.tap()

        let addEntryPoint = firstButton(labelContains: "Add to Radarr", in: app)
        XCTAssertTrue(
            addEntryPoint.waitForExistence(in: app, timeout: 15),
            "A movie absent from the Radarr library should expose Add to Radarr."
        )
        addEntryPoint.tap()

        let sheet = app.navigationBars["Add to Radarr"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let confirm = sheet.buttons["Add"]
        XCTAssertTrue(
            waitForEnabled(confirm, timeout: 15),
            "The real quality-profile/root-folder refresh should default both pickers and enable Add."
        )

        let baseline = server.requests.count
        confirm.tap()
        waitForDisappearance(of: sheet, timeout: 20)
        XCTAssertFalse(sheet.exists, "A successful Radarr add should dismiss its sheet.")

        let automatic = firstButton(labelContains: "Automatic", in: app)
        XCTAssertTrue(
            automatic.waitForExistence(in: app, timeout: 15),
            "After Radarr's uncached library refetch, the detail screen should switch to library-only search actions."
        )
        XCTAssertFalse(
            firstButton(labelContains: "Add to Radarr", in: app).exists,
            "The add entry point must disappear once the movie is in the library."
        )

        let adds = server.requests.dropFirst(baseline).filter {
            $0.method == "POST" && $0.path == "/api/v3/movie"
        }
        XCTAssertEqual(adds.count, 1, "One user confirmation should issue exactly one movie add.")
        let add = try XCTUnwrap(adds.first)
        let body = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(add.body.utf8))) as? [String: Any]
        )
        XCTAssertEqual(body["title"] as? String, title)
        XCTAssertEqual(body["tmdbId"] as? Int, tmdbID)
        XCTAssertEqual(body["qualityProfileId"] as? Int, 4)
        XCTAssertEqual(body["rootFolderPath"] as? String, "/movies")
        XCTAssertEqual(body["monitored"] as? Bool, true)
        XCTAssertEqual(body["minimumAvailability"] as? String, "released")
        let options = try XCTUnwrap(body["addOptions"] as? [String: Any])
        XCTAssertEqual(options["searchForMovie"] as? Bool, true)
        XCTAssertEqual(options["monitor"] as? String, "movieOnly")
    }

    @MainActor
    private func firstButton(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.isEnabled
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }

    private func queryValues(_ rawQuery: String?) -> [String: String] {
        guard let rawQuery,
              let components = URLComponents(string: "http://fixture.invalid/?\(rawQuery)") else {
            return [:]
        }
        return Dictionary(
            components.queryItems?.compactMap { item in
                item.value.map { (item.name, $0) }
            } ?? [],
            uniquingKeysWith: { _, latest in latest }
        )
    }
}
