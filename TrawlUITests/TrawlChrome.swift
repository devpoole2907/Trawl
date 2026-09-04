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
/// Idiom rather than an actual size-class read, because XCUITest has no view of the
/// environment. That makes one case this deliberately gets wrong: an iPad in a narrow
/// multitasking slot is compact, and would be reported here as `.sidebar`. No test in
/// this target runs multitasking - XCUITest cannot arrange one - so the distinction
/// costs nothing today, and `ensureRootChromeIsReady` fails with a legible message
/// rather than a mystery if that ever changes.
enum TrawlChrome {
    /// Five tabs, with seven more destinations inside More.
    case tabBar
    /// A split-view sidebar listing all twelve destinations.
    case sidebar

    static var current: TrawlChrome {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .sidebar : .tabBar
        #else
        .sidebar
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
    case qbittorrent
    case sabnzbd
    case linkedApplications
    case remotePaths
    case cleanuparr
    case rootFolders
    case qualityProfiles
    case libraryImport
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
        case .qbittorrent: "qBittorrent"
        case .sabnzbd: "SABnzbd"
        case .linkedApplications: "Linked Applications"
        case .remotePaths: "Remote Path Mappings"
        case .cleanuparr: "Cleanuparr"
        case .rootFolders: "Root Folders"
        case .qualityProfiles: "Quality Profiles"
        case .libraryImport: "Library Import"
        case .subtitles: "Subtitles"
        case .setupCheck: "Setup Check"
        case .health: "Health"
        case .tasks: "Tasks"
        case .logs: "Logs"
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
        case .qbittorrent: "nav.qbittorrent"
        case .sabnzbd: "nav.sabnzbd"
        case .linkedApplications: "nav.linkedApplications"
        case .remotePaths: "nav.remotePaths"
        case .cleanuparr: "nav.cleanuparr"
        case .rootFolders: "nav.rootFolders"
        case .qualityProfiles: "nav.qualityProfiles"
        case .libraryImport: "nav.libraryImport"
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
        case .indexers, .downloadClients, .qbittorrent, .sabnzbd,
             .linkedApplications, .remotePaths, .cleanuparr, .tasks:
            .automation
        case .rootFolders, .qualityProfiles, .libraryImport, .subtitles:
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
            let downloads = app.tabBars.buttons[TrawlDestination.downloads.title]
            if downloads.waitForExistence(timeout: timeout) { return true }
            // A relaunch inside a suite can come back with the bar still minimised.
            expandTabBarIfMinimized(in: app)
            return downloads.waitForExistence(timeout: 5)
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
        // Any sidebar row will do as proof it is already showing; Downloads is always
        // the first one.
        let anyRow = app.cells
            .containing(NSPredicate(format: "identifier == %@", TrawlDestination.downloads.navigationIdentifier))
            .firstMatch
        if anyRow.exists { return }

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
        guard destination.isHubBehindMore else {
            let tab = app.tabBars.buttons[destination.title]
            if !tab.waitForExistence(timeout: 3) {
                expandTabBarIfMinimized(in: app)
                guard tab.waitForExistence(timeout: timeout) else { return false }
            }
            return tapWhenPossible(tab)
        }

        // A screen filed under a hub is two rows deep on this chrome: More, the hub,
        // then the screen. The sidebar promotes both levels to one click, which is
        // the whole difference between the chromes and the reason a test names the
        // *screen* rather than the route to it.
        if let hub = destination.parentHub {
            guard openViaTabBar(hub, in: app, timeout: timeout) else { return false }
            return tapListRow(titled: destination.title, in: app)
                && confirmArrival(at: destination, in: app, timeout: timeout)
        }

        let more = app.tabBars.buttons["More"]
        if !more.waitForExistence(timeout: 3) {
            expandTabBarIfMinimized(in: app)
        }
        guard more.waitForExistence(timeout: timeout), tapWhenPossible(more) else { return false }

        // More's own list is long enough that several rows start below the fold, so
        // the row is scrolled to rather than merely waited for.
        let row = app.buttons
            .matching(NSPredicate(
                format: "label ==[c] %@ OR label BEGINSWITH[c] %@",
                destination.title,
                "\(destination.title),"
            ))
            .firstMatch
        guard row.waitForExistence(timeout: 10) else { return false }

        // A TabView keeps off-screen tabs mounted. The shared scrolling helper can
        // therefore find the previous tab's retained list before More's visible
        // list and scroll the wrong screen. Settings is the last More row and starts
        // below the fold, so drive the gesture through the visible application until
        // that exact row is hittable. Do not coordinate-tap an off-screen row: its
        // synthesized coordinate can overlap the tab bar and silently select the
        // previous tab instead.
        for _ in 0..<8 where !row.isHittable {
            app.swipeUp()
            _ = row.waitForExistence(timeout: 0.5)
        }
        guard row.isHittable else { return false }
        row.tap()

        return confirmArrival(at: destination, in: app, timeout: timeout)
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
        // And a screen with a detail pane beside it is not in the bar at all: both
        // panes share the column's one bar, whose title belongs to whatever the
        // detail is showing, so the screen's own name is pinned above its list. Every
        // suite that opens Indexers, Download Clients, Linked Applications, Quality
        // Profiles, Tasks, Requests, Calendar or Missing reaches this line.
        let paneName = app.staticTexts[XCUIApplication.listDetailScreenNameIdentifier]
        return paneName.waitForExistence(timeout: 3) && paneName.label.contains(destination.title)
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
    /// So focus is *verified* rather than assumed, using the one observable signal
    /// there is: a keyboard on screen. The fallback tap is the field's centre, which
    /// always focuses but may place the caret mid-text - acceptable, because it only
    /// runs when the precise tap already failed.
    @MainActor
    @discardableResult
    func focus(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        if field.elementType == .secureTextField {
            // A SecureField exposes a compact text-input element with no meaningful
            // trailing inset; tapping it directly is what focuses it.
            field.tap()
        } else {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        if app.keyboards.element.waitForExistence(timeout: 3) { return true }

        field.tap()
        return app.keyboards.element.waitForExistence(timeout: 3)
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
            let more = app.tabBars.buttons["More"]
            guard more.waitForExistence(timeout: 15), tapWhenPossible(more) else { return false }
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
}
