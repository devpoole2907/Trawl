import SwiftUI
import SwiftData

enum MoreDestination: Hashable {
    case diskSpace
    case health
    case wanted
    case settings
    case qbittorrentSettings
    case sabnzbdSettings
    case sonarrSettings
    case radarrSettings
    case prowlarrSettings
    case prowlarrIndexers
    case automationClients
    case requestsAndAccess
    case systemHub
    case linkedApplicationsManagement
    case downloadClientsManagement
    case prowlarrLinkedApplications
    case bazarrLinkedApplications
    case seerrLinkedApplications
    case downloadClients(service: ArrServiceType)
    case remotePathMappings
    case libraryImport
    case manualImport
    case calendar
    case libraryImportScan(path: String, service: ArrServiceType, instanceID: UUID?)
    case manualImportScan(path: String, service: ArrServiceType, instanceID: UUID?)
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
    case jellyfinTranscoding
    case cleanuparrDashboard
    case cleanuparrSettings
    case unifiedUsers
    case logsAndEvents
    case arrEvents
    case qbittorrentLog
    case tasksHub
    /// The qBittorrent and SABnzbd hubs. These used to be reachable only by pushing
    /// through Download Clients, which is right on a phone and wrong on a display
    /// with a sidebar - a client you use every day should not be three clicks in.
    case qbittorrentHub
    case sabnzbdHub
    case arrTasks
    case seerrJobs
    case updatesHub
    case backupsHub
    case qualityDefinitions
}

/// User-facing breadcrumbs for destinations referenced outside the More hierarchy.
/// Keeping guidance on the destination prevents error copy from retaining a route
/// that no longer exists when the hierarchy changes.
extension MoreDestination {
    /// Where to send someone in prose, e.g. "Add a SABnzbd server in Settings → SABnzbd."
    ///
    /// Deliberately does **not** start at "More". More exists on iPhone and in the
    /// iPad tab bar, but not in the iPad sidebar, where these same screens are
    /// top-level destinations - so a breadcrumb naming it was telling half the users
    /// to look for something that isn't on their screen. Naming the destination and
    /// not its container is the one phrasing that stays true in every chrome, and
    /// Settings is reachable (and searchable) in all of them.
    var userFacingPath: String {
        switch self {
        case .settings:
            "Settings"
        case .sabnzbdSettings:
            "\(MoreDestination.settings.userFacingPath) → SABnzbd"
        default:
            "Settings"
        }
    }
}

enum MoreDestinationAccent {
    case settings
    case activity
    case calendar
    case libraryImport
    case manualImport
    case categoriesAndTags
    case rssFeeds
    case transferStats
    case torrentManagement
    case indexers
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
    case cleanuparr
    case logsAndEvents
    case tasks
    case updates
    case backups
    case systemHub
    case automationClients

    var color: Color {
        switch self {
        case .settings: return .secondary
        case .activity: return .indigo
        case .calendar: return .purple
        case .libraryImport: return .blue
        case .manualImport: return .teal
        case .categoriesAndTags: return .brown
        case .rssFeeds: return .cyan
        case .transferStats: return .mint
        case .torrentManagement: return .mint
        case .indexers: return .yellow
        case .integrations: return .blue
        case .downloadClients: return .mint
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
        case .cleanuparr: return ServiceIdentity.cleanuparr.brandColor
        case .logsAndEvents: return .brown
        case .tasks: return .teal
        case .updates: return .green
        case .backups: return .indigo
        case .systemHub: return .gray
        case .automationClients: return .blue
        }
    }
}

struct MoreView: View {
    @Query private var servers: [ServerProfile]
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @Query private var cleanuparrProfiles: [CleanuparrServiceProfile]
    let appServices: AppServices?
    @Binding var path: [MoreDestination]
    let isQBittorrentConnecting: Bool
    let onRetryQBittorrent: (() -> Void)?
    /// What this stack is rooted at. `nil` means the More list, which is the iPhone
    /// arrangement. On iPad there is no More: each of its top-level rows is a sidebar
    /// destination that roots this same view at its own screen, so the list is
    /// skipped and the user lands on that screen directly.
    var root: MoreDestination?
    /// Which part of the app's navigation this instance is supplying.
    ///
    /// On iPad the caller owns a single three-column `NavigationSplitView`, and asks
    /// for the middle column and the detail column separately. Letting this view
    /// build a split of its own instead is what produced nested split views - and a
    /// visible band of empty space above the middle column, where the inner split's
    /// own bar had been.
    var presentation: Presentation = .stack

