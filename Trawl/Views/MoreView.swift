import SwiftUI
import SwiftData

enum MoreDestination: Hashable {
    case activity
    case categoriesAndTags
    case rssFeeds
    case diskSpace
    case health
    case wanted
    case settings
    case qbittorrentSettings
    case sonarrSettings
    case radarrSettings
    case prowlarrSettings
    case prowlarrIndexers
    case transferStats
    case torrentManagement
    case integrations
    case linkedApplicationsManagement
    case downloadClientsManagement
    case prowlarrLinkedApplications
    case bazarrLinkedApplications
    case seerrLinkedApplications
    case downloadClients(service: ArrServiceType)
    case remotePathMappings
    case blocklist
    case manualImport
    case calendar
    case calendarSeries(id: Int)
    case calendarMovie(id: Int)
    case manualImportScan(path: String, service: ArrServiceType)
    case mediaManagement
    case arrNamingConfig(service: ArrServiceType)
    case rootFolders
    case qualityProfiles(service: ArrServiceType)
    case bazarrSettings
    case subtitleManagement
    case bazarrLanguageProfiles
    case bazarrProviders
    case bazarrSeriesDetail(seriesId: Int)
    case bazarrMovieDetail(radarrId: Int)
    case requestManagement
    case seerrSettings
    case seerrAdmin
    case seerrIssues
    case seerrLogs
    case jellyfinManagement
    case jellyfinSettings
    case jellyfinLibraries
    case jellyfinSessions
    case jellyfinActivityLog
    case jellyfinScheduledTasks
    case jellyfinPlugins
    case unifiedUsers
}

enum MoreDestinationAccent {
    case calendar
    case manualImport
    case categoriesAndTags
    case transferStats
    case torrentManagement
    case integrations
    case mediaManagement
    case subtitleManagement
    case sonarrNaming
    case radarrNaming
    case rootFolders
    case languageProfiles
    case providers
    case userManagement
    case requestManagement
    case seerr
    case jellyfin

    var color: Color {
        switch self {
        case .calendar: return .purple
        case .manualImport: return .blue
        case .categoriesAndTags: return .brown
        case .transferStats: return .mint
        case .torrentManagement: return .mint
        case .integrations: return .blue
        case .mediaManagement: return .green
        case .subtitleManagement: return .teal
        case .sonarrNaming: return .purple
        case .radarrNaming: return .orange
        case .rootFolders: return .indigo
        case .languageProfiles: return .cyan
        case .providers: return .pink
        case .userManagement: return .blue
        case .requestManagement: return ServiceIdentity.seerr.brandColor
        case .seerr: return ServiceIdentity.seerr.brandColor
        case .jellyfin: return ServiceIdentity.jellyfin.brandColor
        }
    }
}

