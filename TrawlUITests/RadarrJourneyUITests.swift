//
//  RadarrJourneyUITests.swift
//  TrawlUITests
//
//  Sonarr already has several UI journeys (`SonarrConnectedJourneyUITests`,
//  `ArrInstanceSwitchJourneyUITests`, `ArrRepointJourneyUITests`,
//  `ArrSearchAddJourneyUITests`); Radarr had none. This suite doesn't re-run the
//  Sonarr journeys against Radarr - most of the list machinery is shared through
//  `ArrMediaListView`, so that would just re-prove the same shared code twice. It
//  targets what's genuinely Radarr-specific instead: `RadarrViewModel`,
//  `RadarrMovieListView`, and above all `RadarrMovieDetailView`
//  (`Trawl/ArrStack/RadarrMovieDetailView.swift`) - 1,952 executable lines at 0%
//  coverage, the largest untested file in the project.
//
//  ## Seeding, reused from `SonarrConnectedJourneyUITests`'s pattern
//
//  Same DEBUG hook, extended for Radarr: `-TrawlUITestInMemoryStore` for a
//  guaranteed-empty in-memory store, `TRAWL_UITEST_RADARR_BASE_URL` to seed one real
//  `ArrServiceProfile` (`serviceType: .radarr`) plus its Keychain API key
//  (`Trawl/TrawlApp.swift`'s `seedUITestRadarrServiceIfRequested(into:)`), pointed at
//  `RadarrFixtureServer`, a real loopback HTTP server this test process hosts. From
//  there the app's own startup, connect, and navigation code runs untouched:
//  `ContentView` sees the seeded profile and skips the welcome gate,
//  `ArrServiceManager.connectService(_:)` makes real requests to the fixture server,
//  and the Movies tab renders whatever `RadarrAPIClient` actually decoded.
//
//  `TRAWL_UITEST_TMDB_BASE_URL` is set on every launch here (not just the failure
//  paths) because `RadarrMovieDetailView`'s `.task(id: movie?.tmdbId)` always fires a
//  real `TMDbClient().movieCredits(tmdbId:)` lookup for the cast shelf
//  (`RadarrMovieDetailView.swift:150-157`) the moment the detail screen appears - left
//  alone it reaches the public internet and sits out a 15s timeout, which is exactly
//  what made an earlier journey in this suite take 140s (see
//  `ArrSearchAddJourneyUITests`'s identical comment). A closed loopback port
//  (`127.0.0.1:1`) fails immediately instead, and the lookup is `try?`
//  fire-and-forget, so nothing under test depends on it succeeding.
//
//  ## The real Movies/Detail UI path (traced, not guessed)
//
//  `RadarrMovieListView` (`Trawl/ArrStack/RadarrMovieListView.swift`) stands up a
//  `RadarrViewModel` once `serviceManager.radarrConnected` and hands it to the shared
//  `ArrMediaListView`, whose rows are `NavigationLink(value: item.id)` wrapping
//  `RadarrMovieRow` (`ArrMediaListView.swift:247`, `RadarrMovieListView.swift:250`).
//  `RadarrMovieRow` renders `Text(movie.title)` with no `.accessibilityElement`
//  grouping, so the title is directly reachable as `app.staticTexts[title]` - the
//  same working pattern `SonarrConnectedJourneyUITests` and `ArrSearchAddJourneyUITests`
//  already rely on for their own rows.
//
//  Tapping a row pushes `RadarrMovieDetailView(movieId:viewModel:)`
//  (`RadarrMovieListView.swift:94`), which wraps its content in `ArrItemDetailView`
//  (`Trawl/ArrStack/Detail/ArrItemDetailView.swift`) - `.navigationTitle(title)` there
//  means the movie's title is reachable unambiguously as `app.navigationBars[title]`,
//  sidestepping any risk of the list row's identical `Text` still being mounted
//  underneath during the push transition. `heroSection` (`RadarrMovieDetailView.swift:
//  457-474`) renders the studio and the "Monitored" badge
//  (`RadarrMovie.detailBadges(context:)`, `Trawl/ArrStack/Detail/
//  ArrDetailSharedTypes.swift:110-112` - appended *only* `if context.isInLibrary &&
//  monitored == true`), and `cardsSection` renders the overview via
//  `ArrDetailOverviewCard` (`RadarrMovieDetailView.swift:512-513`) whenever
//  `movie.overview` is non-empty - all three are plain, ungrouped `Text`/`Label`
//  nodes, so `RadarrFixtureServer`'s known constants (`movieTitle`, `movieStudio`,
//  `movieOverview`) are asserted directly against `app.staticTexts`/`app.navigationBars`.
//
//  ## The Radarr-specific action: toggling "Monitored"
//
//  `RadarrMovieDetailView`'s toolbar renders a `Menu` titled "More" whenever the
//  movie is in the library (`RadarrMovieDetailView.swift:991-1046`), with a row whose
//  label is `movie.monitored == true ? "Unmonitor" : "Monitor"`
//  (`RadarrMovieDetailView.swift:1008-1015`) that calls
//  `viewModel.toggleMovieMonitored(movie)`. That method
//  (`Trawl/ArrStack/RadarrViewModel.swift:259-299`) first re-fetches the movie via
//  `GET /api/v3/movie/{id}` to get a canonical copy - bailing out silently if
//  `qualityProfileId` is nil or `rootFolderPath` is empty
//  (`RadarrViewModel.swift:267-273`), which is exactly why
//  `RadarrFixtureServer.movieJSON()` always serves both - then sends the flipped
//  value via `PUT /api/v3/movie/{id}` (`RadarrAPIClient.updateMovie(_:moveFiles:)`,
//  `RadarrAPIClient.swift:48-51`), and finally reloads the library with
//  `loadMovies()`. `RadarrFixtureServer` remembers the `monitored` flag a `PUT`
//  changes, so that reload reflects the flip - which is what lets this suite use the
//  "Monitored" badge's disappearance as its positive on-screen signal: unlike a
//  filtered list row that stays mounted with `exists == true`, this badge is
//  genuinely absent from the view hierarchy once `monitored` is no longer `true`
//  (`ArrDetailSharedTypes.swift:110-112`'s `if` guards its very presence in the
//  `badges` array), the same kind of real conditional-rendering absence
//  `ArrSearchAddJourneyUITests` already relies on for "Add to Sonarr" disappearing
//  post-add.
//
//  ## Established UI facts this suite leans on
//
//  - A tap on an element that `exists` but isn't yet `isHittable` is silently
//    dropped, surfacing as a failure on the *next* assertion instead. `tapWhenHittable`
//    below never taps without first polling `isHittable` in a bounded loop, built
//    only from `waitForExistence` - no `sleep()`/`Thread.sleep` anywhere in this file.
//  - Even a confirmed-hittable `StaticText` inside a `List` row can fail
//    `element.tap()` with "Timed out while synthesizing event" when the app never
//    reaches quiescence - which happens under full-plan load but not in isolation,
//    so it presents as a flaky test rather than a harness timing dependency.
//    `tapCentre(of:)` delivers the already-verified tap by coordinate instead.
//  - `TrawlUITests/XCUIElement+Scrolling.swift`'s `waitForExistence(in:timeout:)`
//    scrolls a bounded number of times for content that's below the fold, which this
//    suite uses for every on-screen assertion on the (scrollable) detail view.

