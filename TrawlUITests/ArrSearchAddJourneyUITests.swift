//
//  ArrSearchAddJourneyUITests.swift
//  TrawlUITests
//
//  UI journey #5 from TRAWL_RELIABILITY_TEST_AUDIT.md's "test system Trawl needs":
//  search for and add a series, including the duplicate and service-failure paths.
//  This is also the UI-level counterpart to M-02 ("Add Movie/Series App Intents fail
//  open when duplicate detection cannot load the library") - M-02 itself was fixed
//  for the App Intents path, but the in-app Search/Add path is separate code
//  (`SearchView`, `SearchViewModel`, `SonarrSeriesDetailView`,
//  `SonarrAddToLibrarySheet`) and had no coverage of its own duplicate or failure
//  behavior before this suite.
//
//  ## Seeding, reused verbatim from `SonarrConnectedJourneyUITests`
//
//  Same DEBUG hook: `-TrawlUITestInMemoryStore` for a guaranteed-empty in-memory
//  store, `TRAWL_UITEST_SONARR_BASE_URL` to seed one real `ArrServiceProfile` (and
//  its Keychain API key) pointed at a loopback fixture server. From there the app's
//  real `ArrServiceManager.connectService(_:)`, real `SonarrAPIClient`, and real
//  SwiftUI navigation run untouched - only the external Sonarr server is faked.
//
//  ## The real Search/Add UI path (traced, not guessed)
//
//  `Trawl/Views/SearchView.swift`:
//  - `SearchViewModel.scope` defaults to `.arr` (`SearchViewModel.swift:9`), so no
//    scope toggle is needed - the Discover/Sonarr+Radarr search is what's live the
//    moment the Search tab appears.
//  - `.searchable(text:isPresented:placement:prompt:)` (line 59) is the one and only
//    searchable field in this view, so `app.searchFields.firstMatch` is unambiguous.
//  - `.onChange(of: viewModel.searchText)` (line 78) starts a debounced Arr lookup
//    as-you-type when the scope is `.arr`; `.onSubmit(of: .search)` (line 65) starts
//    one immediately. This suite types the term and submits (`\n`), which calls
//    `SearchViewModel.startArrLookup(immediate: true)` and bypasses the 300ms
//    debounce, matching the guidance to prefer submit over relying on timing.
//  - A result row is `NavigationLink(value: ArrMediaDestination.seriesLookup(series))`
//    wrapping `ArrSeriesResultRow` (`arrSeriesRow`, line 607), whose only visible
//    text is `series.title` (`ArrSeriesResultRow.body`, line 861) - tapping that text
//    activates the same `NavigationLink` since it's the row's whole hit target.
//  - `.arrMediaNavigationDestinations(onLibraryChanged: { await refreshLibrary() })`
//    (line 54, resolved in `Trawl/ArrStack/ArrMediaDestination.swift`) pushes
//    `SonarrSeriesDetailView(series:viewModel:onAdded:)` for `.seriesLookup`, built
//    with a `SonarrViewModel` preloaded from
//    `serviceManager.calendarViewModel?.sonarrSeries` - the app-wide library cache
//    that `ArrServiceManager.initialize(from:)` populates via
//    `calendarViewModel.initialize()` immediately after connecting, i.e. before this
//    suite ever reaches the Search tab.
//
//  `Trawl/ArrStack/SonarrSeriesDetailView.swift`:
//  - `isInLibrary` (line 75) matches by `tvdbId` against `viewModel.series` - the
//    same signal, sourced the same way, that decides both the duplicate path and the
//    add path.
//  - `cardsSection` (line 428) renders a `Button("Add to Sonarr", showAddSheet = true)`
//    *only* `if !isInLibrary`. This is the UI-level fact the duplicate test pins:
//    there is no add affordance at all once the app believes the item already
//    exists, so a duplicate add is structurally unreachable from this screen rather
//    than merely discouraged.
//  - `if isInLibrary { statsCard(series) }` (line 471) renders a "Seasons" stat label
//    (`Trawl/ArrStack/SonarrSeriesDetailView.swift:547`) that only exists in
//    library-mode rendering - this suite uses its appearance as the positive,
//    on-screen signal that the app has recognized (and is displaying) the item as
//    already in the library, alongside the negative signal that "Add to Sonarr"
//    never renders.
//  - `.sheet(isPresented: $showAddSheet)` (line 318) presents
//    `SonarrAddToLibrarySheet(viewModel:series:onAdded:)`
//    (`Trawl/ArrStack/SonarrSeriesSearchViews.swift:86`).
//
//  `SonarrAddToLibrarySheet`:
//  - `AppSheetShell(title: "Add to Sonarr", confirmTitle: "Add", ...)` means the
//    sheet is `app.navigationBars["Add to Sonarr"]`. Its confirm control is *not*
//    in that navigation bar: the shell is configured `confirmPlacement:
//    .prominentBottom`, so "Add" is the full-width capsule in the sheet's bottom
//    safe-area inset and is addressed as `app.buttons["Add"]`. Cancel stays in the
//    navigation bar. Exact-label matching keeps these apart - the detail screen's
//    own "Add to Sonarr" button does not match `buttons["Add"]`.
//    (`Trawl/ArrStack/ArrSheetShell.swift` renders `confirmTitle`/`onConfirm` as a
//    `.confirmationAction` toolbar `Button`), mirroring
//    `ArrRepointJourneyUITests`'s already-proven `app.navigationBars["Edit
//    Sonarr"]`/`Save` pattern for the same `AppSheetShell`.
//  - `.task { await refreshConfigurationAndDefaults() }` (line 187) both refreshes
//    quality profiles/root folders over real HTTP and defaults the two pickers to
//    the first available value, so `canAdd` (line 218) becomes true - and the
//    toolbar "Add" button enabled - without any picker interaction from this suite,
//    as long as the fixture serves at least one profile and one root folder (it
//    always does).
//  - `addSeries()` (line 226) calls `SonarrViewModel.addSeries`
//    (`Trawl/ArrStack/SonarrViewModel.swift:415`), which does the real
//    `POST /api/v3/series` (`SonarrAPIClient.addSeries`,
//    `Trawl/ArrStack/SonarrAPIClient.swift:40`). On success it calls `loadSeries()`
//    (a real, un-cached `GET /api/v3/series` - `maxAge: 0`) before returning `true`;
//    `SonarrAddToLibrarySheet.addSeries()` only calls `onAdded()` and `dismiss()`
//    when that returns `true`. On failure it sets `viewModel.error` to
//    `error.localizedDescription` and returns `false` *without* calling
//    `loadSeries()` - the sheet stays open, and the fixture's library never gets an
//    item it never actually stored. This suite's failure test pins exactly that: no
//    false-positive success, and no phantom library entry.
//  - On a failed add, the sheet's `Form` renders
//    `Label(error, systemImage: "exclamationmark.triangle.fill")`
//    (`SonarrSeriesSearchViews.swift:177`) - this suite's fixture server returns a
//    plain-text (non-JSON) 500 body specifically so
//    `ArrError.serverErrorDisplayMessage` (`Trawl/ArrStack/ArrSharedModels.swift`)
//    passes it straight through, making the on-screen error text deterministic:
//    "Server error (500): <body>".