struct MoreView: View {
    @Query private var servers: [ServerProfile]
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]
    let appServices: AppServices?
    @Binding var path: [MoreDestination]
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var showingNotificationsSheet = false
    @State private var subtitleBadgeCount = 0

    private var hasQBittorrentServer: Bool { !servers.isEmpty }

    private var seerrProfile: SeerrServiceProfile? {
        seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
    }

    private var jellyfinProfile: JellyfinServiceProfile? {
        jellyfinProfiles.first(where: { $0.isEnabled }) ?? jellyfinProfiles.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: MoreDestination.activity) {
                        moreRow(icon: "arrow.down.doc.fill", color: .indigo,
                                title: "Activity", subtitle: "Queue, downloads, and import history")
                    }

                    NavigationLink(value: MoreDestination.wanted) {
                        moreRow(icon: "exclamationmark.triangle.fill", color: .orange,
                                title: "Wanted / Missing", subtitle: "Missing files and subtitles")
                    }

                    NavigationLink(value: MoreDestination.calendar) {
                        moreRow(icon: "calendar", color: MoreDestinationAccent.calendar.color,
                                title: "Calendar", subtitle: "Upcoming releases and air dates")
                    }

                    NavigationLink(value: MoreDestination.health) {
                        moreRow(icon: "heart.text.square.fill", color: .pink,
                                title: "Health", subtitle: "Service health checks")
                    }

                    NavigationLink(value: MoreDestination.blocklist) {
                        moreRow(icon: "nosign", color: .red,
                                title: "Blocklist", subtitle: "Releases blocked from being grabbed")
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.mediaManagement) {
                        moreRow(icon: "folder.badge.gearshape", color: MoreDestinationAccent.mediaManagement.color,
                                title: "Media & Import", subtitle: "Naming, quality profiles, root folders, and import")
                    }

                    NavigationLink(value: MoreDestination.subtitleManagement) {
                        moreRow(icon: "captions.bubble.fill", color: MoreDestinationAccent.subtitleManagement.color,
                                title: "Subtitles", subtitle: subtitleBadgeCount > 0 ? "\(subtitleBadgeCount) items need subtitles" : "Language profiles and subtitle providers")
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.prowlarrIndexers) {
                        moreRow(icon: "magnifyingglass.circle.fill", color: .yellow,
                                title: "Indexers", subtitle: "Manage indexers across your services")
                    }

                    NavigationLink(value: MoreDestination.torrentManagement) {
                        moreRow(icon: "arrow.down.circle.fill", color: MoreDestinationAccent.torrentManagement.color,
                                title: "Torrents", subtitle: "Categories, RSS feeds, and transfer stats")
                    }

                    NavigationLink(value: MoreDestination.integrations) {
                        moreRow(
                            icon: "app.connected.to.app.below.fill",
                            color: MoreDestinationAccent.integrations.color,
                            title: "Integrations",
                            subtitle: "Linked apps, download clients, and remote path mappings"
                        )
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.requestManagement) {
                        moreRow(
                            icon: ServiceIdentity.seerr.systemImage,
                            color: MoreDestinationAccent.requestManagement.color,
                            title: "Requests",
                            subtitle: seerrProfile == nil ? "Not configured" : "Requests, issues, and logs"
                        )
                    }

                    NavigationLink(value: MoreDestination.unifiedUsers) {
                        moreRow(
                            icon: "person.2.fill",
                            color: MoreDestinationAccent.userManagement.color,
                            title: "Users",
                            subtitle: jellyfinProfile == nil ? "Requires Jellyfin" : "Jellyfin and Seerr accounts"
                        )
                    }

                    NavigationLink(value: MoreDestination.jellyfinManagement) {
                        moreRow(
                            icon: "server.rack",
                            color: MoreDestinationAccent.jellyfin.color,
                            title: "Jellyfin",
                            subtitle: jellyfinProfile == nil ? "Not configured" : "Libraries, sessions, activity, and server tasks"
                        )
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.settings) {
                        moreRow(icon: "gearshape.fill", color: .secondary,
                                title: "Settings", subtitle: "App and server configuration")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("More")
            #if os(iOS)
            .toolbarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button {
                        showingNotificationsSheet.toggle()
                    } label: {
                        Image(systemName: "bell.fill")
                            .symbolRenderingMode(.hierarchical)
                            .overlay(alignment: .topTrailing) {
                                if inAppNotificationCenter.unreadCount > 0 {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.red)
                                        .offset(x: 2, y: -2)
                                }
                            }
                    }
                    .accessibilityLabel(inAppNotificationCenter.unreadCount > 0 ? "Recent Notifications, Unread" : "Recent Notifications")
                }
            }
            .sheet(isPresented: $showingNotificationsSheet) {
                RecentNotificationsSheet()
                    .environment(inAppNotificationCenter)
            }
            .navigationDestination(for: MoreDestination.self) { destination in
                switch destination {
                case .activity:
                    ArrActivityView()
                        .moreDestinationTitleStyle()
                case .categoriesAndTags:
                    qbittorrentCategoriesAndTagsDestination
                        .moreDestinationTitleStyle()
                case .rssFeeds:
                    qbittorrentRSSDestination
                        .moreDestinationTitleStyle()
                case .torrentManagement:
                    TorrentManagementView()
                        .moreDestinationTitleStyle()
                case .integrations:
                    IntegrationsManagementView()
                        .moreDestinationTitleStyle()
                case .linkedApplicationsManagement:
                    LinkedApplicationsManagementView()
                        .moreDestinationTitleStyle()
                case .downloadClientsManagement:
                    DownloadClientsManagementView()
                        .moreDestinationTitleStyle()
                case .prowlarrLinkedApplications:
                    prowlarrLinkedApplicationsDestination
                        .moreDestinationTitleStyle()
                case .bazarrLinkedApplications:
                    bazarrLinkedApplicationsDestination
                        .moreDestinationTitleStyle()
                case .seerrLinkedApplications:
                    seerrLinkedApplicationsDestination
                        .moreDestinationTitleStyle()
                case .downloadClients(let service):
                    ArrDownloadClientListView(serviceType: service)
                        .environment(arrServiceManager)
                        .environment(inAppNotificationCenter)
                        .moreDestinationTitleStyle()
                case .remotePathMappings:
                    ArrRemotePathMappingListView()
                        .environment(arrServiceManager)
                        .environment(inAppNotificationCenter)
                        .moreDestinationTitleStyle()
                case .diskSpace:
                    ArrDiskSpaceView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .health:
                    ArrHealthView()
                        .moreDestinationTitleStyle()
                case .wanted:
                    ArrWantedView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .settings:
                    settingsDestination
                        .moreDestinationTitleStyle()
                case .qbittorrentSettings:
                    qbittorrentSettingsDestination
                        .moreDestinationTitleStyle()
                case .sonarrSettings:
                    ArrServiceSettingsView(serviceType: .sonarr)
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .radarrSettings:
                    ArrServiceSettingsView(serviceType: .radarr)
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .prowlarrSettings:
                    ArrServiceSettingsView(serviceType: .prowlarr)
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .prowlarrIndexers:
                    prowlarrIndexersDestination
                        .moreDestinationTitleStyle()
                case .transferStats:
                    transferStatsDestination
                        .moreDestinationTitleStyle()
                case .blocklist:
                    ArrBlocklistView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .manualImport:
                    ArrManualImportView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .calendar:
                    ArrCalendarView(
                        seriesNavigationValue: { MoreDestination.calendarSeries(id: $0) },
                        movieNavigationValue: { MoreDestination.calendarMovie(id: $0) }
                    )
                        .environment(arrServiceManager)
                        .injectSyncService(appServices)
                        .moreDestinationTitleStyle()
                case .seerrAdmin:
                    seerrAdminDestination
                        .moreDestinationTitleStyle()
                case .seerrIssues:
                    if let client = seerrServiceManager.activeClient {
                        SeerrIssueListView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        seerrAdminDestination
                            .moreDestinationTitleStyle()
                    }
                case .seerrLogs:
                    if let client = seerrServiceManager.activeClient {
                        SeerrLogsView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        seerrAdminDestination
                            .moreDestinationTitleStyle()
                    }
                case .seerrSettings:
                    SeerrSettingsView()
                        .moreDestinationTitleStyle()
                case .requestManagement:
                    RequestManagementView(seerrProfile: seerrProfile)
                        .moreDestinationTitleStyle()
                case .jellyfinManagement:
                    JellyfinManagementView(jellyfinProfile: jellyfinProfile)
                        .moreDestinationTitleStyle()
                case .jellyfinLibraries:
                    if let client = jellyfinServiceManager.activeClient {
                        JellyfinLibrariesView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        jellyfinUnavailableDestination
                            .moreDestinationTitleStyle()
                    }
                case .jellyfinSessions:
                    if let client = jellyfinServiceManager.activeClient {
                        JellyfinSessionsView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        jellyfinUnavailableDestination
                            .moreDestinationTitleStyle()
                    }
                case .jellyfinActivityLog:
                    if let client = jellyfinServiceManager.activeClient {
                        JellyfinActivityLogView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        jellyfinUnavailableDestination
                            .moreDestinationTitleStyle()
                    }
                case .jellyfinScheduledTasks:
                    if let client = jellyfinServiceManager.activeClient {
                        JellyfinScheduledTasksView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        jellyfinUnavailableDestination
                            .moreDestinationTitleStyle()
                    }
                case .jellyfinPlugins:
                    if let client = jellyfinServiceManager.activeClient {
                        JellyfinPluginsView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        jellyfinUnavailableDestination
                            .moreDestinationTitleStyle()
                    }
                case .jellyfinSettings:
                    JellyfinSettingsView()
                        .moreDestinationTitleStyle()
                case .unifiedUsers:
                    unifiedUsersDestination
                        .moreDestinationTitleStyle()
                case .calendarSeries(let id):
                    CalendarSeriesDestination(id: id, appServices: appServices, arrServiceManager: arrServiceManager)
                        .moreDestinationTitleStyle()
                case .calendarMovie(let id):
                    CalendarMovieDestination(id: id, appServices: appServices, arrServiceManager: arrServiceManager)
                        .moreDestinationTitleStyle()
                case .manualImportScan(let path, let service):
                    ManualImportScanView(path: path, service: service, serviceManager: arrServiceManager)
                        .moreDestinationTitleStyle()
                case .mediaManagement:
                    ArrMediaManagementView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .arrNamingConfig(let service):
                    ArrNamingConfigView(serviceType: service)
                        .environment(arrServiceManager)
                        .environment(InAppNotificationCenter.shared)
                        .moreDestinationTitleStyle()
                case .rootFolders:
                    ArrRootFoldersView()
                        .environment(arrServiceManager)
                        .environment(inAppNotificationCenter)
                        .moreDestinationTitleStyle()
                case .qualityProfiles(let service):
                    ArrQualityProfilesListView(serviceType: service)
                        .environment(arrServiceManager)
                        .environment(inAppNotificationCenter)
                        .moreDestinationTitleStyle()
                case .bazarrSettings:
                    ArrServiceSettingsView(serviceType: .bazarr)
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .subtitleManagement:
                    SubtitleManagementView()
                        .moreDestinationTitleStyle()
                case .bazarrLanguageProfiles:
                    BazarrLanguageProfilesView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .bazarrProviders:
                    BazarrProvidersView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .bazarrSeriesDetail(let seriesId):
                    BazarrSeriesDestination(seriesId: seriesId, arrServiceManager: arrServiceManager)
                        .moreDestinationTitleStyle()
                case .bazarrMovieDetail(let radarrId):
                    BazarrMovieDestination(radarrId: radarrId, arrServiceManager: arrServiceManager)
                        .moreDestinationTitleStyle()
                }
            }
            .task {
                guard let client = arrServiceManager.activeBazarrEntry?.client else { return }
                if let badges = try? await client.getBadges() {
                    subtitleBadgeCount = badges.episodes + badges.movies
                }
            }
        }
    }

    @ViewBuilder
    private var prowlarrLinkedApplicationsDestination: some View {
        if arrServiceManager.prowlarrConnected {
            ProwlarrApplicationsListView()
                .environment(arrServiceManager)
        } else if arrServiceManager.hasProwlarrInstance {
            ContentUnavailableView {
                Label("Prowlarr Unreachable", systemImage: "network.slash")
            } description: {
                Text(arrServiceManager.prowlarrConnectionError ?? "Unable to reach your configured Prowlarr server.")
            } actions: {
                Button("Retry Connection") {
                    Task { await arrServiceManager.retry(.prowlarr) }
                }
                .buttonStyle(.bordered)
            }
            .navigationTitle("Prowlarr Linked Apps")
        } else {
            ContentUnavailableView {
                Label("Prowlarr Not Set Up", systemImage: ServiceIdentity.prowlarr.tabSystemImage)
            } description: {
                Text("Add a Prowlarr server in Settings to link indexer sync destinations.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
            .navigationTitle("Prowlarr Linked Apps")
        }
    }

    @ViewBuilder
    private var bazarrLinkedApplicationsDestination: some View {
        if arrServiceManager.hasAnyConnectedBazarrInstance {
            BazarrLinkedApplicationsListView()
                .environment(arrServiceManager)
        } else if arrServiceManager.hasBazarrInstance {
            ContentUnavailableView {
                Label("Bazarr Unreachable", systemImage: "network.slash")
            } description: {
                Text(arrServiceManager.bazarrConnectionError ?? "Unable to reach your configured Bazarr server.")
            } actions: {
                Button("Retry Connection") {
                    Task { await arrServiceManager.retry(.bazarr) }
                }
                .buttonStyle(.bordered)
            }
            .navigationTitle("Bazarr Linked Apps")
        } else {
            ContentUnavailableView {
                Label("Bazarr Not Set Up", systemImage: ServiceIdentity.bazarr.tabSystemImage)
            } description: {
                Text("Add a Bazarr server in Settings to link subtitle sync destinations.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
            .navigationTitle("Bazarr Linked Apps")
        }
    }

    @ViewBuilder
    private var seerrLinkedApplicationsDestination: some View {
        if let client = seerrServiceManager.activeClient {
            SeerrLinkedApplicationsView(apiClient: client)
        } else {
            seerrAdminDestination
        }
    }

    @ViewBuilder
    private var transferStatsDestination: some View {
        if let services = appServices {
            TorrentStatsView()
                .environment(services.syncService)
        } else if hasQBittorrentServer {
            ContentUnavailableView {
                Label("Unable to Reach qBittorrent", systemImage: "network.slash")
            } description: {
                Text("Your qBittorrent server is currently unreachable. Check your connection or server status.")
            }
        } else {
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text("Connect a qBittorrent server to view transfer statistics.")
            }
        }
    }

    @ViewBuilder
    private var prowlarrIndexersDestination: some View {
        if arrServiceManager.hasAnyConnectedProwlarrInstance ||
            arrServiceManager.hasAnyConnectedSonarrInstance ||
            arrServiceManager.hasAnyConnectedRadarrInstance {
            ProwlarrIndexerListView()
                .environment(arrServiceManager)
        } else if arrServiceManager.hasProwlarrInstance || arrServiceManager.hasSonarrInstance || arrServiceManager.hasRadarrInstance {
            ContentUnavailableView {
                Label("No Connected Indexer Sources", systemImage: "network.slash")
            } description: {
                if let error = arrServiceManager.prowlarrConnectionError ?? arrServiceManager.sonarrConnectionError ?? arrServiceManager.radarrConnectionError {
                    Text(error)
                } else {
                    Text("Your configured Prowlarr, Sonarr, or Radarr services are currently unreachable.")
                }
            } actions: {
                Button("Retry Connection") {
                    Task {
                        async let prowlarrRetry: Void = arrServiceManager.retry(.prowlarr)
                        async let sonarrRetry: Void = arrServiceManager.retry(.sonarr)
                        async let radarrRetry: Void = arrServiceManager.retry(.radarr)
                        _ = await (prowlarrRetry, sonarrRetry, radarrRetry)
                    }
                }
                .buttonStyle(.bordered)
            }
        } else {
            ContentUnavailableView {
                Label("Indexers Not Set Up", systemImage: ServiceIdentity.prowlarr.tabSystemImage)
            } description: {
                Text("Add a Prowlarr, Sonarr, or Radarr server in Settings to manage your indexers.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
        }
    }

    @ViewBuilder
    private var settingsDestination: some View {
        let services = appServices ?? AppServices.disconnected()
        SettingsView(showsDoneButton: false)
            .environment(services.syncService)
            .environment(services.torrentService)
            .environment(arrServiceManager)
    }

    @ViewBuilder
    private var qbittorrentSettingsDestination: some View {
        if let services = appServices {
            QBittorrentSettingsView()
                .environment(services.syncService)
                .environment(services.torrentService)
        } else if hasQBittorrentServer {
            ContentUnavailableView {
                Label("Unable to Reach qBittorrent", systemImage: "network.slash")
            } description: {
                Text("Your qBittorrent server is currently unreachable. Check your connection or server status.")
            }
        } else {
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: ServiceIdentity.qbittorrent.tabSystemImage)
            } description: {
                Text("Add a qBittorrent server in Settings to manage your downloads.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
        }
    }

    @ViewBuilder
    private var qbittorrentCategoriesAndTagsDestination: some View {
        if let services = appServices {
            QBittorrentCategoriesAndTagsView()
                .environment(services.syncService)
                .environment(services.torrentService)
        } else if hasQBittorrentServer {
            ContentUnavailableView {
                Label("Unable to Reach qBittorrent", systemImage: "network.slash")
            } description: {
                Text("Your qBittorrent server is currently unreachable. Check your connection or server status.")
            }
        } else {
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: "tag")
            } description: {
                Text("Add a qBittorrent server in Settings before managing categories and tags.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
        }
    }

    @ViewBuilder
    private var qbittorrentRSSDestination: some View {
        if let services = appServices {
            QBittorrentRSSView()
                .environment(services.torrentService)
                .environment(services)
        } else if hasQBittorrentServer {
            ContentUnavailableView {
                Label("Unable to Reach qBittorrent", systemImage: "network.slash")
            } description: {
                Text("Your qBittorrent server is currently unreachable. Check your connection or server status.")
            }
        } else {
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text("Add a qBittorrent server before managing RSS feeds.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
        }
    }

    @ViewBuilder
    private var seerrAdminDestination: some View {
        if seerrServiceManager.isConnected {
            SeerrDashboardView()
        } else if seerrServiceManager.isConnecting {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to Seerr…")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Requests")
        } else if let seerrProfile {
            ContentUnavailableView {
                Label("Seerr Unreachable", systemImage: "network.slash")
            } description: {
                Text(seerrServiceManager.connectionError ?? "Unable to reach your configured Seerr server.")
            } actions: {
                Button("Retry Connection") {
                    Task {
                        await seerrServiceManager.connectService(seerrProfile)
                    }
                }
                .buttonStyle(.bordered)
            }
            .navigationTitle("Requests")
        } else {
            ContentUnavailableView {
                Label("Seerr Not Configured", systemImage: ServiceIdentity.seerr.tabSystemImage)
            } description: {
                Text("Add a Seerr server in Settings to manage requests.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
            .navigationTitle("Requests")
        }
    }

    @ViewBuilder
    private var unifiedUsersDestination: some View {
        if let jellyfinClient = jellyfinServiceManager.activeClient {
            UnifiedUserListView(
                jellyfinClient: jellyfinClient,
                seerrClient: seerrServiceManager.activeClient,
                seerrBaseURL: seerrServiceManager.activeClient?.baseURL
            )
            .environment(jellyfinServiceManager)
            .environment(seerrServiceManager)
            .environment(inAppNotificationCenter)
        } else {
            jellyfinUnavailableDestination
        }
    }

    @ViewBuilder
    private var jellyfinUnavailableDestination: some View {
        if jellyfinServiceManager.isConnecting {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting to Jellyfin…")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Jellyfin")
        } else if let jellyfinProfile {
            ContentUnavailableView {
                Label("Jellyfin Unreachable", systemImage: "network.slash")
            } description: {
                Text(jellyfinServiceManager.connectionError ?? "Unable to reach your configured Jellyfin server.")
            } actions: {
                Button("Retry Connection") {
                    Task {
                        await jellyfinServiceManager.connectService(jellyfinProfile)
                    }
                }
                .buttonStyle(.bordered)
            }
            .navigationTitle("Jellyfin")
        } else {
            ContentUnavailableView {
                Label("Jellyfin Not Configured", systemImage: "server.rack")
            } description: {
                Text("Add a Jellyfin server in Settings to manage your media server.")
            } actions: {
                Button("Open Settings") {
                    path = [.settings]
                }
            }
            .navigationTitle("Jellyfin")
        }
    }

    private func moreRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        NavigationMenuRow(icon: icon, color: color, title: title, subtitle: subtitle)
    }
}

private struct IntegrationsManagementView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.linkedApplicationsManagement) {
                    NavigationMenuRow(
                        icon: "app.connected.to.app.below.fill",
                        color: MoreDestinationAccent.integrations.color,
                        title: "Linked Applications",
                        subtitle: "Indexer sync, subtitle sync, and request routing"
                    )
                }

                NavigationLink(value: MoreDestination.downloadClientsManagement) {
                    NavigationMenuRow(
                        icon: ServiceIdentity.qbittorrent.systemImage,
                        color: ServiceIdentity.qbittorrent.brandColor,
                        title: "Download Clients",
                        subtitle: "Sonarr and Radarr download clients"
                    )
                }

                NavigationLink(value: MoreDestination.remotePathMappings) {
                    NavigationMenuRow(
                        icon: "arrow.triangle.swap",
                        color: .indigo,
                        title: "Remote Path Mappings",
                        subtitle: "Map download paths for imports"
                    )
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Integrations")
        .moreDestinationBackground(.integrations)
    }
}

private struct LinkedApplicationsManagementView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @State private var statusModel = LinkedApplicationsStatusViewModel()

    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.prowlarrLinkedApplications) {
                    IntegrationRelationshipRow(
                        source: .prowlarr,
                        targets: [.sonarr, .radarr],
                        title: "Indexer Sync",
                        subtitle: "Prowlarr linked applications",
                        status: statusModel.indexerStatus
                    )
                }

                NavigationLink(value: MoreDestination.bazarrLinkedApplications) {
                    IntegrationRelationshipRow(
                        source: .bazarr,
                        targets: [.sonarr, .radarr],
                        title: "Subtitle Sync",
                        subtitle: "Bazarr linked applications",
                        status: statusModel.subtitleStatus
                    )
                }

                NavigationLink(value: MoreDestination.seerrLinkedApplications) {
                    IntegrationRelationshipRow(
                        source: .seerr,
                        targets: [.sonarr, .radarr],
                        title: "Request Routing",
                        subtitle: "Seerr linked applications",
                        status: statusModel.requestRoutingStatus
                    )
                }
            } footer: {
                Text("Configure how services publish indexers, subtitles, and approved requests to Sonarr and Radarr.")
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Linked Applications")
        .moreDestinationBackground(.integrations)
        .refreshable {
            await statusModel.load(
                arrServiceManager: arrServiceManager,
                seerrServiceManager: seerrServiceManager,
                arrProfiles: arrProfiles,
                hasSeerrProfile: !seerrProfiles.isEmpty
            )
        }
        .task {
            await statusModel.load(
                arrServiceManager: arrServiceManager,
                seerrServiceManager: seerrServiceManager,
                arrProfiles: arrProfiles,
                hasSeerrProfile: !seerrProfiles.isEmpty
            )
        }
        .onAppear {
            Task {
                await statusModel.load(
                    arrServiceManager: arrServiceManager,
                    seerrServiceManager: seerrServiceManager,
                    arrProfiles: arrProfiles,
                    hasSeerrProfile: !seerrProfiles.isEmpty
                )
            }
        }
    }
}

