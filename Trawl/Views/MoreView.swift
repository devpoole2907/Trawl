import SwiftUI
import SwiftData

enum MoreDestination: Hashable {
    case activity
    case categoriesAndTags
    case rssFeeds
    case diskSpace
    case health
    case history
    case wanted
    case ssh
    case sshSession
    case settings
    case qbittorrentSettings
    case sonarrSettings
    case radarrSettings
    case prowlarrSettings
    case prowlarrIndexers
    case transferStats
    case blocklist
    case manualImport
    case calendar
    case calendarSeries(id: Int)
    case calendarMovie(id: Int)
    case manualImportScan(path: String, service: ArrServiceType)
}

enum MoreDestinationAccent {
    case calendar
    case manualImport
    case categoriesAndTags
    case transferStats

    var color: Color {
        switch self {
        case .calendar:
            return .purple
        case .manualImport:
            return .blue
        case .categoriesAndTags:
            return .brown
        case .transferStats:
            return .mint
        }
    }
}

struct MoreView: View {
    @Query private var servers: [ServerProfile]
    let appServices: AppServices?
    @Binding var path: [MoreDestination]
    let openSSHSession: () -> Void
    let selectSSHProfile: (SSHProfile) -> Void
    @Environment(SSHSessionStore.self) private var sshSessionStore
    @Environment(ArrServiceManager.self) private var arrServiceManager

    private var hasQBittorrentServer: Bool { !servers.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if sshSessionStore.hasSession {
                    Section("Live Session") {
                        Button {
                            sshSessionStore.focusSession()
                            openSSHSession()
                        } label: {
                            activeSessionRow
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.activity) {
                        moreRow(icon: "arrow.down.doc.fill", color: .indigo,
                                title: "Activity", subtitle: "Queue, downloads, and import history")
                    }

                    NavigationLink(value: MoreDestination.health) {
                        moreRow(icon: "heart.text.square.fill", color: .pink,
                                title: "Health", subtitle: "Service health checks")
                    }

                    NavigationLink(value: MoreDestination.wanted) {
                        moreRow(icon: "exclamationmark.triangle.fill", color: .orange,
                                title: "Wanted / Missing", subtitle: "Monitored items without files")
                    }

                    NavigationLink(value: MoreDestination.calendar) {
                        moreRow(icon: "calendar", color: MoreDestinationAccent.calendar.color,
                                title: "Calendar", subtitle: "Upcoming releases and air dates")
                    }

                    NavigationLink(value: MoreDestination.blocklist) {
                        moreRow(icon: "nosign", color: .red,
                                title: "Blocklist", subtitle: "Releases blocked from being grabbed")
                    }

                    NavigationLink(value: MoreDestination.manualImport) {
                        moreRow(icon: "tray.and.arrow.down.fill", color: MoreDestinationAccent.manualImport.color,
                                title: "Manual Import", subtitle: "Browse and import files from root folders")
                    }

                    NavigationLink(value: MoreDestination.prowlarrIndexers) {
                        moreRow(icon: "magnifyingglass.circle.fill", color: .yellow,
                                title: "Indexers", subtitle: "Manage indexers across your services")
                    }

                    NavigationLink(value: MoreDestination.diskSpace) {
                        moreRow(icon: "internaldrive.fill", color: .teal,
                                title: "Disk Space", subtitle: "Storage usage across Sonarr and Radarr")
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.categoriesAndTags) {
                        moreRow(icon: "tag.fill", color: MoreDestinationAccent.categoriesAndTags.color,
                                title: "Categories & Tags", subtitle: "Manage your torrent organization")
                    }
                    
                    NavigationLink(value: MoreDestination.rssFeeds) {
                        moreRow(icon: "dot.radiowaves.left.and.right", color: .cyan,
                                title: "RSS Feeds", subtitle: "Automatically download from feed rules")
                    }

                    NavigationLink(value: MoreDestination.transferStats) {
                        moreRow(icon: "chart.line.uptrend.xyaxis", color: MoreDestinationAccent.transferStats.color,
                                title: "Transfer Stats", subtitle: "Speed, session totals, and network info")
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.ssh) {
                        sshRow
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
                case .diskSpace:
                    ArrDiskSpaceView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .health:
                    ArrHealthView()
                        .moreDestinationTitleStyle()
                case .history:
                    ArrActivityView()
                        .moreDestinationTitleStyle()
                case .wanted:
                    ArrWantedView()
                        .environment(arrServiceManager)
                        .moreDestinationTitleStyle()
                case .ssh:
                    SSHProfileListView { profile in
                        selectSSHProfile(profile)
                    }
                    .moreDestinationTitleStyle()
                case .sshSession:
                    SSHSessionContainerView()
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
                case .calendarSeries(let id):
                    SonarrSeriesDetailView(seriesId: id, viewModel: SonarrViewModel(serviceManager: arrServiceManager, preloadedSeries: arrServiceManager.calendarViewModel?.sonarrSeries ?? []))
                        .injectSyncService(appServices)
                        .moreDestinationTitleStyle()
                case .calendarMovie(let id):
                    RadarrMovieDetailView(movieId: id, viewModel: RadarrViewModel(serviceManager: arrServiceManager, preloadedMovies: arrServiceManager.calendarViewModel?.radarrMovies ?? []))
                        .injectSyncService(appServices)
                        .moreDestinationTitleStyle()
                case .manualImportScan(let path, let service):
                    ManualImportScanView(path: path, service: service, serviceManager: arrServiceManager)
                        .moreDestinationTitleStyle()
                }
            }
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
                Label("Indexers Not Set Up", systemImage: "magnifyingglass.circle")
            } description: {
                Text("Add a Prowlarr, Sonarr, or Radarr server in Settings to manage your indexers.")
            }
        }
    }

    private var sshRow: some View {
        moreRow(
            icon: "terminal.fill",
            color: .green,
            title: "SSH",
            subtitle: sshSessionStore.hasSession ? "Profiles and active shell access" : "Profiles and remote shell access"
        )
    }

    private var activeSessionRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.green.opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: "terminal")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(sshSessionStore.sessionTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(sshSessionStore.sessionSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(sshSessionStore.statusColor)
                    .frame(width: 8, height: 8)
                Text(sshSessionStore.statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
        }
        .padding(.vertical, 4)
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
                Label("qBittorrent Not Set Up", systemImage: "arrow.down.circle")
            } description: {
                Text("Add a qBittorrent server in Settings to manage your downloads.")
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
            }
        }
    }

    private func moreRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
