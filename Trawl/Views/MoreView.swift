import SwiftUI
import SwiftData

enum MoreDestination: Hashable {
    case activity
    case activityQueue
    case activityHistory
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
    case arrNaming
    case rootFolders
    case qualityProfiles
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
    case logsAndEvents
    case arrEvents
    case qbittorrentLog
    case tasksHub
    case arrTasks
    case seerrJobs
    case updatesHub
    case backupsHub
    case qualityDefinitions
}

enum MoreDestinationAccent {
    case settings
    case activity
    case calendar
    case manualImport
    case categoriesAndTags
    case rssFeeds
    case transferStats
    case torrentManagement
    case integrations
    case downloadClients
    case remotePathMappings
    case mediaManagement
    case diskSpace
    case subtitleManagement
    case sonarrNaming
    case radarrNaming
    case rootFolders
    case qualityProfiles
    case qualityDefinitions
    case languageProfiles
    case providers
    case userManagement
    case requestManagement
    case seerr
    case jellyfin
    case logsAndEvents
    case tasks
    case updates
    case backups

    var color: Color {
        switch self {
        case .settings: return .secondary
        case .activity: return .indigo
        case .calendar: return .purple
        case .manualImport: return .blue
        case .categoriesAndTags: return .brown
        case .rssFeeds: return .cyan
        case .transferStats: return .mint
        case .torrentManagement: return .mint
        case .integrations: return .blue
        case .downloadClients: return ServiceIdentity.qbittorrent.brandColor
        case .remotePathMappings: return .indigo
        case .mediaManagement: return .green
        case .diskSpace: return .teal
        case .subtitleManagement: return .teal
        case .sonarrNaming: return .purple
        case .radarrNaming: return .orange
        case .rootFolders: return .indigo
        case .qualityProfiles: return .cyan
        case .qualityDefinitions: return .mint
        case .languageProfiles: return .cyan
        case .providers: return .teal
        case .userManagement: return .blue
        case .requestManagement: return ServiceIdentity.seerr.brandColor
        case .seerr: return ServiceIdentity.seerr.brandColor
        case .jellyfin: return ServiceIdentity.jellyfin.brandColor
        case .logsAndEvents: return .brown
        case .tasks: return .teal
        case .updates: return .green
        case .backups: return .indigo
        }
    }
}