private struct DownloadClientsManagementView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @State private var statusModel = DownloadClientsStatusViewModel()

    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.downloadClients(service: .sonarr)) {
                    IntegrationRelationshipRow(
                        source: .sonarr,
                        targets: [.qbittorrent],
                        title: "Sonarr Download Clients",
                        subtitle: "Clients used for series grabs",
                        status: statusModel.sonarrStatus
                    )
                }

                NavigationLink(value: MoreDestination.downloadClients(service: .radarr)) {
                    IntegrationRelationshipRow(
                        source: .radarr,
                        targets: [.qbittorrent],
                        title: "Radarr Download Clients",
                        subtitle: "Clients used for movie grabs",
                        status: statusModel.radarrStatus
                    )
                }
            } footer: {
                Text("Manage where Sonarr and Radarr send downloads.")
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Download Clients")
        .moreDestinationBackground(.integrations)
        .refreshable {
            await statusModel.load(arrServiceManager: arrServiceManager)
        }
        .task {
            await statusModel.load(arrServiceManager: arrServiceManager)
        }
        .onAppear {
            Task {
                await statusModel.load(arrServiceManager: arrServiceManager)
            }
        }
    }
}

@MainActor
@Observable
private final class DownloadClientsStatusViewModel {
    private(set) var sonarrStatus: IntegrationRelationshipStatus = .loading
    private(set) var radarrStatus: IntegrationRelationshipStatus = .loading