import Foundation
import XCTest

final class ArrSearchAddJourneyUITests: XCTestCase {
    private var server: ArrSearchAddFixtureServer?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    // MARK: - 1. Successful add

    /// Regressions this catches: the add-search lookup breaking, the "Add to Sonarr"
    /// entry point disappearing, `SonarrAddToLibrarySheet` failing to default its
    /// pickers (leaving "Add" permanently disabled), `SonarrAPIClient.addSeries`
    /// sending the wrong identifying field, and the post-add refetch
    /// (`loadSeries()`) not actually flipping the screen into its library-mode
    /// rendering - which would leave the user unable to tell whether the add
    /// actually took.
    @MainActor
    func testSearchingAndAddingASeriesSendsTheAddRequestAndShowsSuccess() async throws {
        let librarySeriesJSON = #"""
        [{"id":1,"title":"Existing Fixture Show","tvdbId":1,"titleSlug":"existing-fixture-show","monitored":true,"statistics":{"seasonCount":2,"episodeFileCount":10,"episodeCount":10}}]
        """#
        let lookupResponseJSON = #"""
        [{"id":0,"title":"Fixture New Series","tvdbId":555,"titleSlug":"fixture-new-series","seasons":[{"seasonNumber":1,"monitored":true}]}]
        """#
        let addedSeriesJSON = #"""
        {"id":555,"title":"Fixture New Series","tvdbId":555,"titleSlug":"fixture-new-series","monitored":true,"statistics":{"seasonCount":1,"episodeFileCount":0,"episodeCount":10}}
        """#

        let server = try await ArrSearchAddFixtureServer(
            librarySeriesJSON: librarySeriesJSON,
            lookupResponseJSON: lookupResponseJSON,
            addedSeriesJSON: addedSeriesJSON
        )
        self.server = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        // The series detail screen fires a real TMDb cast lookup. Left alone it
        // reaches the public internet and sits out a 15s timeout - that alone made
        // this journey take 140s - and it would fail outright on a sandboxed
        // runner. A closed loopback port fails immediately, and the cast lookup is
        // `try?` fire-and-forget, so nothing under test depends on it.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        try searchForNewSeries(titled: "Fixture New Series", in: app)

        let addButton = firstElement(labelContains: "Add to Sonarr", in: app)
        XCTAssertTrue(
            addButton.waitForExistence(in: app, timeout: 15),
            "SonarrSeriesDetailView should offer an 'Add to Sonarr' button for a lookup result that isn't in the library (cardsSection, `if !isInLibrary`) - regression: the add entry point is missing."
        )
        addButton.tap()

        let sheetTitle = app.navigationBars["Add to Sonarr"]
        XCTAssertTrue(
            sheetTitle.waitForExistence(timeout: 10),
            "Tapping 'Add to Sonarr' should present SonarrAddToLibrarySheet (AppSheetShell titled 'Add to Sonarr')."
        )

        let confirmButton = app.buttons["Add"]
        XCTAssertTrue(
            waitForEnabled(confirmButton, timeout: 15),
            "The sheet's 'Add' confirm button should become enabled once refreshConfigurationAndDefaults() defaults the quality profile and root folder pickers from the fixture's non-empty lists - regression: canAdd never became true."
        )

        let serverRequestCountBeforeAdd = server.requests.count
        confirmButton.tap()

        // Success dismisses the sheet (`SonarrAddToLibrarySheet.addSeries()` only
        // calls `dismiss()` when the add actually succeeded), so waiting for that
        // dismissal is itself proof the app believes the add worked - not just that
        // a network call happened.
        waitForDisappearance(of: sheetTitle, timeout: 20)
        XCTAssertFalse(
            sheetTitle.exists,
            "The add sheet should dismiss once the real POST /api/v3/series succeeds - regression: addSeries() returned false, or dismiss() stopped being called on success."
        )

        // The strongest on-screen success signal available: SonarrSeriesDetailView
        // re-renders as library-mode content (isInLibrary flips true) only after the
        // real, uncached GET /api/v3/series refetch - triggered by
        // SonarrViewModel.addSeries's loadSeries() call - actually returns the newly
        // added series. "Add to Sonarr" must also be gone, since it only renders
        // `if !isInLibrary`.
        let seasonsStat = app.staticTexts["Seasons"]
        XCTAssertTrue(
            seasonsStat.waitForExistence(in: app, timeout: 15),
            "Silent-non-update regression: after a successful add, the detail screen should re-render as library content (statsCard's 'Seasons' label, `if isInLibrary`) - its absence would mean the post-add refetch never landed or never flipped isInLibrary, i.e. a change the user can't distinguish from a failed add."
        )
        XCTAssertFalse(
            firstElement(labelContains: "Add to Sonarr", in: app).exists,
            "The 'Add to Sonarr' button should not still be offered once the series is in the library - regression: isInLibrary didn't flip true after the add."
        )

        // Proves the add actually went over real HTTP with the right identifying
        // field, not that the UI merely believes it did.
        let addRequests = server.requests[serverRequestCountBeforeAdd...].filter {
            $0.method == "POST" && $0.path == "/api/v3/series"
        }
        XCTAssertEqual(
            addRequests.count, 1,
            "Exactly one POST /api/v3/series should have been sent for tapping 'Add' once - regression: a double-submit, or the tap not reaching the network at all."
        )
        guard let addRequest = addRequests.first else {
            XCTFail("No POST /api/v3/series was recorded even though the sheet reported success.")
            return
        }
        let bodyJSON = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: Data(addRequest.body.utf8))) as? [String: Any],
            "The add request body should be JSON matching SonarrAddSeriesBody's shape."
        )
        XCTAssertEqual(
            bodyJSON["tvdbId"] as? Int, 555,
            "The add request body should identify the series by the TVDb ID the user searched for and added ('tvdbId': 555) - regression: the wrong lookup result, or a stale/garbled body, was sent to Sonarr."
        )
    }

    // MARK: - 2. Duplicate

    /// The UI-level counterpart to M-02: proves that when a search result is
    /// already in the library, the app never offers a way to add it again and never
    /// sends the add request - not merely that a duplicate-check read failure is
    /// handled (that's M-02's App Intents fix), but that the ordinary path can't
    /// double-add in the first place.
    @MainActor
    func testSearchingForASeriesAlreadyInTheLibraryOffersNoAddAndSendsNoPOST() async throws {
        let existingSeriesJSON = #"{"id":42,"title":"Existing Fixture Show","tvdbId":42,"titleSlug":"existing-fixture-show","monitored":true,"statistics":{"seasonCount":3,"episodeFileCount":30,"episodeCount":30}}"#
        let librarySeriesJSON = "[\(existingSeriesJSON)]"
        // Real Sonarr's /series/lookup returns the same object (non-zero `id`, full
        // library fields) for a title that's already been added - mirrored here.
        let lookupResponseJSON = "[\(existingSeriesJSON)]"

        let server = try await ArrSearchAddFixtureServer(
            librarySeriesJSON: librarySeriesJSON,
            lookupResponseJSON: lookupResponseJSON,
            addedSeriesJSON: existingSeriesJSON
        )
        self.server = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        // The series detail screen fires a real TMDb cast lookup. Left alone it
        // reaches the public internet and sits out a 15s timeout - that alone made
        // this journey take 140s - and it would fail outright on a sandboxed
        // runner. A closed loopback port fails immediately, and the cast lookup is
        // `try?` fire-and-forget, so nothing under test depends on it.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        try searchForNewSeries(titled: "Existing Fixture Show", in: app)

        // Positive signal: the app recognizes and renders this as an in-library
        // item (statsCard's "Seasons" label only renders `if isInLibrary`) -
        // this is how the app "tells the user it already exists", by presenting
        // the same library-management screen a user would get from the Series tab
        // rather than an add flow.
        let seasonsStat = app.staticTexts["Seasons"]
        XCTAssertTrue(
            seasonsStat.waitForExistence(in: app, timeout: 15),
            "A lookup result whose tvdbId matches an already-seeded library series should render as library content (isInLibrary == true) - regression: the duplicate match broke, and the app is treating an existing series as new."
        )

        // Negative signal: no add affordance exists at all for a duplicate.
        XCTAssertFalse(
            firstElement(labelContains: "Add to Sonarr", in: app).exists,
            "M-02-class regression: 'Add to Sonarr' should never be offered for a series already in the library - its presence here would mean a user could re-trigger an add for something Sonarr already has."
        )

        // The real proof this doesn't quietly double-add: the fixture never saw the
        // request at all, not merely that the UI didn't show one succeeding.
        XCTAssertEqual(
            server.requestCount(method: "POST", path: "/api/v3/series"), 0,
            "M-02-class regression: no POST /api/v3/series should ever be sent for a duplicate search result - its presence would mean Trawl re-added (or attempted to re-add) a series Sonarr already has."
        )
    }

    // MARK: - 3. Failure

    /// Proves a failed add surfaces as a failure, not a false success - "a silent
    /// success on a failed add is the worst outcome here" per the audit. Both the
    /// negative claim (no dismiss, no library-mode flip) and the positive one (the
    /// real error text on screen) are asserted, because a test that only checked
    /// "the sheet didn't dismiss" could also pass for an add that silently hung.
    @MainActor
    func testFailedAddShowsAFailureAndNeverASilentSuccess() async throws {
        let lookupResponseJSON = #"""
        [{"id":0,"title":"Fixture Failing Series","tvdbId":777,"titleSlug":"fixture-failing-series","seasons":[{"seasonNumber":1,"monitored":true}]}]
        """#
        let addedSeriesJSON = #"{"id":777,"title":"Fixture Failing Series","tvdbId":777,"titleSlug":"fixture-failing-series"}"#
        let failureBody = "Sonarr rejected the add."

        let server = try await ArrSearchAddFixtureServer(
            librarySeriesJSON: "[]",
            lookupResponseJSON: lookupResponseJSON,
            addedSeriesJSON: addedSeriesJSON,
            addOutcome: .failure(status: 500, body: failureBody)
        )
        self.server = server

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = server.baseURL
        // The series detail screen fires a real TMDb cast lookup. Left alone it
        // reaches the public internet and sits out a 15s timeout - that alone made
        // this journey take 140s - and it would fail outright on a sandboxed
        // runner. A closed loopback port fails immediately, and the cast lookup is
        // `try?` fire-and-forget, so nothing under test depends on it.
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = "http://127.0.0.1:1/tmdb"
        app.launch()

        try searchForNewSeries(titled: "Fixture Failing Series", in: app)

        let addButton = firstElement(labelContains: "Add to Sonarr", in: app)
        XCTAssertTrue(
            addButton.waitForExistence(in: app, timeout: 15),
            "The lookup result isn't in the (empty) library, so 'Add to Sonarr' should be offered."
        )
        addButton.tap()

        let sheetTitle = app.navigationBars["Add to Sonarr"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), "The add sheet should present.")

        let confirmButton = app.buttons["Add"]
        XCTAssertTrue(
            waitForEnabled(confirmButton, timeout: 15),
            "The 'Add' confirm button should become enabled from the fixture's defaulted quality profile / root folder, independent of what the add itself will do."
        )

        confirmButton.tap()

        // Positive signal: the real 500's message reaches the screen. Matched with
        // a broad element query (existence only - nothing here is tapped) since
        // SwiftUI's `Label` doesn't necessarily surface as a `staticText`.
        let errorText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Server error (500)"))
            .firstMatch
        XCTAssertTrue(
            errorText.waitForExistence(in: app, timeout: 15),
            "A failed add should surface ArrError's real message ('Server error (500): \(failureBody)') in the sheet's form (SonarrAddToLibrarySheet's error Label) - regression: the failure is swallowed instead of shown."
        )

        // Negative signal: no silent success. The sheet must still be up (a
        // dismissed sheet after a failed add would itself be a false-success bug),
        // and the confirm button must not be stuck disabled/loading forever.
        XCTAssertTrue(
            sheetTitle.exists,
            "M-worst-outcome regression: the add sheet dismissing after a failed POST would present as a false success - it must stay open."
        )
        XCTAssertTrue(
            waitForEnabled(confirmButton, timeout: 10),
            "isAdding should reset (SonarrAddToLibrarySheet.addSeries()'s `defer`) after the failure, re-enabling 'Add' for a retry rather than leaving the sheet stuck loading."
        )

        // Dismiss and confirm the detail screen agrees nothing was added: no
        // library-mode flip, 'Add to Sonarr' still offered. This is what proves the
        // failure didn't leave a half-applied state behind.
        let cancelButton = app.navigationBars["Add to Sonarr"].buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "The add sheet should offer a way to back out (AppSheetShell's default Cancel action).")
        cancelButton.tap()
        waitForDisappearance(of: sheetTitle, timeout: 10)

        XCTAssertTrue(
            firstElement(labelContains: "Add to Sonarr", in: app).waitForExistence(in: app, timeout: 10),
            "M-worst-outcome regression: 'Add to Sonarr' should still be offered after a failed add - its absence (i.e. the screen now believing the series is in the library) would be exactly the false-success this test exists to catch."
        )

        XCTAssertEqual(
            server.requestCount(method: "POST", path: "/api/v3/series"), 1,
            "Exactly one POST /api/v3/series should have been attempted (proving the request really was sent, not swallowed client-side before the network) even though it failed server-side."
        )
    }

    // MARK: - Helpers

    /// Drives the real Search UI from the tab bar through to a lookup result
    /// appearing on screen: taps the Search tab, focuses the one `.searchable`
    /// field (scope already defaults to `.arr`, so no scope toggle is needed),
    /// types `title`, and submits - which calls
    /// `SearchViewModel.startArrLookup(immediate: true)` immediately rather than
    /// relying on the 300ms as-you-type debounce.
    @MainActor
    private func searchForNewSeries(titled title: String, in app: XCUIApplication) throws {
        XCTAssertTrue(ensureRootChromeIsReady(in: app))
        XCTAssertTrue(openDestination(.search, in: app), "The Search destination should be reachable.")

        // `contentSearchField` rather than `searchFields.firstMatch`: on iPad the
        // sidebar has a permanent search field of its own, and typing into that one
        // would search the feature index instead of Sonarr.
        let searchField = contentSearchField(in: app)
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 10),
            "SearchView's one .searchable field should exist once the Search destination is open."
        )
        searchField.tap()
        searchField.typeText("\(title)\n")

        let resultRow = app.staticTexts[title]
        XCTAssertTrue(
            resultRow.waitForExistence(in: app, timeout: 15),
            "ArrSeriesResultRow should show '\(title)' once the real GET /api/v3/series/lookup round-trip completes - regression: the add-search lookup broke, or its result row stopped rendering the series title."
        )
        resultRow.tap()
    }

    /// Finds the first `Button` anywhere in the tree whose accessibility label
    /// contains `text`. Restricted to buttons (never `.any`/`.other`) so an
    /// existence-and-tap query can't silently land on a non-interactive element -
    /// mirrors `ArrRepointJourneyUITests.firstElement(labelContains:in:)`.
    private func firstElement(labelContains text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
    }

    /// Polls `element.isEnabled` until it goes true or `timeout` elapses. Built
    /// entirely from `waitForExistence(timeout:)` calls (never `sleep()` /
    /// `Thread.sleep`) - mirrors `ArrInstanceSwitchJourneyUITests.waitForEnabled`.
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            _ = element.waitForExistence(timeout: 0.25)
        }
        return element.exists && element.isEnabled
    }

    /// Polls `element.exists` until it goes false or `timeout` elapses. XCTest has
    /// no built-in "wait for disappearance" - mirrors
    /// `ArrRepointJourneyUITests.waitForDisappearance`.
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            _ = element.waitForExistence(timeout: 0.25)
        }
    }
}