struct MoreView: View {
    @Query private var servers: [ServerProfile]
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]
    let appServices: AppServices?
    @Binding var path: [MoreDestination]
    let isQBittorrentConnecting: Bool
    let onRetryQBittorrent: (() -> Void)?
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var subtitleBadgeCount = 0
    @State private var moreSearchText = ""
    @State private var connectionEditSheet: ConnectionEditSheet?

    private var hasQBittorrentServer: Bool { !servers.isEmpty }

    private var configuredServiceIdentities: [ServiceIdentity] {
        var identities: [ServiceIdentity] = []
        if hasQBittorrentServer { identities.append(.qbittorrent) }
        if arrServiceManager.hasSonarrInstance { identities.append(.sonarr) }
        if arrServiceManager.hasRadarrInstance { identities.append(.radarr) }
        if arrServiceManager.hasProwlarrInstance { identities.append(.prowlarr) }
        if arrServiceManager.hasBazarrInstance { identities.append(.bazarr) }
        if !seerrProfiles.isEmpty { identities.append(.seerr) }
        if !jellyfinProfiles.isEmpty { identities.append(.jellyfin) }
        return identities
    }

    private var seerrProfile: SeerrServiceProfile? {
        seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
    }

    private var jellyfinProfile: JellyfinServiceProfile? {
        jellyfinProfiles.first(where: { $0.isEnabled }) ?? jellyfinProfiles.first
    }

    private var trimmedMoreSearchText: String {
        moreSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isShowingMoreSearchResults: Bool {
        !trimmedMoreSearchText.isEmpty
    }

    private var filteredMoreSearchEntries: [MoreSearchIndexEntry] {
        MoreSearchIndex.results(for: trimmedMoreSearchText)
    }

    private struct ConnectionIssue: Identifiable {
        let identity: ServiceIdentity
        let isConnecting: Bool
        let message: String
        var id: ServiceIdentity { identity }
    }

    private enum ConnectionEditSheet: Identifiable, Hashable {
        case qbittorrent
        case arr(ArrServiceType)
        case seerr
        case jellyfin

        var id: String {
            switch self {
            case .qbittorrent:
                "qbittorrent"
            case .arr(let service):
                "arr-\(service.rawValue)"
            case .seerr:
                "seerr"
            case .jellyfin:
                "jellyfin"
            }
        }
    }

    private var connectionIssues: [ConnectionIssue] {
        guard !isShowingMoreSearchResults else { return [] }
        var issues: [ConnectionIssue] = []

        if hasQBittorrentServer && (isQBittorrentConnecting || appServices == nil) {
            issues.append(ConnectionIssue(
                identity: .qbittorrent,
                isConnecting: isQBittorrentConnecting,
                message: isQBittorrentConnecting
                    ? "Checking your configured qBittorrent server."
                    : "Unable to reach your configured qBittorrent server."
            ))
        }
        if arrServiceManager.hasSonarrInstance && !arrServiceManager.sonarrConnected
            && (arrServiceManager.sonarrIsConnecting || arrServiceManager.isInitializing || arrServiceManager.sonarrConnectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .sonarr,
                isConnecting: arrServiceManager.sonarrIsConnecting || arrServiceManager.isInitializing,
                message: arrServiceManager.sonarrConnectionError ?? "Checking your configured Sonarr server."
            ))
        }
        if arrServiceManager.hasRadarrInstance && !arrServiceManager.radarrConnected
            && (arrServiceManager.radarrIsConnecting || arrServiceManager.isInitializing || arrServiceManager.radarrConnectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .radarr,
                isConnecting: arrServiceManager.radarrIsConnecting || arrServiceManager.isInitializing,
                message: arrServiceManager.radarrConnectionError ?? "Checking your configured Radarr server."
            ))
        }
        if arrServiceManager.hasProwlarrInstance && !arrServiceManager.prowlarrConnected
            && (arrServiceManager.prowlarrIsConnecting || arrServiceManager.isInitializing || arrServiceManager.prowlarrConnectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .prowlarr,
                isConnecting: arrServiceManager.prowlarrIsConnecting || arrServiceManager.isInitializing,
                message: arrServiceManager.prowlarrConnectionError ?? "Checking your configured Prowlarr server."
            ))
        }
        if arrServiceManager.hasBazarrInstance && !arrServiceManager.hasAnyConnectedBazarrInstance
            && (arrServiceManager.isConnecting(.bazarr) || arrServiceManager.isInitializing || arrServiceManager.bazarrConnectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .bazarr,
                isConnecting: arrServiceManager.isConnecting(.bazarr) || arrServiceManager.isInitializing,
                message: arrServiceManager.bazarrConnectionError ?? "Checking your configured Bazarr server."
            ))
        }
        if !seerrProfiles.isEmpty && !seerrServiceManager.isConnected
            && (seerrServiceManager.isConnecting || seerrServiceManager.connectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .seerr,
                isConnecting: seerrServiceManager.isConnecting,
                message: seerrServiceManager.connectionError ?? "Checking your configured Seerr server."
            ))
        }
        if !jellyfinProfiles.isEmpty && !jellyfinServiceManager.isConnected
            && (jellyfinServiceManager.isConnecting || jellyfinServiceManager.connectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .jellyfin,
                isConnecting: jellyfinServiceManager.isConnecting,
                message: jellyfinServiceManager.connectionError ?? "Checking your configured Jellyfin server."
            ))
        }

        return issues
    }

    private var connectionIssuesAnimationKey: String {
        connectionIssues
            .map { "\($0.identity.rawValue):\($0.isConnecting):\($0.message)" }
            .joined(separator: "|")
    }

    private func retryAllConnections() {
        if hasQBittorrentServer && appServices == nil {
            onRetryQBittorrent?()
        }
        if !seerrServiceManager.isConnected && !seerrServiceManager.isConnecting {
            Task { await seerrServiceManager.initialize(from: seerrProfiles) }
        }
        if !jellyfinServiceManager.isConnected && !jellyfinServiceManager.isConnecting {
            Task { await jellyfinServiceManager.initialize(from: jellyfinProfiles) }
        }
        Task { await arrServiceManager.retryDisconnected() }
    }

    private func retryConnection(for identity: ServiceIdentity) {
        switch identity {
        case .qbittorrent:
            onRetryQBittorrent?()
        case .sonarr:
            Task { await arrServiceManager.retry(.sonarr) }
        case .radarr:
            Task { await arrServiceManager.retry(.radarr) }
        case .prowlarr:
            Task { await arrServiceManager.retry(.prowlarr) }
        case .bazarr:
            Task { await arrServiceManager.retry(.bazarr) }
        case .seerr:
            Task { await seerrServiceManager.initialize(from: seerrProfiles) }
        case .jellyfin:
            Task { await jellyfinServiceManager.initialize(from: jellyfinProfiles) }
        }
    }

    private func presentConnectionEditor(for identity: ServiceIdentity) {
        let sheet: ConnectionEditSheet
        switch identity {
        case .qbittorrent:
            sheet = .qbittorrent
        case .sonarr:
            sheet = .arr(.sonarr)
        case .radarr:
            sheet = .arr(.radarr)
        case .prowlarr:
            sheet = .arr(.prowlarr)
        case .bazarr:
            sheet = .arr(.bazarr)
        case .seerr:
            sheet = .seerr
        case .jellyfin:
            sheet = .jellyfin
        }

        withAnimation(.snappy) {
            connectionEditSheet = sheet
        }
    }

    private func dismissConnectionEditor() {
        withAnimation(.snappy) {
            connectionEditSheet = nil
        }
    }

    private var connectionEditorIsPresented: Binding<Bool> {
        Binding(
            get: { connectionEditSheet != nil },
            set: { isPresented in
                if !isPresented {
                    dismissConnectionEditor()
                }
            }
        )
    }

    @ViewBuilder
    private var connectivityAlertSection: some View {
        let issues = connectionIssues
        if !issues.isEmpty {
            Section {
                ForEach(issues) { issue in
                    ConnectionIssueRow(
                        identity: issue.identity,
                        title: issue.isConnecting ? "Connecting to \(issue.identity.displayName)" : "\(issue.identity.displayName) Unreachable",
                        message: issue.message,
                        isConnecting: issue.isConnecting,
                        actionStyle: .glassIcons,
                        onRetry: { retryConnection(for: issue.identity) },
                        onEdit: { presentConnectionEditor(for: issue.identity) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Button {
                    withAnimation(.snappy) {
                        retryAllConnections()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry Connections")
                    }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .font(.subheadline.weight(.medium))
                }
            } header: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Connection Issues")
                }
                    .foregroundStyle(.orange)
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
            }
            .animation(.snappy, value: connectionIssuesAnimationKey)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if isShowingMoreSearchResults {
                    moreSearchResultsContent
                } else {
                    connectivityAlertSection
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
                                    title: "Blocked & Excluded", subtitle: "Blocked releases and import-list exclusions")
                        }
                    }

                    Section {
                        NavigationLink(value: MoreDestination.mediaManagement) {
                            moreRow(icon: "folder.badge.gearshape", color: MoreDestinationAccent.mediaManagement.color,
                                    title: "Media & Import", subtitle: "Root folders, naming, quality, disk space, and import")
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
                                    title: "Torrents", subtitle: "Transfer stats, categories, and RSS feeds")
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
                                subtitle: seerrProfile == nil ? "Not configured" : "Requests and issues"
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
                                subtitle: jellyfinProfile == nil ? "Not configured" : "Sessions, libraries, and plugins"
                            )
                        }
                    }

                    Section {
                        NavigationLink(value: MoreDestination.logsAndEvents) {
                            moreRow(icon: "text.document.fill", color: .brown,
                                    title: "Logs", subtitle: "Server logs and activity across all services")
                        }

                        NavigationLink(value: MoreDestination.tasksHub) {
                            moreRow(icon: "clock.arrow.2.circlepath", color: .teal,
                                    title: "Tasks", subtitle: "Scheduled tasks across connected services")
                        }

                        NavigationLink(value: MoreDestination.updatesHub) {
                            moreRow(icon: "arrow.down.app.fill", color: .green,
                                    title: "Updates", subtitle: "Software updates for connected services")
                        }

                        NavigationLink(value: MoreDestination.backupsHub) {
                            moreRow(icon: "externaldrive.fill", color: .indigo,
                                    title: "Backups", subtitle: "System backups for Sonarr, Radarr, Prowlarr and Bazarr")
                        }
                    }

                    Section {
                        NavigationLink(value: MoreDestination.settings) {
                            moreRow(icon: "gearshape.fill", color: .secondary,
                                    title: "Settings", subtitle: "App and server configuration")
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .scrollContentBackground(.hidden)
            .background(MoreServicesGradientBackground(services: configuredServiceIdentities))
            .navigationTitle("More")
            .searchable(text: $moreSearchText, placement: .automatic, prompt: "Search settings and features")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inlineLarge)
            #endif
            .sheet(item: $connectionEditSheet) { sheet in
                connectionEditSheetView(for: sheet)
            }
            .navigationDestination(for: MoreDestination.self) { destination in
                switch destination {
                case .activity:
                    ArrActivityHubView()
                        .moreDestinationTitleStyle()
                case .activityQueue:
                    ArrActivityQueueView()
                        .moreDestinationTitleStyle()
                case .activityHistory:
                    ArrHistoryView()
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
                case .logsAndEvents:
                    LogsAndEventsHubView(hasQBittorrentLog: appServices != nil)
                        .moreDestinationTitleStyle()
                case .arrEvents:
                    ArrEventsView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .qbittorrentLog:
                    qbittorrentLogDestination
                        .moreDestinationTitleStyle()
                case .tasksHub:
                    TasksHubView(jellyfinProfile: jellyfinProfile)
                        .moreDestinationTitleStyle()
                case .arrTasks:
                    ArrScheduledTasksView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .seerrJobs:
                    if let client = seerrServiceManager.activeClient {
                        SeerrJobsView(apiClient: client)
                            .moreDestinationTitleStyle()
                    } else {
                        seerrAdminDestination
                            .moreDestinationTitleStyle()
                    }
                case .updatesHub:
                    ArrUpdatesView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .backupsHub:
                    ArrBackupsView()
                        .environment(arrServiceManager)
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
                case .arrNaming:
                    ArrNamingConfigView()
                        .environment(arrServiceManager)
                        .environment(InAppNotificationCenter.shared)
                        .moreDestinationTitleStyle()
                case .rootFolders:
                    ArrRootFoldersView()
                        .environment(arrServiceManager)
                        .environment(inAppNotificationCenter)
                        .moreDestinationTitleStyle()
                case .qualityProfiles:
                    ArrQualityProfilesListView()
                        .environment(arrServiceManager)
                        .environment(inAppNotificationCenter)
                        .moreDestinationTitleStyle()
                case .qualityDefinitions:
                    ArrQualityDefinitionsView()
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
    private var moreSearchResultsContent: some View {
        if filteredMoreSearchEntries.isEmpty {
            Section {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No settings or features match \"\(trimmedMoreSearchText)\".")
                )
                .frame(maxWidth: .infinity)
            }
        } else {
            Section("Search Results") {
                ForEach(filteredMoreSearchEntries) { entry in
                    NavigationLink(value: entry.destination) {
                        MoreSearchResultRow(entry: entry)
                    }
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
            ArrServiceConnectionStatusView(
                serviceType: .prowlarr,
                title: arrServiceManager.prowlarrIsConnecting || arrServiceManager.isInitializing ? "Connecting to Prowlarr" : "Prowlarr Unreachable",
                message: arrServiceManager.prowlarrConnectionError ?? "Unable to reach your configured Prowlarr server."
            )
            .navigationTitle("Linked Apps")
            .navigationSubtitle("Prowlarr")
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
            .navigationTitle("Linked Apps")
            .navigationSubtitle("Prowlarr")
        }
    }

    @ViewBuilder
    private var bazarrLinkedApplicationsDestination: some View {
        if arrServiceManager.hasAnyConnectedBazarrInstance {
            BazarrLinkedApplicationsListView()
                .environment(arrServiceManager)
        } else if arrServiceManager.hasBazarrInstance {
            ArrServiceConnectionStatusView(
                serviceType: .bazarr,
                title: arrServiceManager.isConnecting(.bazarr) || arrServiceManager.isInitializing ? "Connecting to Bazarr" : "Bazarr Unreachable",
                message: arrServiceManager.bazarrConnectionError ?? "Unable to reach your configured Bazarr server."
            )
            .navigationTitle("Linked Apps")
            .navigationSubtitle("Bazarr")
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
            .navigationTitle("Linked Apps")
            .navigationSubtitle("Bazarr")
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
            qbittorrentConnectionStatusView
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
            ArrServicesConnectionStatusView(
                services: indexerSourceServices,
                title: "No Connected Indexer Sources",
                message: arrServiceManager.prowlarrConnectionError
                    ?? arrServiceManager.sonarrConnectionError
                    ?? arrServiceManager.radarrConnectionError
                    ?? "Your configured Prowlarr, Sonarr, or Radarr services are currently unreachable."
            )
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
        SettingsView(showsDoneButton: false)
            .environment(syncService)
            .environment(torrentService)
            .environment(arrServiceManager)
    }

    @ViewBuilder
    private func connectionEditSheetView(for sheet: ConnectionEditSheet) -> some View {
        switch sheet {
        case .qbittorrent:
            NavigationStack {
                QBittorrentSettingsView()
                    .environment(syncService)
                    .environment(torrentService)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: dismissConnectionEditor)
                        }
                    }
            }

        case .arr(let service):
            ArrServiceSettingsSheet(serviceType: service, isPresented: connectionEditorIsPresented)
                .environment(arrServiceManager)

        case .seerr:
            NavigationStack {
                SeerrSettingsView()
                    .environment(seerrServiceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: dismissConnectionEditor)
                        }
                    }
            }

        case .jellyfin:
            NavigationStack {
                JellyfinSettingsView()
                    .environment(jellyfinServiceManager)
                    .environment(inAppNotificationCenter)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: dismissConnectionEditor)
                        }
                    }
            }
        }
    }

    private var indexerSourceServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if arrServiceManager.hasProwlarrInstance { services.append(.prowlarr) }
        if arrServiceManager.hasSonarrInstance { services.append(.sonarr) }
        if arrServiceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var qbittorrentConnectionStatusView: some View {
        ConnectionStatusCard(
            identity: .qbittorrent,
            title: isQBittorrentConnecting ? "Connecting to qBittorrent" : "qBittorrent Unreachable",
            message: isQBittorrentConnecting
                ? "Checking your configured qBittorrent server."
                : "Your qBittorrent server is currently unreachable. Check your connection or server status.",
            isConnecting: isQBittorrentConnecting,
            onRetry: { onRetryQBittorrent?() },
            onEdit: { presentConnectionEditor(for: .qbittorrent) }
        )
    }

    @ViewBuilder
    private var qbittorrentSettingsDestination: some View {
        if appServices != nil || hasQBittorrentServer {
            QBittorrentSettingsView()
                .environment(syncService)
                .environment(torrentService)
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
            qbittorrentConnectionStatusView
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
    private var qbittorrentLogDestination: some View {
        if let services = appServices {
            QBittorrentLogView()
                .environment(services.torrentService)
        } else if hasQBittorrentServer {
            qbittorrentConnectionStatusView
        } else {
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: "doc.text")
            } description: {
                Text("Add a qBittorrent server in Settings to view server logs.")
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
            qbittorrentConnectionStatusView
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
        } else if let seerrProfile {
            ConnectionStatusCard(
                identity: .seerr,
                title: seerrServiceManager.isConnecting ? "Connecting to Seerr" : "Seerr Unreachable",
                message: seerrServiceManager.connectionError ?? "Unable to reach your configured Seerr server.",
                isConnecting: seerrServiceManager.isConnecting,
                detailTitle: seerrProfile.displayName,
                detailSubtitle: seerrProfile.hostURL,
                onRetry: {
                    Task { await seerrServiceManager.connectService(seerrProfile) }
                },
                onEdit: { presentConnectionEditor(for: .seerr) }
            )
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
        if let jellyfinProfile {
            ConnectionStatusCard(
                identity: .jellyfin,
                title: jellyfinServiceManager.isConnecting ? "Connecting to Jellyfin" : "Jellyfin Unreachable",
                message: jellyfinServiceManager.connectionError ?? "Unable to reach your configured Jellyfin server.",
                isConnecting: jellyfinServiceManager.isConnecting,
                detailTitle: jellyfinProfile.displayName,
                detailSubtitle: jellyfinProfile.hostURL,
                onRetry: {
                    Task { await jellyfinServiceManager.connectService(jellyfinProfile) }
                },
                onEdit: { presentConnectionEditor(for: .jellyfin) }
            )
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

#if DEBUG
@MainActor
private enum MorePreviewFixtures {
    static func appServices() -> AppServices {
        AppServices.disconnected()
    }

    static func notificationCenter() -> InAppNotificationCenter {
        InAppNotificationCenter(
            previewNotifications: notificationEntries,
            lastReadDate: Date().addingTimeInterval(-3_600)
        )
    }

    static var notificationEntries: [NotificationLogEntry] {
        [
            NotificationLogEntry(
                title: "Sonarr Health Warning",
                message: "Indexer sync completed, but one indexer reported a stale certificate.",
                style: .error,
                source: .system,
                timestamp: Date().addingTimeInterval(-240)
            ),
            NotificationLogEntry(
                title: "Download Complete",
                message: "Dune Part Two imported successfully through qBittorrent and Radarr.",
                style: .success,
                source: .inApp,
                timestamp: Date().addingTimeInterval(-1_800)
            ),
            NotificationLogEntry(
                title: "Jellyfin User Import",
                message: "Three Jellyfin users are ready to import into Seerr.",
                style: .progress,
                source: .inApp,
                timestamp: Date().addingTimeInterval(-7_200)
            ),
        ]
    }
}

private struct MorePreviewHost<Content: View>: View {
    let profiles: PreviewSupport.ProfileScenario
    let arr: ArrServiceManager
    let jellyfin: JellyfinServiceManager
    let seerr: SeerrServiceManager
    let appServices: AppServices?
    let content: (AppServices?) -> Content

    init(
        profiles: PreviewSupport.ProfileScenario = .allServices,
        arr: ArrServiceManager = .preview(),
        jellyfin: JellyfinServiceManager = .preview(),
        seerr: SeerrServiceManager = .preview(),
        appServices: AppServices? = MorePreviewFixtures.appServices(),
        @ViewBuilder content: @escaping (AppServices?) -> Content
    ) {
        self.profiles = profiles
        self.arr = arr
        self.jellyfin = jellyfin
        self.seerr = seerr
        self.appServices = appServices
        self.content = content
    }

    var body: some View {
        PreviewHost(
            profiles: profiles,
            arr: arr,
            jellyfin: jellyfin,
            seerr: seerr,
            appServices: appServices,
            notificationCenter: MorePreviewFixtures.notificationCenter()
        ) {
            content(appServices)
        }
    }
}

#Preview("More - All Services") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { appServices in
        MoreView(
            appServices: appServices,
            path: .constant([]),
            isQBittorrentConnecting: false,
            onRetryQBittorrent: nil
        )
    }
}

#Preview("More - Sonarr Only") {
    MorePreviewHost(
        profiles: .arrOnly,
        arr: .preview(.sonarrOnly),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { appServices in
        MoreView(
            appServices: appServices,
            path: .constant([]),
            isQBittorrentConnecting: false,
            onRetryQBittorrent: nil
        )
    }
}

#Preview("More - Connection Issue") {
    MorePreviewHost(
        profiles: .arrOnly,
        arr: .preview(.sonarrConnectionError("Could not reach the Sonarr preview host.")),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { appServices in
        MoreView(
            appServices: appServices,
            path: .constant([]),
            isQBittorrentConnecting: false,
            onRetryQBittorrent: nil
        )
    }
}

#Preview("More - Empty") {
    MorePreviewHost(
        profiles: .empty,
        arr: .preview(.noneConfigured),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { appServices in
        MoreView(
            appServices: appServices,
            path: .constant([]),
            isQBittorrentConnecting: false,
            onRetryQBittorrent: nil
        )
    }
}
#endif

private struct MoreSearchResultRow: View {
    let entry: MoreSearchIndexEntry

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(entry.color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: entry.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(entry.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(entry.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(entry.category)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct MoreSearchIndexEntry: Identifiable {
    let id: String
    let destination: MoreDestination
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let category: String
    let keywords: [String]

    init(
        id: String,
        destination: MoreDestination,
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        category: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.destination = destination
        self.icon = icon
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.keywords = keywords
    }

    func matches(_ query: String) -> Bool {
        let tokens = Self.searchTokens(in: query)
        guard !tokens.isEmpty else { return false }

        let indexedText = Self.normalized(([title, subtitle, category] + keywords).joined(separator: " "))
        return tokens.allSatisfy { indexedText.contains($0) }
    }

    private static func searchTokens(in text: String) -> [String] {
        normalized(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let characters = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }

        return String(characters)
    }
}

private enum MoreSearchIndex {
    static func results(for query: String) -> [MoreSearchIndexEntry] {
        entries.filter { $0.matches(query) }
    }

    private static var entries: [MoreSearchIndexEntry] {
        [
            .init(
                id: "activity",
                destination: .activity,
                icon: "arrow.down.doc.fill",
                color: .indigo,
                title: "Activity",
                subtitle: "Queue, downloads, and import history",
                category: "Monitoring",
                keywords: ["queue", "download", "import", "history", "grab", "release"]
            ),
            .init(
                id: "wanted",
                destination: .wanted,
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Wanted / Missing",
                subtitle: "Missing files and subtitles",
                category: "Monitoring",
                keywords: ["missing", "wanted", "episodes", "movies", "subtitles"]
            ),
            .init(
                id: "calendar",
                destination: .calendar,
                icon: "calendar",
                color: MoreDestinationAccent.calendar.color,
                title: "Calendar",
                subtitle: "Upcoming releases and air dates",
                category: "Monitoring",
                keywords: ["schedule", "air date", "release date", "episodes", "movies"]
            ),
            .init(
                id: "health",
                destination: .health,
                icon: "heart.text.square.fill",
                color: .pink,
                title: "Health",
                subtitle: "Service health checks",
                category: "Monitoring",
                keywords: ["status", "warnings", "errors", "checks"]
            ),
            .init(
                id: "blocklist",
                destination: .blocklist,
                icon: "nosign",
                color: .red,
                title: "Blocked & Excluded",
                subtitle: "Blocked releases and import-list exclusions",
                category: "Monitoring",
                keywords: ["blocked", "blacklist", "failed", "grabbed", "release", "exclusion", "import list"]
            ),
            .init(
                id: "media-management",
                destination: .mediaManagement,
                icon: "folder.badge.gearshape",
                color: MoreDestinationAccent.mediaManagement.color,
                title: "Media & Import",
                subtitle: "Root folders, naming, quality, disk space, and import",
                category: "Media Management",
                keywords: ["storage", "files", "paths", "profiles", "definitions"]
            ),
            .init(
                id: "root-folders",
                destination: .rootFolders,
                icon: "folder.fill",
                color: MoreDestinationAccent.rootFolders.color,
                title: "Root Folders",
                subtitle: "Library paths across Sonarr and Radarr",
                category: "Media & Import",
                keywords: ["paths", "storage", "library", "folder", "sonarr", "radarr"]
            ),
            .init(
                id: "manual-import",
                destination: .manualImport,
                icon: "tray.and.arrow.down.fill",
                color: MoreDestinationAccent.manualImport.color,
                title: "Manual Import",
                subtitle: "Browse and import files from root folders",
                category: "Media & Import",
                keywords: ["files", "scan", "import", "download", "folder"]
            ),
            .init(
                id: "disk-space",
                destination: .diskSpace,
                icon: "internaldrive.fill",
                color: MoreDestinationAccent.diskSpace.color,
                title: "Disk Space",
                subtitle: "Storage usage across Sonarr and Radarr",
                category: "Media & Import",
                keywords: ["drive", "storage", "free space", "usage", "sonarr", "radarr"]
            ),
            .init(
                id: "naming",
                destination: .arrNaming,
                icon: "character.cursor.ibeam",
                color: MoreDestinationAccent.sonarrNaming.color,
                title: "Naming",
                subtitle: "Episode, series, and movie file name formats",
                category: "Media & Import",
                keywords: ["filename", "format", "movies", "episodes", "sonarr", "radarr"]
            ),
            .init(
                id: "quality-profiles",
                destination: .qualityProfiles,
                icon: "slider.horizontal.3",
                color: MoreDestinationAccent.qualityProfiles.color,
                title: "Quality Profiles",
                subtitle: "Allowed qualities and upgrade rules",
                category: "Media & Import",
                keywords: ["profiles", "quality", "upgrade", "cutoff", "sonarr", "radarr"]
            ),
            .init(
                id: "quality-definitions",
                destination: .qualityDefinitions,
                icon: "chart.bar.fill",
                color: MoreDestinationAccent.qualityDefinitions.color,
                title: "Quality Definitions",
                subtitle: "File size limits per quality level",
                category: "Media & Import",
                keywords: ["definitions", "quality", "size", "limits", "megabytes"]
            ),
            .init(
                id: "subtitles",
                destination: .subtitleManagement,
                icon: "captions.bubble.fill",
                color: MoreDestinationAccent.subtitleManagement.color,
                title: "Subtitles",
                subtitle: "Language profiles and subtitle providers",
                category: "Subtitles",
                keywords: ["bazarr", "captions", "languages", "providers", "missing"]
            ),
            .init(
                id: "language-profiles",
                destination: .bazarrLanguageProfiles,
                icon: "globe",
                color: MoreDestinationAccent.languageProfiles.color,
                title: "Language Profiles",
                subtitle: "Preferred languages and cutoff rules",
                category: "Subtitles",
                keywords: ["bazarr", "languages", "cutoff", "profiles", "subtitles"]
            ),
            .init(
                id: "subtitle-providers",
                destination: .bazarrProviders,
                icon: "person.2.fill",
                color: MoreDestinationAccent.providers.color,
                title: "Providers",
                subtitle: "Configure subtitle provider integrations",
                category: "Subtitles",
                keywords: ["bazarr", "provider", "subtitles", "integration", "settings"]
            ),
            .init(
                id: "indexers",
                destination: .prowlarrIndexers,
                icon: "magnifyingglass.circle.fill",
                color: .yellow,
                title: "Indexers",
                subtitle: "Manage indexers across your services",
                category: "Indexers",
                keywords: ["prowlarr", "trackers", "search", "sources", "sonarr", "radarr"]
            ),
            .init(
                id: "torrents",
                destination: .torrentManagement,
                icon: "arrow.down.circle.fill",
                color: MoreDestinationAccent.torrentManagement.color,
                title: "Torrents",
                subtitle: "Transfer stats, categories, and RSS feeds",
                category: "Torrents",
                keywords: ["qbittorrent", "downloads", "rss", "speed"]
            ),
            .init(
                id: "transfer-stats",
                destination: .transferStats,
                icon: "chart.line.uptrend.xyaxis",
                color: MoreDestinationAccent.transferStats.color,
                title: "Transfer Stats",
                subtitle: "Speed, session totals, and network info",
                category: "Torrents",
                keywords: ["qbittorrent", "speed", "upload", "download", "session", "network"]
            ),
            .init(
                id: "categories-tags",
                destination: .categoriesAndTags,
                icon: "tag.fill",
                color: MoreDestinationAccent.categoriesAndTags.color,
                title: "Categories & Tags",
                subtitle: "Manage torrent organization labels",
                category: "Torrents",
                keywords: ["qbittorrent", "category", "tag", "labels", "organization"]
            ),
            .init(
                id: "rss-feeds",
                destination: .rssFeeds,
                icon: "dot.radiowaves.left.and.right",
                color: .cyan,
                title: "RSS Feeds",
                subtitle: "Feeds and automatic download rules",
                category: "Torrents",
                keywords: ["qbittorrent", "rss", "feeds", "automatic", "rules"]
            ),
            .init(
                id: "integrations",
                destination: .integrations,
                icon: "app.connected.to.app.below.fill",
                color: MoreDestinationAccent.integrations.color,
                title: "Integrations",
                subtitle: "Linked apps, download clients, and remote path mappings",
                category: "Integrations",
                keywords: ["links", "applications", "clients", "paths", "routing"]
            ),
            .init(
                id: "linked-applications",
                destination: .linkedApplicationsManagement,
                icon: "app.connected.to.app.below.fill",
                color: MoreDestinationAccent.integrations.color,
                title: "Linked Applications",
                subtitle: "Indexer sync, subtitle sync, and request routing",
                category: "Integrations",
                keywords: ["prowlarr", "bazarr", "seerr", "sync", "routing"]
            ),
            .init(
                id: "indexer-sync",
                destination: .prowlarrLinkedApplications,
                icon: ServiceIdentity.prowlarr.systemImage,
                color: ServiceIdentity.prowlarr.brandColor,
                title: "Indexer Sync",
                subtitle: "Prowlarr linked applications",
                category: "Integrations",
                keywords: ["prowlarr", "sonarr", "radarr", "linked apps", "sync"]
            ),
            .init(
                id: "subtitle-sync",
                destination: .bazarrLinkedApplications,
                icon: ServiceIdentity.bazarr.systemImage,
                color: ServiceIdentity.bazarr.brandColor,
                title: "Subtitle Sync",
                subtitle: "Bazarr linked applications",
                category: "Integrations",
                keywords: ["bazarr", "sonarr", "radarr", "linked apps", "sync"]
            ),
            .init(
                id: "request-routing",
                destination: .seerrLinkedApplications,
                icon: ServiceIdentity.seerr.systemImage,
                color: ServiceIdentity.seerr.brandColor,
                title: "Request Routing",
                subtitle: "Seerr linked applications",
                category: "Integrations",
                keywords: ["seerr", "sonarr", "radarr", "linked apps", "routing"]
            ),
            .init(
                id: "download-clients",
                destination: .downloadClientsManagement,
                icon: ServiceIdentity.qbittorrent.systemImage,
                color: ServiceIdentity.qbittorrent.brandColor,
                title: "Download Clients",
                subtitle: "Sonarr and Radarr download clients",
                category: "Integrations",
                keywords: ["qbittorrent", "client", "download", "sonarr", "radarr"]
            ),
            .init(
                id: "sonarr-download-clients",
                destination: .downloadClients(service: .sonarr),
                icon: ServiceIdentity.sonarr.systemImage,
                color: ServiceIdentity.sonarr.brandColor,
                title: "Sonarr Download Clients",
                subtitle: "Clients used for series grabs",
                category: "Integrations",
                keywords: ["sonarr", "download", "clients", "qbittorrent", "series"]
            ),
            .init(
                id: "radarr-download-clients",
                destination: .downloadClients(service: .radarr),
                icon: ServiceIdentity.radarr.systemImage,
                color: ServiceIdentity.radarr.brandColor,
                title: "Radarr Download Clients",
                subtitle: "Clients used for movie grabs",
                category: "Integrations",
                keywords: ["radarr", "download", "clients", "qbittorrent", "movies"]
            ),
            .init(
                id: "remote-path-mappings",
                destination: .remotePathMappings,
                icon: "arrow.triangle.swap",
                color: MoreDestinationAccent.remotePathMappings.color,
                title: "Remote Path Mappings",
                subtitle: "Map download paths for imports",
                category: "Integrations",
                keywords: ["paths", "mapping", "remote", "local", "downloads", "import"]
            ),
            .init(
                id: "requests-hub",
                destination: .requestManagement,
                icon: ServiceIdentity.seerr.systemImage,
                color: MoreDestinationAccent.requestManagement.color,
                title: "Requests",
                subtitle: "Requests and issues",
                category: "Requests",
                keywords: ["seerr", "overseerr", "jellyseerr", "issues", "approval"]
            ),
            .init(
                id: "requests",
                destination: .seerrAdmin,
                icon: ServiceIdentity.seerr.systemImage,
                color: MoreDestinationAccent.requestManagement.color,
                title: "Requests",
                subtitle: "Manage Seerr requests",
                category: "Requests",
                keywords: ["seerr", "overseerr", "jellyseerr", "approval", "discover"]
            ),
            .init(
                id: "issues",
                destination: .seerrIssues,
                icon: "exclamationmark.bubble.fill",
                color: .orange,
                title: "Issues",
                subtitle: "Review and respond to user issues",
                category: "Requests",
                keywords: ["seerr", "problems", "reports", "support"]
            ),
            .init(
                id: "users",
                destination: .unifiedUsers,
                icon: "person.2.fill",
                color: MoreDestinationAccent.userManagement.color,
                title: "Users",
                subtitle: "Jellyfin and Seerr accounts",
                category: "Users",
                keywords: ["accounts", "permissions", "jellyfin", "seerr", "members"]
            ),
            .init(
                id: "jellyfin",
                destination: .jellyfinManagement,
                icon: "server.rack",
                color: MoreDestinationAccent.jellyfin.color,
                title: "Jellyfin",
                subtitle: "Sessions, libraries, and plugins",
                category: "Jellyfin",
                keywords: ["media server", "users", "activity", "tasks"]
            ),
            .init(
                id: "jellyfin-sessions",
                destination: .jellyfinSessions,
                icon: "play.rectangle.fill",
                color: .green,
                title: "Sessions",
                subtitle: "Active playback sessions",
                category: "Jellyfin",
                keywords: ["playback", "streaming", "active", "users"]
            ),
            .init(
                id: "jellyfin-libraries",
                destination: .jellyfinLibraries,
                icon: "folder.fill",
                color: .orange,
                title: "Libraries",
                subtitle: "Browse and scan media libraries",
                category: "Jellyfin",
                keywords: ["library", "scan", "media", "folders", "collections"]
            ),
            .init(
                id: "jellyfin-activity",
                destination: .jellyfinActivityLog,
                icon: "person.crop.rectangle.stack.fill",
                color: ServiceIdentity.jellyfin.brandColor,
                title: "Jellyfin Activity",
                subtitle: "Jellyfin server activity history",
                category: "Logs",
                keywords: ["logs", "history", "activity", "jellyfin", "users"]
            ),
            .init(
                id: "jellyfin-tasks",
                destination: .jellyfinScheduledTasks,
                icon: "clock.arrow.2.circlepath",
                color: ServiceIdentity.jellyfin.brandColor,
                title: "Jellyfin Tasks",
                subtitle: "View and trigger Jellyfin background tasks",
                category: "Tasks",
                keywords: ["scheduled", "jobs", "background", "trigger", "jellyfin"]
            ),
            .init(
                id: "jellyfin-plugins",
                destination: .jellyfinPlugins,
                icon: "shippingbox.fill",
                color: .purple,
                title: "Plugins",
                subtitle: "Installed Jellyfin plugins",
                category: "Jellyfin",
                keywords: ["addons", "extensions", "jellyfin", "installed"]
            ),
            .init(
                id: "logs",
                destination: .logsAndEvents,
                icon: "text.document.fill",
                color: .brown,
                title: "Logs",
                subtitle: "Server logs and activity across all services",
                category: "Operations",
                keywords: ["events", "activity", "history", "server"]
            ),
            .init(
                id: "qbittorrent-log",
                destination: .qbittorrentLog,
                icon: "doc.text.fill",
                color: ServiceIdentity.qbittorrent.brandColor,
                title: "qBittorrent Log",
                subtitle: "Application events and warnings from qBittorrent",
                category: "Logs",
                keywords: ["qbittorrent", "log", "events", "warnings", "errors"]
            ),
            .init(
                id: "arr-events",
                destination: .arrEvents,
                icon: "list.bullet.rectangle.fill",
                color: MoreDestinationAccent.logsAndEvents.color,
                title: "Arr Events",
                subtitle: "Sonarr, Radarr, Prowlarr, and Bazarr server logs",
                category: "Logs",
                keywords: ["events", "logs", "sonarr", "radarr", "prowlarr", "bazarr"]
            ),
            .init(
                id: "seerr-logs",
                destination: .seerrLogs,
                icon: "doc.text.magnifyingglass",
                color: ServiceIdentity.seerr.brandColor,
                title: "Seerr Logs",
                subtitle: "Live Seerr server logs",
                category: "Logs",
                keywords: ["overseerr", "jellyseerr", "server", "events"]
            ),
            .init(
                id: "tasks",
                destination: .tasksHub,
                icon: "clock.arrow.2.circlepath",
                color: .teal,
                title: "Tasks",
                subtitle: "Scheduled tasks across connected services",
                category: "Operations",
                keywords: ["jobs", "scheduled", "background", "maintenance"]
            ),
            .init(
                id: "arr-tasks",
                destination: .arrTasks,
                icon: "clock.arrow.2.circlepath",
                color: MoreDestinationAccent.tasks.color,
                title: "Arr Tasks",
                subtitle: "Sonarr, Radarr, Prowlarr, and Bazarr tasks",
                category: "Tasks",
                keywords: ["scheduled", "jobs", "sonarr", "radarr", "prowlarr", "bazarr"]
            ),
            .init(
                id: "seerr-jobs",
                destination: .seerrJobs,
                icon: "clock.arrow.2.circlepath",
                color: ServiceIdentity.seerr.brandColor,
                title: "Seerr Jobs",
                subtitle: "Scheduled jobs and background tasks",
                category: "Tasks",
                keywords: ["seerr", "overseerr", "jellyseerr", "jobs", "scheduled"]
            ),
            .init(
                id: "updates",
                destination: .updatesHub,
                icon: "arrow.down.app.fill",
                color: .green,
                title: "Updates",
                subtitle: "Software updates for connected services",
                category: "Operations",
                keywords: ["update", "version", "software", "sonarr", "radarr", "prowlarr", "bazarr"]
            ),
            .init(
                id: "backups",
                destination: .backupsHub,
                icon: "externaldrive.fill",
                color: .indigo,
                title: "Backups",
                subtitle: "System backups for Sonarr, Radarr, Prowlarr and Bazarr",
                category: "Operations",
                keywords: ["backup", "restore", "system", "sonarr", "radarr", "prowlarr", "bazarr"]
            ),
            .init(
                id: "settings",
                destination: .settings,
                icon: "gearshape.fill",
                color: .secondary,
                title: "Settings",
                subtitle: "App and server configuration",
                category: "Settings",
                keywords: ["app", "server", "configuration", "connections", "services"]
            ),
            .init(
                id: "sonarr-settings",
                destination: .sonarrSettings,
                icon: ServiceIdentity.sonarr.systemImage,
                color: ServiceIdentity.sonarr.brandColor,
                title: "Sonarr Settings",
                subtitle: "Series server connection and API key",
                category: "Settings",
                keywords: ["sonarr", "server", "api", "connection", "series"]
            ),
            .init(
                id: "radarr-settings",
                destination: .radarrSettings,
                icon: ServiceIdentity.radarr.systemImage,
                color: ServiceIdentity.radarr.brandColor,
                title: "Radarr Settings",
                subtitle: "Movie server connection and API key",
                category: "Settings",
                keywords: ["radarr", "server", "api", "connection", "movies"]
            ),
            .init(
                id: "prowlarr-settings",
                destination: .prowlarrSettings,
                icon: ServiceIdentity.prowlarr.systemImage,
                color: ServiceIdentity.prowlarr.brandColor,
                title: "Prowlarr Settings",
                subtitle: "Indexer server connection and API key",
                category: "Settings",
                keywords: ["prowlarr", "server", "api", "connection", "indexers"]
            ),
            .init(
                id: "bazarr-settings",
                destination: .bazarrSettings,
                icon: ServiceIdentity.bazarr.systemImage,
                color: ServiceIdentity.bazarr.brandColor,
                title: "Bazarr Settings",
                subtitle: "Subtitle server connection and API key",
                category: "Settings",
                keywords: ["bazarr", "server", "api", "connection", "subtitles"]
            ),
            .init(
                id: "seerr-settings",
                destination: .seerrSettings,
                icon: ServiceIdentity.seerr.systemImage,
                color: ServiceIdentity.seerr.brandColor,
                title: "Seerr Settings",
                subtitle: "Request server connection and API key",
                category: "Settings",
                keywords: ["seerr", "overseerr", "jellyseerr", "server", "api", "requests"]
            ),
            .init(
                id: "jellyfin-settings",
                destination: .jellyfinSettings,
                icon: ServiceIdentity.jellyfin.systemImage,
                color: ServiceIdentity.jellyfin.brandColor,
                title: "Jellyfin Settings",
                subtitle: "Media server connection and API key",
                category: "Settings",
                keywords: ["jellyfin", "server", "api", "connection", "users"]
            )
        ]
    }
}

private struct IntegrationsManagementView: View {
    var body: some View {
        List {
            Section("Service Links") {
                NavigationLink(value: MoreDestination.linkedApplicationsManagement) {
                    NavigationMenuRow(
                        icon: "app.connected.to.app.below.fill",
                        color: MoreDestinationAccent.integrations.color,
                        title: "Linked Applications",
                        subtitle: "Indexer sync, subtitle sync, and request routing"
                    )
                }
            }

            Section("Download Plumbing") {
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
                        color: MoreDestinationAccent.remotePathMappings.color,
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

#if DEBUG
#Preview("Integrations Hub") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            IntegrationsManagementView()
        }
    }
}
#endif

private struct LinkedApplicationsManagementView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @State private var statusModel = LinkedApplicationsStatusViewModel()
    #if DEBUG
    private var skipsStatusRefresh = false
    #endif

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
            #if DEBUG
            guard !skipsStatusRefresh else { return }
            #endif
            await statusModel.load(
                arrServiceManager: arrServiceManager,
                seerrServiceManager: seerrServiceManager,
                arrProfiles: arrProfiles,
                hasSeerrProfile: !seerrProfiles.isEmpty
            )
        }
        .onAppear {
            #if DEBUG
            guard !skipsStatusRefresh else { return }
            #endif
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

#if DEBUG
extension LinkedApplicationsManagementView {
    init(previewStatusModel: LinkedApplicationsStatusViewModel) {
        self._statusModel = State(initialValue: previewStatusModel)
        self.skipsStatusRefresh = true
    }
}

#Preview("Linked Applications - Mixed") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            LinkedApplicationsManagementView(
                previewStatusModel: LinkedApplicationsStatusViewModel(
                    indexerStatus: .connected,
                    subtitleStatus: .partiallyConnected,
                    requestRoutingStatus: .connected
                )
            )
        }
    }
}

#Preview("Linked Applications - Not Configured") {
    MorePreviewHost(
        profiles: .empty,
        arr: .preview(.noneConfigured),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { _ in
        NavigationStack {
            LinkedApplicationsManagementView(
                previewStatusModel: LinkedApplicationsStatusViewModel(
                    indexerStatus: .notConfigured,
                    subtitleStatus: .notConfigured,
                    requestRoutingStatus: .notConfigured
                )
            )
        }
    }
}
#endif

private struct DownloadClientsManagementView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @State private var statusModel = DownloadClientsStatusViewModel()
    #if DEBUG
    private var skipsStatusRefresh = false
    #endif

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
            #if DEBUG
            guard !skipsStatusRefresh else { return }
            #endif
            await statusModel.load(arrServiceManager: arrServiceManager)
        }
        .onAppear {
            #if DEBUG
            guard !skipsStatusRefresh else { return }
            #endif
            Task {
                await statusModel.load(arrServiceManager: arrServiceManager)
            }
        }
    }
}

