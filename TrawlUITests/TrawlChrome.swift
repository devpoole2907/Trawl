//
//  TrawlChrome.swift
//  TrawlUITests
//
//  One way to reach a destination, whichever chrome the app is wearing.
//
//  Trawl presents two root chromes and `ContentView` picks between them on
//  horizontal size class:
//
//    - compact (iPhone, and a narrow iPad multitasking slot) - a five-tab
//      `TabView`, where seven further destinations live *inside* the More tab as
//      rows of a list.
//    - regular (iPad) - a `NavigationSplitView` sidebar, where those same seven are
//      promoted to top-level rows and More does not exist at all.
//
//  Every journey suite in this target used to open with `app.tabBars.buttons["More"]`
//  and walk down from there. On an iPad destination that element does not exist, so
//  the first assertion failed and - with `continueAfterFailure = false` - took the
//  rest of the class with it. The suite was not iPad-hostile so much as iPad-blind:
//  it knew one route to each screen and that route was the phone's.
//
//  So the chrome is the only thing that differs, and it is the only thing this file
//  knows about. A test says where it wants to be; this decides how to get there. The
//  behaviour a suite actually asserts - what the screen renders, which requests the
//  production client made - is identical on both, which is the point: the same test
//  runs on an iPhone destination and an iPad one, and a chrome that breaks on either
//  fails the suite rather than silently going unexercised.
//
//  See `IPadSidebarJourneyUITests` for the tests that pin the sidebar's own
//  behaviour. This file is not that - it is the plumbing that lets every *other*
//  suite stop caring which chrome it launched into.

import XCTest

/// Which root chrome the running device presents.
///
/// XCUITest cannot read SwiftUI's size-class environment. Ordinary runs therefore use
/// idiom as a default, while adaptive-device runs can name the observed chrome through
/// `TRAWL_UITEST_CHROME`. An open iPhone Duo is still a phone idiom but presents the
/// regular sidebar, so treating idiom as authoritative would make the test harness
/// reject the UI it is supposed to verify.
enum TrawlChrome {
    /// Five tabs, with seven more destinations inside More.
    case tabBar
    /// A split-view sidebar listing all twelve destinations.
    case sidebar

    static var current: TrawlChrome {
        if let override = ProcessInfo.processInfo.environment["TRAWL_UITEST_CHROME"] {
            switch override.lowercased() {
            case "tabbar", "compact": return .tabBar
            case "sidebar", "regular": return .sidebar
            default: break
            }
        }
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? .sidebar : .tabBar
        #else
        return .sidebar
        #endif
    }

    static var isSidebar: Bool { current == .sidebar }
}

/// A destination reachable from the app's root chrome.
///
/// The two chromes no longer agree about what a destination *is*, which is the point
/// of this type. On compact there are five tabs and seven hub screens inside More,
/// each hub listing the screens beneath it. On regular there is no More and there are
/// no hubs: every screen worth going to is a sidebar row, so what is three taps away
/// on a phone is one click away on a tablet.
///
/// So a case here is a *screen*, and the route to it is the chrome's business. A hub
/// case exists only for the compact route - `parentHub` is how a screen says which
/// one it is filed under - and asking for a hub itself on the sidebar chrome is a
/// test bug rather than a navigation one, because there is nothing there to open.
enum TrawlDestination: CaseIterable {
    // Primary tabs, present in both chromes.
    case downloads
    case series
    case movies
    case search

    // The hubs. Compact only: on regular their contents are sidebar rows.
    case libraryManagement
    case requestsAndAccess
    case mediaServer
    case automation
    case system

    // Sidebar rows. On compact each is reached through the hub named by `parentHub`.
    case missing
    case calendar
    case requests
    case issues
    case users
    case jellyfinLibraries
    case jellyfinSessions
    case jellyfinTranscoding
    case jellyfinPlugins
    case jellyfinActivity
    case indexers
    case downloadClients
    case linkedApplications
    case remotePaths
    case cleanuparr
    case rootFolders
    case qualityProfiles
    case qualityDefinitions
    case naming
    case libraryImport
    case manualImport
    case subtitles
    case setupCheck
    case health
    case tasks
    case logs
    case diskSpace
    case updates
    case backups
    case settings