    private var isLoading = false

    func load(arrServiceManager: ArrServiceManager) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        sonarrStatus = await loadStatus(for: .sonarr, arrServiceManager: arrServiceManager)
        radarrStatus = await loadStatus(for: .radarr, arrServiceManager: arrServiceManager)
    }

    private func loadStatus(for serviceType: ArrServiceType, arrServiceManager: ArrServiceManager) async -> IntegrationRelationshipStatus {
        switch serviceType {
        case .sonarr:
            guard arrServiceManager.hasSonarrInstance else { return .notConfigured }
            guard arrServiceManager.sonarrConnected, let apiClient = arrServiceManager.sonarrClient else { return .error }
            return await loadStatus(client: apiClient)
        case .radarr:
            guard arrServiceManager.hasRadarrInstance else { return .notConfigured }
            guard arrServiceManager.radarrConnected, let apiClient = arrServiceManager.radarrClient else { return .error }
            return await loadStatus(client: apiClient)
        case .prowlarr, .bazarr:
            return .notConfigured
        }
    }

    private func loadStatus<Client: SharedArrClient>(client: Client) async -> IntegrationRelationshipStatus {
        do {
            let clients = try await client.getDownloadClients()
            guard !clients.isEmpty else { return .notConfigured }

            var states: [IntegrationTargetState] = []
            for downloadClient in clients {
                guard downloadClient.enable else {
                    states.append(.disabled)
                    continue
                }

                do {
                    try await client.testDownloadClient(downloadClient)
                    states.append(.connected)
                } catch {
                    states.append(.notConnected)
                }
            }

            return Self.aggregate(states)
        } catch {
            return .error
        }
    }

    private static func aggregate(_ states: [IntegrationTargetState]) -> IntegrationRelationshipStatus {
        guard !states.isEmpty else { return .notConfigured }

        let hasConnected = states.contains(.connected)
        let hasDisabled = states.contains(.disabled)
        let hasNotConnected = states.contains(.notConnected)

        if hasConnected && !hasDisabled && !hasNotConnected {
            return .connected
        }
        if hasDisabled && !hasConnected && !hasNotConnected {
            return .disabled
        }
        if hasConnected && hasDisabled && !hasNotConnected {
            return .partiallyEnabled
        }
        if hasConnected && hasNotConnected {
            return .partiallyConnected
        }
        if hasDisabled && hasNotConnected {
            return .partiallyDisabled
        }
        return .error
    }
}