#if DEBUG
extension DownloadClientsManagementView {
    init(previewStatusModel: DownloadClientsStatusViewModel) {
        self._statusModel = State(initialValue: previewStatusModel)
        self.skipsStatusRefresh = true
    }
}

#Preview("Download Clients Hub - Connected") {
    MorePreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            DownloadClientsManagementView(
                previewStatusModel: DownloadClientsStatusViewModel(
                    sonarrStatus: .connected,
                    radarrStatus: .partiallyEnabled
                )
            )
        }
    }
}

#Preview("Download Clients Hub - Empty") {
    MorePreviewHost(
        profiles: .empty,
        arr: .preview(.noneConfigured),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { _ in
        NavigationStack {
            DownloadClientsManagementView(
                previewStatusModel: DownloadClientsStatusViewModel(
                    sonarrStatus: .notConfigured,
                    radarrStatus: .notConfigured
                )
            )
        }
    }
}
#endif

@MainActor
@Observable
private final class DownloadClientsStatusViewModel {
    private(set) var sonarrStatus: IntegrationRelationshipStatus = .loading
    private(set) var radarrStatus: IntegrationRelationshipStatus = .loading

    private var isLoading = false

    init() {}

    #if DEBUG
    init(
        sonarrStatus: IntegrationRelationshipStatus,
        radarrStatus: IntegrationRelationshipStatus
    ) {
        self.sonarrStatus = sonarrStatus
        self.radarrStatus = radarrStatus
    }
    #endif

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

