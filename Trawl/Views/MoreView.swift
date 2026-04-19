import SwiftUI

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
    case calendar
}

struct MoreView: View {
    let appServices: AppServices?
    @Binding var path: [MoreDestination]
    let openSSHSession: () -> Void
    let selectSSHProfile: (SSHProfile) -> Void
    @Environment(SSHSessionStore.self) private var sshSessionStore
    @Environment(ArrServiceManager.self) private var arrServiceManager

    var body: some View {
        NavigationStack(path: $path) {
            List {
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
                        moreRow(icon: "calendar", color: .purple,
                                title: "Calendar", subtitle: "Upcoming releases and air dates")
                    }

                    NavigationLink(value: MoreDestination.blocklist) {
                        moreRow(icon: "nosign", color: .red,
                                title: "Blocklist", subtitle: "Releases blocked from being grabbed")
                    }

                    NavigationLink(value: MoreDestination.prowlarrIndexers) {
                        moreRow(icon: "magnifyingglass.circle.fill", color: .yellow,
                                title: "Indexers", subtitle: "Manage Prowlarr indexers")
                    }

                    NavigationLink(value: MoreDestination.diskSpace) {
                        moreRow(icon: "internaldrive.fill", color: .teal,
                                title: "Disk Space", subtitle: "Storage usage across Sonarr and Radarr")
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.categoriesAndTags) {
                        moreRow(icon: "tag.fill", color: .blue,
                                title: "Categories & Tags", subtitle: "Manage your torrent organization")
                    }
                    
                    NavigationLink(value: MoreDestination.rssFeeds) {
                        moreRow(icon: "dot.radiowaves.left.and.right", color: .cyan,
                                title: "RSS Feeds", subtitle: "Automatically download from feed rules")
                    }

                    NavigationLink(value: MoreDestination.transferStats) {
                        moreRow(icon: "chart.line.uptrend.xyaxis", color: .blue,
                                title: "Transfer Stats", subtitle: "Speed, session totals, and network info")
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.ssh) {
                        sshRow
                    }
                }

                if sshSessionStore.hasSession {
                    Section("Live Session") {
                        Button {
                            sshSessionStore.focusSession()
                            openSSHSession()
                        } label: {
                            activeSessionRow
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    NavigationLink(value: MoreDestination.settings) {
                        moreRow(icon: "gearshape.fill", color: .secondary,
                                title: "Settings", subtitle: "App and server configuration")
                    }
                }
            }
            .listStyle(.insetGrouped)
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
                    SSHSessionView()
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
                case .calendar:
                    ArrCalendarView()
                        .environment(arrServiceManager)
                        .injectSyncService(appServices)
                        .moreDestinationTitleStyle()
                }
            }
            .navigationDestination(for: CalendarSeriesDestination.self) { dest in
                SonarrSeriesDetailView(seriesId: dest.id, viewModel: SonarrViewModel(serviceManager: arrServiceManager, preloadedSeries: arrServiceManager.calendarViewModel?.sonarrSeries ?? []))
                    .injectSyncService(appServices)
                    .moreDestinationTitleStyle()
            }
            .navigationDestination(for: CalendarMovieDestination.self) { dest in
                RadarrMovieDetailView(movieId: dest.id, viewModel: RadarrViewModel(serviceManager: arrServiceManager, preloadedMovies: arrServiceManager.calendarViewModel?.radarrMovies ?? []))
                    .injectSyncService(appServices)
                    .moreDestinationTitleStyle()
            }
        }
    }

    @ViewBuilder
    private var transferStatsDestination: some View {
        if let services = appServices {
            TorrentStatsView()
                .environment(services.syncService)
        } else {
            ContentUnavailableView {
                Label("qBittorrent Not Connected", systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text("Connect a qBittorrent server to view transfer statistics.")
            }
        }
    }

    @ViewBuilder
    private var prowlarrIndexersDestination: some View {
        if arrServiceManager.prowlarrConnected {
            ProwlarrIndexerListView()
                .environment(arrServiceManager)
        } else {
            ContentUnavailableView {
                Label("Prowlarr Not Set Up", systemImage: "magnifyingglass.circle")
            } description: {
                Text("Add a Prowlarr server in Settings to manage your indexers.")
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

private extension View {
    @ViewBuilder
    func moreDestinationTitleStyle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
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