@MainActor
@Observable
private final class LinkedApplicationsStatusViewModel {
    private(set) var indexerStatus: IntegrationRelationshipStatus = .loading
    private(set) var subtitleStatus: IntegrationRelationshipStatus = .loading
    private(set) var requestRoutingStatus: IntegrationRelationshipStatus = .loading

    private var isLoading = false

    func load(
        arrServiceManager: ArrServiceManager,
        seerrServiceManager: SeerrServiceManager,
        arrProfiles: [ArrServiceProfile],
        hasSeerrProfile: Bool
    ) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        indexerStatus = await loadIndexerStatus(arrServiceManager: arrServiceManager, arrProfiles: arrProfiles)
        subtitleStatus = await loadSubtitleStatus(arrServiceManager: arrServiceManager)
        requestRoutingStatus = await loadRequestRoutingStatus(seerrServiceManager: seerrServiceManager, hasSeerrProfile: hasSeerrProfile)
    }

    private func loadIndexerStatus(arrServiceManager: ArrServiceManager, arrProfiles: [ArrServiceProfile]) async -> IntegrationRelationshipStatus {
        guard arrServiceManager.hasProwlarrInstance else { return .notConfigured }
        guard arrServiceManager.prowlarrConnected, let client = arrServiceManager.prowlarrClient else { return .error }

        do {
            let applications = try await client.getApplications()
                .filter { $0.linkedAppType == .sonarr || $0.linkedAppType == .radarr }

            guard !applications.isEmpty else { return .notConfigured }

            var states: [IntegrationTargetState] = []
            for application in applications {
                if application.syncLevel == .disabled {
                    states.append(.disabled)
                } else {
                    states.append(Self.prowlarrTargetState(for: application, arrServiceManager: arrServiceManager, arrProfiles: arrProfiles))
                }
            }
            return Self.aggregate(states)
        } catch {
            return .error
        }
    }

    private static func prowlarrTargetState(
        for application: ProwlarrApplication,
        arrServiceManager: ArrServiceManager,
        arrProfiles: [ArrServiceProfile]
    ) -> IntegrationTargetState {
        guard let appType = application.linkedAppType,
              let baseURL = application.stringFieldValue(named: "baseUrl"),
              let matchedProfile = matchingProfile(for: baseURL, appType: appType, arrProfiles: arrProfiles) else {
            return .notConnected
        }

        switch appType {
        case .sonarr:
            return arrServiceManager.isConnected(.sonarr, profileID: matchedProfile.id) ? .connected : .notConnected
        case .radarr:
            return arrServiceManager.isConnected(.radarr, profileID: matchedProfile.id) ? .connected : .notConnected
        }
    }

    private static func matchingProfile(
        for linkedAppURL: String,
        appType: ProwlarrLinkedAppType,
        arrProfiles: [ArrServiceProfile]
    ) -> ArrServiceProfile? {
        let targetService: ArrServiceType = switch appType {
        case .sonarr: .sonarr
        case .radarr: .radarr
        }
        let normalizedLinkedURL = normalizedURL(linkedAppURL)

        return arrProfiles
            .filter { $0.resolvedServiceType == targetService && $0.isEnabled }
            .first { normalizedURL($0.hostURL) == normalizedLinkedURL }
    }

    private static func normalizedURL(_ string: String) -> String {
        guard var components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            ?? string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func loadSubtitleStatus(arrServiceManager: ArrServiceManager) async -> IntegrationRelationshipStatus {
        guard arrServiceManager.hasBazarrInstance else { return .notConfigured }
        guard arrServiceManager.hasAnyConnectedBazarrInstance, let client = arrServiceManager.activeBazarrEntry?.client else { return .error }

        do {
            let settings = try await client.getSettings()
            let states = BazarrLinkedApplicationType.allCases.compactMap { appType -> IntegrationTargetState? in
                let isConfigured = settings.bazarrLinkedAppBaseURL(appType) != nil || settings.bazarrLinkedAppIsEnabled(appType)
                guard isConfigured else { return nil }

                guard settings.bazarrLinkedAppIsEnabled(appType) else {
                    return .disabled
                }

                switch appType {
                case .sonarr:
                    return arrServiceManager.sonarrConnected ? .connected : .notConnected
                case .radarr:
                    return arrServiceManager.radarrConnected ? .connected : .notConnected
                }
            }

            return Self.aggregate(states)
        } catch {
            return .error
        }
    }

    private func loadRequestRoutingStatus(
        seerrServiceManager: SeerrServiceManager,
        hasSeerrProfile: Bool
    ) async -> IntegrationRelationshipStatus {
        guard hasSeerrProfile else { return .notConfigured }
        guard seerrServiceManager.isConnected, let client = seerrServiceManager.activeClient else { return .error }

        do {
            let sonarrSettings = try await client.getDVRSettings(.sonarr).map {
                SeerrLinkedAppEntry(kind: .sonarr, settings: $0)
            }
            let radarrSettings = try await client.getDVRSettings(.radarr).map {
                SeerrLinkedAppEntry(kind: .radarr, settings: $0)
            }
            let entries = sonarrSettings + radarrSettings

            guard !entries.isEmpty else { return .notConfigured }

            var states: [IntegrationTargetState] = []
            for entry in entries {
                if entry.settings.syncEnabled == false {
                    states.append(.disabled)
                } else {
                    do {
                        _ = try await client.testDVRConnection(
                            entry.kind,
                            body: SeerrDVRTestBody(
                                hostname: entry.settings.hostname,
                                port: entry.settings.port,
                                apiKey: entry.settings.apiKey,
                                useSsl: entry.settings.useSsl ?? false,
                                baseUrl: entry.settings.baseUrl
                            )
                        )
                        states.append(.connected)
                    } catch {
                        states.append(.notConnected)
                    }
                }
            }

            return Self.aggregate(states)
        } catch {
            return .error
        }
    }

    private static func aggregate(_ states: [IntegrationTargetState]) -> IntegrationRelationshipStatus {
        guard !states.isEmpty else { return .notConfigured }

        let hasConnected = states.contains(.connected)
        let hasDisabled = states.contains(.disabled)
        let hasNotConnected = states.contains(.notConnected)

        if hasConnected && !hasDisabled && !hasNotConnected {
            return .connected
        }
        if hasDisabled && !hasConnected && !hasNotConnected {
            return .disabled
        }
        if hasConnected && hasDisabled && !hasNotConnected {
            return .partiallyEnabled
        }
        if hasConnected && hasNotConnected {
            return .partiallyConnected
        }
        if hasDisabled && hasNotConnected {
            return .partiallyDisabled
        }
        return .error
    }
}