    init() {}

    #if DEBUG
    init(
        indexerStatus: IntegrationRelationshipStatus,
        subtitleStatus: IntegrationRelationshipStatus,
        requestRoutingStatus: IntegrationRelationshipStatus
    ) {
        self.indexerStatus = indexerStatus
        self.subtitleStatus = subtitleStatus
        self.requestRoutingStatus = requestRoutingStatus
    }
    #endif

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

            HStack(spacing: 5) {
                ForEach(targets, id: \.self) { target in
                    serviceIcon(target)
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

#if DEBUG
#Preview("Subtitles Hub") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            SubtitleManagementView()
        }
    }
}
#endif

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
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Torrents")
        .moreDestinationBackground(.torrentManagement)
    }
}

#if DEBUG
#Preview("Torrent Management Hub") {
    MorePreviewHost(profiles: .qBittorrentOnly) { _ in
        NavigationStack {
            TorrentManagementView()
        }
    }
}
#endif

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

            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Requests")
        .moreDestinationBackground(.requestManagement)
    }
}

#if DEBUG
#Preview("Requests Hub - Configured") {
    MorePreviewHost(profiles: .seerrOnly) { _ in
        NavigationStack {
            RequestManagementView(seerrProfile: .preview())
        }
    }
}

#Preview("Requests Hub - Empty") {
    MorePreviewHost(profiles: .empty, seerr: .preview(.notConfigured), appServices: nil) { _ in
        NavigationStack {
            RequestManagementView(seerrProfile: nil)
        }
    }
}
#endif