    /// The row's label, and the navigation title of the screen it opens.
    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .series: "Series"
        case .movies: "Movies"
        case .search: "Search"
        case .libraryManagement: "Library Management"
        case .requestsAndAccess: "Requests & Access"
        case .mediaServer: "Media Server"
        case .automation: "Integrations & Automation"
        case .system: "System"
        case .missing: "Missing"
        case .calendar: "Calendar"
        case .requests: "Requests"
        case .issues: "Issues"
        case .users: "Users"
        case .jellyfinLibraries: "Libraries"
        case .jellyfinSessions: "Sessions"
        case .jellyfinTranscoding: "Transcoding"
        case .jellyfinPlugins: "Plugins"
        case .jellyfinActivity: "Activity"
        case .indexers: "Indexers"
        case .downloadClients: "Download Clients"
        case .linkedApplications: "Linked Applications"
        case .remotePaths: "Remote Path Mappings"
        case .cleanuparr: "Cleanuparr"
        case .rootFolders: "Root Folders"
        case .qualityProfiles: "Quality Profiles"
        case .qualityDefinitions: "Quality Definitions"
        case .naming: "Naming"
        case .libraryImport: "Library Import"
        case .manualImport: "Manual Import"
        case .subtitles: "Subtitles"
        case .setupCheck: "Setup Check"
        case .health: "Health"
        case .tasks: "Tasks"
        case .logs: "Logs & Activity"
        case .diskSpace: "Disk Space"
        case .updates: "Updates"
        case .backups: "Backups"
        case .settings: "Settings"
        }
    }

    /// Mirrors `RootTab.navigationIdentifier`. Sidebar rows are matched by this and
    /// never by label text: the Downloads row's badge makes its label "Downloads, 2",
    /// and a prefix match loose enough to allow for that also matches the Downloads
    /// screen's own "Downloads, change view" title menu - which a capture run duly
    /// tapped, opening a popover that swallowed every tap after it.
    var navigationIdentifier: String {
        switch self {
        case .downloads: "nav.downloads"
        case .series: "nav.series"
        case .movies: "nav.movies"
        case .search: "nav.search"
        case .libraryManagement, .requestsAndAccess, .mediaServer, .automation, .system:
            // No sidebar row exists for a hub; see `sidebarRow(for:)`.
            "nav.none"
        case .missing: "nav.missing"
        case .calendar: "nav.calendar"
        case .requests: "nav.requests"
        case .issues: "nav.issues"
        case .users: "nav.users"
        case .jellyfinLibraries: "nav.jellyfinLibraries"
        case .jellyfinSessions: "nav.jellyfinSessions"
        case .jellyfinTranscoding: "nav.jellyfinTranscoding"
        case .jellyfinPlugins: "nav.jellyfinPlugins"
        case .jellyfinActivity: "nav.jellyfinActivity"
        case .indexers: "nav.indexers"
        case .downloadClients: "nav.downloadClients"
        case .linkedApplications: "nav.linkedApplications"
        case .remotePaths: "nav.remotePaths"
        case .cleanuparr: "nav.cleanuparr"
        case .rootFolders: "nav.rootFolders"
        case .qualityProfiles: "nav.qualityProfiles"
        case .qualityDefinitions: "nav.qualityDefinitions"
        case .naming: "nav.naming"
        case .libraryImport: "nav.libraryImport"
        case .manualImport: "nav.manualImport"
        case .subtitles: "nav.subtitles"
        case .setupCheck: "nav.setupCheck"
        case .health: "nav.health"
        case .tasks: "nav.tasks"
        case .logs: "nav.logs"
        case .diskSpace: "nav.diskSpace"
        case .updates: "nav.updates"
        case .backups: "nav.backups"
        case .settings: "nav.settings"
        }
    }

    /// The More section this screen is listed under on the phone - the sidebar's
    /// section, since More now draws the same map.
    var compactMoreSectionTitle: String? {
        switch self {
        case .missing: "Library"
        case .requests, .issues, .users, .requestsAndAccess: "Requests & Access"
        case .jellyfinLibraries, .jellyfinSessions, .jellyfinTranscoding, .jellyfinPlugins, .jellyfinActivity, .mediaServer:
            "Media Server"
        case .indexers, .downloadClients, .linkedApplications, .remotePaths, .cleanuparr, .automation:
            "Integrations"
        case .rootFolders, .qualityProfiles, .qualityDefinitions, .naming, .libraryImport, .manualImport, .subtitles, .libraryManagement:
            "Management"
        case .setupCheck, .health, .tasks, .logs, .diskSpace, .updates, .backups, .settings, .system:
            "System"
        case .downloads, .series, .movies, .search, .calendar:
            nil
        }
    }

    /// Which hub this screen is filed under in the compact chrome, if any.
    ///
    /// Nil for the primary tabs, which are in the tab bar, and for the hubs
    /// themselves, which are rows of More's own list.
    var parentHub: TrawlDestination? {
        switch self {
        case .downloads, .series, .movies, .search,
             .libraryManagement, .requestsAndAccess, .mediaServer, .automation, .system,
             .missing, .settings:
            nil
        case .calendar:
            .series
        case .requests, .issues, .users:
            .requestsAndAccess
        case .jellyfinLibraries, .jellyfinSessions, .jellyfinTranscoding,
             .jellyfinPlugins, .jellyfinActivity:
            .mediaServer
        case .indexers, .downloadClients,
             .linkedApplications, .remotePaths, .cleanuparr, .tasks:
            .automation
        case .rootFolders, .qualityProfiles, .qualityDefinitions, .naming, .libraryImport, .manualImport, .subtitles:
            .libraryManagement
        case .setupCheck, .health, .logs, .diskSpace, .updates, .backups:
            .system
        }
    }

    /// True for the screens reached *through* More on compact - the hubs themselves,
    /// and Missing and Settings, which are rows of More's list rather than tabs.
    var isHubBehindMore: Bool {
        switch self {
        case .downloads, .series, .movies, .search: false
        default: true
        }
    }

    /// Whether arriving here can be confirmed by a navigation bar carrying `title`.
    ///
    /// False for the primary tabs, whose bars are retitled - Downloads titles its bar
    /// with a "change view" menu, and the libraries take the server's name when only
    /// one is configured - and for Calendar, which is a sheet on compact.
    var arrivalIsConfirmedByNavigationBar: Bool {
        switch self {
        case .downloads, .series, .movies, .search, .calendar: false
        default: true
        }
    }
}

// MARK: - Reaching a destination

extension XCTestCase {

    /// The prompt on the sidebar's own `.searchable`, from `ContentView.sidebarList`.
    /// It is how a search field belonging to the chrome is told apart from one
    /// belonging to the screen under test.
    fileprivate static var sidebarSearchPrompt: String { "Search Trawl" }

    /// Opens `destination`, by whichever route the running chrome provides.
    ///
    /// On compact that is the tab bar, plus a trip through More for the seven hubs.
    /// On regular it is a single sidebar row - revealing the sidebar first if the
    /// window is portrait, where iPadOS keeps it behind a "Show Sidebar" button.
    ///
    /// Returns whether the destination was actually *reached*, not whether a tap was
    /// dispatched. That distinction is not pedantry: an earlier version of the iPad
    /// capture harness reported success for "I tapped something", and a walk that
    /// stayed on Series spent the next minute scrolling a Sonarr list looking for a
    /// Radarr row before failing somewhere unrelated.
    @MainActor
    @discardableResult
    func openDestination(
        _ destination: TrawlDestination,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        switch TrawlChrome.current {
        case .sidebar: openViaSidebar(destination, in: app, timeout: timeout)
        case .tabBar: openViaTabBar(destination, in: app, timeout: timeout)
        }
    }