private enum IntegrationTargetState {
    case connected
    case disabled
    case notConnected
}

private enum IntegrationRelationshipStatus {
    case connected
    case disabled
    case partiallyEnabled
    case partiallyConnected
    case partiallyDisabled
    case error
    case loading
    case warning(String)
    case notConfigured

    var label: String {
        switch self {
        case .connected: "Connected"
        case .disabled: "Disabled"
        case .partiallyEnabled: "Partially Enabled"
        case .partiallyConnected: "Partially Connected"
        case .partiallyDisabled: "Partially Disabled"
        case .error: "Error"
        case .loading: "Checking"
        case .warning(let value): value
        case .notConfigured: "Not configured"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .disabled: .secondary
        case .partiallyEnabled: .orange
        case .partiallyConnected: .orange
        case .partiallyDisabled: .orange
        case .error: .red
        case .loading: .secondary
        case .warning: .orange
        case .notConfigured: .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .disabled: "pause.circle"
        case .partiallyEnabled: "circle.lefthalf.filled"
        case .partiallyConnected: "exclamationmark.circle.fill"
        case .partiallyDisabled: "pause.circle.fill"
        case .error: "xmark.octagon.fill"
        case .loading: "clock"
        case .warning: "exclamationmark.circle.fill"
        case .notConfigured: "circle"
        }
    }
}

private struct IntegrationRelationshipRow: View {
    let source: ServiceIdentity
    let targets: [ServiceIdentity]
    let title: String
    let subtitle: String
    let status: IntegrationRelationshipStatus

    var body: some View {
        HStack(spacing: 12) {
            serviceFlow
                .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: status.systemImage)
                    Text(status.label)
                }
                .font(.caption2)
                .foregroundStyle(status.color)
            }
        }
        .padding(.vertical, 3)
    }

    private var serviceFlow: some View {
        HStack(spacing: 5) {
            serviceIcon(source)

            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: -6) {
                ForEach(targets, id: \.self) { target in
                    serviceIcon(target)
                        .background(Circle().fill(.background))
                }
            }
        }
    }

    private func serviceIcon(_ service: ServiceIdentity) -> some View {
        Image(systemName: service.systemImage)
            .font(.subheadline)
            .foregroundStyle(service.brandColor)
            .frame(width: 24, height: 24)
            .accessibilityLabel(service.displayName)
    }
}