private struct LogsAndEventsHubView: View {
    let hasQBittorrentLog: Bool
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager

    private var hasArrEvents: Bool {
        arrServiceManager.hasSonarrInstance ||
            arrServiceManager.hasRadarrInstance ||
            arrServiceManager.hasProwlarrInstance ||
            arrServiceManager.hasBazarrInstance
    }

    private var hasAnyLogDestination: Bool {
        hasQBittorrentLog || hasArrEvents || seerrServiceManager.activeClient != nil || jellyfinServiceManager.activeClient != nil
    }

    var body: some View {
        List {
            if hasAnyLogDestination {
                Section {
                    if hasQBittorrentLog {
                        NavigationLink(value: MoreDestination.qbittorrentLog) {
                            NavigationMenuRow(
                                icon: "doc.text.fill",
                                color: ServiceIdentity.qbittorrent.brandColor,
                                title: "qBittorrent Log",
                                subtitle: "Application events and warnings"
                            )
                        }
                    }

                    if hasArrEvents {
                        NavigationLink(value: MoreDestination.arrEvents) {
                            NavigationMenuRow(
                                icon: "list.bullet.rectangle.fill",
                                color: MoreDestinationAccent.logsAndEvents.color,
                                title: "Arr Events",
                                subtitle: "Sonarr, Radarr, Prowlarr, and Bazarr server logs"
                            )
                        }
                    }

                    if seerrServiceManager.activeClient != nil {
                        NavigationLink(value: MoreDestination.seerrLogs) {
                            NavigationMenuRow(
                                icon: "doc.text.magnifyingglass",
                                color: ServiceIdentity.seerr.brandColor,
                                title: "Seerr Logs",
                                subtitle: "Live Seerr server logs"
                            )
                        }
                    }

                    if jellyfinServiceManager.activeClient != nil {
                        NavigationLink(value: MoreDestination.jellyfinActivityLog) {
                            NavigationMenuRow(
                                icon: "person.crop.rectangle.stack.fill",
                                color: ServiceIdentity.jellyfin.brandColor,
                                title: "Jellyfin Activity",
                                subtitle: "Jellyfin server activity history"
                            )
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Logs")
        .moreDestinationBackground(.logsAndEvents)
    }
}

#if DEBUG
#Preview("Logs Hub - All Services") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            LogsAndEventsHubView(hasQBittorrentLog: true)
        }
    }
}

#Preview("Logs Hub - Empty") {
    MorePreviewHost(
        profiles: .empty,
        arr: .preview(.noneConfigured),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { _ in
        NavigationStack {
            LogsAndEventsHubView(hasQBittorrentLog: false)
        }
    }
}
#endif

private struct ArrActivityHubView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager

    private var hasAnyActivitySource: Bool {
        arrServiceManager.hasSonarrInstance ||
            arrServiceManager.hasRadarrInstance ||
            arrServiceManager.hasProwlarrInstance ||
            arrServiceManager.hasBazarrInstance
    }

    private var hasQueueCapableService: Bool {
        arrServiceManager.hasSonarrInstance ||
            arrServiceManager.hasRadarrInstance ||
            arrServiceManager.hasBazarrInstance
    }

    var body: some View {
        List {
            if hasAnyActivitySource {
                Section {
                    if hasQueueCapableService {
                        NavigationLink(value: MoreDestination.activityQueue) {
                            NavigationMenuRow(
                                icon: "arrow.down.circle.fill",
                                color: MoreDestinationAccent.activity.color,
                                title: "Queue",
                                subtitle: "Downloads, imports, and background tasks"
                            )
                        }
                    }

                    NavigationLink(value: MoreDestination.activityHistory) {
                        NavigationMenuRow(
                            icon: "clock.arrow.circlepath",
                            color: MoreDestinationAccent.activity.color,
                            title: "History",
                            subtitle: "Past grabs, imports, and indexer events"
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "server.rack",
                    description: Text("Connect Sonarr, Radarr, Prowlarr, or Bazarr to view activity.")
                )
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Activity")
        .moreDestinationBackground(.activity)
    }
}

#if DEBUG
#Preview("Arr Activity Hub - Configured") {
    MorePreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            ArrActivityHubView()
        }
    }
}

#Preview("Arr Activity Hub - Empty") {
    MorePreviewHost(profiles: .empty, arr: .preview(.noneConfigured), appServices: nil) { _ in
        NavigationStack {
            ArrActivityHubView()
        }
    }
}
#endif

private struct TasksHubView: View {
    let jellyfinProfile: JellyfinServiceProfile?
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager

    private var hasArrTasks: Bool {
        arrServiceManager.hasSonarrInstance ||
            arrServiceManager.hasRadarrInstance ||
            arrServiceManager.hasProwlarrInstance ||
            arrServiceManager.hasBazarrInstance
    }

    private var hasAnyTaskDestination: Bool {
        hasArrTasks || seerrServiceManager.activeClient != nil || jellyfinServiceManager.activeClient != nil
    }

    var body: some View {
        List {
            if hasAnyTaskDestination {
                Section {
                    if hasArrTasks {
                        NavigationLink(value: MoreDestination.arrTasks) {
                            NavigationMenuRow(
                                icon: "clock.arrow.2.circlepath",
                                color: MoreDestinationAccent.tasks.color,
                                title: "Arr Tasks",
                                subtitle: "Sonarr, Radarr, Prowlarr, and Bazarr tasks"
                            )
                        }
                    }

                    if seerrServiceManager.activeClient != nil {
                        NavigationLink(value: MoreDestination.seerrJobs) {
                            NavigationMenuRow(
                                icon: "clock.arrow.2.circlepath",
                                color: ServiceIdentity.seerr.brandColor,
                                title: "Seerr Jobs",
                                subtitle: "Scheduled jobs and background tasks"
                            )
                        }
                    }

                    if jellyfinServiceManager.activeClient != nil {
                        NavigationLink(value: MoreDestination.jellyfinScheduledTasks) {
                            NavigationMenuRow(
                                icon: "clock.arrow.2.circlepath",
                                color: ServiceIdentity.jellyfin.brandColor,
                                title: "Jellyfin Tasks",
                                subtitle: "View and trigger Jellyfin background tasks"
                            )
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Tasks")
        .moreDestinationBackground(.tasks)
    }
}

#if DEBUG
#Preview("Tasks Hub - All Services") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            TasksHubView(jellyfinProfile: .preview())
        }
    }
}

#Preview("Tasks Hub - Arr Only") {
    MorePreviewHost(
        profiles: .arrOnly,
        arr: .preview(.sonarrOnly),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { _ in
        NavigationStack {
            TasksHubView(jellyfinProfile: nil)
        }
    }
}
#endif

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

#if DEBUG
#Preview("Jellyfin Management Hub") {
    MorePreviewHost(profiles: .jellyfinOnly) { _ in
        NavigationStack {
            JellyfinManagementView(jellyfinProfile: .preview())
        }
    }
}
#endif

private struct MoreServicesGradientBackground: View {
    let services: [ServiceIdentity]