    /// Waits for the root chrome to finish appearing.
    ///
    /// Every journey suite needs this before its first navigation, because a launch
    /// with seeded services still has to get past the welcome gate, and a query that
    /// runs during that window finds nothing and reports the app broken. Suites used
    /// to spell it `app.tabBars.buttons["More"].waitForExistence(...)`, which is the
    /// same wait wearing a chrome-specific disguise.
    @MainActor
    @discardableResult
    func ensureRootChromeIsReady(in app: XCUIApplication, timeout: TimeInterval = 20) -> Bool {
        switch TrawlChrome.current {
        case .tabBar:
            // Tab buttons do not carry the label's identifier, so the title is the
            // match - "Library" is unique in the tab bar.
            if app.tabBars.buttons["Library"].waitForExistence(timeout: timeout) { return true }
            // A relaunch inside a suite can come back with the bar still minimised.
            expandTabBarIfMinimized(in: app)
            return app.tabBars.buttons["Library"].waitForExistence(timeout: 5)
        case .sidebar:
            // Landscape, and this is the one place it can be set: right after launch,
            // before any navigation has happened.
            //
            // In portrait, three columns do not fit, so iPadOS makes the sidebar an
            // *overlay* on top of the content column rather than a column beside it.
            // Everything underneath keeps its full-width frame, so the sidebar's own
            // search field and the content's land on the same origin - a tap meant for
            // one focuses the other, and `typeText` then fails with "neither element
            // nor any descendant has keyboard focus" while pointing at a field that is
            // plainly on screen. Landscape gives the sidebar a column of its own and
            // the overlap disappears.
            //
            // Set here rather than per-suite because every suite needs it, and set
            // *before* the first query rather than mid-journey: rotating a running app
            // that has already navigated wedged the chrome badly enough that no
            // destination resolved at all.
            XCUIDevice.shared.orientation = .landscapeLeft

            // Most of `timeout` is spent waiting for the app to clear the welcome
            // gate, which is a real wait. But a collapsed sidebar never appears at all
            // until its toggle is pressed, so waiting the full budget first would
            // spend twenty seconds proving something that was never going to happen.
            // The toggle is offered as soon as the chrome exists, so the reveal is
            // attempted early and the long wait follows it.
            if sidebarRow(for: .downloads, in: app, timeout: 5) != nil { return true }
            revealSidebarIfHidden(in: app)
            if sidebarRow(for: .downloads, in: app, timeout: timeout) != nil { return true }
            // Second reveal: on a slow launch the first one ran before the toolbar
            // had a toggle to press.
            revealSidebarIfHidden(in: app)
            return sidebarRow(for: .downloads, in: app, timeout: 5) != nil
        }
    }

    // MARK: Sidebar

    @MainActor
    private func openViaSidebar(
        _ destination: TrawlDestination,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        // A hub is not a place on this chrome. Its contents are sidebar rows, so a
        // test that asks for one is describing the compact route; failing loudly here
        // is better than selecting something arbitrary and reporting success.
        guard destination.navigationIdentifier != "nav.none" else { return false }

        // Short wait, then reveal, then the real wait - see `ensureRootChromeIsReady`.
        // A collapsed sidebar is not a slow sidebar, and waiting for it as though it
        // were burns the whole budget before trying the one thing that would work.
        if let row = sidebarRow(for: destination, in: app, timeout: 3) {
            return tapAndConfirm(row, destination: destination, in: app, timeout: timeout)
        }
        revealSidebarIfHidden(in: app)
        guard let revealed = sidebarRow(for: destination, in: app, timeout: timeout) else { return false }
        return tapAndConfirm(revealed, destination: destination, in: app, timeout: timeout)
    }