private struct SubtitleManagementView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.bazarrLanguageProfiles) {
                    NavigationMenuRow(
                        icon: "globe",
                        color: MoreDestinationAccent.languageProfiles.color,
                        title: "Language Profiles",
                        subtitle: "Preferred languages and cutoff rules"
                    )
                }

                NavigationLink(value: MoreDestination.bazarrProviders) {
                    NavigationMenuRow(
                        icon: "person.2.fill",
                        color: MoreDestinationAccent.providers.color,
                        title: "Providers",
                        subtitle: "Configure subtitle provider integrations"
                    )
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Subtitles")
        .moreDestinationBackground(.subtitleManagement)
    }
}

private struct TorrentManagementView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.transferStats) {
                    NavigationMenuRow(
                        icon: "chart.line.uptrend.xyaxis",
                        color: MoreDestinationAccent.transferStats.color,
                        title: "Transfer Stats",
                        subtitle: "Speed, session totals, and network info"
                    )
                }

                NavigationLink(value: MoreDestination.categoriesAndTags) {
                    NavigationMenuRow(
                        icon: "tag.fill",
                        color: MoreDestinationAccent.categoriesAndTags.color,
                        title: "Categories & Tags",
                        subtitle: "Manage torrent organization labels"
                    )
                }

                NavigationLink(value: MoreDestination.rssFeeds) {
                    NavigationMenuRow(
                        icon: "dot.radiowaves.left.and.right",
                        color: .cyan,
                        title: "RSS Feeds",
                        subtitle: "Feeds and automatic download rules"
                    )
                }

                NavigationLink(value: MoreDestination.qbittorrentSettings) {
                    NavigationMenuRow(
                        icon: "gearshape.fill",
                        color: ServiceIdentity.qbittorrent.brandColor,
                        title: "qBittorrent Settings",
                        subtitle: "Server, speed limits, and save location"
                    )
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Torrents")
        .moreDestinationBackground(.torrentManagement)
    }
}

private struct RequestManagementView: View {
    let seerrProfile: SeerrServiceProfile?

    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.seerrAdmin) {
                    NavigationMenuRow(
                        icon: ServiceIdentity.seerr.systemImage,
                        color: MoreDestinationAccent.requestManagement.color,
                        title: "Requests",
                        subtitle: seerrProfile == nil ? "Not configured" : "Manage Seerr requests"
                    )
                }

                NavigationLink(value: MoreDestination.seerrIssues) {
                    NavigationMenuRow(
                        icon: "exclamationmark.bubble.fill",
                        color: .orange,
                        title: "Issues",
                        subtitle: "Review and respond to user issues"
                    )
                }

                NavigationLink(value: MoreDestination.seerrLogs) {
                    NavigationMenuRow(
                        icon: "doc.text.magnifyingglass",
                        color: ServiceIdentity.seerr.brandColor,
                        title: "Seerr Logs",
                        subtitle: "Live Seerr server logs"
                    )
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Requests")
        .moreDestinationBackground(.requestManagement)
    }
}

private struct JellyfinManagementView: View {
    let jellyfinProfile: JellyfinServiceProfile?

    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.jellyfinSessions) {
                    NavigationMenuRow(
                        icon: "play.rectangle.fill",
                        color: .green,
                        title: "Sessions",
                        subtitle: "Active playback sessions"
                    )
                }

                NavigationLink(value: MoreDestination.jellyfinLibraries) {
                    NavigationMenuRow(
                        icon: "folder.fill",
                        color: .orange,
                        title: "Libraries",
                        subtitle: "Browse and scan media libraries"
                    )
                }

                NavigationLink(value: MoreDestination.jellyfinScheduledTasks) {
                    NavigationMenuRow(
                        icon: "clock.arrow.2.circlepath",
                        color: .teal,
                        title: "Scheduled Tasks",
                        subtitle: "View and trigger Jellyfin background tasks"
                    )
                }

                NavigationLink(value: MoreDestination.jellyfinActivityLog) {
                    NavigationMenuRow(
                        icon: "list.bullet.rectangle.fill",
                        color: ServiceIdentity.jellyfin.brandColor,
                        title: "Activity Log",
                        subtitle: "Jellyfin server activity history"
                    )
                }

                NavigationLink(value: MoreDestination.jellyfinPlugins) {
                    NavigationMenuRow(
                        icon: "shippingbox.fill",
                        color: .purple,
                        title: "Plugins",
                        subtitle: "Installed Jellyfin plugins"
                    )
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Jellyfin")
        .moreDestinationBackground(.jellyfin)
    }
}

struct MoreDestinationGradientBackground: View {
    let accent: MoreDestinationAccent

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [accent.color.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [accent.color.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    @ViewBuilder
    func moreDestinationTitleStyle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func moreDestinationBackground(_ accent: MoreDestinationAccent) -> some View {
        background(MoreDestinationGradientBackground(accent: accent))
    }

    @ViewBuilder
    func injectSyncService(_ appServices: AppServices?) -> some View {
        if let syncService = appServices?.syncService {
            self.environment(syncService)
        } else {
            self
        }
    }
}


private struct RecentNotificationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var showClearConfirmation = false
    @State private var unreadSinceDate: Date = .distantPast

    private var notificationCount: Int { inAppNotificationCenter.recentNotifications.count }

    var body: some View {
        AppSheetShell(
            title: "Notifications",
            subtitle: notificationCount > 0 ? "\(notificationCount) notification\(notificationCount == 1 ? "" : "s")" : nil,
            confirmTitle: notificationCount > 0 ? "Clear" : nil,
            onConfirm: notificationCount > 0 ? { showClearConfirmation = true } : nil,
            detents: [.medium, .large]
        ) {
            Group {
                if inAppNotificationCenter.recentNotifications.isEmpty {
                    ContentUnavailableView {
                        Label("No Notifications Yet", systemImage: "bell.slash")
                    } description: {
                        Text("Recent in-app and system notifications will appear here.")
                    } actions: {
                        Button("Open Notification Settings") {
                            #if os(iOS)
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                            #endif
                        }
                    }
                } else {
                    List(inAppNotificationCenter.recentNotifications) { entry in
                        notificationRow(for: entry)
                    }
                }
            }
            .alert("Clear Notifications?", isPresented: $showClearConfirmation) {
                Button("Clear", role: .destructive) {
                    inAppNotificationCenter.clearRecentNotifications()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("All recent notifications will be removed.")
            }
        }
        .onAppear {
            unreadSinceDate = inAppNotificationCenter.lastReadDate
            inAppNotificationCenter.markAllRead()
        }
    }

    private func icon(for entry: NotificationLogEntry) -> String {
        let blob = "\(entry.title) \(entry.message)".lowercased()
        let tokens = Set(blob.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) })

        if tokens.contains("health") || tokens.contains("warning") || tokens.contains("alert") {
            return "heart.text.square.fill"
        }
        if tokens.contains("issue") {
            return "exclamationmark.bubble.fill"
        }
        if tokens.contains("user") {
            return "person.crop.circle.badge.exclamationmark"
        }
        if tokens.contains("download") || tokens.contains("import") {
            return "arrow.down.circle.fill"
        }

        switch entry.style {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .progress: return "arrow.triangle.2.circlepath"
        }
    }