    var body: some View {
        ZStack {
            groupedBackgroundColor

            if !services.isEmpty {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: meshPoints,
                    colors: meshColors,
                    background: .clear,
                    smoothsColors: true
                )
            }
        }
        .ignoresSafeArea()
    }

    private var meshPoints: [SIMD2<Float>] {
        [
            SIMD2<Float>(0.0, 0.0), SIMD2<Float>(0.5, 0.0), SIMD2<Float>(1.0, 0.0),
            SIMD2<Float>(0.0, 0.5), SIMD2<Float>(0.5, 0.5), SIMD2<Float>(1.0, 0.5),
            SIMD2<Float>(0.0, 1.0), SIMD2<Float>(0.5, 1.0), SIMD2<Float>(1.0, 1.0)
        ]
    }

    private var meshColors: [Color] {
        [
            serviceColor(at: 0, opacity: 0.20), serviceColor(at: 1, opacity: 0.14), serviceColor(at: 2, opacity: 0.18),
            serviceColor(at: 3, opacity: 0.10), serviceColor(at: 4, opacity: 0.08), serviceColor(at: 5, opacity: 0.10),
            serviceColor(at: 6, opacity: 0.05), serviceColor(at: 0, opacity: 0.04), serviceColor(at: 1, opacity: 0.05)
        ]
    }

    private func serviceColor(at index: Int, opacity: Double) -> Color {
        services[index % services.count].brandColor.opacity(opacity)
    }

    private var groupedBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}

struct MoreDestinationGradientBackground: View {
    let accent: MoreDestinationAccent