import Foundation
import XCTest

final class RadarrJourneyUITests: XCTestCase {
    private var server: RadarrFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    /// Regressions this catches: the welcome gate no longer respecting a configured
    /// Radarr service, `ArrServiceManager.connectService`'s `.radarr` branch or
    /// `RadarrAPIClient` breaking against a real server, the Movies tab failing to
    /// render a connected library, `RadarrMovieDetailView` rendering an empty screen
    /// for a real movie payload (the 1,952-line, 0%-covered file this suite exists
    /// for), the "More" menu's monitored toggle not actually reaching Radarr, and a
    /// silent no-op that leaves the UI looking successful without a real
    /// `PUT /api/v3/movie/{id}` behind it.
    @MainActor
    func testRadarrMovieDetailRendersRealDataAndTogglingMonitoredReachesTheServer() async throws {
        let server = try await RadarrFixtureServer(initiallyMonitored: true)
        self.server = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = server.baseURL
        // See the file-level comment: the detail screen's cast-shelf lookup always
        // fires and would otherwise sit out a real 15s network timeout.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        // MARK: 1. Past the welcome gate, onto the Movies tab, with the fixture's movie.

        let moviesTab = app.tabBars.buttons["Movies"]
        XCTAssertTrue(
            moviesTab.waitForExistence(timeout: 15),
            "A launch with a configured Radarr service should reach the real tab UI, not the welcome screen."
        )
        moviesTab.tap()

        let movieRow = app.staticTexts[RadarrFixtureServer.movieTitle]
        XCTAssertTrue(
            movieRow.waitForExistence(timeout: 15),
            "RadarrMovieRow should show the fixture movie's title once the real connect sequence and GET /api/v3/movie complete - regression: the Radarr connect path or the Movies tab's rendering broke."
        )
        XCTAssertTrue(
            server.hasReceivedRequest(method: "GET", path: "/api/v3/movie"),
            "The fixture server should have actually received the movie library request - proves the row came over real HTTP through RadarrAPIClient, not from a stub."
        )

        // MARK: 2. Open the movie detail screen and assert real, distinct content.

        XCTAssertTrue(
            tapWhenHittable(movieRow, in: app, timeout: 15),
            "The movie row should become tappable once the list finishes loading - regression: the row exists but its tap is silently dropped (see file header, 'established UI facts')."
        )

        // Deliberately NOT `app.navigationBars[RadarrFixtureServer.movieTitle]`.
        // Subscripting a navigation bar by this title crashes the test runner
        // outright - "Assertion failure in -[XCUIElementQuery
        // _predicateWithType:identifier:]" - because the title contains a colon.
        // The runner dies rather than failing an assertion, so the whole journey is
        // lost with no useful message.
        //
        // A navigation bar existing at all is enough to prove the push happened, and
        // the studio and overview assertions below are the real proof that this is
        // the detail screen rendering real payload data: neither appears on the list
        // row, so they cannot be satisfied by a row still mounted underneath during
        // the push transition.
        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 15),
            "Tapping the movie should push a detail screen - regression: RadarrMovieDetailView failed to resolve the movie, or the navigation never happened."
        )

        let studioText = app.staticTexts[RadarrFixtureServer.movieStudio]
        XCTAssertTrue(
            studioText.waitForExistence(timeout: 15),
            "ArrDetailHeaderView should render the movie's real studio ('\(RadarrFixtureServer.movieStudio)') - regression: heroSection stopped passing movie.studio through, or the field failed to decode."
        )

        // Matched on a distinctive fragment rather than subscripting by the whole
        // overview. The full string is ~160 characters, and using it as an element
        // identifier crashes the runner outright ("Assertion failure in
        // -[XCUIElementQuery _predicateWithType:identifier:]") rather than failing an
        // assertion, taking the entire journey with it and reporting nothing useful.
        let overviewText = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "exercise RadarrMovieDetailView end-to-end"))
            .firstMatch
        XCTAssertTrue(
            overviewText.waitForExistence(timeout: 15),
            "ArrDetailOverviewCard should render the movie's real overview text verbatim - regression: cardsSection stopped rendering the overview card, or RadarrMovie.overview failed to decode. This is the core proof RadarrMovieDetailView - the largest untested file in the project - actually renders real payload content, not just a title."
        )

        let monitoredBadge = app.staticTexts["Monitored"]
        XCTAssertTrue(
            monitoredBadge.waitForExistence(timeout: 15),
            "The fixture movie is seeded monitored and in the library, so detailBadges(context:) should append a 'Monitored' pill (ArrDetailSharedTypes.swift) - this is also the baseline state the toggle action below flips away from."
        )

        // MARK: 3. Radarr-specific action: toggle "Monitored" off via the "More" menu.

        let moreButton = app.navigationBars.buttons["More"]
        XCTAssertTrue(
            tapWhenHittable(moreButton, in: app, timeout: 15),
            "RadarrMovieDetailView's toolbar should offer a 'More' menu once the movie is in the library - regression: the toolbar Menu disappeared, or isInLibrary stopped being true for a library movie."
        )

        let unmonitorButton = firstElement(labelContains: "Unmonitor", in: app)
        XCTAssertTrue(
            unmonitorButton.waitForExistence(timeout: 10),
            "The More menu should offer 'Unmonitor' while the movie is monitored - regression: the menu's label stopped reflecting movie.monitored, or the row disappeared entirely."
        )

        // Captured immediately before the tap that triggers toggleMovieMonitored's
        // real GET-then-PUT sequence, so every request from here on is attributable
        // to this one action - mirrors ArrSearchAddJourneyUITests's
        // `serverRequestCountBeforeAdd`.
        let requestsBeforeToggleSettles = server.requests.count
        XCTAssertTrue(
            tapWhenHittable(unmonitorButton, in: app, timeout: 10),
            "The 'Unmonitor' menu row should be tappable once the menu finishes presenting."
        )

        // Positive UI outcome: unlike a filtered list row that stays mounted with
        // `exists == true` (see file header on absence-assertion pitfalls), the
        // "Monitored" badge is only ever appended to the badges array `if monitored
        // == true` - its disappearance is a genuine conditional-render change, not a
        // hidden-but-present row.
        waitForDisappearance(of: monitoredBadge, timeout: 20)
        XCTAssertFalse(
            monitoredBadge.exists,
            "toggleMovieMonitored's PUT + loadMovies() refetch should flip the movie to unmonitored, removing the 'Monitored' badge - regression: the toggle silently failed, or the post-update refetch didn't land."
        )

        // Positive UI outcome #2: reopening the menu should now offer the opposite
        // action, proving the flip stuck rather than merely dismissing the badge.
        XCTAssertTrue(
            tapWhenHittable(moreButton, in: app, timeout: 15),
            "The 'More' menu should still be reachable after the toggle completes."
        )
        let monitorButtonAfterToggle = firstElement(labelContains: "Monitor", in: app)
        XCTAssertTrue(
            monitorButtonAfterToggle.waitForExistence(timeout: 10),
            "After unmonitoring, the More menu's row should now read 'Monitor' (movie.monitored == false) - regression: the view model's local `movies` array wasn't updated, leaving the menu offering the wrong action for the movie's actual state."
        )

        // Server evidence: not just that the UI believes the toggle worked, but that
        // toggleMovieMonitored's real sequence (canonical GET, then PUT) reached the
        // fixture, and the PUT carried the flipped value.
        let requestsDuringToggle = server.requests[requestsBeforeToggleSettles...]
        let movieDetailPath = "/api/v3/movie/\(RadarrFixtureServer.movieId)"

        XCTAssertTrue(
            requestsDuringToggle.contains { $0.method == "GET" && $0.path == movieDetailPath },
            "toggleMovieMonitored should re-fetch the canonical movie via GET \(movieDetailPath) before building its update - regression: RadarrViewModel stopped calling client.getMovie(id:), which would also silently break the qualityProfileId/rootFolderPath guard."
        )

        let putRequests = requestsDuringToggle.filter { $0.method == "PUT" && $0.path == movieDetailPath }
        XCTAssertEqual(
            putRequests.count, 1,
            "Exactly one PUT \(movieDetailPath) should have been sent for tapping 'Unmonitor' once - regression: a double-submit, or the tap never reaching the network."
        )
        guard let putRequest = putRequests.first else {
            XCTFail("No PUT \(movieDetailPath) was recorded even though the UI reflects the toggle having taken effect.")
            return
        }
        let putBodyJSON = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(putRequest.body.utf8))) as? [String: Any],
            "The PUT request body should be JSON matching RadarrMovie's shape (RadarrAPIClient.updateMovie's putCodable body)."
        )
        XCTAssertEqual(
            putBodyJSON["monitored"] as? Bool, false,
            "The PUT body should carry the flipped 'monitored': false - regression: toggleMovieMonitored sent the movie's old value instead of the new one, i.e. tapping 'Unmonitor' would be a no-op against real Radarr."
        )

        // MARK: 4. Navigate back and confirm we're on the movie list again.

        // The system back button's label is normally the previous screen's title
        // ("Movies", ArrMediaListView.navigationTitleText with a single Radarr
        // instance) - but iOS falls back to a bare chevron with no title text if
        // that label doesn't fit, so this tries the named button first and falls
        // back to the navigation bar's leading (back) button by position.
        let namedBackButton = app.navigationBars.buttons["Movies"]
        if namedBackButton.waitForExistence(timeout: 5), namedBackButton.isHittable {
            namedBackButton.tap()
        } else {
            // iOS drops the back button's title when it does not fit, and the
            // remaining chevron is not reliably reachable by label or by position
            // (the toolbar also carries a trailing "More" button). The interactive
            // pop gesture is what a user would do anyway, and does not depend on
            // either.
            app.swipeRight()
        }

        XCTAssertTrue(
            app.staticTexts[RadarrFixtureServer.movieTitle].waitForExistence(timeout: 15),
            "Popping back from the detail screen should return to the Movies list still showing the fixture movie - regression: the back navigation left the app on a blank or wrong screen."
        )
    }

    // MARK: - Helpers

    /// Finds the first `Button` anywhere in the tree whose accessibility label
    /// contains `text`. Restricted to buttons (never `.any`/`.other`) so an
    /// existence-and-tap query can't silently land on a non-interactive element -
    /// mirrors `ArrSearchAddJourneyUITests.firstElement(labelContains:in:)` and
    /// `ArrInstanceSwitchJourneyUITests`'s equivalent inline predicate.
    private func firstElement(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Waits for `element` to exist (scrolling if necessary via
    /// `XCUIElement+Scrolling.swift`), then polls `isHittable` in a bounded loop
    /// before tapping - never taps blind. Addresses the file header's first
    /// established UI fact: a tap on an element that `exists` but isn't yet
    /// `isHittable` is silently dropped, and the resulting failure lands on the
    /// *next* assertion instead, blaming the wrong screen. Returns whether the tap
    /// was actually performed.
    @discardableResult
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable {
                tapCentre(of: element)
                return true
            }
            _ = element.waitForExistence(timeout: 0.25)
        }
        guard element.isHittable else { return false }
        tapCentre(of: element)
        return true
    }

    /// Taps the centre of an element whose `isHittable` has *already* been
    /// confirmed by `tapWhenHittable`.
    ///
    /// This is the file header's second established UI fact. `element.tap()` on a
    /// `StaticText` inside a `List` row fails as
    /// "Failed to tap … Timed out while synthesizing event" whenever the app does
    /// not reach quiescence within XCTest's internal idle wait. The journey passes
    /// in isolation and fails inside the full plan, because the shared simulator is
    /// under load there and Trawl's polling never lets the run loop go idle - so
    /// the symptom looks like flakiness in this test rather than a timing
    /// dependency in the harness.
    ///
    /// A coordinate tap resolves the hit point directly and skips the element-frame
    /// synthesis that stalls. It is not a blind tap: hittability is verified by the
    /// caller immediately beforehand, so this only changes *how* the confirmed tap
    /// is delivered, never *whether* the element was ready to receive one.
    private func tapCentre(of element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Polls `element.exists` until it goes false or `timeout` elapses. XCTest has
    /// no built-in "wait for disappearance" - mirrors
    /// `ArrSearchAddJourneyUITests.waitForDisappearance(of:timeout:)`.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }
}
