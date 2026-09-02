//
//  IPadSurfaceCaptureUITests.swift
//  TrawlUITests
//
//  A capture harness, not a behavior suite. Every other journey in this target
//  asserts something and fails when it breaks; this one drives the app across its
//  primary surfaces on an iPad and attaches a screenshot of each, so the layout can
//  actually be looked at. It deliberately makes no layout assertions - "does this
//  look right on a 13-inch iPad" is a judgement call, and encoding it as
//  `XCTAssert` would either be vacuous or brittle.
//
//  Run it by name, against an iPad destination:
//
//      xcodebuild test -project Trawl.xcodeproj -scheme Trawl \
//        -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
//        -only-testing:TrawlUITests/IPadSurfaceCaptureUITests
//
//  Note for anyone tempted to keep it out of full plan runs by adding it to
//  `Trawl.xctestplan`'s `skippedTests`: a plan skip beats `-only-testing`, so the
//  command above then reports `Executed 0 tests` *and* `TEST SUCCEEDED`. It has to
//  stay unskipped to be runnable at all.
//
//  Screenshots come back as `.keepAlways` attachments in the result bundle and are
//  pulled out with `xcrun xcresulttool export attachments`.
//
//  Seeding follows the established pattern (`NavigationSmokeWalkUITests`): real
//  loopback fixture servers handed to the app through `TrawlApp`'s DEBUG hooks, so
//  the app's own startup, connect, and navigation code runs unmodified. The one
//  departure is *volume*. Journeys seed one series and one movie because one is
//  enough to assert against; a one-row list on a 13-inch iPad reveals nothing about
//  how the layout breathes, so this suite seeds a library-sized fixture instead.
//
//  `TRAWL_UITEST_TMDB_BASE_URL` is pointed at an unreachable loopback address for
//  the same reason as every other suite here: without it, detail screens fire a real
//  TMDb lookup that reaches the public internet and sits out a 15s timeout. Posters
//  therefore render as placeholders throughout, which is the intended trade - this
//  is a layout capture, not an artwork capture.

import XCTest

final class IPadSurfaceCaptureUITests: XCTestCase {
    private var sonarr: SonarrFixtureServer?
    private var radarr: RadarrFixtureServer?
    private var sabnzbd: SABnzbdFixtureServer?
    private var qbittorrent: QBittorrentFixtureServer?
    private var seerr: SeerrUIFixtureServer?
    private var jellyfin: JellyfinUIFixtureServer?
    private var prowlarr: ProwlarrUIFixtureServer?

    override func setUpWithError() throws {
        // A capture run is worth more partially complete than aborted: if one surface
        // can't be reached, the remaining ones should still be photographed.
        continueAfterFailure = true
    }