    enum Presentation {
        /// A self-contained `NavigationStack`. The compact arrangement.
        case stack
        /// Just the rooted screen, for the middle column of the caller's split view.
        case contentColumn
        /// The `NavigationStack` its pushes land in, for the caller's detail column.
        case detailColumn
    }
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.navigateToDownloadsTab) private var navigateToDownloadsTab
    /// Optional so previews and any host that doesn't inject a navigator still work.
    @Environment(DownloadsNavigator.self) private var downloadsNavigator: DownloadsNavigator?
    @State private var subtitleBadgeCount = 0
    @State private var moreSearchText = ""
    @State private var connectionEditSheet: ConnectionEditSheet?

    private var hasQBittorrentServer: Bool { !servers.isEmpty }

    private var configuredServiceIdentities: [ServiceIdentity] {
        var identities: [ServiceIdentity] = []
        if hasQBittorrentServer { identities.append(.qbittorrent) }
        if !sabnzbdProfiles.isEmpty { identities.append(.sabnzbd) }
        if arrServiceManager.hasSonarrInstance { identities.append(.sonarr) }
        if arrServiceManager.hasRadarrInstance { identities.append(.radarr) }
        if arrServiceManager.hasProwlarrInstance { identities.append(.prowlarr) }
        if arrServiceManager.hasBazarrInstance { identities.append(.bazarr) }
        if !seerrProfiles.isEmpty { identities.append(.seerr) }
        if !jellyfinProfiles.isEmpty { identities.append(.jellyfin) }
        if !cleanuparrProfiles.isEmpty { identities.append(.cleanuparr) }
        return identities
    }

    private var seerrProfile: SeerrServiceProfile? {
        seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
    }

    private var jellyfinProfile: JellyfinServiceProfile? {
        jellyfinProfiles.first(where: { $0.isEnabled }) ?? jellyfinProfiles.first
    }

    private var sabnzbdProfile: SABnzbdServiceProfile? {
        sabnzbdProfiles.first(where: { $0.isEnabled }) ?? sabnzbdProfiles.first
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
        case sabnzbd
        case arr(ArrServiceType)
        case seerr
        case jellyfin
        case cleanuparr

        var id: String {
            switch self {
            case .qbittorrent:
                "qbittorrent"
            case .sabnzbd:
                "sabnzbd"
            case .arr(let service):
                "arr-\(service.rawValue)"
            case .seerr:
                "seerr"
            case .jellyfin:
                "jellyfin"
            case .cleanuparr:
                "cleanuparr"
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
        if !sabnzbdProfiles.isEmpty && !sabnzbdServiceManager.isConnected
            && (sabnzbdServiceManager.isConnecting || sabnzbdServiceManager.connectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .sabnzbd,
                isConnecting: sabnzbdServiceManager.isConnecting,
                message: sabnzbdServiceManager.connectionError ?? "Checking your configured SABnzbd server."
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
        if !cleanuparrProfiles.isEmpty && !cleanuparrServiceManager.isConnected
            && (cleanuparrServiceManager.isConnecting || cleanuparrServiceManager.connectionError != nil) {
            issues.append(ConnectionIssue(
                identity: .cleanuparr,
                isConnecting: cleanuparrServiceManager.isConnecting,
                message: cleanuparrServiceManager.connectionError ?? "Checking your configured Cleanuparr server."
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
        if !sabnzbdServiceManager.isConnected && !sabnzbdServiceManager.isConnecting {
            Task { await sabnzbdServiceManager.initialize(from: sabnzbdProfiles) }
        }
        if !seerrServiceManager.isConnected && !seerrServiceManager.isConnecting {
            Task { await seerrServiceManager.initialize(from: seerrProfiles) }
        }
        if !jellyfinServiceManager.isConnected && !jellyfinServiceManager.isConnecting {
            Task { await jellyfinServiceManager.initialize(from: jellyfinProfiles) }
        }
        if !cleanuparrServiceManager.isConnected && !cleanuparrServiceManager.isConnecting {
            Task { await cleanuparrServiceManager.initialize(from: cleanuparrProfiles) }
        }
        Task { await arrServiceManager.retryDisconnected() }
    }

    private func retryConnection(for identity: ServiceIdentity) {
        switch identity {
        case .qbittorrent:
            onRetryQBittorrent?()
        case .sabnzbd:
            Task { await sabnzbdServiceManager.initialize(from: sabnzbdProfiles) }
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
        case .cleanuparr:
            Task { await cleanuparrServiceManager.initialize(from: cleanuparrProfiles) }
        }
    }

    private func presentConnectionEditor(for identity: ServiceIdentity) {
        let sheet: ConnectionEditSheet
        switch identity {
        case .qbittorrent:
            sheet = .qbittorrent
        case .sabnzbd:
            sheet = .sabnzbd
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
        case .cleanuparr:
            sheet = .cleanuparr
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
                    ConnectionStatusCard(
                        identity: issue.identity,
                        title: issue.isConnecting ? "Connecting to \(issue.identity.displayName)" : "\(issue.identity.displayName) Unreachable",
                        message: issue.message,
                        isConnecting: issue.isConnecting,
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

    // On iPhone this is a stack rooted at the More list. On iPad there is no More:
    // its rows are sidebar destinations, and this view supplies one *column* of the
    // app's single three-column split rather than a navigation container of its own.
    // Everything below the root is shared by all three modes: one
    // `navigationDestination` table, one set of environment reads.
    //
    // The compact branches are written out as separate `NavigationStack`s rather
    // than one stack wrapping a `Group`, and that is not a style choice. Wrapping
    // the list in a `Group` cost every row its merged-button accessibility:
    // `NavigationLink` rows that had been one `Button` labelled "Settings" became
    // unlabelled `Cell`s with the text as a child, which is invisible on screen and
    // broke every UI journey that reaches a More row by name. Keeping `List` as the
    // stack's direct child keeps the semantics it had before any of this existed.
    var body: some View {
        switch presentation {
        case .stack:
            if let root {
                NavigationStack(path: $path) {
                    stackChrome { moreDestinationView(for: root) }
                }
            } else {
                NavigationStack(path: $path) {
                    stackChrome { moreListRoot }
                }
            }

        case .contentColumn:
            // Deliberately bare - no stack, no split. This is handed straight to the
            // middle column of `ContentView`'s split view, and wrapping it in a
            // navigation container of its own is exactly what put a second bar and a
            // dead band of space above the column.
            rootScreen
                .task { await loadSubtitleBadge() }

        case .detailColumn:
            // The stack lives here, in the detail column, and not in the content
            // column beside it. These screens are reached two ways: a
            // `NavigationLink` the user taps, and a `path.append(...)` from one of
            // the `navigateToX` environment actions or a deep link. The split view
            // routes the first into this column on its own, but the second only
            // arrives if `path` is driving a stack - so the stack has to be what
            // this column contains.
            NavigationStack(path: $path) {
                ContentUnavailableView("Nothing Selected", systemImage: "sidebar.right")
                    .navigationDestination(for: MoreDestination.self) { moreDestinationView(for: $0) }
            }
        }
    }

    @ViewBuilder
    private var rootScreen: some View {
        if let root {
            moreDestinationView(for: root)
        } else {
            moreListRoot
        }
    }


    /// The destination table and badge fetch both compact roots share.
    @ViewBuilder
    private func stackChrome(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .navigationDestination(for: MoreDestination.self) { moreDestinationView(for: $0) }
            .task { await loadSubtitleBadge() }
    }

    private func loadSubtitleBadge() async {
        guard let client = arrServiceManager.activeBazarrEntry?.client else { return }
        if let badges = try? await client.getBadges() {
            subtitleBadgeCount = badges.episodes + badges.movies
        }
    }

    /// The More list itself - the iPhone root, and unused on iPad.
    private var moreListRoot: some View {
        List {
            if isShowingMoreSearchResults {
                moreSearchResultsContent
            } else {
                connectivityAlertSection
                Section {
                    NavigationLink(value: MoreDestination.wanted) {
                        moreRow(.wanted)
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.mediaManagement) {
                        moreRow(.mediaManagement,
                                subtitle: subtitleBadgeCount > 0 ? "\(subtitleBadgeCount) items need subtitles" : nil)
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.requestsAndAccess) {
                        moreRow(.requestsAndAccess,
                                subtitle: seerrProfile == nil && jellyfinProfile == nil ? "Not set up" : nil)
                    }

                    NavigationLink(value: MoreDestination.jellyfinManagement) {
                        moreRow(.jellyfinManagement, subtitle: jellyfinProfile == nil ? "Not set up" : nil)
                    }

                    NavigationLink(value: MoreDestination.automationClients) {
                        moreRow(.automationClients)
                    }

                    NavigationLink(value: MoreDestination.systemHub) {
                        moreRow(.systemHub)
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.settings) {
                        moreRow(.settings)
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
    }

    /// Every screen reachable from More, in one place.
    ///
    /// This is deliberately a method on `MoreView` rather than a free function or a
    /// separate modifier: nearly every branch reads one of this view's environment
    /// values or computed destinations, and hoisting it out would mean threading a
    /// dozen dependencies through a new type for no gain. Keeping it here lets the
    /// iPad sidebar tabs reuse the table exactly as the push navigation does.
    @ViewBuilder
    func moreDestinationView(for destination: MoreDestination) -> some View {
        switch destination {
        case .requestsAndAccess:
            RequestsAndAccessHubView(
                seerrProfile: seerrProfile,
                jellyfinProfile: jellyfinProfile
            )
                .moreDestinationTitleStyle()
        case .systemHub:
            SystemHubView()
                .moreDestinationTitleStyle()
        case .automationClients:
            AutomationAndClientsHubView()
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
        case .sabnzbdSettings:
            SABnzbdSettingsView()
                .environment(sabnzbdServiceManager)
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
                .moreDestinationBackground(.indexers)
                .moreDestinationTitleStyle()
        case .libraryImport:
            ArrImportLocationView(kind: .library)
                .environment(arrServiceManager)
                .moreDestinationTitleStyle()
        case .manualImport:
            ArrImportLocationView(kind: .manual)
                .environment(arrServiceManager)
                .moreDestinationTitleStyle()
        case .calendar:
            // Search-reachable only - no permanent More row. The primary,
            // correctly media-scoped entry points are the Series and Movies
            // toolbars (ArrMediaListView); this unscoped copy stays for search.
            ArrCalendarView()
                .environment(arrServiceManager)
                .injectSyncService(appServices)
                .moreDestinationTitleStyle()
        case .seerrAdmin:
            seerrAdminDestination()
                .moreDestinationTitleStyle()
        case .seerrIssues:
            if let client = seerrServiceManager.activeClient {
                SeerrIssueListView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                seerrAdminDestination(title: "Issues")
                    .moreDestinationTitleStyle()
            }
        case .seerrLogs:
            if let client = seerrServiceManager.activeClient {
                SeerrLogsView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                seerrAdminDestination(title: "Logs")
                    .moreDestinationTitleStyle()
            }
        case .seerrSettings:
            SeerrSettingsView()
                .moreDestinationTitleStyle()
        case .jellyfinManagement:
            JellyfinManagementView(jellyfinProfile: jellyfinProfile)
                .moreDestinationTitleStyle()
        case .jellyfinLibraries:
            if let client = jellyfinServiceManager.activeClient {
                JellyfinLibrariesView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                jellyfinUnavailableDestination(title: "Libraries")
                    .moreDestinationTitleStyle()
            }
        case .jellyfinSessions:
            if let client = jellyfinServiceManager.activeClient {
                JellyfinSessionsView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                jellyfinUnavailableDestination(title: "Sessions")
                    .moreDestinationTitleStyle()
            }
        case .jellyfinActivityLog:
            if let client = jellyfinServiceManager.activeClient {
                JellyfinActivityLogView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                jellyfinUnavailableDestination(title: "Activity Log")
                    .moreDestinationTitleStyle()
            }
        case .jellyfinScheduledTasks:
            if let client = jellyfinServiceManager.activeClient {
                JellyfinScheduledTasksView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                jellyfinUnavailableDestination(title: "Tasks")
                    .moreDestinationTitleStyle()
            }
        case .jellyfinPlugins:
            if let client = jellyfinServiceManager.activeClient {
                JellyfinPluginsView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                jellyfinUnavailableDestination(title: "Plugins")
                    .moreDestinationTitleStyle()
            }
        case .jellyfinTranscoding:
            if let client = jellyfinServiceManager.activeClient {
                JellyfinTranscodingSettingsView(apiClient: client)
                    .moreDestinationTitleStyle()
            } else {
                jellyfinUnavailableDestination(title: "Transcoding")
                    .moreDestinationTitleStyle()
            }
        case .jellyfinSettings:
            JellyfinSettingsView()
                .moreDestinationTitleStyle()
        case .cleanuparrDashboard:
            CleanuparrDashboardView()
                .environment(cleanuparrServiceManager)
                .moreDestinationBackground(.cleanuparr)
                .moreDestinationTitleStyle()
        case .cleanuparrSettings:
            CleanuparrSettingsView()
                .environment(cleanuparrServiceManager)
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
        case .qbittorrentHub:
            QBittorrentClientHubView()
                .environment(syncService)
                .environment(torrentService)
                .moreDestinationTitleStyle()
        case .sabnzbdHub:
            SABnzbdClientHubView()
                .environment(sabnzbdServiceManager)
                // `SABnzbdManagerView` under this hub reads both of these; without
                // them it traps with "No Observable object of type SyncService
                // found", which crashes rather than merely failing to render.
                .environment(syncService)
                .environment(torrentService)
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
                seerrAdminDestination(title: "Tasks")
                    .moreDestinationTitleStyle()
            }
        case .updatesHub:
            ArrUpdatesView()
                .environment(arrServiceManager)
                .moreDestinationTitleStyle()
        case .backupsHub:
            ArrBackupsView()
                .environment(arrServiceManager)
                .environment(jellyfinServiceManager)
                .moreDestinationTitleStyle()
        case .unifiedUsers:
            unifiedUsersDestination
                .moreDestinationBackground(.userManagement)
                .moreDestinationTitleStyle()
        case .libraryImportScan(let path, let service, let instanceID):
            LibraryImportScanView(path: path, service: service, serviceManager: arrServiceManager, instanceID: instanceID, kind: .library)
                .moreDestinationTitleStyle()
        case .manualImportScan(let path, let service, let instanceID):
            LibraryImportScanView(path: path, service: service, serviceManager: arrServiceManager, instanceID: instanceID, kind: .manual)
                .moreDestinationTitleStyle()
        case .mediaManagement:
            ArrMediaManagementView(
                subtitleBadgeCount: subtitleBadgeCount,
                hasJellyfin: jellyfinProfile != nil
            )
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
                    if let destination = entry.destination {
                        NavigationLink(value: destination) {
                            MoreSearchResultRow(entry: entry)
                        }
                    } else {
                        Button {
                            // Queue the push before switching tabs; DownloadsView
                            // applies it on arrival.
                            if let route = entry.downloadsRoute {
                                downloadsNavigator?.show(route)
                            }
                            navigateToDownloadsTab()
                        } label: {
                            MoreSearchResultRow(entry: entry)
                        }
                        .buttonStyle(.plain)
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
            ServiceSetupView(title: "Prowlarr Not Set Up", message: "Add a Prowlarr server in Settings to link indexer sync destinations.", systemImage: ServiceIdentity.prowlarr.tabSystemImage)
            .scrollableUnavailableState()
            .moreDestinationBackground(.integrations)
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
            ServiceSetupView(title: "Bazarr Not Set Up", message: "Add a Bazarr server in Settings to link subtitle sync destinations.", systemImage: ServiceIdentity.bazarr.tabSystemImage)
            .scrollableUnavailableState()
            .moreDestinationBackground(.integrations)
            .navigationTitle("Linked Apps")
            .navigationSubtitle("Bazarr")
        }
    }

    @ViewBuilder
    private var seerrLinkedApplicationsDestination: some View {
        if let client = seerrServiceManager.activeClient {
            SeerrLinkedApplicationsView(apiClient: client)
        } else {
            seerrAdminDestination(title: "Linked Apps")
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
            // Titled here, because neither of these fallbacks titles itself and the
            // connected view is the only branch that did. A screen reached from a
            // sidebar row called "Indexers" arrived under a blank bar whenever the
            // servers were down - which is exactly when someone is least sure what
            // they are looking at.
            .navigationTitle("Indexers")
        } else {
            ServiceSetupView(title: "Indexers Not Set Up", message: "Add a Prowlarr, Sonarr, or Radarr server in Settings to manage your indexers.", systemImage: ServiceIdentity.prowlarr.tabSystemImage)
            .scrollableUnavailableState()
            .moreDestinationBackground(.indexers)
            .navigationTitle("Indexers")
        }
    }

    @ViewBuilder
    private var settingsDestination: some View {
        SettingsView(showsDoneButton: false)
            .environment(syncService)
            .environment(torrentService)
            .environment(arrServiceManager)
            .environment(sabnzbdServiceManager)
            .environment(cleanuparrServiceManager)
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

        case .sabnzbd:
            NavigationStack {
                SABnzbdSettingsView()
                    .environment(sabnzbdServiceManager)
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

        case .cleanuparr:
            NavigationStack {
                CleanuparrSettingsView()
                    .environment(cleanuparrServiceManager)
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
            presentation: .embedded,
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
            ServiceSetupView(title: "qBittorrent Not Set Up", message: "Add a qBittorrent server in Settings to manage your downloads.", systemImage: ServiceIdentity.qbittorrent.tabSystemImage)
            .scrollableUnavailableState()
            .moreDestinationBackground(.downloadClients)
            // The connected branch is titled by `QBittorrentSettingsView`; without
            // this the not-set-up branch arrives under a blank bar.
            .navigationTitle("qBittorrent")
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
            ServiceSetupView(title: "qBittorrent Not Set Up", message: "Add a qBittorrent server in Settings to view server logs.", systemImage: "doc.text")
            .scrollableUnavailableState()
            .moreDestinationBackground(.downloadClients)
            .navigationTitle("qBittorrent Log")
        }
    }

    /// The Seerr fallback, titled with the screen that asked for it - Issues and Jobs
    /// share it with Requests, and all three used to arrive saying "Requests".
    @ViewBuilder
    private func seerrAdminDestination(title: String = "Requests") -> some View {
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
                presentation: .embedded,
            onRetry: {
                    Task { await seerrServiceManager.connectService(seerrProfile) }
                },
                onEdit: { presentConnectionEditor(for: .seerr) }
            )
            .navigationTitle(title)
        } else {
            ServiceSetupView(title: "Seerr Not Set Up", message: "Add a Seerr server in Settings to manage requests.", systemImage: ServiceIdentity.seerr.tabSystemImage)
            .scrollableUnavailableState()
            .moreDestinationBackground(.requestManagement)
            .navigationTitle(title)
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
            jellyfinUnavailableDestination(title: "Users")
        }
    }

    /// The Jellyfin fallback, titled with the screen that asked for it.
    ///
    /// It used to title itself "Jellyfin" for every caller, so selecting Libraries,
    /// Sessions or Users with the server down landed on a bar that named the service
    /// rather than the screen - the sidebar row and the title beside it disagreeing
    /// about where you were.
    @ViewBuilder
    private func jellyfinUnavailableDestination(title: String = "Jellyfin") -> some View {
        if let jellyfinProfile {
            ConnectionStatusCard(
                identity: .jellyfin,
                title: jellyfinServiceManager.isConnecting ? "Connecting to Jellyfin" : "Jellyfin Unreachable",
                message: jellyfinServiceManager.connectionError ?? "Unable to reach your configured Jellyfin server.",
                isConnecting: jellyfinServiceManager.isConnecting,
                detailTitle: jellyfinProfile.displayName,
                detailSubtitle: jellyfinProfile.hostURL,
                presentation: .embedded,
            onRetry: {
                    Task { await jellyfinServiceManager.connectService(jellyfinProfile) }
                },
                onEdit: { presentConnectionEditor(for: .jellyfin) }
            )
            .navigationTitle(title)
        } else {
            ServiceSetupView(title: "Jellyfin Not Set Up", message: "Add a Jellyfin server in Settings to manage your media server.", systemImage: "server.rack")
            .scrollableUnavailableState()
            .moreDestinationBackground(.jellyfin)
            .navigationTitle(title)
        }
    }

    private func moreRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        NavigationMenuRow(icon: icon, color: color, title: title, subtitle: subtitle)
    }

    /// Builds a dashboard row from the shared `MoreSearchIndex` catalog so the icon,
    /// color, title, and subtitle live in one place. Pass `subtitle` to override the
    /// catalog default for rows that vary by connection state.
    @ViewBuilder
    private func moreRow(_ destination: MoreDestination, subtitle: String? = nil) -> some View {
        if let info = MoreSearchIndex.entry(for: destination) {
            NavigationMenuRow(
                icon: info.icon,
                color: info.color,
                title: info.title,
                subtitle: subtitle ?? info.subtitle
            )
        }
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

struct MoreSearchResultRow: View {
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

/// One searchable feature. Not private: the iPad sidebar searches the same index,
/// so that a screen is found by the same words in both chromes.
struct MoreSearchIndexEntry: Identifiable {
    let id: String
    /// `nil` for entries that redirect to a root tab (e.g. Downloads) instead of
    /// pushing a `MoreDestination` in this tab's own navigation stack.
    let destination: MoreDestination?
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let category: String
    let keywords: [String]
    /// For entries that live in the Downloads tab rather than in More's own stack.
    /// Without this every such result landed on the Downloads root, so searching
    /// "RSS Feeds" and searching "Blocklist" went to the same place.
    let downloadsRoute: DownloadsManagementRoute?

    init(
        id: String,
        destination: MoreDestination?,
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        category: String,
        keywords: [String] = [],
        downloadsRoute: DownloadsManagementRoute? = nil
    ) {
        self.id = id
        self.destination = destination
        self.icon = icon
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.keywords = keywords
        self.downloadsRoute = downloadsRoute
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

/// The app's feature search. Shared by More's own search field and, on iPad, by
/// the sidebar's - which is the *only* search on that chrome, since More is not
/// there to hold one.
enum MoreSearchIndex {
    static func results(for query: String) -> [MoreSearchIndexEntry] {
        entries.filter { $0.matches(query) }
    }

    /// Single source of truth for a destination's row presentation (icon, color, title,
    /// subtitle). Consumed by the More dashboard rows so they aren't duplicated here.
    static func entry(for destination: MoreDestination) -> MoreSearchIndexEntry? {
        entries.first { $0.destination == destination }
    }

    static let entries: [MoreSearchIndexEntry] = {
        [
            .init(
                id: "downloads",
                destination: nil,
                icon: "arrow.down.doc.fill",
                color: .indigo,
                title: "Downloads",
                subtitle: "Active downloads, queue, and history",
                category: "Monitoring",
                keywords: ["activity", "queue", "download", "import", "history", "grab", "release", "torrent", "usenet", "sabnzbd", "qbittorrent"]
            ),
            .init(
                id: "wanted",
                destination: .wanted,
                icon: "exclamationmark.triangle.fill",
                color: .orange,
                title: "Missing",
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
                category: "Series & Movies",
                keywords: ["schedule", "air date", "release date", "episodes", "movies"]
            ),
            .init(
                id: "health",
                destination: .health,
                icon: "heart.text.square.fill",
                color: .pink,
                title: "Health",
                subtitle: "Service health checks",
                category: "System",
                keywords: ["status", "warnings", "errors", "checks"]
            ),
            .init(
                id: "blocklist",
                destination: nil,
                icon: "nosign",
                color: .red,
                title: "Blocked & Excluded",
                subtitle: "Blocked releases and import-list exclusions",
                category: "Downloads",
                keywords: ["blocked", "blacklist", "failed", "grabbed", "release", "exclusion", "import list"],
                downloadsRoute: .blocklist
            ),
            .init(
                id: "library-management",
                destination: .mediaManagement,
                icon: "folder.badge.gearshape",
                color: MoreDestinationAccent.mediaManagement.color,
                title: "Library Management",
                subtitle: "Imports, root folders, naming, quality, and subtitles",
                category: "Library Management",
                keywords: ["media", "import", "storage", "files", "paths", "profiles", "definitions", "subtitles", "libraries"]
            ),
            .init(
                id: "root-folders",
                destination: .rootFolders,
                icon: "folder.fill",
                color: MoreDestinationAccent.rootFolders.color,
                title: "Root Folders",
                subtitle: "Library paths across Sonarr and Radarr",
                category: "Library Management",
                keywords: ["paths", "storage", "library", "folder", "sonarr", "radarr"]
            ),
            .init(
                id: "library-import",
                destination: .libraryImport,
                icon: "square.and.arrow.down.on.square.fill",
                color: MoreDestinationAccent.libraryImport.color,
                title: "Library Import",
                subtitle: "Import an existing organized library into Sonarr or Radarr",
                category: "Library Management",
                keywords: ["existing", "library", "import", "scan", "folder", "sonarr", "radarr", "unmapped"]
            ),
            .init(
                id: "manual-import",
                destination: .manualImport,
                icon: "tray.and.arrow.down.fill",
                color: MoreDestinationAccent.manualImport.color,
                title: "Manual Import",
                subtitle: "Import files into series or movies already in your library",
                category: "Library Management",
                keywords: ["manual", "import", "interactive", "file", "move", "copy", "existing", "scan"]
            ),
            .init(
                id: "disk-space",
                destination: .diskSpace,
                icon: "internaldrive.fill",
                color: MoreDestinationAccent.diskSpace.color,
                title: "Disk Space",
                subtitle: "Storage usage across Sonarr and Radarr",
                category: "System",
                keywords: ["drive", "storage", "free space", "usage", "sonarr", "radarr"]
            ),
            .init(
                id: "naming",
                destination: .arrNaming,
                icon: "character.cursor.ibeam",
                color: MoreDestinationAccent.sonarrNaming.color,
                title: "Naming",
                subtitle: "Episode, series, and movie file name formats",
                category: "Library Management",
                keywords: ["filename", "format", "movies", "episodes", "sonarr", "radarr"]
            ),
            .init(
                id: "quality-profiles",
                destination: .qualityProfiles,
                icon: "slider.horizontal.3",
                color: MoreDestinationAccent.qualityProfiles.color,
                title: "Quality Profiles",
                subtitle: "Allowed qualities and upgrade rules",
                category: "Library Management",
                keywords: ["profiles", "quality", "upgrade", "cutoff", "sonarr", "radarr"]
            ),
            .init(
                id: "quality-definitions",
                destination: .qualityDefinitions,
                icon: "chart.bar.fill",
                color: MoreDestinationAccent.qualityDefinitions.color,
                title: "Quality Definitions",
                subtitle: "File size limits per quality level",
                category: "Library Management",
                keywords: ["definitions", "quality", "size", "limits", "megabytes"]
            ),
            .init(
                id: "subtitles",
                destination: .subtitleManagement,
                icon: "captions.bubble.fill",
                color: MoreDestinationAccent.subtitleManagement.color,
                title: "Subtitles",
                subtitle: "Language profiles and subtitle providers",
                category: "Library Management",
                keywords: ["bazarr", "captions", "languages", "providers", "missing"]
            ),
            .init(
                id: "language-profiles",
                destination: .bazarrLanguageProfiles,
                icon: "globe",
                color: MoreDestinationAccent.languageProfiles.color,
                title: "Language Profiles",
                subtitle: "Preferred languages and cutoff rules",
                category: "Library Management",
                keywords: ["bazarr", "languages", "cutoff", "profiles", "subtitles"]
            ),
            .init(
                id: "subtitle-providers",
                destination: .bazarrProviders,
                icon: "person.2.fill",
                color: MoreDestinationAccent.providers.color,
                title: "Providers",
                subtitle: "Subtitle provider integrations",
                category: "Library Management",
                keywords: ["bazarr", "provider", "subtitles", "integration", "settings"]
            ),
            .init(
                id: "indexers",
                destination: .prowlarrIndexers,
                icon: "magnifyingglass.circle.fill",
                color: .yellow,
                title: "Indexers",
                subtitle: "Indexers across your services",
                category: "Integrations & Automation",
                keywords: ["prowlarr", "trackers", "search", "sources", "sonarr", "radarr"]
            ),
            .init(
                id: "torrents",
                destination: nil,
                icon: ServiceIdentity.qbittorrent.systemImage,
                color: MoreDestinationAccent.torrentManagement.color,
                title: ServiceIdentity.qbittorrent.displayName,
                subtitle: "Torrents, transfer stats, categories, and RSS feeds",
                category: "Downloads › Client Management",
                keywords: ["qbittorrent", "torrents", "client", "downloads", "rss", "speed"],
                downloadsRoute: .torrents
            ),
            .init(
                id: "transfer-stats",
                destination: nil,
                icon: "chart.line.uptrend.xyaxis",
                color: MoreDestinationAccent.transferStats.color,
                title: "Transfer Stats",
                subtitle: "Speed, session totals, and network info",
                category: "Downloads › qBittorrent",
                keywords: ["qbittorrent", "speed", "upload", "download", "session", "network"],
                downloadsRoute: .transferStats
            ),
            .init(
                id: "categories-tags",
                destination: nil,
                icon: "tag.fill",
                color: MoreDestinationAccent.categoriesAndTags.color,
                title: "Categories & Tags",
                subtitle: "Torrent organization labels",
                category: "Downloads › qBittorrent",
                keywords: ["qbittorrent", "category", "tag", "labels", "organization"],
                downloadsRoute: .categoriesAndTags
            ),
            .init(
                id: "rss-feeds",
                destination: nil,
                icon: "dot.radiowaves.left.and.right",
                color: .cyan,
                title: "RSS Feeds",
                subtitle: "Feeds and automatic download rules",
                category: "Downloads › qBittorrent",
                keywords: ["qbittorrent", "rss", "feeds", "automatic", "rules"],
                downloadsRoute: .rssFeeds
            ),
            .init(
                id: "cleanuparr",
                destination: .cleanuparrDashboard,
                icon: ServiceIdentity.cleanuparr.systemImage,
                color: ServiceIdentity.cleanuparr.brandColor,
                title: "Cleanuparr",
                subtitle: "Cleanup activity, job results, and service health",
                category: "Integrations & Automation",
                keywords: ["cleanup", "strikes", "removals", "malware", "seeding", "health", "jobs"]
            ),
            .init(
                id: "automation-clients",
                destination: .automationClients,
                icon: "gearshape.2.fill",
                color: MoreDestinationAccent.automationClients.color,
                title: "Integrations & Automation",
                subtitle: "Indexers, linked apps, download clients, path mappings, and tasks",
                category: "Integrations & Automation",
                keywords: ["integrations", "links", "applications", "clients", "paths", "routing", "indexers", "tasks", "prowlarr"]
            ),
            .init(
                id: "linked-applications",
                destination: .linkedApplicationsManagement,
                icon: "app.connected.to.app.below.fill",
                color: MoreDestinationAccent.integrations.color,
                title: "Linked Applications",
                subtitle: "Indexer sync, subtitle sync, and request routing",
                category: "Integrations & Automation",
                keywords: ["prowlarr", "bazarr", "seerr", "sync", "routing"]
            ),
            .init(
                id: "indexer-sync",
                destination: .prowlarrLinkedApplications,
                icon: ServiceIdentity.prowlarr.systemImage,
                color: ServiceIdentity.prowlarr.brandColor,
                title: "Indexer Sync",
                subtitle: "Prowlarr linked applications",
                category: "Integrations & Automation",
                keywords: ["prowlarr", "sonarr", "radarr", "linked apps", "sync"]
            ),
            .init(
                id: "subtitle-sync",
                destination: .bazarrLinkedApplications,
                icon: ServiceIdentity.bazarr.systemImage,
                color: ServiceIdentity.bazarr.brandColor,
                title: "Subtitle Sync",
                subtitle: "Bazarr linked applications",
                category: "Integrations & Automation",
                keywords: ["bazarr", "sonarr", "radarr", "linked apps", "sync"]
            ),
            .init(
                id: "request-routing",
                destination: .seerrLinkedApplications,
                icon: ServiceIdentity.seerr.systemImage,
                color: ServiceIdentity.seerr.brandColor,
                title: "Request Routing",
                subtitle: "Seerr linked applications",
                category: "Integrations & Automation",
                keywords: ["seerr", "sonarr", "radarr", "linked apps", "routing"]
            ),
            .init(
                id: "download-clients",
                destination: .downloadClientsManagement,
                icon: ServiceIdentity.qbittorrent.systemImage,
                color: ServiceIdentity.qbittorrent.brandColor,
                title: "Download Clients",
                subtitle: "Sonarr and Radarr download clients",
                category: "Integrations & Automation",
                keywords: ["qbittorrent", "sabnzbd", "sab", "usenet", "nzb", "newsgroup", "torrent", "client", "download", "sonarr", "radarr"]
            ),
            .init(
                id: "sonarr-download-clients",
                destination: .downloadClients(service: .sonarr),
                icon: ServiceIdentity.sonarr.systemImage,
                color: ServiceIdentity.sonarr.brandColor,
                title: "Sonarr Download Clients",
                subtitle: "Torrent and Usenet clients for series grabs",
                category: "Integrations & Automation",
                keywords: ["sonarr", "download", "clients", "qbittorrent", "sabnzbd", "usenet", "nzb", "series"]
            ),
            .init(
                id: "radarr-download-clients",
                destination: .downloadClients(service: .radarr),
                icon: ServiceIdentity.radarr.systemImage,
                color: ServiceIdentity.radarr.brandColor,
                title: "Radarr Download Clients",
                subtitle: "Torrent and Usenet clients for movie grabs",
                category: "Integrations & Automation",
                keywords: ["radarr", "download", "clients", "qbittorrent", "sabnzbd", "usenet", "nzb", "movies"]
            ),
            .init(
                id: "remote-path-mappings",
                destination: .remotePathMappings,
                icon: "arrow.triangle.swap",
                color: MoreDestinationAccent.remotePathMappings.color,
                title: "Remote Path Mappings",
                subtitle: "Remote path mappings for imports",
                category: "Integrations & Automation",
                keywords: ["paths", "mapping", "remote", "local", "downloads", "import"]
            ),
            .init(
                id: "requests-access-hub",
                destination: .requestsAndAccess,
                icon: ServiceIdentity.seerr.systemImage,
                color: MoreDestinationAccent.requestManagement.color,
                title: "Requests & Access",
                subtitle: "Requests, issues, and users",
                category: "Requests & Access",
                keywords: ["seerr", "overseerr", "jellyseerr", "issues", "approval", "users", "accounts"]
            ),
            .init(
                id: "requests",
                destination: .seerrAdmin,
                icon: ServiceIdentity.seerr.systemImage,
                color: MoreDestinationAccent.requestManagement.color,
                title: "Requests",
                subtitle: "Seerr media requests",
                category: "Requests & Access",
                keywords: ["seerr", "overseerr", "jellyseerr", "approval", "discover"]
            ),
            .init(
                id: "issues",
                destination: .seerrIssues,
                icon: "exclamationmark.bubble.fill",
                color: .orange,
                title: "Issues",
                subtitle: "User-reported issues",
                category: "Requests & Access",
                keywords: ["seerr", "problems", "reports", "support"]
            ),
            .init(
                id: "users",
                destination: .unifiedUsers,
                icon: "person.2.fill",
                color: MoreDestinationAccent.userManagement.color,
                title: "Users",
                subtitle: "Jellyfin and Seerr accounts",
                category: "Requests & Access",
                keywords: ["accounts", "permissions", "jellyfin", "seerr", "members"]
            ),
            .init(
                id: "jellyfin",
                destination: .jellyfinManagement,
                icon: "server.rack",
                color: MoreDestinationAccent.jellyfin.color,
                title: "Media Server",
                subtitle: "Sessions, transcoding, and plugins",
                category: "Media Server",
                keywords: ["media server", "users", "activity", "tasks", "transcoding"]
            ),
            .init(
                id: "jellyfin-sessions",
                destination: .jellyfinSessions,
                icon: "play.rectangle.fill",
                color: .green,
                title: "Sessions",
                subtitle: "Active playback sessions",
                category: "Media Server",
                keywords: ["playback", "streaming", "active", "users"]
            ),
            .init(
                id: "jellyfin-libraries",
                destination: .jellyfinLibraries,
                icon: "folder.fill",
                color: .orange,
                title: "Jellyfin Libraries",
                subtitle: "Media libraries and scans",
                category: "Library Management",
                keywords: ["library", "scan", "media", "folders", "collections"]
            ),
            .init(
                id: "jellyfin-transcoding",
                destination: .jellyfinTranscoding,
                icon: "cpu.fill",
                color: ServiceIdentity.jellyfin.brandColor,
                title: "Transcoding",
                subtitle: "Hardware acceleration and playback conversion",
                category: "Media Server",
                keywords: ["transcoding", "hardware acceleration", "hevc", "h265", "nvenc", "playback", "encoding", "av1", "tone mapping"]
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
                subtitle: "Jellyfin background tasks",
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
                category: "Media Server",
                keywords: ["addons", "extensions", "jellyfin", "installed"]
            ),
            .init(
                id: "logs",
                destination: .logsAndEvents,
                icon: "text.document.fill",
                color: .brown,
                title: "Logs",
                subtitle: "Server logs and activity across all services",
                category: "System",
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
                category: "Integrations & Automation",
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
                category: "System",
                keywords: ["update", "version", "software", "sonarr", "radarr", "prowlarr", "bazarr"]
            ),
            .init(
                id: "backups",
                destination: .backupsHub,
                icon: "externaldrive.fill",
                color: .indigo,
                title: "Backups",
                subtitle: "System backups for Sonarr, Radarr, Prowlarr and Bazarr",
                category: "System",
                keywords: ["backup", "restore", "system", "sonarr", "radarr", "prowlarr", "bazarr"]
            ),
            .init(
                id: "system-hub",
                destination: .systemHub,
                icon: "gearshape.arrow.trianglehead.2.clockwise.rotate.90",
                color: MoreDestinationAccent.systemHub.color,
                title: "System",
                subtitle: "Health, disk space, logs, updates, and backups",
                category: "System",
                keywords: ["operations", "health", "disk", "storage", "logs", "events", "updates", "backups"]
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
            ),
            .init(
                id: "sabnzbd-settings",
                destination: .sabnzbdSettings,
                icon: ServiceIdentity.sabnzbd.systemImage,
                color: ServiceIdentity.sabnzbd.brandColor,
                title: "SABnzbd Settings",
                subtitle: "Usenet download client connection and API key",
                category: "Settings",
                keywords: ["sabnzbd", "sab", "usenet", "nzb", "newsgroup", "news server", "queue", "server", "api", "connection", "downloads"]
            ),
            .init(
                id: "qbittorrent-settings",
                destination: .qbittorrentSettings,
                icon: ServiceIdentity.qbittorrent.systemImage,
                color: ServiceIdentity.qbittorrent.brandColor,
                title: "qBittorrent Settings",
                subtitle: "Torrent download client connection and credentials",
                category: "Settings",
                keywords: ["qbittorrent", "qbit", "torrent", "server", "connection", "downloads"]
            )
        ]
    }()
}

/// Standard "service not set up" placeholder shown when a hub's backing service(s)
/// aren't configured. Offers a shortcut to Settings.
private struct HubEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ServiceSetupView(title: title, message: message, systemImage: systemImage)
        .listRowBackground(Color.clear)
    }
}

struct MoreSettingsNavigationLink: View {
    @Environment(\.navigateToSettings) private var navigateToSettings

    var body: some View {
        Button {
            navigateToSettings()
        } label: {
            Text("Open Settings")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
    }
}


private struct LinkedApplicationsManagementView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    /// Which integration's linked apps the detail pane is showing, at regular width.
    /// Nil on iPhone, where the row pushes instead.
    @State private var selectedIntegration: MoreDestination?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @State private var statusModel = LinkedApplicationsStatusViewModel()
    #if DEBUG
    private var skipsStatusRefresh = false
    #endif

    private var hasLinkableServices: Bool {
        arrServiceManager.hasSonarrInstance ||
            arrServiceManager.hasRadarrInstance ||
            arrServiceManager.hasProwlarrInstance ||
            arrServiceManager.hasBazarrInstance ||
            !seerrProfiles.isEmpty
    }

    private var showsDetailPane: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    /// A row that selects beside a detail pane, and pushes without one.
    @ViewBuilder
    private func integrationRow<Label: View>(
        _ destination: MoreDestination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if showsDetailPane {
            label().tag(destination)
        } else {
            NavigationLink(value: destination, label: label)
        }
    }

    /// The right-hand pane: whichever integration's linked apps are selected.
    @ViewBuilder
    private var selectedIntegrationDetail: some View {
        switch selectedIntegration {
        case .prowlarrLinkedApplications:
            if arrServiceManager.prowlarrConnected {
                ProwlarrApplicationsListView()
                    .environment(arrServiceManager)
            } else {
                listDetailPlaceholder("Prowlarr Not Connected", systemImage: ServiceIdentity.prowlarr.systemImage)
            }
        case .bazarrLinkedApplications:
            if arrServiceManager.hasBazarrInstance {
                BazarrLinkedApplicationsListView()
                    .environment(arrServiceManager)
            } else {
                listDetailPlaceholder("Bazarr Not Connected", systemImage: ServiceIdentity.bazarr.systemImage)
            }
        case .seerrLinkedApplications:
            if let client = seerrServiceManager.activeClient {
                SeerrLinkedApplicationsView(apiClient: client)
            } else {
                listDetailPlaceholder("Seerr Not Connected", systemImage: ServiceIdentity.seerr.systemImage)
            }
        default:
            listDetailPlaceholder("Select an Integration", systemImage: "link")
        }
    }

    var body: some View {
        // Two panes at regular width. These three screens answer one question -
        // "is everything pointed at everything else?" - and answering it one screen
        // at a time is what made the configuration audit necessary in the first place.
        TrawlListDetailPanes(title: "Linked Applications") {
            integrationList
        } detail: {
            selectedIntegrationDetail
        }
    }

    private var integrationList: some View {
        List(selection: $selectedIntegration) {
            if !hasLinkableServices {
                HubEmptyState(
                    title: "No Services Configured",
                    systemImage: "app.connected.to.app.below.fill",
                    message: "Connect Prowlarr, Bazarr, Seerr, Sonarr, or Radarr in Settings to manage how they link together."
                )
            } else {
            Section {
                integrationRow(.prowlarrLinkedApplications) {
                    IntegrationRelationshipRow(
                        source: .prowlarr,
                        targets: [.sonarr, .radarr],
                        title: "Indexer Sync",
                        subtitle: "Prowlarr linked applications",
                        status: statusModel.indexerStatus
                    )
                }

                integrationRow(.bazarrLinkedApplications) {
                    IntegrationRelationshipRow(
                        source: .bazarr,
                        targets: [.sonarr, .radarr],
                        title: "Subtitle Sync",
                        subtitle: "Bazarr linked applications",
                        status: statusModel.subtitleStatus
                    )
                }

                integrationRow(.seerrLinkedApplications) {
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
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
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
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var statusModel = DownloadClientsStatusViewModel()
    /// Whose download clients the detail pane is showing, at regular width. Nil on
    /// iPhone, where the row pushes instead.
    @State private var selectedService: MoreDestination?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    #if DEBUG
    private var skipsStatusRefresh = false
    #endif

    private var showsDetailPane: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    /// A row that selects beside a detail pane, and pushes without one.
    @ViewBuilder
    private func clientRow<Label: View>(
        _ destination: MoreDestination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if showsDetailPane {
            label().tag(destination)
        } else {
            NavigationLink(value: destination, label: label)
        }
    }

    /// The right-hand pane: whichever server's client list is selected.
    @ViewBuilder
    private var selectedServiceDetail: some View {
        switch selectedService {
        case .downloadClients(let service):
            ArrDownloadClientListView(serviceType: service)
                .environment(arrServiceManager)
                .environment(inAppNotificationCenter)
        default:
            listDetailPlaceholder("Select a Service", systemImage: "shippingbox.fill")
        }
    }

    private var hasSonarrOrRadarr: Bool {
        arrServiceManager.hasSonarrInstance || arrServiceManager.hasRadarrInstance
    }

    /// Changes whenever a server appears or its connection settles - exactly when
    /// this screen's answer could become knowable, or become wrong.
    private var arrConnectionSignature: String {
        [
            arrServiceManager.hasSonarrInstance,
            arrServiceManager.sonarrConnected,
            arrServiceManager.hasRadarrInstance,
            arrServiceManager.radarrConnected
        ]
        .map(String.init)
        .joined(separator: "-")
    }

    var body: some View {
        // Two panes at regular width. This screen exists to answer "is each server
        // pointed at the right client?", and the answer lives one push away in the
        // list it opens - so on a display wide enough to hold both, hold both.
        TrawlListDetailPanes(title: "Download Clients") {
            serviceList
        } detail: {
            selectedServiceDetail
        }
    }

    private var serviceList: some View {
        List(selection: $selectedService) {
            if !hasSonarrOrRadarr {
                HubEmptyState(
                    title: "No Services Configured",
                    systemImage: "shippingbox.fill",
                    message: "Connect Sonarr or Radarr in Settings to manage their download clients."
                )
            } else {
            Section {
                clientRow(.downloadClients(service: .sonarr)) {
                    IntegrationRelationshipRow(
                        source: .sonarr,
                        targets: [.qbittorrent, .sabnzbd],
                        title: "Sonarr Download Clients",
                        subtitle: "Torrent and Usenet clients for series grabs",
                        status: statusModel.sonarrStatus
                    )
                }

                clientRow(.downloadClients(service: .radarr)) {
                    IntegrationRelationshipRow(
                        source: .radarr,
                        targets: [.qbittorrent, .sabnzbd],
                        title: "Radarr Download Clients",
                        subtitle: "Torrent and Usenet clients for movie grabs",
                        status: statusModel.radarrStatus
                    )
                }
            } footer: {
                Text("Manage where Sonarr and Radarr send downloads.")
            }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .moreDestinationBackground(.integrations)
        .refreshable {
            await statusModel.load(arrServiceManager: arrServiceManager)
        }
        // Keyed on the servers' connection state rather than run once on appear.
        //
        // Instances populate as each server finishes connecting, so a screen opened
        // early asks about a service whose instances have not landed yet and is told
        // there are none - a configured Radarr with two working download clients,
        // reported as "Not set up", and never re-checked because nothing asked
        // again. Re-running when connections settle lets that answer correct itself
        // instead of needing a manual pull-to-refresh.
        .task(id: arrConnectionSignature) {
            #if DEBUG
            guard !skipsStatusRefresh else { return }
            #endif
            await statusModel.load(arrServiceManager: arrServiceManager)
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

    /// Generation of the load currently allowed to publish. A plain `isLoading`
    /// bail dropped the *newer* request, which is the wrong one to lose: loads are
    /// now re-triggered when the servers' connection state settles, and that change
    /// can easily land while the first load - the one asking too early, and getting
    /// the wrong answer - is still in flight.
    private var loadGeneration = 0

    func load(arrServiceManager: ArrServiceManager) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        let sonarr = await loadStatus(for: .sonarr, arrServiceManager: arrServiceManager)
        let radarr = await loadStatus(for: .radarr, arrServiceManager: arrServiceManager)

        // A superseded load must not publish: its answers describe servers as they
        // were before the connection state that superseded it.
        guard generation == loadGeneration else { return }
        sonarrStatus = sonarr
        radarrStatus = radarr
    }

    /// The state of *every* server configured for this service, not whichever one
    /// happens to be resolved.
    ///
    /// This asked `arrServiceManager.sonarrClient` - the single active client -
    /// which predates the service having more than one server. With an HD/4K pair
    /// it reported on one of the two and silently ignored the other, so a second
    /// server with no download client, or a broken one, read as "Connected".
    /// Download clients are configured per server, so the row has to speak for
    /// both.
    private func loadStatus(for serviceType: ArrServiceType, arrServiceManager: ArrServiceManager) async -> IntegrationRelationshipStatus {
        switch serviceType {
        case .sonarr, .radarr:
            break
        case .prowlarr, .bazarr:
            return .notConfigured
        }

        let refs = arrServiceManager.refs(for: serviceType)
        guard !refs.isEmpty else { return .notConfigured }

        var states: [IntegrationTargetState] = []
        var reachedAnyServer = false
        var sawDownloadClient = false

        for ref in refs {
            guard arrServiceManager.isConnected(serviceType, profileID: ref.id),
                  let client = arrServiceManager.sharedClient(for: ref) else {
                // A server Trawl cannot reach may hold a perfectly good download
                // client or none at all - either way the row must not claim
                // everything is fine on its behalf.
                states.append(.notConnected)
                continue
            }
            reachedAnyServer = true

            do {
                let clients = try await client.getDownloadClients()
                guard !clients.isEmpty else {
                    // This server answered and has no download client, so it cannot
                    // grab anything. Contributing nothing here would let its healthy
                    // partner speak for the pair - which is the half-truth this row
                    // exists to stop: a 4K server with no client reads as
                    // "Connected" on the strength of the default server's.
                    states.append(.notConnected)
                    continue
                }
                sawDownloadClient = true
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
            } catch {
                states.append(.notConnected)
            }
        }

        guard reachedAnyServer else { return .error }
        // Reached the servers, and not one of them has a download client. That is
        // a real problem - neither server can grab anything - but it is not the
        // same as the service being unconfigured, which is what this used to say.
        guard sawDownloadClient else { return .warning("No Clients") }

        return Self.aggregate(states)
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
        case .notConfigured: "Not set up"
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

/// Tracks whether the "no language profile" tip has been dismissed during the
/// current app launch. In-memory only, so it resets on every fresh launch -
/// the tip reappears next launch if profiles are still unconfigured.
@MainActor
private enum SubtitleLanguageProfileTipState {
    static var dismissedThisLaunch = false
}

private struct SubtitleManagementView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var showLanguageProfileTip = false

    var body: some View {
        List {
            if !serviceManager.hasBazarrInstance {
                HubEmptyState(
                    title: "Bazarr Not Set Up",
                    systemImage: "captions.bubble",
                    message: "Add a Bazarr server in Settings to manage language profiles and subtitle providers."
                )
            } else {
                if showLanguageProfileTip {
                    Section {
                        TrawlInlineCallout(
                            icon: "globe.badge.chevron.backward",
                            tint: MoreDestinationAccent.languageProfiles.color,
                            title: "No Language Profile",
                            message: "Bazarr needs at least one language profile before it can find subtitles. Create one to get started.",
                            onDismiss: {
                                SubtitleLanguageProfileTipState.dismissedThisLaunch = true
                                withAnimation(.snappy) { showLanguageProfileTip = false }
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

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
                            subtitle: "Subtitle provider integrations"
                        )
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Subtitles")
        .moreDestinationBackground(.subtitleManagement)
        .task { await evaluateLanguageProfileTip() }
    }

    /// Shows the tip when Bazarr is connected but has no language profiles, and
    /// it hasn't already been dismissed this launch.
    private func evaluateLanguageProfileTip() async {
        guard !SubtitleLanguageProfileTipState.dismissedThisLaunch else { return }
        guard serviceManager.hasAnyConnectedBazarrInstance,
              let client = serviceManager.activeBazarrEntry?.client else { return }

        var profiles = serviceManager.activeBazarrEntry?.languageProfiles ?? []
        // Cache may not be populated yet on first visit; confirm with a fetch
        // before deciding there are genuinely no profiles.
        if profiles.isEmpty, let fetched = try? await client.getLanguageProfiles() {
            profiles = fetched
        }

        if profiles.isEmpty {
            withAnimation(.snappy) { showLanguageProfileTip = true }
        }
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


/// Requests & Access - Seerr requests and issues plus unified user management.
/// The children moved here from the former `RequestManagementView` (Requests, Issues)
/// and the old top-level Users row, so they are not duplicated elsewhere.
private struct RequestsAndAccessHubView: View {
    let seerrProfile: SeerrServiceProfile?
    let jellyfinProfile: JellyfinServiceProfile?

    var body: some View {
        List {
            if seerrProfile == nil && jellyfinProfile == nil {
                HubEmptyState(
                    title: "No Services Configured",
                    systemImage: ServiceIdentity.seerr.systemImage,
                    message: "Add a Seerr or Jellyfin server in Settings to manage requests, issues, and users."
                )
            } else {
                Section {
                    if seerrProfile != nil {
                        NavigationLink(value: MoreDestination.seerrAdmin) {
                            NavigationMenuRow(
                                icon: ServiceIdentity.seerr.systemImage,
                                color: MoreDestinationAccent.requestManagement.color,
                                title: "Requests",
                                subtitle: "Seerr media requests"
                            )
                        }

                        NavigationLink(value: MoreDestination.seerrIssues) {
                            NavigationMenuRow(
                                icon: "exclamationmark.bubble.fill",
                                color: .orange,
                                title: "Issues",
                                subtitle: "User-reported issues"
                            )
                        }
                    }

                    if jellyfinProfile != nil {
                        NavigationLink(value: MoreDestination.unifiedUsers) {
                            NavigationMenuRow(
                                icon: "person.2.fill",
                                color: MoreDestinationAccent.userManagement.color,
                                title: "Users",
                                subtitle: "Jellyfin and Seerr accounts"
                            )
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Requests & Access")
        .moreDestinationBackground(.requestManagement)
    }
}

#if DEBUG
#Preview("Requests & Access Hub - Configured") {
    MorePreviewHost(profiles: .allServices) { _ in
        NavigationStack {
            RequestsAndAccessHubView(seerrProfile: .preview(), jellyfinProfile: .preview())
        }
    }
}

#Preview("Requests & Access Hub - Empty") {
    MorePreviewHost(
        profiles: .empty,
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured),
        appServices: nil
    ) { _ in
        NavigationStack {
            RequestsAndAccessHubView(seerrProfile: nil, jellyfinProfile: nil)
        }
    }
}
#endif

/// System - the cross-service operational read-outs. Every child owns its own
/// unavailable state, so the rows stay visible even with nothing configured
/// (matching how these rows behaved on the More dashboard before regrouping).
private struct SystemHubView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(ConfigurationAuditStore.self) private var auditStore
    @Environment(SeerrServiceManager.self) private var seerrServiceManager: SeerrServiceManager?
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager: CleanuparrServiceManager?
    @Query private var qbittorrentServers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @State private var showSetupCheck = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// True where the app draws a sidebar, which is where this hub's rows have rows
    /// of their own.
    private var hasSidebarChrome: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    /// The download clients Trawl itself is connected to. The audit compares these
    /// against what each Arr has been told, which is the whole point of it.
    private var trawlClientHosts: [DownloadClientLinkKind: [String]] {
        ConfigurationAuditInput.trawlClientHosts(
            qbittorrentServers: qbittorrentServers,
            sabnzbdProfiles: sabnzbdProfiles
        )
    }

    private var auditInputRevision: String {
        ConfigurationAuditInput.revision(
            arrServiceManager: arrServiceManager,
            trawlClients: trawlClientHosts,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager
        )
    }

    private var setupCheckSubtitle: String {
        guard auditStore.hasCompletedAnAudit else { return "How your services are wired to each other" }
        let count = auditStore.problemCount
        // A check that could not be run is not a check that passed, so the row never
        // says "nothing needs attention" while something is unverified.
        if count == 0, !auditStore.unknowns.isEmpty {
            return auditStore.unknowns.count == 1 ? "1 check could not be completed" : "\(auditStore.unknowns.count) checks could not be completed"
        }
        if count == 0 { return "Nothing needs attention" }
        return count == 1 ? "1 problem found" : "\(count) problems found"
    }

    var body: some View {
        Group {
            if hasSidebarChrome {
                setupCheckScreen
            } else {
                hubList
            }
        }
        // "System" is the name of the *hub*, and on the sidebar chrome this is no
        // longer a hub - every other row it used to hold has a row of its own, and
        // what is left is the Setup Check itself.
        .navigationTitle(hasSidebarChrome ? "Setup Check" : "System")
        .moreDestinationBackground(.systemHub)
    }

    /// The Setup Check as the screen, where it has a sidebar row of its own.
    ///
    /// Every other row of this hub was promoted, so what remained on iPad and Mac was
    /// a screen whose entire content was one button that opened a sheet - a click
    /// spent on nothing, and a pane of empty space beside it. The wizard is the
    /// screen here. Its fixes push onto the column's own stack rather than into a
    /// modal, which is the same place they would land if the user had navigated to
    /// them by hand.
    private var setupCheckScreen: some View {
        ConfigurationWizardView(
            issues: auditStore.issues,
            onDismissIssue: { auditStore.dismiss($0) },
            onRecheck: { await refreshAudit() },
            presentation: .screen
        )
        .environment(arrServiceManager)
        .refreshesConfigurationAudit()
    }

    private func refreshAudit() async {
        await auditStore.refresh(
            serviceManager: arrServiceManager,
            trawlClients: trawlClientHosts,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager,
            inputRevision: auditInputRevision
        )
    }

    private var hubList: some View {
        List {
            Section {
                Button {
                    showSetupCheck = true
                } label: {
                    NavigationMenuRow(
                        icon: auditStore.problemCount > 0 ? "exclamationmark.triangle.fill" : "checklist",
                        color: auditStore.problemCount > 0 ? .orange : .teal,
                        title: "Setup Check",
                        subtitle: setupCheckSubtitle
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("more-setup-check")

                // Hidden where each of these is a sidebar row of its own: repeating
                // them here would make the screen a menu of things already listed
                // beside it. Setup Check above stays, because it is what this screen
                // is *for* on that chrome.
                if !hasSidebarChrome {
                NavigationLink(value: MoreDestination.health) {
                    NavigationMenuRow(
                        icon: "heart.text.square.fill",
                        color: .pink,
                        title: "Health",
                        subtitle: "Service health checks"
                    )
                }

                NavigationLink(value: MoreDestination.diskSpace) {
                    NavigationMenuRow(
                        icon: "internaldrive.fill",
                        color: MoreDestinationAccent.diskSpace.color,
                        title: "Disk Space",
                        subtitle: "Free space on your media drives"
                    )
                }

                NavigationLink(value: MoreDestination.logsAndEvents) {
                    NavigationMenuRow(
                        icon: "text.document.fill",
                        color: MoreDestinationAccent.logsAndEvents.color,
                        title: "Logs",
                        subtitle: "Server logs and activity across all services"
                    )
                }

                NavigationLink(value: MoreDestination.updatesHub) {
                    NavigationMenuRow(
                        icon: "arrow.down.app.fill",
                        color: MoreDestinationAccent.updates.color,
                        title: "Updates",
                        subtitle: "Software updates for connected services"
                    )
                }

                NavigationLink(value: MoreDestination.backupsHub) {
                    NavigationMenuRow(
                        icon: "externaldrive.fill",
                        color: MoreDestinationAccent.backups.color,
                        title: "Backups",
                        subtitle: "System backups for Sonarr, Radarr, Prowlarr and Bazarr"
                    )
                }
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        // On the List, not on a Section: a sheet attached to a Section inside a
        // List never presents - the Setup Check row toggled its flag and nothing
        // appeared.
        .sheet(isPresented: $showSetupCheck) {
            ConfigurationWizardView(
                issues: auditStore.issues,
                onDismissIssue: { auditStore.dismiss($0) },
                onRecheck: { await refreshAudit() }
            )
            .environment(arrServiceManager)
        }
        .refreshesConfigurationAudit()
        // Returning from a repair re-checks, so the row and the wizard cannot keep
        // reporting a fault the user has just fixed.
        .onChange(of: showSetupCheck) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            Task { await refreshAudit() }
        }
    }
}

#if DEBUG
#Preview("System Hub") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            SystemHubView()
        }
    }
}
#endif

/// Integrations & Automation - indexers, service wiring, and scheduled work. The three
/// service-link children (linked applications, download clients, remote path
/// mappings) moved here from the former `IntegrationsManagementView`, which this
/// hub replaces rather than duplicates.
private struct AutomationAndClientsHubView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.prowlarrIndexers) {
                    NavigationMenuRow(
                        icon: "magnifyingglass.circle.fill",
                        color: MoreDestinationAccent.indexers.color,
                        title: "Indexers",
                        subtitle: "Indexers across your services"
                    )
                }

                NavigationLink(value: MoreDestination.cleanuparrDashboard) {
                    NavigationMenuRow(
                        icon: ServiceIdentity.cleanuparr.systemImage,
                        color: ServiceIdentity.cleanuparr.brandColor,
                        title: "Cleanuparr",
                        subtitle: "Cleanup activity, jobs, and service health"
                    )
                }
            }

            Section("Service Links") {
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
                        icon: "shippingbox.fill",
                        color: MoreDestinationAccent.downloadClients.color,
                        title: "Download Clients",
                        subtitle: "Torrent and Usenet clients used by Sonarr and Radarr"
                    )
                }

                NavigationLink(value: MoreDestination.remotePathMappings) {
                    NavigationMenuRow(
                        icon: "arrow.triangle.swap",
                        color: MoreDestinationAccent.remotePathMappings.color,
                        title: "Remote Path Mappings",
                        subtitle: "Remote path mappings for imports"
                    )
                }
            }

            Section {
                NavigationLink(value: MoreDestination.tasksHub) {
                    NavigationMenuRow(
                        icon: "clock.arrow.2.circlepath",
                        color: MoreDestinationAccent.tasks.color,
                        title: "Tasks",
                        subtitle: "Scheduled tasks across connected services"
                    )
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Integrations & Automation")
        .moreDestinationBackground(.automationClients)
    }
}

#if DEBUG
#Preview("Integrations & Automation Hub") {
    MorePreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) { _ in
        NavigationStack {
            AutomationAndClientsHubView()
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
            } else {
                HubEmptyState(
                    title: "No Services Configured",
                    systemImage: "text.document.fill",
                    message: "Connect a service in Settings to view its logs and events."
                )
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

private struct TasksHubView: View {
    let jellyfinProfile: JellyfinServiceProfile?
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    /// Whose tasks the detail pane is showing, at regular width. Nil on iPhone, where
    /// the row pushes instead.
    @State private var selectedTaskSource: MoreDestination?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    private var hasArrTasks: Bool {
        arrServiceManager.hasSonarrInstance ||
            arrServiceManager.hasRadarrInstance ||
            arrServiceManager.hasProwlarrInstance ||
            arrServiceManager.hasBazarrInstance
    }

    private var hasAnyTaskDestination: Bool {
        hasArrTasks || seerrServiceManager.activeClient != nil || jellyfinServiceManager.activeClient != nil
    }

    private var showsDetailPane: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    /// A row that selects beside a detail pane, and pushes without one.
    @ViewBuilder
    private func taskRow<Label: View>(
        _ destination: MoreDestination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if showsDetailPane {
            label().tag(destination)
        } else {
            NavigationLink(value: destination, label: label)
        }
    }

    /// The right-hand pane: whichever service's tasks are selected.
    @ViewBuilder
    private var selectedTasksDetail: some View {
        switch selectedTaskSource {
        case .arrTasks:
            ArrScheduledTasksView()
                .environment(arrServiceManager)
        case .seerrJobs:
            if let client = seerrServiceManager.activeClient {
                SeerrJobsView(apiClient: client)
            } else {
                listDetailPlaceholder("Seerr Not Connected", systemImage: ServiceIdentity.seerr.systemImage)
            }
        case .jellyfinScheduledTasks:
            if let client = jellyfinServiceManager.activeClient {
                JellyfinScheduledTasksView(apiClient: client)
            } else {
                listDetailPlaceholder("Jellyfin Not Connected", systemImage: ServiceIdentity.jellyfin.systemImage)
            }
        default:
            listDetailPlaceholder("Select a Service", systemImage: "clock.arrow.2.circlepath")
        }
    }

    var body: some View {
        // Two panes at regular width. Scheduled tasks are something you *watch* -
        // kick one off on Sonarr, see whether Seerr's sync has run - and a layout that
        // shows one service at a time makes comparing them a navigation exercise.
        TrawlListDetailPanes(title: "Tasks") {
            taskList
        } detail: {
            selectedTasksDetail
        }
    }

    private var taskList: some View {
        List(selection: $selectedTaskSource) {
            if hasAnyTaskDestination {
                Section {
                    if hasArrTasks {
                        taskRow(.arrTasks) {
                            NavigationMenuRow(
                                icon: "clock.arrow.2.circlepath",
                                color: MoreDestinationAccent.tasks.color,
                                title: "Arr Tasks",
                                subtitle: "Sonarr, Radarr, Prowlarr, and Bazarr tasks"
                            )
                        }
                    }

                    if seerrServiceManager.activeClient != nil {
                        taskRow(.seerrJobs) {
                            NavigationMenuRow(
                                icon: "clock.arrow.2.circlepath",
                                color: ServiceIdentity.seerr.brandColor,
                                title: "Seerr Jobs",
                                subtitle: "Scheduled jobs and background tasks"
                            )
                        }
                    }

                    if jellyfinServiceManager.activeClient != nil {
                        taskRow(.jellyfinScheduledTasks) {
                            NavigationMenuRow(
                                icon: "clock.arrow.2.circlepath",
                                color: ServiceIdentity.jellyfin.brandColor,
                                title: "Jellyfin Tasks",
                                subtitle: "Jellyfin background tasks"
                            )
                        }
                    }
                }
            } else {
                HubEmptyState(
                    title: "No Services Configured",
                    systemImage: "clock.arrow.2.circlepath",
                    message: "Connect Sonarr, Radarr, Prowlarr, Bazarr, Seerr, or Jellyfin in Settings to view scheduled tasks."
                )
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
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
            if jellyfinProfile == nil {
                HubEmptyState(
                    title: "Jellyfin Not Set Up",
                    systemImage: ServiceIdentity.jellyfin.systemImage,
                    message: "Add a Jellyfin server in Settings to view sessions, libraries, transcoding, and plugins."
                )
            } else {
                Section {
                    NavigationLink(value: MoreDestination.jellyfinSessions) {
                        NavigationMenuRow(
                            icon: "play.rectangle.fill",
                            color: .green,
                            title: "Sessions",
                            subtitle: "Active playback sessions"
                        )
                    }

                    NavigationLink(value: MoreDestination.jellyfinTranscoding) {
                        NavigationMenuRow(
                            icon: "cpu.fill",
                            color: ServiceIdentity.jellyfin.brandColor,
                            title: "Transcoding",
                            subtitle: "Hardware acceleration and playback conversion"
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
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Media Server")
        .moreDestinationBackground(.jellyfin)
    }
}

#if DEBUG
#Preview("Media Server Hub") {
    MorePreviewHost(profiles: .jellyfinOnly) { _ in
        NavigationStack {
            JellyfinManagementView(jellyfinProfile: .preview())
        }
    }
}
#endif

/// A mesh gradient built from the brand colours of the services that are actually
/// configured.
///
/// Shared with the Downloads tab, which blends whichever download clients exist -
/// so a qBittorrent-and-SABnzbd setup reads as both, and a setup with one reads as
/// that one. An unconfigured service contributes no colour, which is what stops the
/// background implying a service the user has not set up.
struct MoreServicesGradientBackground: View {
    let services: [ServiceIdentity]

    var body: some View {
        ZStack {
            groupedBackgroundColor

            if !services.isEmpty {
                MeshGradient(
                    width: meshWidth,
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

    /// Four columns for a small palette, three otherwise.
    ///
    /// The extra column is what lets the two colours sit near the middle *and* still
    /// reach the edges. An earlier attempt simply moved the outer points inward,
    /// which brought the colours together but left the mesh undefined beyond its own
    /// hull - black bars down both sides of the screen.
    private var meshWidth: Int { services.count <= 2 ? 4 : 3 }

    private var meshPoints: [SIMD2<Float>] {
        let columns: [Float] = meshWidth == 4 ? [0.0, 0.34, 0.66, 1.0] : [0.0, 0.5, 1.0]
        return [0.0, 0.5, 1.0].flatMap { row in
            columns.map { SIMD2<Float>($0, row) }
        }
    }

    /// With several services, cycling the palette across the mesh reads as a wash of
    /// the whole stack, which is what the More tab wants.
    ///
    /// With one or two it does not. Two colours cycled by `index % 2` land adjacent
    /// on every edge of the grid, and two brand colours that happen to be opposites -
    /// qBittorrent's blue and SABnzbd's orange - smear through grey where they meet.
    /// A small palette therefore gets regions instead: each colour owns a top corner
    /// and fades down through a clear middle, so they never blend into each other.
    private var meshColors: [Color] {
        switch services.count {
        case 1:
            let color = services[0].brandColor
            return [
                color.opacity(0.14), color.opacity(0.26), color.opacity(0.26), color.opacity(0.14),
                color.opacity(0.06), color.opacity(0.11), color.opacity(0.11), color.opacity(0.06),
                .clear, .clear, .clear, .clear
            ]
        case 2:
            let leading = services[0].brandColor
            let trailing = services[1].brandColor
            // The strong anchors sit on the two inner columns, so the colours meet
            // near the middle; the outer columns carry the *same* colour faded, which
            // covers the edges without putting blue next to orange anywhere.
            return [
                leading.opacity(0.12), leading.opacity(0.28), trailing.opacity(0.28), trailing.opacity(0.12),
                leading.opacity(0.05), leading.opacity(0.13), trailing.opacity(0.13), trailing.opacity(0.05),
                .clear, .clear, .clear, .clear
            ]
        default:
            return [
                serviceColor(at: 0, opacity: 0.20), serviceColor(at: 1, opacity: 0.14), serviceColor(at: 2, opacity: 0.18),
                serviceColor(at: 3, opacity: 0.10), serviceColor(at: 4, opacity: 0.08), serviceColor(at: 5, opacity: 0.10),
                serviceColor(at: 6, opacity: 0.05), serviceColor(at: 0, opacity: 0.04), serviceColor(at: 1, opacity: 0.05)
            ]
        }
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
        modifier(MoreDestinationTitleStyle())
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


/// How a More destination titles itself: inline on the phone, large under a sidebar.
///
/// `.inline` everywhere left every promoted sidebar destination with a small centred
/// title floating over the middle of the split - and for the two-pane hubs, over the
/// divider between their own list and detail. Beside Series and Downloads, which draw
/// a large title at the top of their column, those hubs read as untitled. The phone
/// keeps `.inline`, where a large title costs a third of a screen that is already a
/// push deep.
private struct MoreDestinationTitleStyle: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(hSizeClass == .regular ? .large : .inline)
        #else
        content
        #endif
    }
}

struct NotificationSettingsHubView: View {
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
                ServiceErrorView(
                    title: "Notification Settings Unavailable",
                    message: loadError,
                    identity: .seerr,
                    hasContent: true,
                    onRetry: { await load() }
                )
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
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
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

/// Detail screen listing every file in an import job, reached by tapping a multi-file
/// import row in the notifications sheet. Observes the notification center so the
/// live per-file progress ("Processing file 3 of 4") updates while the user watches.
struct ImportJobFilesView: View {
    let jobID: UUID
    /// Snapshot used as a fallback if the live job is removed (e.g. auto-cleared
    /// shortly after success) while this screen is still on screen.
    let snapshot: ActiveImportJob
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    init(job: ActiveImportJob) {
        self.jobID = job.id
        self.snapshot = job
    }

    private var job: ActiveImportJob {
        inAppNotificationCenter.activeImportJobs.first { $0.id == jobID } ?? snapshot
    }

    private var tint: Color {
        switch job.serviceTint {
        case .sonarr: return ServiceIdentity.sonarr.brandColor
        case .radarr: return ServiceIdentity.radarr.brandColor
        case .generic: return .accentColor
        }
    }

    /// State of a single file relative to the server's live progress.
    private enum FileState { case done, current, pending }

    private func state(forIndex index: Int) -> FileState {
        guard job.status == .running else {
            // Finished: succeeded → all done, failed → leave neutral (no false checkmarks).
            return job.status == .succeeded ? .done : .pending
        }
        guard let current = job.currentIndex else { return .pending }
        if index + 1 < current { return .done }
        if index + 1 == current { return .current }
        return .pending
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(job.fileNames.enumerated()), id: \.offset) { index, name in
                    let fileState = state(forIndex: index)
                    HStack(spacing: 10) {
                        fileStateIcon(fileState)
                            .frame(width: 16)
                        Text(name)
                            .font(.subheadline)
                            .fontWeight(fileState == .current ? .semibold : .regular)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Label(headerText, systemImage: job.serviceSystemImage)
                    .foregroundStyle(tint)
            } footer: {
                Text("Importing into \(job.serviceTitle) from \(job.folderName).")
            }
        }
        .animation(.snappy, value: job.currentIndex)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle(job.primaryName)
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var headerText: String {
        let fileWord = job.fileCount == 1 ? "file" : "files"
        if job.status == .running, let current = job.currentIndex, let total = job.progressTotal {
            return "Processing \(current) of \(total)"
        }
        return "\(job.fileCount) \(fileWord)"
    }

    @ViewBuilder
    private func fileStateIcon(_ state: FileState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .current:
            ProgressView()
                .controlSize(.small)
                .tint(tint)
        case .pending:
            Image(systemName: "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