    private func color(for style: InAppBannerStyle) -> Color {
        switch style {
        case .success: .green
        case .error: .red
        case .progress: .blue
        }
    }

    private func serviceContext(for entry: NotificationLogEntry) -> NotificationServiceContext {
        let blob = "\(entry.title) \(entry.message)".lowercased()
        let tokens = Set(blob.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { String($0) })

        if tokens.contains("sonarr") { return .sonarr }
        if tokens.contains("radarr") { return .radarr }
        if tokens.contains("prowlarr") { return .prowlarr }
        if tokens.contains("bazarr") { return .bazarr }
        if tokens.contains("seerr") || tokens.contains("overseerr") || tokens.contains("jellyseerr") { return .seerr }
        if tokens.contains("qbittorrent") || tokens.contains("qbit") || tokens.contains("torrent") { return .qbittorrent }
        return .trawl
    }

    private enum NotificationServiceContext {
        case qbittorrent
        case sonarr
        case radarr
        case prowlarr
        case bazarr
        case seerr
        case trawl

        var title: String {
            switch self {
            case .qbittorrent: "qBittorrent"
            case .sonarr: "Sonarr"
            case .radarr: "Radarr"
            case .prowlarr: "Prowlarr"
            case .bazarr: "Bazarr"
            case .seerr: "Seerr"
            case .trawl: "Trawl"
            }
        }

        var systemImage: String {
            switch self {
            case .qbittorrent: ServiceIdentity.qbittorrent.systemImage
            case .sonarr: ServiceIdentity.sonarr.systemImage
            case .radarr: ServiceIdentity.radarr.systemImage
            case .prowlarr: ServiceIdentity.prowlarr.systemImage
            case .bazarr: ServiceIdentity.bazarr.systemImage
            case .seerr: ServiceIdentity.seerr.systemImage
            case .trawl: "app.badge"
            }
        }
    }

    private static let longMessageThreshold = 140

    private func isLongMessage(_ message: String) -> Bool {
        message.count > Self.longMessageThreshold || message.contains("\n")
    }

    @ViewBuilder
    private func notificationRow(for entry: NotificationLogEntry) -> some View {
        let long = isLongMessage(entry.message)
        Group {
            if long {
                NavigationLink {
                    NotificationDetailView(
                        entry: entry,
                        icon: icon(for: entry),
                        tint: color(for: entry.style)
                    )
                } label: {
                    notificationRowBody(entry: entry, truncate: true)
                }
            } else {
                notificationRowBody(entry: entry, truncate: false)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                inAppNotificationCenter.removeNotification(id: entry.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func notificationRowBody(entry: NotificationLogEntry, truncate: Bool) -> some View {
        let service = serviceContext(for: entry)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.timestamp > unreadSinceDate ? Color.accentColor : Color.clear)
                    .frame(width: 7, height: 7)
                HStack(spacing: 4) {
                    Image(systemName: icon(for: entry))
                        .foregroundStyle(color(for: entry.style))
                    Text(entry.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Text(service.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !entry.message.isEmpty {
                Text(entry.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 15)
                    .lineLimit(truncate ? 2 : nil)
            }
            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 15)
        }
        .padding(.vertical, 2)
    }
}

private struct NotificationDetailView: View {
    let entry: NotificationLogEntry
    let icon: String
    let tint: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Label(entry.source.rawValue, systemImage: "tray.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Divider()

                if entry.message.isEmpty {
                    Text("No additional details.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.message)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .navigationTitle("Notification")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct CalendarSeriesDestination: View {
    let id: Int
    let appServices: AppServices?
    @State private var viewModel: SonarrViewModel

    init(id: Int, appServices: AppServices?, arrServiceManager: ArrServiceManager) {
        self.id = id
        self.appServices = appServices
        self._viewModel = State(wrappedValue: SonarrViewModel(
            serviceManager: arrServiceManager,
            preloadedSeries: arrServiceManager.calendarViewModel?.sonarrSeries ?? []
        ))
    }

    var body: some View {
        SonarrSeriesDetailView(seriesId: id, viewModel: viewModel)
            .injectSyncService(appServices)
    }
}

private struct CalendarMovieDestination: View {
    let id: Int
    let appServices: AppServices?
    @State private var viewModel: RadarrViewModel

    init(id: Int, appServices: AppServices?, arrServiceManager: ArrServiceManager) {
        self.id = id
        self.appServices = appServices
        self._viewModel = State(wrappedValue: RadarrViewModel(
            serviceManager: arrServiceManager,
            preloadedMovies: arrServiceManager.calendarViewModel?.radarrMovies ?? []
        ))
    }

    var body: some View {
        RadarrMovieDetailView(movieId: id, viewModel: viewModel)
            .injectSyncService(appServices)
    }
}

private struct BazarrSeriesDestination: View {
    let seriesId: Int
    @State private var viewModel: BazarrViewModel

    init(seriesId: Int, arrServiceManager: ArrServiceManager) {
        self.seriesId = seriesId
        self._viewModel = State(wrappedValue: BazarrViewModel(serviceManager: arrServiceManager))
    }

    var body: some View {
        BazarrSeriesDetailView(seriesId: seriesId, viewModel: viewModel)
    }
}

private struct BazarrMovieDestination: View {
    let radarrId: Int
    @State private var viewModel: BazarrViewModel

    init(radarrId: Int, arrServiceManager: ArrServiceManager) {
        self.radarrId = radarrId
        self._viewModel = State(wrappedValue: BazarrViewModel(serviceManager: arrServiceManager))
    }

    var body: some View {
        BazarrMovieDetailView(radarrId: radarrId, viewModel: viewModel)
    }
}