    override func tearDownWithError() throws {
        sonarr?.stop(); sonarr = nil
        radarr?.stop(); radarr = nil
        sabnzbd?.stop(); sabnzbd = nil
        qbittorrent?.stop(); qbittorrent = nil
        seerr?.stop(); seerr = nil
        jellyfin?.stop(); jellyfin = nil
        prowlarr?.stop(); prowlarr = nil
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Landscape pass

    /// Landscape first because it is where iPad layout problems actually live: a
    /// phone layout stretched to 1366pt wide shows its seams (full-bleed rows, a
    /// single column of content in a sea of margin, controls pinned to one edge)
    /// far more readably than portrait does.
    @MainActor
    func testCapturePrimarySurfacesLandscape() async throws {
        // Orientation is set *before* launch, so the app lays out for landscape once
        // at startup and nothing rotates mid-session. Rotating a running app was the
        // source of both earlier capture failures: it wedged the chrome so no
        // destination ever resolved, and it left the screen buffer's content
        // rotation varying from shot to shot.
        let app = try await launchFullyConfiguredApp(orientation: .landscapeLeft)

        guard reachedTabUI(app) else {
            capture(app, "00-UNREACHED-tab-ui-landscape")
            dumpHierarchy(app, label: "landscape, tab UI unreachable")
            return
        }
        ensureSidebarExpanded(app)

        captureRootTabs(app, orientation: "landscape", indexOffset: 1)

        // Detail screens. These are the densest layouts in the app and the ones most
        // likely to read as a blown-up phone screen, so all four are captured rather
        // than treating one as representative of the rest.
        captureDetail(app, tab: "Series", row: Self.headlineSeriesTitle,
                      expecting: Self.headlineSeriesTitle, named: "06-series-detail-landscape")
        captureDetail(app, tab: "Movies", row: Self.headlineMovieTitle,
                      expecting: Self.headlineMovieTitle, named: "07-movie-detail-landscape")
        captureDetail(app, tab: "Downloads", row: Self.qbittorrentTorrentName,
                      expecting: Self.qbittorrentTorrentName, named: "14-download-detail-landscape")
        captureDetail(app, tab: "Downloads", row: Self.sabnzbdJobName,
                      expecting: Self.sabnzbdJobName, named: "15-nzb-detail-landscape")

        // The seven screens More used to hold. On iPad they are sidebar destinations
        // in their own right, so they are reached as root tabs here rather than as
        // pushes inside More - which is the change this whole branch exists to make.
        // On iPhone they are still behind More, and `captureMorePush` below covers
        // that arrangement instead.
        if goToTab(app, "More") {
            captureMorePush(app, row: "Settings", title: "Settings", named: "09-settings-landscape")
            captureMorePush(app, row: "Requests & Access", title: "Requests & Access", named: "10-requests-landscape")
            captureMorePush(app, row: "Media Server", title: "Media Server", named: "11-media-server-landscape")
            captureMorePush(app, row: "System", title: "System", named: "12-system-landscape")
            popToRoot(app)
        } else {
            captureSidebarDestination(app, "Settings", named: "09-settings-landscape")
            captureSidebarDestination(app, "Requests & Access", named: "10-requests-landscape")
            captureSidebarDestination(app, "Media Server", named: "11-media-server-landscape")
            captureSidebarDestination(app, "System", named: "12-system-landscape")
            captureSidebarDestination(app, "Missing", named: "17-missing-landscape")
            captureSidebarDestination(app, "Library Management", named: "18-library-management-landscape")
            captureSidebarDestination(app, "Integrations & Automation", named: "19-automation-landscape")
        }

        // One level deeper: a configured service's own settings screen, which is
        // where the longest forms in the app live. On iPad this is the split view's
        // detail column; on iPhone it is a second push.
        if goToTab(app, "Settings") || goToTab(app, "More") {
            // A plain query, not the scrolling `tapFirst(labelContains:)`. Settings is
            // the largest tree in the app, and the scrolling helper re-snapshots the
            // whole thing on each of its eight attempts - enough to blow the query
            // budget and abort the run ("Failed to get matching snapshots") before
            // anything after this point had a chance.
            let sonarrRow = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Fixture Sonarr"))
                .firstMatch
            if sonarrRow.waitForExistence(timeout: 8) {
                tapEvenIfNotHittable(sonarrRow)
                if app.navigationBars["Sonarr"].waitForExistence(timeout: 12) {
                    capture(app, "16-sonarr-settings-detail-landscape")
                }
            }
            popToRoot(app)
        }

        // Edit mode. Worth its own capture because the list swaps selection *types*
        // to get here - single-value navigation selection out, multi-select `Set` in -
        // which rebuilds the `List`. What that does to the detail column beside it,
        // and to the row that was driving it, is not something to assume.
        if goToTab(app, "Series") {
            settleRootTab(app, "Series")
            // The overflow menu is labelled by service, not by screen:
            // `"\(serviceType.displayName) Actions"`.
            if tapFirst(app, exactly: "Sonarr Actions") {
                if tapFirst(app, exactly: "Select") {
                    settle(app, untilAnyOf: [app.buttons["Select All"], app.buttons["Done"]], timeout: 8)
                    capture(app, "29-series-edit-mode-landscape")
                    tapFirst(app, exactly: "Done")
                }
            }
        }

        // Calendar last, deliberately. It is presented as a sheet over the split view,
        // and evaluating queries against that stacked tree has timed out twice
        // ("Failed to get matching snapshots"), which aborts the whole test. Every
        // surface above is worth more than this one screenshot, so none of them wait
        // behind it any more.
        if goToTab(app, "Series"), tapFirst(app, exactly: "Calendar") {
            if app.navigationBars["Calendar"].waitForExistence(timeout: 15) {
                capture(app, "08-calendar-sheet-landscape")
            }
            tapFirst(app, exactly: "Close")
        }

        // The sidebar is collapsible, and how a screen looks with it hidden is a
        // separate layout question from how it looks alongside it - a list sized for
        // 1106pt of content is not the same list at 1376pt.
        let toggle = Self.sidebarToggle(in: app)
        if goToTab(app, "Downloads"), toggle.waitForExistence(timeout: 5) {
            settleRootTab(app, "Downloads")
            tapEvenIfNotHittable(toggle)
            capture(app, "13-downloads-sidebar-collapsed-landscape")
        }
    }

    // MARK: - Portrait pass

    /// Portrait is the orientation where `.sidebarAdaptable` is most likely to have
    /// collapsed back to something phone-shaped, so the root tabs are recaptured
    /// here rather than assumed to match landscape.
    @MainActor
    func testCapturePrimarySurfacesPortrait() async throws {
        let app = try await launchFullyConfiguredApp(orientation: .portrait)

        guard reachedTabUI(app) else {
            capture(app, "20-UNREACHED-tab-ui-portrait")
            dumpHierarchy(app, label: "portrait, tab UI unreachable")
            return
        }
        ensureSidebarExpanded(app)

        captureRootTabs(app, orientation: "portrait", indexOffset: 21)

        captureDetail(app, tab: "Series", row: Self.headlineSeriesTitle,
                      expecting: Self.headlineSeriesTitle, named: "26-series-detail-portrait")
        captureDetail(app, tab: "Movies", row: Self.headlineMovieTitle,
                      expecting: Self.headlineMovieTitle, named: "27-movie-detail-portrait")
        captureDetail(app, tab: "Downloads", row: Self.qbittorrentTorrentName,
                      expecting: Self.qbittorrentTorrentName, named: "28-download-detail-portrait")
    }

    // MARK: - Chrome diagnostic

    /// Not a capture: a read-out of what each iPad chrome actually contains.
    ///
    /// `.sidebarAdaptable` presents two chromes on iPad - a floating top tab-bar pill
    /// and an expanded sidebar - and `defaultVisibility(_:for:)` decides which tabs
    /// each one shows. Which placement the *pill* counts as is not something to guess
    /// at: get the accessibility tree for both states and read it.
    @MainActor
    func testDumpChromeHierarchies() async throws {
        let app = try await launchFullyConfiguredApp(orientation: .landscapeLeft)
        guard reachedTabUI(app) else {
            dumpHierarchy(app, label: "collapsed, tab UI unreachable")
            return
        }

        dumpHierarchy(app, label: "collapsed pill")
        capture(app, "90-chrome-collapsed")

        if goToTab(app, "More") {
            settleRootTab(app, "More")
            dumpHierarchy(app, label: "more tab contents")
            capture(app, "92-more-contents")
        } else {
            print("=== MORE TAB NOT REACHABLE ===")
        }

        let toggle = Self.sidebarToggle(in: app)
        if toggle.waitForExistence(timeout: 10) {
            tapEvenIfNotHittable(toggle)
            _ = app.cells.firstMatch.waitForExistence(timeout: 10)
            dumpHierarchy(app, label: "expanded sidebar")
            capture(app, "91-chrome-expanded")
        } else {
            print("=== NO SIDEBAR TOGGLE FOUND ===")
        }
    }

    // MARK: - Welcome surface

    /// The first screen a new user sees, and the only primary surface that cannot be
    /// reached from a configured launch - it needs its own, unseeded launch.
    @MainActor
    func testCaptureWelcomeSurface() async throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = Self.unreachableTMDbURL
        app.launch()

        // No fixture services means no tab UI; wait on the app itself being up and
        // any text having rendered rather than on a specific control, so a reworded
        // welcome screen still gets photographed.
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 20)
        capture(app, "30-welcome-landscape")