    var body: some View {
        ZStack {
            groupedBackgroundColor

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

    private var groupedBackgroundColor: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
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


struct RecentNotificationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var showClearConfirmation = false
    @State private var unreadSinceDate: Date = .distantPast

    private var notificationCount: Int { inAppNotificationCenter.recentNotifications.count }
    private var unreadNotificationCount: Int {
        inAppNotificationCenter.recentNotifications.filter { $0.timestamp > effectiveUnreadSinceDate }.count
    }
    private var effectiveUnreadSinceDate: Date {
        unreadSinceDate == .distantPast ? inAppNotificationCenter.lastReadDate : unreadSinceDate
    }

    private var activeJobs: [ActiveImportJob] {
        inAppNotificationCenter.activeImportJobs
    }

    private var subtitleText: String {
        let running = inAppNotificationCenter.runningImportJobsCount
        if running > 0 {
            let word = running == 1 ? "import" : "imports"
            return "\(running) \(word) in progress · \(unreadNotificationCount) unread"
        }
        return "\(unreadNotificationCount) unread"
    }

    var body: some View {
        AppSheetShell(
            title: "Notifications",
            subtitle: subtitleText,
            cancelTitle: "Close",
            cancelSystemImage: "xmark",
            showsCancel: false,
            usesInlineLargeTitle: true,
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            Group {
                if activeJobs.isEmpty && inAppNotificationCenter.recentNotifications.isEmpty {
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
                    List {
                        if !activeJobs.isEmpty {
                            Section {
                                ForEach(activeJobs) { job in
                                    activeImportJobRow(job)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: job.status != .running) {
                                            if job.status != .running {
                                                Button(role: .destructive) {
                                                    inAppNotificationCenter.removeImportJob(id: job.id)
                                                } label: {
                                                    Label("Dismiss", systemImage: "xmark")
                                                }
                                            }
                                        }
                                }
                            } header: {
                                HStack {
                                    Text("Imports")
                                    Spacer(minLength: 8)
                                    if activeJobs.contains(where: { $0.status != .running }) {
                                        Button("Clear Finished") {
                                            inAppNotificationCenter.clearFinishedImportJobs()
                                        }
                                        .font(.caption.weight(.semibold))
                                        .textCase(nil)
                                    }
                                }
                            }
                        }

                        if !inAppNotificationCenter.recentNotifications.isEmpty {
                            Section {
                                ForEach(inAppNotificationCenter.recentNotifications) { entry in
                                    notificationRow(for: entry)
                                }
                            } header: {
                                Text("Recent")
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
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
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        NotificationSettingsHubView()
                    } label: {
                        Label("Notification Settings", systemImage: "gearshape")
                    }
                }

                if notificationCount > 0 {
                    ToolbarSpacer(.flexible, placement: .topBarTrailing)
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Clear") {
                            showClearConfirmation = true
                        }
                    }
                }
            }
            #endif
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

    private func tintColor(for tint: ImportJobTint) -> Color {
        switch tint {
        case .sonarr: return ServiceIdentity.sonarr.brandColor
        case .radarr: return ServiceIdentity.radarr.brandColor
        case .generic: return .accentColor
        }
    }

    @ViewBuilder
    private func activeImportJobRow(_ job: ActiveImportJob) -> some View {
        let tint = tintColor(for: job.serviceTint)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 38, height: 38)
                switch job.status {
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: job.serviceSystemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(job.serviceTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(activeImportJobStatusText(job))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(activeImportJobStatusColor(job))
                    Spacer(minLength: 0)
                }

                Text(job.primaryName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(activeImportJobSubtitle(job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let error = job.errorMessage, job.status == .failed {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func activeImportJobStatusText(_ job: ActiveImportJob) -> String {
        switch job.status {
        case .running: return "Importing"
        case .succeeded: return "Imported"
        case .failed: return "Failed"
        }
    }

    private func activeImportJobStatusColor(_ job: ActiveImportJob) -> Color {
        switch job.status {
        case .running: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private func activeImportJobSubtitle(_ job: ActiveImportJob) -> String {
        let fileWord = job.fileCount == 1 ? "file" : "files"
        let countText = "\(job.fileCount) \(fileWord)"
        let timeText: String
        if let completedAt = job.completedAt {
            timeText = completedAt.formatted(date: .omitted, time: .shortened)
        } else {
            timeText = job.startedAt.formatted(date: .omitted, time: .shortened)
        }
        return "\(countText) · \(job.folderName) · \(timeText)"
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

private struct NotificationSettingsHubView: View {
    @Environment(\.openURL) private var openURL
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Query private var allProfiles: [ArrServiceProfile]
    @Query private var seerrProfiles: [SeerrServiceProfile]

    var body: some View {
        List {
            Section {
                ForEach(ArrServiceType.webhookNotificationServices) { serviceType in
                    let profile = profile(for: serviceType)
                    NavigationLink {
                        ArrWebhookNotificationConfigView(
                            serviceType: serviceType,
                            profile: profile,
                            isConnected: isConnected(serviceType)
                        )
                    } label: {
                        ArrWebhookNotificationHubRow(
                            serviceType: serviceType,
                            profile: profile,
                            isConnected: isConnected(serviceType),
                            showsProfileSubtitle: false
                        )
                    }
                }

                NavigationLink {
                    SeerrWebhookNotificationConfigView(
                        profile: seerrProfile,
                        isConnected: isSeerrConnected
                    )
                } label: {
                    SeerrWebhookNotificationHubRow(
                        profile: seerrProfile,
                        isConnected: isSeerrConnected
                    )
                }
            } header: {
                Text("App Webhooks")
            } footer: {
                Text("Creates or updates the same Trawl webhook offered from each app's settings.")
            }

            #if os(iOS)
            Section {
                Button("Open Trawl Notification Settings", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            } header: {
                Text("Device Notifications")
            } footer: {
                Text("System notification permission is required before app webhooks can send push notifications.")
            }
            #endif
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Notification Settings")
    }

    private func profile(for serviceType: ArrServiceType) -> ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: serviceType, in: allProfiles, allowErroredFallback: true)
    }

    private func isConnected(_ serviceType: ArrServiceType) -> Bool {
        guard let profile = profile(for: serviceType) else { return false }
        return arrServiceManager.isConnected(serviceType, profileID: profile.id)
    }

    private var seerrProfile: SeerrServiceProfile? {
        seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
    }

    private var isSeerrConnected: Bool {
        guard let seerrProfile else { return false }
        return seerrServiceManager.activeProfileID == seerrProfile.id && seerrServiceManager.isConnected
    }
}

private struct SeerrWebhookNotificationHubRow: View {
    let profile: SeerrServiceProfile?
    let isConnected: Bool

    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @State private var status: ArrNotificationSetupStatus?
    #if os(iOS)
    @State private var deviceToken: String?
    #endif

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ServiceIdentity.seerr.systemImage)
                .foregroundStyle(ServiceIdentity.seerr.brandColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("Seerr")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                statusLabel
                    .font(.caption2)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .task(id: taskID) {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await refreshStatus()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: NotificationConstants.apnsTokenReceivedNotification)) { notification in
            if let token = notification.object as? String {
                deviceToken = token
                Task { await loadStatus() }
            }
        }
        #endif
    }

    @ViewBuilder
    private var statusLabel: some View {
        if profile == nil {
            Label("Add a Seerr server first", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
        } else if !isConnected {
            Label("Seerr is unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if status == nil {
            Label("Open to configure request and issue events", systemImage: "slider.horizontal.3")
                .foregroundStyle(.secondary)
        } else if let status {
            webhookStatusRow(status)
        }
    }

    private var taskID: String {
        #if os(iOS)
        "seerr-\(profile?.id.uuidString ?? "none")-\(isConnected)-\(deviceToken ?? "nil")"
        #else
        "seerr-\(profile?.id.uuidString ?? "none")-\(isConnected)"
        #endif
    }

    @MainActor
    private func refreshStatus() async {
        #if os(iOS)
        deviceToken = await NotificationService.shared.deviceToken
        #endif
        await loadStatus()
    }

    @MainActor
    private func loadStatus() async {
        guard isConnected, profile != nil else {
            status = nil
            return
        }

        #if os(iOS)
        let token = if let deviceToken {
            deviceToken
        } else {
            await NotificationService.shared.deviceToken
        }
        #else
        let token: String? = nil
        #endif

        guard let token, !token.isEmpty else {
            status = nil
            return
        }

        status = try? await seerrServiceManager.webhookNotificationSetupStatus(
            workerURL: NotificationService.shared.workerURL,
            deviceToken: token
        )
    }
}

private struct SeerrWebhookNotificationConfigView: View {
    let profile: SeerrServiceProfile?
    let isConnected: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var draft = SeerrWebhookNotificationDraft()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var loadError: String?
    #if os(iOS)
    @State private var deviceToken: String?
    #endif

    private var canSave: Bool {
        isConnected && profile != nil && !isSaving && !isLoading && hasDeviceToken
    }

    private var canTest: Bool {
        canSave && !isTesting
    }

    private var hasDeviceToken: Bool {
        #if os(iOS)
        deviceToken?.isEmpty == false
        #else
        false
        #endif
    }

    var body: some View {
        Form {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if profile == nil || !isConnected || !hasDeviceToken {
                Section {
                    Label(unavailableMessage, systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(SeerrWebhookNotificationTrigger.all) { trigger in
                    Toggle(isOn: binding(for: trigger.type)) {
                        Label(trigger.title, systemImage: trigger.systemImage)
                    }
                }
            } header: {
                Text("Notification Triggers")
            } footer: {
                Text("Select which request and issue events should trigger this notification")
            }

            Section {
                Button {
                    Task { await testNotification() }
                } label: {
                    if isTesting {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Testing...")
                        }
                    } else {
                        Label("Test", systemImage: "paperplane")
                    }
                }
                .disabled(!canTest)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("Seerr Notifications")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .task(id: "\(profile?.id.uuidString ?? "none")-\(isConnected)") {
            #if DEBUG
            if ArrPreviewRuntime.isActive {
                draft = .preview
                return
            }
            #endif
            await load()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: NotificationConstants.apnsTokenReceivedNotification)) { notification in
            if let token = notification.object as? String {
                deviceToken = token
                Task { await load() }
            }
        }
        #endif
    }

    private var unavailableMessage: String {
        if profile == nil {
            return "Add a Seerr server before configuring notifications."
        }
        if !isConnected {
            return "Seerr needs to be connected before webhook setup."
        }
        if !hasDeviceToken {
            return "Enable notifications in Trawl settings first."
        }
        return "Notification configuration is unavailable."
    }

    @MainActor
    private func load() async {
        guard isConnected, profile != nil else { return }
        isLoading = true
        defer { isLoading = false }

        #if os(iOS)
        deviceToken = await NotificationService.shared.deviceToken
        #endif

        guard let token = currentDeviceToken else { return }

        do {
            let settings = try await seerrServiceManager.trawlWebhookNotificationSettings(
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            )
            draft = SeerrWebhookNotificationDraft(settings: settings)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var currentDeviceToken: String? {
        #if os(iOS)
        guard let deviceToken, !deviceToken.isEmpty else { return nil }
        return deviceToken
        #else
        return nil
        #endif
    }

    private func binding(for type: SeerrNotificationType) -> Binding<Bool> {
        Binding(
            get: { draft.isEnabled(type) },
            set: { draft.setEnabled($0, for: type) }
        )
    }

    @MainActor
    private func save() async {
        guard let token = currentDeviceToken else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            try await seerrServiceManager.saveTrawlWebhookNotificationSettings(
                draft.settings,
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            )
            inAppNotificationCenter.showSuccess(title: "Saved", message: "Seerr notifications updated.")
            dismiss()
        } catch {
            inAppNotificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
        }
    }

    @MainActor
    private func testNotification() async {
        guard let token = currentDeviceToken else { return }
        isTesting = true
        defer { isTesting = false }

        do {
            try await seerrServiceManager.testTrawlWebhookNotificationSettings(
                draft.settings,
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            )
            inAppNotificationCenter.showSuccess(title: "Test Sent", message: "Seerr accepted the webhook test.")
        } catch {
            inAppNotificationCenter.showError(title: "Test Failed", message: error.localizedDescription)
        }
    }
}

private struct SeerrWebhookNotificationDraft {
    var enabledTypes: Set<SeerrNotificationType> = Set(SeerrWebhookNotificationTrigger.all.map(\.type))

    init() {}

    init(settings: SeerrWebhookNotificationSettings) {
        let visibleTypes = Set(SeerrWebhookNotificationTrigger.all.map(\.type))
        enabledTypes = Set(visibleTypes.filter { settings.types & $0.rawValue != 0 })
        if enabledTypes.isEmpty {
            enabledTypes = visibleTypes
        }
    }

    static var preview: SeerrWebhookNotificationDraft {
        var draft = SeerrWebhookNotificationDraft()
        draft.enabledTypes.remove(.issueReopened)
        return draft
    }

    var settings: SeerrWebhookNotificationSettings {
        let typeMask = enabledTypes.reduce(SeerrNotificationType.testNotification.rawValue) { partialResult, type in
            partialResult | type.rawValue
        }

        return SeerrWebhookNotificationSettings(
            enabled: true,
            types: typeMask,
            options: SeerrWebhookNotificationOptions(
                webhookUrl: nil,
                authHeader: nil,
                jsonPayload: nil,
                supportVariables: true,
                customHeaders: nil
            )
        )
    }

    func isEnabled(_ type: SeerrNotificationType) -> Bool {
        enabledTypes.contains(type)
    }

    mutating func setEnabled(_ isEnabled: Bool, for type: SeerrNotificationType) {
        if isEnabled {
            enabledTypes.insert(type)
        } else {
            enabledTypes.remove(type)
        }
    }
}

private struct SeerrWebhookNotificationTrigger: Identifiable {
    let type: SeerrNotificationType
    let title: String
    let systemImage: String

    var id: Int { type.rawValue }

    static let all: [SeerrWebhookNotificationTrigger] = [
        .init(type: .mediaPending, title: "Request Pending Approval", systemImage: "hourglass.badge.plus"),
        .init(type: .mediaAutoRequested, title: "Request Automatically Submitted", systemImage: "wand.and.sparkles"),
        .init(type: .mediaAutoApproved, title: "Request Automatically Approved", systemImage: "checkmark.seal.fill"),
        .init(type: .mediaApproved, title: "Request Approved", systemImage: "checkmark.circle.fill"),
        .init(type: .mediaDeclined, title: "Request Declined", systemImage: "xmark.circle.fill"),
        .init(type: .mediaAvailable, title: "Request Available", systemImage: "play.tv.fill"),
        .init(type: .mediaFailed, title: "Request Processing Failed", systemImage: "exclamationmark.triangle.fill"),
        .init(type: .issueCreated, title: "Issue Reported", systemImage: "exclamationmark.bubble.fill"),
        .init(type: .issueComment, title: "Issue Comment", systemImage: "text.bubble.fill"),
        .init(type: .issueResolved, title: "Issue Resolved", systemImage: "checkmark.message.fill"),
        .init(type: .issueReopened, title: "Issue Reopened", systemImage: "arrow.counterclockwise.circle.fill")
    ]
}

@ViewBuilder
private func webhookStatusRow(_ status: ArrNotificationSetupStatus) -> some View {
    switch status {
    case .configured:
        WebhookStatusInlineRow(
            text: "Trawl webhook is configured",
            systemImage: "checkmark.circle.fill",
            color: .green
        )
    case .needsUpdate:
        WebhookStatusInlineRow(
            text: "Trawl webhook needs updating",
            systemImage: "arrow.triangle.2.circlepath.circle.fill",
            color: .orange
        )
    case .notAdded:
        WebhookStatusInlineRow(
            text: "Trawl webhook has not been added",
            systemImage: "minus.circle.fill",
            color: .secondary
        )
    }
}

#if DEBUG
#Preview("Recent Notifications - Loaded") {
    NavigationStack {
        RecentNotificationsSheet()
            .environment(MorePreviewFixtures.notificationCenter())
    }
}

#Preview("Recent Notifications - Empty") {
    NavigationStack {
        RecentNotificationsSheet()
            .environment(InAppNotificationCenter(previewNotifications: []))
    }
}
#endif

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

#Preview("All services") {
    MoreServicesGradientBackground(services: ServiceIdentity.allCases)
}

#Preview("No services") {
    MoreServicesGradientBackground(services: [])
}

#Preview("Arr only") {
    MoreServicesGradientBackground(services: [.qbittorrent, .sonarr, .radarr, .prowlarr, .bazarr])
}

#Preview("Jellyfin + Seerr only") {
    MoreServicesGradientBackground(services: [.jellyfin, .seerr])
}

#Preview("Single service") {
    MoreServicesGradientBackground(services: [.sonarr])
}
