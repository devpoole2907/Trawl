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

        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.search, in: app), "The Search destination should be reachable.")

        // `contentSearchField` rather than `searchFields.firstMatch`: on iPad the
        // sidebar has a permanent search field of its own, and typing into that one
        // would search the feature index instead of Radarr.
        let searchField = contentSearchField(in: app)
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
        // The confirm is the sheet's prominent bottom capsule, not a navigation-bar
        // item (`confirmPlacement: .prominentBottom`). Exact-label matching keeps it
        // distinct from the detail screen's own "Add to Radarr" button underneath.
        let confirm = app.buttons["Add"]
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

    /// Two Radarr lookup results that are not yet in the library both carry `id: 0`
    /// - Radarr's own marker for "not added". `ArrMediaDestination.movieLookup`
    /// wraps `RadarrMovie`, whose `Hashable` conformance is `(id, instanceID)`, and
    /// a lookup result belongs to no server, so `instanceID` is nil for both. Every
    /// un-added result therefore hashes and compares identically, and a
    /// `NavigationStack` keyed on those values reuses the destination it already
    /// built for the first one: tapping the second result opens the first movie's
    /// screen.
    ///
    /// The user hit this on Search's trending shelf, which pushes the very same
    /// `.movieLookup` value; this test drives the lookup-results list instead
    /// because that surface already has a real loopback fixture, and both share the
    /// one destination type.
    @MainActor
    func testTappingASecondUnaddedResultOpensItsOwnDetailScreen() async throws {
        let firstTitle = "Fixture The Ant Bully"
        let secondTitle = "Fixture Obsession"
        // Both ids are 0 on purpose: that is exactly what Radarr returns for a
        // lookup result it has never added, and it is the collision under test.
        let lookupJSON = #"""
        [{
          "id": 0,
          "title": "\#(firstTitle)",
          "sortTitle": "fixture the ant bully",
          "tmdbId": 900001,
          "year": 2006,
          "runtime": 88,
          "monitored": false,
          "status": "released"
        },
        {
          "id": 0,
          "title": "\#(secondTitle)",
          "sortTitle": "fixture obsession",
          "tmdbId": 900002,
          "year": 1976,
          "runtime": 98,
          "monitored": false,
          "status": "released"
        }]
        """#

        let server = try await RadarrFixtureServer(lookupResponseJSON: lookupJSON)
        self.server = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = server.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.search, in: app), "The Search destination should be reachable.")

        // `contentSearchField` rather than `searchFields.firstMatch`: on iPad the
        // sidebar has a permanent search field of its own, and typing into that one
        // would search the feature index instead of Radarr.
        let searchField = contentSearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("Fixture\n")

        let firstRow = app.staticTexts[firstTitle]
        XCTAssertTrue(
            firstRow.waitForExistence(in: app, timeout: 15),
            "Both lookup results should render. Requests: \(server.requests)"
        )
        XCTAssertTrue(
            app.staticTexts[secondTitle].waitForExistence(in: app, timeout: 10),
            "The second lookup result should render alongside the first."
        )

        firstRow.tap()
        XCTAssertTrue(
            app.navigationBars[firstTitle].waitForExistence(timeout: 15),
            "Tapping the first result should open the first movie."
        )

        // `backButton(in:)`, not `buttons.firstMatch`: on iPad a pushed screen inside a
        // split-view column carries the sidebar toggle at its leading edge as well as
        // the back button, so the first button slides the sidebar out and the test
        // then fails on the screen it never left.
        let back = backButton(in: app.navigationBars[firstTitle])
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(
            app.navigationBars[firstTitle].waitForNonExistence(timeout: 10),
            "Going back should leave the first movie's screen."
        )

        let secondRow = app.staticTexts[secondTitle]
        XCTAssertTrue(secondRow.waitForExistence(in: app, timeout: 10))
        secondRow.tap()

        XCTAssertTrue(
            app.navigationBars[secondTitle].waitForExistence(timeout: 15),
            """
            Tapping the second un-added result opened the wrong movie. Both results \
            carry Radarr's id 0, so the two ArrMediaDestination.movieLookup values \
            compare equal and the stack reuses the first movie's detail screen.
            """
        )
        XCTAssertFalse(
            app.navigationBars[firstTitle].exists,
            "The first movie's screen must not still be on the stack."
        )
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
