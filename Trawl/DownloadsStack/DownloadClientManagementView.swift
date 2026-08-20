import SwiftData
import SwiftUI

struct DownloadClientManagementView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query(sort: \ServerProfile.dateAdded) private var qbittorrentServers: [ServerProfile]
    @Query(sort: \SABnzbdServiceProfile.dateAdded) private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @State private var showQBittorrentSetup = false
    @State private var showSABnzbdSetup = false
    @State private var links: [DownloadClientLink] = []
    @State private var pendingArrLink: DownloadClientLink?

    var body: some View {
        List {
            linkIssueSection

            if !qbittorrentServers.isEmpty || !sabnzbdProfiles.isEmpty {
                Section {
                    if !qbittorrentServers.isEmpty {
                        NavigationLink {
                            TorrentListView(title: "qBittorrent")
                                .environment(syncService)
                                .environment(torrentService)
                        } label: {
                            NavigationMenuRow(
                                icon: "arrow.down.circle.fill",
                                color: ServiceIdentity.qbittorrent.brandColor,
                                title: "qBittorrent",
                                subtitle: "Torrents, seeding, peers, files, and limits"
                            )
                        }
                    }

                    if !sabnzbdProfiles.isEmpty {
                        NavigationLink {
                            SABnzbdManagerView()
                                .environment(sabnzbdServiceManager)
                        } label: {
                            NavigationMenuRow(
                                icon: ServiceIdentity.sabnzbd.systemImage,
                                color: ServiceIdentity.sabnzbd.brandColor,
                                title: "SABnzbd",
                                subtitle: "Queue, repairs, unpacking, and history"
                            )
                        }
                    }
                }
            }

            // Both clients are single-instance for now, so each add row only appears
            // while no profile of that kind exists.
            Section {
                if qbittorrentServers.isEmpty {
                    Button {
                        showQBittorrentSetup = true
                    } label: {
                        NavigationMenuRow(
                            icon: "plus.circle.fill",
                            color: ServiceIdentity.qbittorrent.brandColor,
                            title: "Add qBittorrent",
                            subtitle: "Connect a torrent client"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if sabnzbdProfiles.isEmpty {
                    Button {
                        showSABnzbdSetup = true
                    } label: {
                        NavigationMenuRow(
                            icon: "plus.circle.fill",
                            color: ServiceIdentity.sabnzbd.brandColor,
                            title: "Add SABnzbd",
                            subtitle: "Connect a Usenet client"
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if qbittorrentServers.isEmpty && sabnzbdProfiles.isEmpty {
                    Text("No Download Clients")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Download Clients")
        .task(id: linkCheckKey) {
            links = await DownloadClientLinkChecker.check(kinds: trawlClientHosts, serviceManager: arrServiceManager)
        }
        .sheet(item: $pendingArrLink) { link in
            NavigationStack {
                ArrDownloadClientEditorSheet(
                    serviceType: link.service,
                    initialImplementation: link.kind.arrImplementation
                ) { saved in
                    inAppNotificationCenter.showSuccess(
                        title: "Added",
                        message: "\(saved.name ?? link.kind.displayName) added to \(link.service.displayName)."
                    )
                    Task {
                        links = await DownloadClientLinkChecker.check(
                            kinds: trawlClientHosts,
                            serviceManager: arrServiceManager
                        )
                    }
                }
                .environment(arrServiceManager)
            }
        }
        .sheet(isPresented: $showQBittorrentSetup) {
            OnboardingSheet(onComplete: {})
        }
        .sheet(isPresented: $showSABnzbdSetup) {
            SABnzbdSetupSheet {
                Task { await sabnzbdServiceManager.initialize(from: sabnzbdProfiles) }
            }
        }
    }

    /// The clients Trawl itself is configured against, keyed by kind, with the host
    /// each one points at. Only these can be checked against the Arrs.
    private var trawlClientHosts: [DownloadClientLinkKind: String] {
        var hosts: [DownloadClientLinkKind: String] = [:]
        if let server = qbittorrentServers.first(where: { $0.isActive }) ?? qbittorrentServers.first {
            hosts[.qbittorrent] = server.hostURL
        }
        if let profile = sabnzbdProfiles.first(where: { $0.isEnabled }) ?? sabnzbdProfiles.first {
            hosts[.sabnzbd] = profile.hostURL
        }
        return hosts
    }

    /// Rerun the check when either side changes: a client added or removed in Trawl,
    /// or an Arr coming online (it can't be queried while disconnected).
    private var linkCheckKey: String {
        let kinds = trawlClientHosts.keys.map(\.rawValue).sorted().joined(separator: ",")
        return "\(kinds)-\(arrServiceManager.sonarrConnected)-\(arrServiceManager.radarrConnected)"
    }

    @ViewBuilder
    private var linkIssueSection: some View {
        let problems = links.filter(\.isProblem)
        let notes = links.filter(\.isNote)

        if !problems.isEmpty {
            Section {
                ForEach(problems) { link in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(link.service.displayName) isn't using this \(link.kind.displayName)")
                            .font(.subheadline.weight(.semibold))

                        Text("\(link.service.displayName) has no enabled \(link.kind.displayName) download client, so its grabs won't appear in the queue Trawl is showing you.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Add to \(link.service.displayName)") {
                            pendingArrLink = link
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Not Connected")
                }
                .foregroundStyle(.orange)
                .font(.footnote.weight(.semibold))
                .textCase(nil)
            }
            .animation(.snappy, value: problems)
        }

        if !notes.isEmpty {
            Section {
                ForEach(notes) { link in
                    if case .differentHost(let host) = link.state {
                        Text("\(link.service.displayName)'s \(link.kind.displayName) client points at \(host), not the host Trawl uses.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("This is often fine — a container hostname and a LAN address can be the same server.")
            }
        }
    }
}
