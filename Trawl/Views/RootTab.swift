import SwiftUI

/// One group of sidebar rows.
///
/// The sections replace the seven hub *screens* the sidebar used to list. A hub was
/// a screen whose entire job was to show you a list of the screens underneath it -
/// which is what a sidebar already is, so on a display wide enough to hold one the
/// hub was a click spent on nothing. Integrations & Automation is now a heading, not
/// a destination, and the four screens it used to introduce are rows in their own
/// right.
///
/// Collapsible, and the collapse is remembered: thirty rows is a lot to re-collapse
/// on every launch, and a section someone has closed is a statement about what they
/// use rather than a transient bit of view state.
enum SidebarSection: String, CaseIterable, Identifiable, Codable {
    case library = "Library"
    case requests = "Requests & Access"
    case mediaServer = "Media Server"
    case integrations = "Integrations"
    case management = "Management"
    case system = "System"

    var id: String { rawValue }

    var title: String { rawValue }

    /// The rows, in the order they appear.
    var rows: [RootTab] {
        switch self {
        case .library:
            [.downloads, .series, .movies, .missing, .calendar, .search]
        case .requests:
            [.requests, .issues, .users]
        case .mediaServer:
            [.jellyfinLibraries, .jellyfinSessions, .jellyfinTranscoding, .jellyfinPlugins, .jellyfinActivity]
        case .integrations:
            [.indexers, .downloadClients, .qbittorrent, .sabnzbd, .linkedApplications, .remotePaths, .cleanuparr]
        case .management:
            [.rootFolders, .qualityProfiles, .libraryImport, .subtitles]
        case .system:
            // Settings sits at the bottom of System rather than in a section of its
            // own: it is one row, and a heading over a single row is a heading that
            // says nothing. On macOS it is also in the menu bar, where a Mac user
            // looks for it first.
            [.setupCheck, .health, .tasks, .logs, .diskSpace, .updates, .backups, .settings]
        }
    }
}

enum RootTab: Hashable, CaseIterable {
    case downloads
    case series
    case movies
    case search
    case more

    // MARK: - Sidebar-only destinations
    //
    // On iPhone these live *inside* More, reached through its list and the hub
    // screens under it. On iPad and Mac there is no More: each screen worth going to
    // is a sidebar row of its own, so what is three taps away on a phone is one click
    // away on a display with room to show the map.
    //
    // They are still `RootTab` cases rather than a second enum because `TabView`
    // takes one selection type for every tab it holds. The two groups are told apart
    // by `isSidebarOnly`, which drives the `defaultVisibility` calls in `ContentView`
    // and keeps these out of places that mean "primary tab", such as the startup-tab
    // picker in Settings.

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

    var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .series: "Series"
        case .movies: "Movies"
        case .search: "Search"
        case .more: "More"
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

    /// True for the destinations that appear only in the sidebar, never in the tab
    /// bar. The tab bar keeps More instead, so collapsing back to a tab bar - which a
    /// narrow multitasking slot does at any moment - still reaches every one of these
    /// through the list they came from. Neither chrome has a dead end.
    var isSidebarOnly: Bool {
        switch self {
        case .downloads, .series, .movies, .search, .more: false
        default: true
        }
    }

    /// Which screen this destination roots its stack at. `nil` for the primary tabs,
    /// which have views of their own.
    var moreRoot: MoreDestination? {
        switch self {
        case .downloads, .series, .movies, .search, .more: nil
        case .missing: .wanted
        case .calendar: .calendar
        case .requests: .seerrAdmin
        case .issues: .seerrIssues
        case .users: .unifiedUsers
        case .jellyfinLibraries: .jellyfinLibraries
        case .jellyfinSessions: .jellyfinSessions
        case .jellyfinTranscoding: .jellyfinTranscoding
        case .jellyfinPlugins: .jellyfinPlugins
        case .jellyfinActivity: .jellyfinActivityLog
        case .indexers: .prowlarrIndexers
        case .downloadClients: .downloadClientsManagement
        case .qbittorrent: .qbittorrentHub
        case .sabnzbd: .sabnzbdHub
        case .linkedApplications: .linkedApplicationsManagement
        case .remotePaths: .remotePathMappings
        case .cleanuparr: .cleanuparrDashboard
        case .rootFolders: .rootFolders
        case .qualityProfiles: .qualityProfiles
        case .libraryImport: .libraryImport
        case .subtitles: .subtitleManagement
        case .setupCheck: .systemHub
        case .health: .health
        case .tasks: .tasksHub
        case .logs: .logsAndEvents
        case .diskSpace: .diskSpace
        case .updates: .updatesHub
        case .backups: .backupsHub
        case .settings: .settings
        }
    }