        XCUIDevice.shared.orientation = .portrait
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
        capture(app, "31-welcome-portrait")
    }

    // MARK: - Surface walking

    @MainActor
    private func captureRootTabs(_ app: XCUIApplication, orientation: String, indexOffset: Int) {
        let tabs = ["Downloads", "Series", "Movies", "Search", "More"]
        for (offset, tab) in tabs.enumerated() {
            guard goToTab(app, tab) else { continue }
            settleRootTab(app, tab)
            capture(app, String(format: "%02d-%@-%@", indexOffset + offset, tab.lowercased(), orientation))
        }
    }

    /// Opens a row from a root tab, captures the screen it pushed, and returns to the
    /// tab root.
    ///
    /// Settling the tab before aiming at the row is the whole point: the movie-detail
    /// capture was missing from the first complete run because the tap was dispatched
    /// while the Radarr library was still loading, so the row it wanted did not exist
    /// yet and the whole surface was silently skipped.
    ///
    /// When the expected screen never arrives, this still captures - under a `-MISS`
    /// name. A capture harness that quietly drops a surface teaches you nothing; a
    /// screenshot of the wrong screen tells you exactly where the walk went instead.
    @MainActor
    @discardableResult
    private func captureDetail(
        _ app: XCUIApplication,
        tab: String,
        row: String,
        expecting title: String,
        named name: String
    ) -> Bool {
        guard goToTab(app, tab) else {
            capture(app, "\(name)-MISS-never-reached-\(tab.lowercased())")
            return false
        }
        settleRootTab(app, tab)

        // Rows are matched across buttons *and* cells: this app's lists render as
        // both depending on the screen, and searching only `buttons` is what made
        // the movie row look absent when it was on screen the whole time.
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", row)
        var target = app.buttons.matching(predicate).firstMatch
        if !target.waitForExistence(in: app, timeout: 10) {
            target = app.cells.matching(predicate).firstMatch
        }
        guard target.waitForExistence(in: app, timeout: 10) else {
            capture(app, "\(name)-MISS-row-never-appeared")
            return false
        }
        tapEvenIfNotHittable(target)

        let arrived = app.navigationBars
            .matching(NSPredicate(format: "identifier CONTAINS[c] %@", title))
            .firstMatch
            .waitForExistence(timeout: 15)
        if !arrived {
            // Some detail screens title themselves differently from the row that
            // opened them; a large-title header still names the thing, so fall back
            // to that before declaring a miss.
            settle(app, untilAnyOf: [app.staticTexts[title]], timeout: 8)
        }
        capture(app, arrived || app.staticTexts[title].exists ? name : "\(name)-MISS-wrong-screen")
        popToRoot(app)
        return true
    }

    /// Selects one of the iPad sidebar's promoted destinations and photographs it.
    /// Unlike `captureMorePush` there is nothing to pop afterwards: these are tabs,
    /// not pushes, so the next call simply selects a different one.
    @MainActor
    private func captureSidebarDestination(_ app: XCUIApplication, _ destination: String, named name: String) {
        guard goToTab(app, destination) else {
            capture(app, "\(name)-MISS-not-in-sidebar")
            return
        }
        settle(app, untilAnyOf: [app.navigationBars[destination]], timeout: 12)
        capture(app, name)
    }

    @MainActor
    private func captureMorePush(_ app: XCUIApplication, row: String, title: String, named name: String) {
        guard tapFirst(app, labelContains: row) else { return }
        guard app.navigationBars[title].waitForExistence(timeout: 15) else { return }
        capture(app, name)
        let back = app.navigationBars[title].buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    /// Waits for the content that proves a tab has actually loaded, so a screenshot
    /// never catches a spinner. Each barrier is a real element the tab renders once
    /// its fixture data has arrived - no timing sleeps.
    @MainActor
    private func settleRootTab(_ app: XCUIApplication, _ tab: String) {
        switch tab {
        case "Downloads":
            settle(app, untilAnyOf: [
                app.staticTexts[Self.sabnzbdJobName],
                app.staticTexts[Self.qbittorrentTorrentName]
            ])
        case "Series":
            settle(app, untilAnyOf: [app.staticTexts[Self.headlineSeriesTitle]])
        case "Movies":
            settle(app, untilAnyOf: [app.staticTexts[Self.headlineMovieTitle]])
        case "Search":
            settle(app, untilAnyOf: [app.navigationBars["Search"], app.searchFields.firstMatch])
        case "More":
            settle(app, untilAnyOf: [app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Settings")
            ).firstMatch])
        default:
            break
        }
    }

    /// Returns once any one of `elements` exists, or after `timeout`. Deliberately
    /// tolerant: a surface that never produced its expected content is still worth a
    /// screenshot, because that empty screen is itself the finding.
    @MainActor
    private func settle(_ app: XCUIApplication, untilAnyOf elements: [XCUIElement], timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) { return }
            _ = elements.first?.waitForExistence(timeout: 1)
        }
    }

    // MARK: - Navigation primitives

    /// `.sidebarAdaptable` means the five root destinations are a bottom tab bar on
    /// iPhone, but on iPad may be a top tab bar *or* a sidebar depending on width and
    /// the user's toggle - and the sidebar's rows are plain buttons, not tab-bar
    /// buttons. Both shapes are tried so the capture survives either.
    /// Matches a root destination in whichever chrome `.sidebarAdaptable` chose.
    ///
    /// On iPad landscape it picks the **sidebar**, where the five destinations are
    /// `Cell`s - not `Button`s, and not `tabBars.buttons`. They are also labelled
    /// with their badge appended ("Downloads, 2"), so an exact-label match misses
    /// the one tab that has a badge. Hence: three element types, and a prefix match.
    @MainActor
    private func rootDestination(_ app: XCUIApplication, _ name: String) -> XCUIElement? {
        // Identifier first, and it is the only reliable route on iPad. The sidebar
        // rows carry `nav.<case>` identifiers precisely because label matching is
        // ambiguous here: "Downloads" also prefixes the Downloads screen's own
        // "Downloads, change view" title menu, and tapping that opens a popover that
        // swallows every subsequent tap in the run.
        let identifier = "nav.\(Self.identifierSuffix(for: name))"
        let hasIdentifier = NSPredicate(format: "identifier == %@", identifier)

        // The row is a `Cell`, but the identifier sits on the `Label` inside it - a
        // `List` row's cell carries neither label nor identifier of its own. Select
        // the cell *containing* the identified view, so the tap lands on the row and
        // `isSelected` reads from the thing that actually tracks selection.
        let cell = app.cells.containing(hasIdentifier).firstMatch
        if cell.waitForExistence(timeout: 3) { return cell }

        // Deliberately *not* `app.descendants(matching: .any)` as a fallback here.
        // That walks the entire tree on every miss, and on these screens it pushed
        // later queries past their limit - the run died with "Failed to get matching
        // snapshots: Timed out while evaluating UI query" three surfaces later, which
        // reads like a broken screen and is really just an over-broad query.
        let button = app.buttons.matching(hasIdentifier).firstMatch
        if button.waitForExistence(timeout: 1) { return button }

        // Label fallback for the compact tab bar, which has no identifiers of its
        // own. Scoped to `tabBars` so it cannot reach a toolbar button.
        let predicate = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, "\(name),")
        let tabButton = app.tabBars.buttons.matching(predicate).firstMatch
        return tabButton.waitForExistence(timeout: 2) ? tabButton : nil
    }

    /// Maps a display name back to its `RootTab` case name, which is what
    /// `navigationIdentifier` is built from.
    private static func identifierSuffix(for displayName: String) -> String {
        switch displayName {
        case "Downloads": "downloads"
        case "Series": "series"
        case "Movies": "movies"
        case "Search": "search"
        case "More": "more"
        case "Missing": "missing"
        case "Library Management": "libraryManagement"
        case "Requests & Access": "requestsAndAccess"
        case "Media Server": "mediaServer"
        case "Integrations & Automation": "automation"
        case "System": "system"
        case "Settings": "settings"
        default: displayName
        }
    }

    /// Switches to a root destination and **confirms the switch actually happened**.
    ///
    /// Tapping is not arriving. A tap dispatched while the previous screen is still
    /// animating away gets swallowed, and the old version of this returned `true`
    /// regardless - so a later step went hunting for a Radarr row inside the Sonarr
    /// list, scrolled it to the bottom, and reported the movie as missing. Checking
    /// the destination's selected state afterwards is what turns that into a retry
    /// instead of a wrong answer.
    @discardableResult
    @MainActor
    private func goToTab(_ app: XCUIApplication, _ name: String) -> Bool {
        for _ in 0..<3 {
            guard let destination = rootDestination(app, name) else { return false }
            if destination.isSelected { return true }
            // `isHittable` is deliberately *not* a precondition. The tab bar uses
            // `.tabBarMinimizeBehavior(.onScrollDown)`, and a minimized bar reports
            // its buttons as existing but not hittable - gating on `isHittable`
            // silently skipped four of the five tabs and captured almost nothing.
            tapEvenIfNotHittable(destination)

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if rootDestination(app, name)?.isSelected == true { return true }
            }
        }
        return rootDestination(app, name)?.isSelected == true
    }

    /// Expands the sidebar if the app came up in the collapsed pill.
    ///
    /// Which chrome `.sidebarAdaptable` shows persists across launches, so a run can
    /// start in either. That matters here because the promoted destinations -
    /// Settings, System, Missing and the rest - exist *only* in the expanded sidebar;
    /// in the pill they are not rendered at all, and a whole capture pass reported
    /// them missing when the previous run happened to leave the pill showing.
    @MainActor
    private func ensureSidebarExpanded(_ app: XCUIApplication) {
        guard rootDestination(app, "Settings") == nil else { return }
        let toggle = Self.sidebarToggle(in: app)
        guard toggle.waitForExistence(timeout: 5) else { return }
        tapEvenIfNotHittable(toggle)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if rootDestination(app, "Settings") != nil { return }
        }
    }

    /// The control that swaps between the floating tab-bar pill and the expanded
    /// sidebar. Matched loosely on purpose: it has appeared as both `ToggleSidebar`
    /// ("Hide Sidebar") and `ToggleSideBar` ("Toggle sidebar") depending on which
    /// state it is currently in, and an exact identifier silently found neither.
    /// The control that reveals a collapsed sidebar.
    ///
    /// Two shapes, both real. `.sidebarAdaptable` used to expose it as an identifier
    /// (`ToggleSidebar` / `ToggleSideBar`, the case varying with its state); the
    /// three-column `NavigationSplitView` exposes it as a button labelled exactly
    /// "Show Sidebar". Matched narrowly on purpose - an earlier `CONTAINS "sidebar"`
    /// match picked up each list column's own toggle instead, so the run "expanded
    /// the sidebar" by collapsing a list and reported every destination missing.
    @MainActor
    private static func sidebarToggle(in app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(
                format: "identifier ==[c] %@ OR label ==[c] %@",
                "togglesidebar", "show sidebar"
            ))
            .firstMatch
    }

    /// Dumps the accessibility tree to the test log. `.sidebarAdaptable` renders the
    /// five root destinations differently on iPad than on iPhone, and guessing at the
    /// right query cost a whole capture run - when a surface can't be reached, the
    /// tree is what says why.
    @MainActor
    private func dumpHierarchy(_ app: XCUIApplication, label: String) {
        print("=== TRAWL HIERARCHY [\(label)] ===")
        print(app.debugDescription)
        print("=== END TRAWL HIERARCHY [\(label)] ===")
    }

    @discardableResult
    @MainActor
    private func tapFirst(_ app: XCUIApplication, exactly label: String) -> Bool {
        let element = app.buttons[label]
        guard element.waitForExistence(timeout: 10) else { return false }
        tapEvenIfNotHittable(element)
        return true
    }

    @discardableResult
    @MainActor
    private func tapFirst(_ app: XCUIApplication, labelContains text: String) -> Bool {
        let element = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
        guard element.waitForExistence(in: app, timeout: 10) else { return false }
        tapEvenIfNotHittable(element)
        return true
    }

    /// Same reasoning as `goToTab`: on iPad plenty of present controls report
    /// `isHittable == false` (a minimized tab bar, a row partly under a toolbar),
    /// and refusing to tap those is what turned the first capture run into two
    /// screenshots instead of eighteen.
    @MainActor
    private func tapEvenIfNotHittable(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Pops every pushed screen off whatever stack we're in, so the next surface
    /// starts from a tab root rather than wherever the last one finished.
    @MainActor
    private func popToRoot(_ app: XCUIApplication) {
        for _ in 0..<4 {
            let back = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
            guard back.exists, back.isHittable else { return }
            back.tap()
        }
    }

    /// True once the app is past the welcome gate and a root destination is on
    /// screen.
    ///
    /// This opens the sidebar itself when it needs to. In portrait the three-column
    /// layout has no room for it, so iPadOS starts it collapsed behind "Show
    /// Sidebar" - and every destination this harness navigates by lives in there.
    /// Waiting for one without opening it first simply times out, which is what the
    /// whole portrait pass used to do.
    @MainActor
    private func reachedTabUI(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var hasTriedToggle = false
        while Date() < deadline {
            if rootDestination(app, "Downloads") != nil { return true }
            if !hasTriedToggle {
                let toggle = Self.sidebarToggle(in: app)
                if toggle.waitForExistence(timeout: 3) {
                    tapEvenIfNotHittable(toggle)
                    hasTriedToggle = true
                }
            }
        }
        return false
    }

    // MARK: - Capture

    /// Screenshots need two things the obvious calls don't give on their own.
    ///
    /// `app.screenshot()` is orientation-correct but captures the app *element's*
    /// frame, which lags a rotation - landscape shots came back letterboxed against
    /// a black band. `XCUIScreen.main.screenshot()` is always clean and full-bleed,
    /// but hands back the raw device buffer (portrait-shaped here) with the content
    /// rotated inside it.
    ///
    /// So: take the screen-level shot, and stamp the interface orientation *as
    /// observed at capture time* into the attachment name, letting the host rotate
    /// by a recorded fact rather than an assumption. Reading the orientation rather
    /// than assuming it matters - the value has been seen to differ between captures
    /// in a single run, which is exactly what made a blanket host-side rotation put
    /// some screens upside down.
    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let stamped = "\(name)--\(orientationTag)"
        XCTContext.runActivity(named: "Capture \(stamped)") { activity in
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = stamped
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    @MainActor
    private var orientationTag: String {
        switch XCUIDevice.shared.orientation {
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .portraitUpsideDown: return "portraitUpsideDown"
        default: return "portrait"
        }
    }

    // MARK: - Launch

    @MainActor
    private func launchFullyConfiguredApp(
        orientation: UIDeviceOrientation
    ) async throws -> XCUIApplication {
        let sonarrServer = try await SonarrFixtureServer(
            seriesJSON: Self.seriesLibraryJSON(),
            statusJSON: #"{"instanceName":"Fixture Sonarr"}"#
        )
        sonarr = sonarrServer

        let radarrServer = try await RadarrFixtureServer(
            extraLibraryMoviesJSON: Self.extraMoviesJSON()
        )
        radarr = radarrServer

        let sabnzbdServer = try await SABnzbdFixtureServer(queueJobName: Self.sabnzbdJobName)
        sabnzbd = sabnzbdServer

        let qbittorrentServer = try await QBittorrentFixtureServer(
            torrentName: Self.qbittorrentTorrentName
        )
        qbittorrent = qbittorrentServer

        let seerrServer = try await SeerrUIFixtureServer()
        seerr = seerrServer

        let jellyfinServer = try await JellyfinUIFixtureServer()
        jellyfin = jellyfinServer

        let prowlarrServer = try await ProwlarrUIFixtureServer()
        prowlarr = prowlarrServer

        XCUIDevice.shared.orientation = orientation

        let app = XCUIApplication()
        app.launchArguments += ["-TrawlUITestInMemoryStore"]
        app.launchEnvironment["TRAWL_UITEST_SONARR_BASE_URL"] = sonarrServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_RADARR_BASE_URL"] = radarrServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_SABNZBD_BASE_URL"] = sabnzbdServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_QBITTORRENT_BASE_URL"] = qbittorrentServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_SEERR_BASE_URL"] = seerrServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_JELLYFIN_BASE_URL"] = jellyfinServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_PROWLARR_BASE_URL"] = prowlarrServer.baseURL
        app.launchEnvironment["TRAWL_UITEST_TMDB_BASE_URL"] = Self.unreachableTMDbURL
        app.launch()
        return app
    }

    // MARK: - Fixture content

    private static let unreachableTMDbURL = "http://127.0.0.1:1/tmdb"
    private static let sabnzbdJobName = "Capture Fixture NZB"
    private static let qbittorrentTorrentName = "Capture Fixture Torrent"
    /// The first row/tile in each library, and the one the detail captures open.
    /// Named distinctly from the rest so a `CONTAINS` match can't land on a sibling.
    private static let headlineSeriesTitle = "Aurora Reach"
    private static let headlineMovieTitle = RadarrFixtureServer.movieTitle

    /// Twelve series, not one: on a 13-inch iPad a single row leaves the entire
    /// screen empty, which tells you nothing about column counts, tile sizing, or
    /// how far a row's trailing metadata drifts from its title at full width.
    private static func seriesLibraryJSON() -> String {
        let library: [(title: String, year: Int, network: String, status: String, seasons: Int, episodes: Int, onDisk: Int64, monitored: Bool)] = [
            (headlineSeriesTitle, 2023, "Meridian+", "continuing", 3, 28, 412_000_000_000, true),
            ("The Longest Winter", 2019, "Northline", "ended", 5, 62, 780_000_000_000, false),
            ("Salt and Static", 2024, "Kestrel TV", "continuing", 1, 8, 96_000_000_000, true),
            ("Harbour Lights", 2021, "Meridian+", "continuing", 4, 41, 530_000_000_000, true),
            ("Paper Cathedrals", 2018, "Vantage", "ended", 2, 16, 188_000_000_000, false),
            ("Nine Kinds of Silence", 2022, "Northline", "continuing", 2, 20, 240_000_000_000, true),
            ("Driftwood County", 2020, "Kestrel TV", "ended", 6, 74, 910_000_000_000, false),
            ("The Glasshouse Papers", 2025, "Vantage", "upcoming", 1, 0, 0, true),
            ("Every Small Hour", 2017, "Meridian+", "ended", 3, 30, 355_000_000_000, false),
            ("Cold Open", 2024, "Kestrel TV", "continuing", 2, 18, 210_000_000_000, true),
            ("Ravensbourne", 2016, "Northline", "ended", 7, 88, 1_120_000_000_000, false),
            ("Fathom", 2025, "Vantage", "continuing", 1, 6, 72_000_000_000, true)
        ]

        let entries = library.enumerated().map { index, show -> String in
            let id = index + 1
            let percent = show.episodes == 0 ? 0 : 100
            return #"""
            {
              "id": \#(id),
              "title": "\#(show.title)",
              "sortTitle": "\#(show.title.lowercased())",
              "status": "\#(show.status)",
              "ended": \#(show.status == "ended"),
              "overview": "A fixture series used to photograph Trawl's library layout at iPad width. It carries enough prose to show how a multi-line synopsis wraps in a row or a tile.",
              "network": "\#(show.network)",
              "year": \#(show.year),
              "path": "/tv/\#(show.title)",
              "qualityProfileId": 1,
              "monitored": \#(show.monitored),
              "runtime": 48,
              "certification": "TV-14",
              "genres": ["Drama", "Mystery"],
              "tags": [],
              "added": "2024-01-0\#((index % 9) + 1)T00:00:00Z",
              "seriesType": "standard",
              "images": [],
              "statistics": {
                "seasonCount": \#(show.seasons),
                "episodeFileCount": \#(show.episodes),
                "episodeCount": \#(show.episodes),
                "totalEpisodeCount": \#(show.episodes),
                "sizeOnDisk": \#(show.onDisk),
                "percentOfEpisodes": \#(percent)
              }
            }
            """#
        }

        return "[\(entries.joined(separator: ","))]"
    }

    /// Library-list padding for the Movies grid, alongside `RadarrFixtureServer`'s
    /// own fixture movie. These carry no detail route - tapping one is not part of
    /// any capture - so they only need the fields the list renders.
    private static func extraMoviesJSON() -> String {
        let library: [(title: String, year: Int, studio: String, hasFile: Bool, size: Int64, monitored: Bool)] = [
            ("The Quiet Coast", 2022, "Vantage Pictures", true, 18_000_000_000, true),
            ("Marrow", 2019, "Northline Films", true, 12_500_000_000, false),
            ("Seventeen Doors", 2024, "Kestrel Studios", false, 0, true),
            ("A Map of Small Fires", 2021, "Vantage Pictures", true, 24_000_000_000, true),
            ("Understory", 2018, "Meridian Motion", true, 9_800_000_000, false),
            ("The Weight of Water", 2023, "Northline Films", false, 0, true),
            ("Glasswing", 2020, "Kestrel Studios", true, 16_400_000_000, true),
            ("Nightjar", 2025, "Meridian Motion", false, 0, true),
            ("The Orchard Keeper", 2017, "Vantage Pictures", true, 21_200_000_000, false),
            ("Sablefish", 2024, "Kestrel Studios", true, 14_100_000_000, true),
            ("Low Country", 2016, "Northline Films", true, 11_300_000_000, false)
        ]

        let entries = library.enumerated().map { index, film -> String in
            // Offset well clear of `RadarrFixtureServer.movieId` so no padding entry
            // can collide with the one movie that does have a detail route.
            let id = 9_000 + index
            return #"""
            {
              "id": \#(id),
              "title": "\#(film.title)",
              "sortTitle": "\#(film.title.lowercased())",
              "originalTitle": "\#(film.title)",
              "overview": "A fixture movie used to photograph Trawl's library layout at iPad width.",
              "status": "released",
              "year": \#(film.year),
              "studio": "\#(film.studio)",
              "hasFile": \#(film.hasFile),
              "sizeOnDisk": \#(film.size),
              "monitored": \#(film.monitored),
              "isAvailable": true,
              "minimumAvailability": "released",
              "runtime": 112,
              "certification": "PG-13",
              "genres": ["Drama"],
              "tags": [],
              "images": [],
              "path": "/movies/\#(film.title) (\#(film.year))",
              "rootFolderPath": "\#(RadarrFixtureServer.movieRootFolderPath)",
              "qualityProfileId": \#(RadarrFixtureServer.movieQualityProfileId),
              "added": "2024-02-0\#((index % 9) + 1)T00:00:00Z",
              "statistics": {
                "movieFileCount": \#(film.hasFile ? 1 : 0),
                "sizeOnDisk": \#(film.size),
                "releaseGroups": []
              }
            }
            """#
        }

        return "[\(entries.joined(separator: ","))]"
    }
}
