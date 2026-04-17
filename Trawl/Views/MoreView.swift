import SwiftUI

enum MoreDestination: Hashable {
    case activity
    case categories
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

                    NavigationLink(value: MoreDestination.diskSpace) {
                        moreRow(icon: "internaldrive.fill", color: .teal,
                                title: "Disk Space", subtitle: "Storage usage across Sonarr and Radarr")
                    }

                    NavigationLink(value: MoreDestination.wanted) {
                        moreRow(icon: "exclamationmark.triangle.fill", color: .orange,
                                title: "Wanted / Missing", subtitle: "Monitored items without files")
                    }

                    NavigationLink(value: MoreDestination.categories) {
                        moreRow(icon: "tag.fill", color: .blue,
                                title: "Categories", subtitle: "Create and remove qBittorrent categories")
                    }

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
                case .categories:
                    qbittorrentCategoriesDestination
                case .diskSpace:
                    ArrDiskSpaceView()
                        .environment(arrServiceManager)
                case .health:
                    ArrHealthView()
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.large)
                        #endif
                case .history:
                    ArrActivityView()
                case .wanted:
                    ArrWantedView()
                        .environment(arrServiceManager)
                case .ssh:
                    SSHProfileListView { profile in
                        selectSSHProfile(profile)
                    }
                case .sshSession:
                    SSHSessionView()
                case .settings:
                    settingsDestination
                case .qbittorrentSettings:
                    qbittorrentSettingsDestination
                case .sonarrSettings:
                    ArrServiceSettingsView(serviceType: .sonarr)
                        .environment(arrServiceManager)
                case .radarrSettings:
                    ArrServiceSettingsView(serviceType: .radarr)
                        .environment(arrServiceManager)
                }
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
        if let services = appServices {
            SettingsView(showsDoneButton: false)
                .environment(services.syncService)
                .environment(services.torrentService)
                .environment(arrServiceManager)
        } else {
            SettingsView(showsDoneButton: false)
                .environment(arrServiceManager)
        }
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
    private var qbittorrentCategoriesDestination: some View {
        if let services = appServices {
            QBittorrentCategoriesView()
                .environment(services.syncService)
                .environment(services.torrentService)
        } else {
            ContentUnavailableView {
                Label("qBittorrent Not Set Up", systemImage: "tag")
            } description: {
                Text("Add a qBittorrent server in Settings before managing categories.")
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