    /// Where a sidebar search result should land.
    ///
    /// Matched on the destination first, because most index entries now *are* a
    /// sidebar row and selecting it is both the shortest route and the one with an
    /// obvious way back. Only a leaf that has no row of its own - Naming, Quality
    /// Definitions, a per-service settings screen - falls through to its section's
    /// first row and is pushed onto that stack.
    static func owningSidebarDestination(
        for destination: MoreDestination?,
        category: String
    ) -> RootTab {
        if let destination, let exact = allCases.first(where: { $0.moreRoot == destination }) {
            return exact
        }
        // Downloads' own sub-routes ("Downloads › Client Management") belong to the
        // Downloads tab, hence the prefix match rather than equality.
        if category.hasPrefix("Downloads") { return .downloads }

        return switch category {
        case "Monitoring": .missing
        case "Series & Movies": .calendar
        case "Library Management": .rootFolders
        case "Requests & Access": .requests
        case "Media Server": .jellyfinLibraries
        case "Integrations & Automation": .indexers
        case "Tasks": .tasks
        case "System": .setupCheck
        case "Logs": .logs
        case "Settings": .settings
        // Anything new in the index lands in Settings rather than nowhere. A wrong
        // row is recoverable; a result that does nothing when clicked is not.
        default: .settings
        }
    }

    /// Whether this destination earns a third column.
    ///
    /// True for the ones that are a *list you pick from*, where a detail beside the
    /// list is the whole point. False for the ones that are a screen you read: giving
    /// Disk Space a permanent "Nothing Selected" panel spends half the display on
    /// nothing.
    ///
    /// This is a property of the destination rather than of the current selection
    /// because a split view's detail column cannot be hidden on the fly -
    /// `NavigationSplitViewVisibility` only trims from the leading edge - so the
    /// choice is which *shape* of split view to build, and that has to be decidable
    /// before anything is selected.
    var wantsDetailColumn: Bool {
        switch self {
        case .downloads, .series, .movies, .search, .indexers,
             .downloadClients, .linkedApplications, .qualityProfiles, .tasks,
             .requests, .issues, .calendar, .missing, .users, .jellyfinLibraries,
             .libraryImport, .subtitles, .logs, .settings, .health: true
        default: false
        }
    }

    /// A stable identifier for this destination's sidebar row.
    ///
    /// Exists so a UI test can select a destination without matching on its label.
    /// Labels collide: the Downloads row's badge makes its label "Downloads, 2", and
    /// a prefix match written to allow for that also matches the Downloads tab's own
    /// "Downloads, change view" title menu - which a capture run duly tapped, opening
    /// a popover that swallowed every tap after it.
    var navigationIdentifier: String { "nav.\(self)" }

    var systemImage: String {
        switch self {
        case .downloads: "tray.and.arrow.down"
        case .series: ServiceIdentity.sonarr.tabSystemImage
        case .movies: ServiceIdentity.radarr.tabSystemImage
        case .search: "magnifyingglass"
        case .more: "ellipsis"
        case .missing: "exclamationmark.magnifyingglass"
        case .calendar: "calendar"
        case .requests: "square.and.arrow.down.on.square"
        case .issues: "exclamationmark.bubble"
        case .users: "person.2"
        case .jellyfinLibraries: "books.vertical"
        case .jellyfinSessions: "play.rectangle.on.rectangle"
        case .jellyfinTranscoding: "wand.and.rays"
        case .jellyfinPlugins: "puzzlepiece.extension"
        case .jellyfinActivity: "list.bullet.rectangle"
        case .indexers: "magnifyingglass.circle"
        case .downloadClients: "arrow.down.circle"
        case .qbittorrent: ServiceIdentity.qbittorrent.systemImage
        case .sabnzbd: ServiceIdentity.sabnzbd.systemImage
        case .linkedApplications: "link"
        case .remotePaths: "arrow.triangle.branch"
        case .cleanuparr: "sparkles"
        case .rootFolders: "folder"
        case .qualityProfiles: "slider.horizontal.3"
        case .libraryImport: "square.and.arrow.down.on.square"
        case .subtitles: "captions.bubble"
        case .setupCheck: "checklist"
        case .health: "stethoscope"
        case .tasks: "clock.arrow.2.circlepath"
        case .logs: "doc.text.magnifyingglass"
        case .diskSpace: "internaldrive"
        case .updates: "arrow.triangle.2.circlepath"
        case .backups: "externaldrive.badge.timemachine"
        case .settings: "gearshape"
        }
    }

    /// The tabs offered as a launch destination. Deliberately not `allCases`: the
    /// sidebar-only destinations do not exist on iPhone, where this setting is read,
    /// and offering thirty options for a preference that means "which of the main
    /// tabs opens first" would make the choice harder rather than richer.
    static var startupChoices: [RootTab] {
        allCases.filter { !$0.isSidebarOnly }
    }

    /// Every sidebar row, in section order.
    static var sidebarDestinations: [RootTab] {
        SidebarSection.allCases.flatMap(\.rows)
    }
}