    /// Finds a sidebar row by its `nav.<case>` identifier, scrolling the sidebar to
    /// reach it.
    ///
    /// `containing` rather than `matching`: the identifier is on the row's `Label`,
    /// which the list wraps in a cell, so the predicate has to look at descendants.
    ///
    /// The scrolling is not optional. The sidebar lists every destination in the app
    /// and only a dozen fit on a 13-inch iPad, and a `List` does not put off-screen
    /// rows in the accessibility tree at all - so a plain wait reports Setup Check,
    /// Indexers, Quality Profiles and everything else below the fold as *missing*,
    /// and the suites that open them failed with "should be reachable" against a
    /// sidebar that had them all along.
    ///
    /// `waitForExistence(in:)` cannot do this job: it deliberately scrolls the
    /// *content* column and skips the sidebar, because on every other screen the
    /// sidebar is the wrong thing to move. Here it is the only thing to move.
    ///
    /// Both directions, because a caller asking for Downloads after Setup Check is
    /// asking to go back up.
    @MainActor
    func sidebarRow(
        for destination: TrawlDestination,
        in app: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> XCUIElement? {
        let row = app.cells
            .containing(NSPredicate(format: "identifier == %@", destination.navigationIdentifier))
            .firstMatch
        if row.waitForExistence(timeout: timeout) { return row }

        let sidebar = app.collectionViews["Sidebar"]
        guard sidebar.exists else { return nil }
        for _ in 0..<8 {
            sidebar.swipeUp()
            if row.waitForExistence(timeout: 1) { return row }
        }
        for _ in 0..<10 {
            sidebar.swipeDown()
            if row.waitForExistence(timeout: 1) { return row }
        }
        return nil
    }

    /// Brings the sidebar on screen if it is currently collapsed.
    ///
    /// Three columns do not fit in an iPad's portrait width, so iPadOS collapses the
    /// sidebar behind a toolbar button. Two things make this narrower than it looks.
    ///
    /// It checks first: the toggle exists in landscape too, where the sidebar is
    /// already on screen, and tapping it there would *hide* the thing the caller is
    /// about to look for. Presence of the toggle is not evidence the sidebar is gone.
    ///
    /// And the toggle is matched by its own identifier and label rather than by
    /// anything looser: a broad matcher grabbed each *list column's* own toggle
    /// instead, collapsing the wrong column and leaving the run somewhere it could not
    /// recover from.
    @MainActor
    func revealSidebarIfHidden(in app: XCUIApplication) {
        // The overlay sidebar preserves its scroll position. Checking only its first
        // row mistakes an already-open, scrolled sidebar for a closed one and taps
        // the same system control as "Hide Sidebar". The collection itself is the
        // stable proof that the overlay is currently on screen.
        if app.collectionViews["Sidebar"].exists { return }

        // Case-insensitive on both, and matched in one query rather than two: the
        // identifier and the label are the same control, and which of them XCUITest
        // reports varies with the iPadOS build. `tapWhenPossible` rather than a bare
        // `tap`, because the toggle regularly reports itself unhittable while sitting
        // plainly in the toolbar.
        let toggle = app.buttons
            .matching(NSPredicate(
                format: "identifier ==[c] %@ OR label ==[c] %@",
                "togglesidebar", "show sidebar"
            ))
            .firstMatch
        guard toggle.waitForExistence(timeout: 3) else { return }
        tapWhenPossible(toggle, timeout: 3)
    }

    // MARK: Tab bar

    @MainActor
    private func openViaTabBar(
        _ destination: TrawlDestination,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        // The phone's tab bar is Library, Calendar, More and Search. Downloads is a
        // tab of the notification sheet, opened from the bar above the tabs; Series
        // and Movies are the Library tab's scope; everything else is a row of More,
        // in the sidebar's own sections.
        if destination != .downloads {
            dismissNotificationsSheetIfPresent(in: app)
        }
        switch destination {
        case .series:
            return openLibraryScope("Series", in: app, timeout: timeout)
        case .movies:
            return openLibraryScope("Movies", in: app, timeout: timeout)
        case .downloads:
            return openDownloadsSheet(in: app, timeout: timeout)
        case .search, .calendar:
            guard let tab = compactTab(identifier: destination.navigationIdentifier, title: destination.title, in: app, timeout: timeout) else {
                return false
            }
            return tapWhenPossible(tab)
        case .libraryManagement, .requestsAndAccess, .mediaServer, .automation, .system:
            // No hub screens on the phone any more: each is a section of More's own
            // list, so "opening" one is opening More with that section on screen.
            return openCompactMoreRoot(in: app, timeout: timeout)
        default:
            guard openCompactMoreRoot(in: app, timeout: timeout) else { return false }
            // Setup Check is More's own status row rather than a plain link.
            let row = app.buttons[destination == .setupCheck ? "more-setup-check" : destination.navigationIdentifier]
            if !row.waitForExistence(timeout: 2), let section = destination.compactMoreSectionTitle {
                // A missing row is either folded away or just below the fold - the
                // list builds only the rows near the screen. The header says which.
                revealCompactMoreSection(section, in: app)
            }
            guard scrollCompactMoreRowIntoView(row, in: app) else { return false }
            row.tap()
            return confirmArrival(at: destination, in: app, timeout: timeout)
        }
    }

    @MainActor
    private func compactTab(identifier: String, title: String, in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let conventional = app.tabBars.buttons[title]
        if conventional.waitForExistence(timeout: 3) { return conventional }
        let identified = app.buttons[identifier]
        if identified.exists { return identified }
        expandTabBarIfMinimized(in: app)
        return conventional.waitForExistence(timeout: timeout) ? conventional : nil
    }

    /// Opens the Library tab at its root and picks a scope from its title menu.
    @MainActor
    func openLibraryScope(_ scope: String, in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        guard let tab = compactTab(identifier: "nav.library", title: "Library", in: app, timeout: timeout),
              tapWhenPossible(tab) else { return false }
        popCompactMoreStackToRoot(in: app)

        let menu = app.buttons
            .matching(NSPredicate(format: "label ENDSWITH[c] %@", ", change view"))
            .firstMatch
        guard menu.waitForExistence(in: app, timeout: timeout) else { return false }
        if menu.label.hasPrefix("\(scope),") { return true }
        guard tapWhenPossible(menu) else { return false }
        let option = app.buttons[scope].firstMatch
        guard option.waitForExistence(timeout: 5), tapWhenPossible(option) else { return false }
        let chosen = app.buttons["\(scope), change view"]
        return chosen.waitForExistence(timeout: timeout)
    }

    /// The Downloads screen's title menu. On the phone Downloads is a tab of the
    /// notification sheet, and the Library tab's own "…, change view" menu is still
    /// in the tree underneath it, so a bare `firstMatch` can pick the wrong one.
    @MainActor
    func downloadsTitleMenu(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@ AND NOT (label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@)",
            "change view", "Library,", "Series,", "Movies,"
        )).firstMatch
    }

    /// Opens Downloads, which on the phone is a tab of the notification sheet.
    @MainActor
    func openDownloadsSheet(in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let sheetTab = app.tabBars.buttons["Downloads"]
        if !sheetTab.exists {
            let accessory = app.buttons["notification-accessory"]
            guard accessory.waitForExistence(timeout: timeout), tapWhenPossible(accessory) else { return false }
        }
        guard sheetTab.waitForExistence(timeout: timeout) else { return false }
        return tapWhenPossible(sheetTab)
    }

    @MainActor
    private func openCompactMoreRoot(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        var more = compactMoreControl(in: app, timeout: 3)
        if more == nil {
            expandTabBarIfMinimized(in: app)
            more = compactMoreControl(in: app, timeout: timeout)
        }
        guard let more, tapWhenPossible(more) else { return false }
        dismissNotificationsSheetIfPresent(in: app)
        popCompactMoreStackToRoot(in: app)
        return app.navigationBars["More"].waitForExistence(timeout: timeout)
    }

    /// Unfolds a More section if it is folded. The header carries its state as
    /// its accessibility value, so an open section - whose row may simply be below
    /// the fold - is never tapped shut. The setup sections - Integrations and
    /// Management - start folded.
    @MainActor
    private func revealCompactMoreSection(_ title: String, in app: XCUIApplication) {
        let header = app.descendants(matching: .any).matching(identifier: "more-section.\(title)").firstMatch
        if !header.waitForExistence(timeout: 1), let list = compactMoreRootCollection(in: app) {
            for _ in 0..<8 where !header.exists { list.swipeUp() }
            for _ in 0..<10 where !header.exists { list.swipeDown() }
        }
        guard header.exists else { return }
        guard (header.value as? String) == "Collapsed" else { return }
        if let list = compactMoreRootCollection(in: app) {
            for _ in 0..<6 where !isClearOfBottomChrome(header, in: app) {
                nudge(list, toward: header, in: app)
            }
        }
        if header.isHittable { header.tap() }
    }

    @MainActor
    private func scrollCompactMoreRowIntoView(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        // More keeps its scroll position between visits, so the row can be above
        // the screen as easily as below it: look down first, then back up.
        if !row.waitForExistence(timeout: 3), let list = compactMoreRootCollection(in: app) {
            var found = false
            for _ in 0..<10 where !found {
                list.swipeUp()
                found = row.waitForExistence(timeout: 1)
            }
            for _ in 0..<12 where !found {
                list.swipeDown()
                found = row.waitForExistence(timeout: 1)
            }
        }
        guard row.waitForExistence(timeout: 3) else { return false }
        if let list = compactMoreRootCollection(in: app) {
            // Scroll toward the row: it can be tucked under the bar above as easily
            // as under the accessory below.
            for _ in 0..<8 where !isClearOfBottomChrome(row, in: app) {
                nudge(list, toward: row, in: app)
                _ = row.waitForExistence(timeout: 0.5)
            }
        }
        return isClearOfBottomChrome(row, in: app)
    }

    /// A short, slow drag that brings `element` toward the middle of the screen. A
    /// full swipe flings the list a screen or more, which can carry a row from
    /// under the bar straight past the middle to under the accessory, and back.
    @MainActor
    private func nudge(_ list: XCUIElement, toward element: XCUIElement, in app: XCUIApplication) {
        let distance = max(-260, min(260, app.frame.midY - element.frame.midY))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: distance == 0 ? 80 : distance))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Hittable, below More's bar, and above the bar accessory and tab bar. A row under the
    /// notification accessory still reports hittable, but the tap lands on the
    /// accessory and opens the notification sheet instead.
    @MainActor
    private func isClearOfBottomChrome(_ row: XCUIElement, in app: XCUIApplication) -> Bool {
        guard row.isHittable else { return false }
        var chromeTop = app.frame.maxY
        let accessory = app.buttons["notification-accessory"]
        if accessory.exists { chromeTop = min(chromeTop, accessory.frame.minY - 12) }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists { chromeTop = min(chromeTop, tabBar.frame.minY) }
        let navigationBar = app.navigationBars["More"]
        let chromeBottom = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
        return row.frame.midY < chromeTop && row.frame.midY > chromeBottom
    }

    /// Taps a row of whatever list is on screen, by its title.
    ///
    /// Used to walk the second level of the compact chrome - the hub's own list -
    /// where the row is an ordinary `NavigationLink` rather than a chrome control.
    @MainActor
    private func tapListRow(titled title: String, in app: XCUIApplication) -> Bool {
        let row = app.buttons
            .matching(NSPredicate(
                format: "label ==[c] %@ OR label BEGINSWITH[c] %@",
                title,
                "\(title),"
            ))
            .firstMatch
        guard row.waitForExistence(in: app, timeout: 10) else { return false }
        return tapWhenPossible(row, timeout: 10)
    }

    /// Restores a tab bar that iOS 26 has minimised behind the selected tab.
    ///
    /// When the content behind the bar scrolls, the bar collapses to a single pill
    /// carrying the selected tab, and every *other* tab leaves the accessibility
    /// hierarchy outright - so a query for one fails in exactly the way it would if
    /// the chrome had never appeared. Reaching Settings scrolls More's list far
    /// enough to trigger it, which is why a journey that edited a server and then
    /// went back to Series reported that the Series tab did not exist.
    ///
    /// The collapsed pill is found by its value rather than by which tab it is: the
    /// selected tab is whichever one the journey happens to be on. Tapping it is the
    /// same gesture a user makes, and it is a no-op when the bar is already expanded
    /// because no button reports itself collapsed then.
    @MainActor
    func expandTabBarIfMinimized(in app: XCUIApplication) {
        let collapsed = app.tabBars.buttons.allElementsBoundByIndex.first {
            ($0.value as? String)?.localizedCaseInsensitiveContains("collapsed") == true
        }
        guard let collapsed, collapsed.isHittable else { return }
        collapsed.tap()
    }

    /// A compact root control can be hosted by a conventional bottom `tabBar` or by
    /// Duo's vertical system rail. Both carry the stable `nav.*` identifier; querying
    /// all buttons first keeps the route independent of the system container shape.
    @MainActor
    private func compactRootControl(
        for destination: TrawlDestination,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let identified = app.buttons[destination.navigationIdentifier]
        if identified.waitForExistence(timeout: timeout) { return identified }

        let conventional = app.tabBars.buttons[destination.title]
        return conventional.waitForExistence(timeout: 1) ? conventional : nil
    }

    @MainActor
    private func compactMoreControl(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let identified = app.buttons["nav.more"]
        if identified.waitForExistence(timeout: timeout) { return identified }

        let conventional = app.tabBars.buttons["More"]
        return conventional.waitForExistence(timeout: 1) ? conventional : nil
    }

    /// Selecting the already-active More rail item does not reset its NavigationStack.
    /// Before opening another deep destination, unwind only the system `BackButton`
    /// controls. On Duo these live in the vertical rail rather than inside the named
    /// navigation bar, which is why a bar-scoped lookup cannot perform this reset.
    @MainActor
    private func popCompactMoreStackToRoot(in app: XCUIApplication) {
        for _ in 0..<8 {
            let back = app.buttons["BackButton"]
            guard back.waitForExistence(timeout: 0.5) else { return }
            guard tapWhenPossible(back, timeout: 2) else { return }
        }
    }

    /// The notification accessory sits beside Duo's compact vertical rail. A broad
    /// swipe can begin on it and present the Notifications sheet instead of moving
    /// More's list. Close that sheet before resolving the root collection so a later
    /// route cannot accidentally scroll the modal's inset list.
    @MainActor
    func dismissNotificationsSheetIfPresent(in app: XCUIApplication) {
        // The sheet has its own tab bar - Alerts, Downloads, Actions - which is how
        // it is told apart from the app's.
        let sheetTab = app.tabBars.buttons["Alerts"]
        guard sheetTab.waitForExistence(timeout: 0.5) else { return }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end)

        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: sheetTab
        )
        if XCTWaiter().wait(for: [gone], timeout: 3) != .completed {
            // A sheet resting at half height leaves the top of the screen dimmed;
            // tapping there dismisses it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            _ = XCTWaiter().wait(for: [gone], timeout: 3)
        }
    }

    /// Returns More's full-window collection, excluding inset sheets such as Recent
    /// Notifications. The Duo outer display keeps off-screen TabView collections in
    /// the hierarchy, so the visible, largest collection is the reliable root.
    @MainActor
    private func compactMoreRootCollection(in app: XCUIApplication) -> XCUIElement? {
        app.collectionViews.allElementsBoundByIndex
            .filter { $0.isHittable }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    // MARK: Shared

    @MainActor
    private func tapAndConfirm(
        _ element: XCUIElement,
        destination: TrawlDestination,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        guard tapWhenPossible(element) else { return false }
        return confirmArrival(at: destination, in: app, timeout: timeout)
    }

    @MainActor
    private func confirmArrival(
        at destination: TrawlDestination,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        guard destination.arrivalIsConfirmedByNavigationBar else { return true }
        if app.navigationBars[destination.title].waitForExistence(timeout: timeout) { return true }
        // Several screens take a subtitle or the owning server's name in their bar -
        // "Linked Apps / Prowlarr", "Indexers / Prowlarr" - so the title is a prefix
        // rather than the whole of it.
        if app.navigationBars
            .matching(NSPredicate(format: "identifier BEGINSWITH[c] %@", destination.title))
            .firstMatch
            .waitForExistence(timeout: 3) {
            return true
        }
        return false
    }

    /// Types into a field, routing the keystrokes through the application rather than
    /// the element.
    ///
    /// `XCUIElement.typeText` insists the element it is called on holds keyboard focus,
    /// and fails outright - "Neither element nor any descendant has keyboard focus" -
    /// when it does not. On iPad that check is the whole problem: the simulator runs
    /// with a hardware keyboard, so no software keyboard ever appears
    /// (`app.keyboards.count == 0`), and a form-sheet field that has plainly been
    /// tapped still does not satisfy it.
    ///
    /// `XCUIApplication.typeText` sends the same keystrokes to whatever holds focus,
    /// which is what a user's hardware keyboard does. If the tap focused the field the
    /// text lands; if it did not, the caller's own assertion fails on the value - an
    /// honest failure about the field, rather than an infrastructural one about
    /// XCUITest's focus bookkeeping.
    @MainActor
    func typeText(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        focus(field, in: app)
        app.typeText(text)
    }

    // MARK: Row swipe actions

    /// Which edge's swipe actions to reveal on a list row.
    enum RowSwipe {
        /// The row's leading actions, revealed by dragging rightward.
        case leading
        /// The row's trailing actions, revealed by dragging leftward.
        case trailing
    }

    /// Reveals a row's swipe actions, without handing the gesture to the system.
    ///
    /// `XCUIElement.swipeRight()` drags across the element's full width, starting at
    /// its leading edge. On iPhone that is a row action. On iPad, where the list sits
    /// in a split-view column and the sidebar is collapsed, a rightward drag beginning
    /// at the leading edge is the *system* show-sidebar gesture - so the sidebar slid
    /// out, the row never moved, and the test reported that the app had lost its swipe
    /// actions.
    ///
    /// Dragging between two interior points keeps the gesture inside the row, which is
    /// the same thing a user's thumb does and is unambiguous on both platforms.
    @MainActor
    func revealSwipeActions(_ edge: RowSwipe, on row: XCUIElement) {
        let (from, to): (CGFloat, CGFloat) = switch edge {
        case .leading: (0.35, 0.9)
        case .trailing: (0.65, 0.1)
        }
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: Text entry

    /// Gives a text field keyboard focus, and confirms it took.
    ///
    /// The tap goes to the field's trailing edge on purpose: SwiftUI aligns URL fields
    /// toward that edge, and tapping there leaves the caret *after* the existing text
    /// rather than before it, which is what makes a subsequent run of deletes remove
    /// the right characters.
    ///
    /// But a trailing-edge tap does not reliably focus the field on iPad. The setup
    /// sheets are form sheets there, and the form is width-limited
    /// (`readableFormWidth()`), so the field is wide and the trailing 5% can land past
    /// the editable text on inset rather than on it. `typeText` then throws "Neither
    /// element nor any descendant has keyboard focus" - which reads as a broken screen
    /// and is really a tap that missed by a few points.
    ///
    /// So focus is *verified* rather than assumed. The signal is the field's own
    /// `hasKeyboardFocus`, not merely a keyboard on screen: moving between two fields
    /// in the same form leaves the keyboard up throughout, so "a keyboard exists" is
    /// already true before the tap and stays true when the tap misses. What follows is
    /// then typed into the field the caller has just left - silently. That is not
    /// hypothetical: a qBittorrent edit typed the new *username* into the *host* field
    /// and saved `http://fixture-updated-user`, and the failure surfaced twenty lines
    /// later as "the server never received a login", naming the wrong thing entirely.
    ///
    /// The keyboard check is kept as a fallback for any element that does not report
    /// focus, so nothing that passes today starts failing on a missing attribute.
    /// The fallback tap is the field's centre, which always focuses but may place the
    /// caret mid-text - acceptable, because it only runs when the precise tap failed.
    @MainActor
    @discardableResult
    func focus(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        if hasKeyboardFocus(field) { return true }

        if field.elementType == .secureTextField {
            // A SecureField exposes a compact text-input element with no meaningful
            // trailing inset; tapping it directly is what focuses it.
            field.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        if waitForKeyboardFocus(field) { return true }

        field.tap()
        if waitForKeyboardFocus(field) { return true }
        return app.keyboards.element.waitForExistence(timeout: 1)
    }

    /// Whether this element currently owns the keyboard. Read through the predicate
    /// XCTest itself evaluates for focus, so it works for any element that publishes
    /// the attribute and is simply false for one that does not.
    @MainActor
    private func hasKeyboardFocus(_ field: XCUIElement) -> Bool {
        guard field.exists else { return false }
        return NSPredicate(format: "hasKeyboardFocus == true").evaluate(with: field)
    }

    @MainActor
    private func waitForKeyboardFocus(_ field: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let focused = expectation(
            for: NSPredicate(format: "hasKeyboardFocus == true"),
            evaluatedWith: field
        )
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }

    // MARK: Library rows

    /// Opens a library item by its title, from either chrome.
    ///
    /// The obvious spelling - `app.staticTexts[title].tap()` - works on iPhone and
    /// fails on iPad, for two reasons that compound.
    ///
    /// A library row is a `NavigationLink` on iPhone and a selection `Cell` on iPad
    /// (see `ArrMediaListView.detailSelection`), so the *container* to tap differs.
    /// And on iPad the title appears twice: once in the list and once in the detail
    /// column, because the first item is selected on arrival - so `staticTexts[title]`
    /// is ambiguous, and the match it returns is a decorative header that reports
    /// itself unhittable. The Bazarr journey spent fifteen seconds swiping a list up
    /// and down trying to make that header tappable.
    ///
    /// So the row's container is what gets tapped, chosen for the running chrome. On
    /// iPhone this pushes a detail screen; on iPad it selects the row and the detail
    /// column follows. Callers assert on the detail's own content either way.
    @MainActor
    @discardableResult
    func openLibraryItem(
        titled title: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> Bool {
        let holdsTitle = NSPredicate(format: "label == %@ OR label CONTAINS[c] %@", title, title)

        // Cells first on iPad, buttons first on iPhone: whichever the chrome does not
        // use is either absent or belongs to something else on screen.
        let containers = TrawlChrome.isSidebar
            ? [app.cells.containing(holdsTitle).firstMatch, app.buttons.containing(holdsTitle).firstMatch]
            : [app.buttons.containing(holdsTitle).firstMatch, app.cells.containing(holdsTitle).firstMatch]

        for container in containers where container.waitForExistence(in: app, timeout: timeout / 3) {
            if tapWhenPossible(container, timeout: 5) { return true }
        }

        // Last resort, and the only route on a screen that renders its rows as plain
        // text: tap the label itself.
        let label = app.staticTexts[title]
        guard label.waitForExistence(in: app, timeout: 3) else { return false }
        return tapWhenPossible(label, timeout: 5)
    }

    // MARK: Searching

    /// Types `query` into whichever field searches the app's feature index, and leaves
    /// the results on screen for the caller to match against.
    ///
    /// Both chromes search the *same* index - `MoreSearchIndex` - but they own
    /// different fields, and only one of them exists at a time. On compact it is
    /// More's own "Search settings and features". On regular More is not in the
    /// chrome at all, so the sidebar's `.searchable` field is the only search there
    /// is, which is why it was wired to the full index rather than to a filter over
    /// the eleven sidebar rows.
    ///
    /// Suites that reach a screen by searching for it - rather than by knowing which
    /// hub it is filed under - therefore exercise genuinely different code on each
    /// platform while asserting the same outcome. That is the useful kind of shared
    /// test: one behaviour, two implementations, both pinned.
    @MainActor
    @discardableResult
    func searchTheAppChrome(for query: String, in app: XCUIApplication) -> Bool {
        let field: XCUIElement
        switch TrawlChrome.current {
        case .tabBar:
            guard let more = compactMoreControl(in: app, timeout: 15), tapWhenPossible(more) else { return false }
            field = app.searchFields["Search settings and features"]
            guard field.waitForExistence(timeout: 10) else { return false }
        case .sidebar:
            guard let sidebarField = sidebarSearchField(in: app) else { return false }
            field = sidebarField
        }

        guard tapWhenPossible(field) else { return false }
        field.typeText(query)
        return true
    }

    /// The search field belonging to the screen under test, rather than to the chrome
    /// around it.
    ///
    /// On iPhone there is only ever one search field on screen and `firstMatch` is
    /// unambiguous. On iPad the sidebar carries a permanent `.searchable` of its own,
    /// so a screen with a search field - SearchView, the Prowlarr indexer list, the
    /// Bazarr browser - has two in the tree at once, and `firstMatch` returns the
    /// sidebar's: it is further up the hierarchy and further left on screen. A test
    /// that typed into it would search the feature index instead of the screen, get no
    /// results, and blame the screen.
    ///
    /// So the sidebar's own field is ruled out by position. Every content column sits
    /// to the right of the sidebar, which is the one thing true of all of them.
    @MainActor
    func contentSearchField(in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        guard TrawlChrome.isSidebar else { return app.searchFields.firstMatch }

        // Polled rather than snapshotted once. The screen's own field arrives with the
        // content column, a moment after the destination is selected, while the
        // sidebar's has been there since launch - so a single early read sees only the
        // sidebar's, picks it, and the test then types its query into the feature index
        // and reports the screen as broken.
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let contentField = app.searchFields.allElementsBoundByIndex
                .first { $0.placeholderValue != Self.sidebarSearchPrompt }
            if let contentField { return contentField }
            _ = app.searchFields.firstMatch.waitForExistence(timeout: 0.5)
        } while Date() < deadline

        // Nothing but the sidebar's field ever appeared. Returning it would quietly
        // search the wrong thing, so the caller's own existence assertion is left to
        // fail against a field that is not there.
        return app.searchFields
            .matching(NSPredicate(format: "placeholderValue != %@", Self.sidebarSearchPrompt))
            .firstMatch
    }

    /// The sidebar's search field, brought on screen first if it is scrolled away.
    ///
    /// Two things make a naive query miss it. `.searchable` inside a `List` sits
    /// *above* the first row, so it starts off screen - it is not absent, it is just
    /// not where a query looks. And it does not reliably surface as a `searchField`:
    /// depending on the chrome it arrives as a plain text field carrying the prompt as
    /// its placeholder, so both are accepted rather than guessing which this build
    /// produces.
    @MainActor
    func sidebarSearchField(in app: XCUIApplication) -> XCUIElement? {
        func candidate() -> XCUIElement {
            let search = app.searchFields.firstMatch
            if search.exists { return search }
            return app.textFields
                .matching(NSPredicate(format: "placeholderValue CONTAINS[c] %@", "Search Trawl"))
                .firstMatch
        }

        revealSidebarIfHidden(in: app)
        if candidate().waitForExistence(timeout: 3) { return candidate() }

        guard let anchor = sidebarRow(for: .downloads, in: app, timeout: 5) else { return nil }
        for _ in 0..<3 {
            anchor.swipeDown()
            if candidate().waitForExistence(timeout: 2) { return candidate() }
        }
        return candidate().exists ? candidate() : nil
    }

    /// The back control in a navigation bar.
    ///
    /// `buttons.element(boundBy: 0)` is the obvious spelling and it is wrong on iPad.
    /// A pushed screen inside a split-view column carries the sidebar toggle at its
    /// leading edge *as well as* the back button whenever the sidebar is collapsed -
    /// which is the normal state in portrait - so index 0 is the toggle. Pressing it
    /// slides the sidebar out instead of popping, and the test then fails on the
    /// screen it never left.
    ///
    /// So the toggle is excluded by name and the first remaining leading button is
    /// taken. On iPhone, where no toggle exists, this is the same element index 0
    /// always was.
    @MainActor
    func backButton(in navigationBar: XCUIElement) -> XCUIElement {
        // UIKit's own identifier, when it is there. It is unambiguous, and it is what
        // makes this safe on a bar that carries trailing actions too.
        let identified = navigationBar.buttons["BackButton"]
        if identified.exists { return identified }

        let isNotSidebarToggle = NSPredicate(
            format: "NOT (identifier ==[c] %@ OR label ==[c] %@ OR label ==[c] %@)",
            "togglesidebar", "show sidebar", "hide sidebar"
        )
        let candidates = navigationBar.buttons.matching(isNotSidebarToggle)
        // Leading-most, not `firstMatch`. Query order is not screen order: on the
        // iPad SABnzbd hub, "first" was the Categories screen's trailing **+**, so
        // popping back opened an Add Category sheet instead - and the walk then failed
        // three screens later, on a hub it had never returned to.
        let leading = candidates.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }
        return leading ?? candidates.firstMatch
    }

    /// Taps an element, falling back to its centre coordinate when it is on screen but
    /// not hittable.
    ///
    /// XCUITest *drops* a tap on an element that is not yet hittable rather than
    /// failing loudly, so the run continues and blames whatever screen it happens to
    /// be looking at several steps later. Waiting on hittability alone is not enough
    /// either: a minimising tab bar reports its buttons unhittable while they are
    /// plainly there and tappable, which once skipped four of five tabs in a capture
    /// run. Trying both is what makes this reliable.
    @MainActor
    @discardableResult
    func tapWhenPossible(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }

        let deadline = Date().addingTimeInterval(min(timeout, 5))
        while Date() < deadline {
            if element.isHittable {
                element.tap()
                return true
            }
            _ = element.waitForExistence(timeout: 0.2)
        }

        guard element.exists else { return false }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
    }

    /// Taps a hub row across all three shapes it takes, rather than assuming one.
    ///
    /// Where the row pushes it is a `Button`. Beside a detail pane it drives a
    /// selection instead, and then it surfaces as a cell - or as nothing but its own
    /// label, which is how `IPadSurfaceCaptureUITests` has always reached these rows.
    /// It also reports itself *not hittable* there while being plainly on screen, so
    /// the tap goes through `tapWhenPossible` and its coordinate fallback.
    ///
    /// This exists because `firstButton(labelContaining:)` is redefined privately in
    /// around twenty suites and every copy is button-only, so each one is blind to any
    /// row on a three-column screen. Two suites failed that way on iPad - the Logs
    /// hub's Events row and the Subtitles hub's Language Profiles row - while the rows
    /// were plainly listed.
    @MainActor
    @discardableResult
    func tapHubRow(labelContaining text: String, in app: XCUIApplication) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        for query in [app.buttons, app.cells, app.staticTexts] {
            let row = query.matching(predicate).firstMatch
            guard row.waitForExistence(in: app, timeout: 6) else { continue }
            if tapWhenPossible(row, timeout: 4) { return true }
        }
        return false
    }
}
