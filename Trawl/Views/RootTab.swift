import SwiftUI

enum RootTab: Hashable, CaseIterable {
    case downloads
    case series
    case movies
    case search
    case more

    // MARK: - Sidebar-only destinations
    //
    // On iPhone these live *inside* More, as the seven rows of its list. On iPad
    // there is no More in the sidebar: each row is promoted to a destination of its
    // own, so a screen two taps away on a phone is one click away on a tablet, which
    // is the whole reason a sidebar earns its width.
    //
    // They are still `RootTab` cases rather than a second enum because `TabView`
    // takes one selection type for every tab it holds. The two groups are told
    // apart by `isSidebarOnly`, which is what drives the `defaultVisibility` calls
    // in `ContentView` - and what keeps them out of places that mean "primary tab",
    // such as the startup-tab picker in Settings.

    case missing
    case libraryManagement
    case requestsAndAccess
    case mediaServer
    case automation
    case system
    case settings

    var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .series: "Series"
        case .movies: "Movies"
        case .search: "Search"
        case .more: "More"
        case .missing: "Missing"
        case .libraryManagement: "Library Management"
        case .requestsAndAccess: "Requests & Access"
        case .mediaServer: "Media Server"
        case .automation: "Integrations & Automation"
        case .system: "System"
        case .settings: "Settings"
        }
    }

    /// True for the destinations that appear only in the iPad sidebar, never in the
    /// tab bar. The tab bar keeps More instead, so collapsing the sidebar back to a
    /// tab bar - which `.sidebarAdaptable` lets the user do at any time - still
    /// reaches every one of these through the list they came from. Neither chrome
    /// has a dead end.
    var isSidebarOnly: Bool {
        switch self {
        case .downloads, .series, .movies, .search, .more:
            false
        case .missing, .libraryManagement, .requestsAndAccess, .mediaServer, .automation, .system, .settings:
            true
        }
    }

    /// Which More screen this tab roots its stack at. `nil` for the primary tabs,
    /// which have their own views.
    var moreRoot: MoreDestination? {
        switch self {
        case .downloads, .series, .movies, .search, .more:
            nil
        case .missing: .wanted
        case .libraryManagement: .mediaManagement
        case .requestsAndAccess: .requestsAndAccess
        case .mediaServer: .jellyfinManagement
        case .automation: .automationClients
        case .system: .systemHub
        case .settings: .settings
        }
    }

    var systemImage: String {
        switch self {
        case .downloads: "tray.and.arrow.down"
        case .series: ServiceIdentity.sonarr.tabSystemImage
        case .movies: ServiceIdentity.radarr.tabSystemImage
        case .search: "magnifyingglass"
        case .more: "ellipsis"
        case .missing: "exclamationmark.magnifyingglass"
        case .libraryManagement: "books.vertical"
        case .requestsAndAccess: "person.2.badge.key"
        case .mediaServer: "play.tv"
        case .automation: "gearshape.2"
        case .system: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }

    /// The tabs offered as a launch destination. Deliberately not `allCases`: the
    /// sidebar-only destinations do not exist on iPhone, where this setting is read,
    /// and listing twelve options for a preference that means "which of the main
    /// tabs opens first" would make the choice harder rather than richer.
    static var startupChoices: [RootTab] {
        allCases.filter { !$0.isSidebarOnly }
    }

    /// The promoted More rows, in the order the More list presents them, so the
    /// sidebar reads the same top to bottom as the list it replaces.
    static var sidebarDestinations: [RootTab] {
        allCases.filter(\.isSidebarOnly)
    }
}
