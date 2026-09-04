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
    /// Which client's hub the detail pane is showing, at regular width. Nil on
    /// iPhone, where the row pushes instead.
    @State private var selectedSource: Source?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// The clients this screen can open. Deliberately not the *Arr* download-client
    /// lists below - those are wiring, and belong to the server that owns them.
    private enum Source: String, Hashable {
        case qbittorrent
        case sabnzbd
    }

    private var showsDetailPane: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        // Two panes at regular width: the clients on the left, whichever one you are
        // working in on the right. Going back to this list for every switch between
        // qBittorrent and SABnzbd is the sort of thing a sidebar-width display exists
        // to stop.
        TrawlListDetailPanes(title: "Download Clients") {
            clientList
        } detail: {
            selectedSourceDetail
        }
    }

    @ViewBuilder
    private var selectedSourceDetail: some View {
        switch selectedSource {
        case .qbittorrent:
            QBittorrentClientHubView()
                .environment(syncService)
                .environment(torrentService)
        case .sabnzbd:
            SABnzbdClientHubView()
                .environment(sabnzbdServiceManager)
                .environment(syncService)
                .environment(torrentService)
        case nil:
            listDetailPlaceholder("Select a Client", systemImage: "arrow.down.circle")
        }
    }

    /// A row that selects beside a detail pane, and pushes without one.
    @ViewBuilder
    private func sourceRow<Destination: View, Label: View>(
        _ source: Source,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if showsDetailPane {
            label().tag(source)
        } else {
            NavigationLink(destination: destination(), label: label)
        }
    }

    private var clientList: some View {
        List(selection: $selectedSource) {
            linkIssueSection

            if !qbittorrentServers.isEmpty || !sabnzbdProfiles.isEmpty {
                Section {
                    if !qbittorrentServers.isEmpty {
                        sourceRow(.qbittorrent) {
                            QBittorrentClientHubView()
                                .environment(syncService)
                                .environment(torrentService)
                        } label: {
                            NavigationMenuRow(
                                icon: "arrow.down.circle.fill",
                                color: ServiceIdentity.qbittorrent.brandColor,
                                title: "qBittorrent",
                                subtitle: "Torrents, stats, categories, RSS, and settings"
                            )
                        }
                    }

                    if !sabnzbdProfiles.isEmpty {
                        sourceRow(.sabnzbd) {
                            SABnzbdClientHubView()
                                .environment(sabnzbdServiceManager)
                                // `SABnzbdManagerView` used to sit under this hub and
                                // read both of these; without them it trapped with "No
                                // Observable object of type SyncService found", which
                                // crashed the app for anyone using SABnzbd. The queue
                                // now lives in the Downloads title menu, but the
                                // hand-over stays: it costs nothing, and the trap it
                                // prevents is a crash rather than a missing view.
                                .environment(syncService)
                                .environment(torrentService)
                        } label: {
                            NavigationMenuRow(
                                icon: ServiceIdentity.sabnzbd.systemImage,
                                color: ServiceIdentity.sabnzbd.brandColor,
                                title: "SABnzbd",
                                subtitle: "Queue, categories, servers, and settings"
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
                Text("This is often fine - a container hostname and a LAN address can be the same server.")
            }
        }
    }
}


/// qBittorrent's own management tools, hung off Downloads → Client Management so the
/// torrent client is symmetrical with SABnzbd's hub.
///
/// Deliberately **client-shaped, not protocol-shaped**: transfer stats, categories/tags
/// and RSS have no SABnzbd analogue (SAB exposes no stats, category, or RSS endpoints),
/// so an umbrella protocol-neutral hub would read as empty-by-accident to a SAB-only
/// user. Naming the hub after the client keeps the empty state predictable.
/// SABnzbd's counterpart to `QBittorrentClientHubView`, laid out the same way:
/// the live queue first, then the configuration the client owns, then settings
/// and logs. Both clients are reached the same way - Downloads → Client
/// Management → the client - rather than one living here and the other buried in
/// app settings.
struct SABnzbdClientHubView: View {
    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService

    var body: some View {
        // The queue itself is not here: it is one of the Downloads tab's own lists,
        // reached from the title menu. Client Management is for configuring the
        // client, not for browsing what it is doing.
        List {
            Section {
                NavigationLink {
                    SABnzbdCategoriesView()
                        .environment(serviceManager)
                } label: {
                    NavigationMenuRow(
                        icon: "tag.fill",
                        color: MoreDestinationAccent.categoriesAndTags.color,
                        title: "Categories & Scripts",
                        subtitle: "Folders, post-processing, and priorities"
                    )
                }

                NavigationLink {
                    SABnzbdNewsServersView()
                        .environment(serviceManager)
                } label: {
                    NavigationMenuRow(
                        icon: "server.rack",
                        color: ServiceIdentity.sabnzbd.brandColor,
                        title: "News Servers",
                        subtitle: "Usenet providers, connections, and SSL"
                    )
                }
            } footer: {
                Text("These tools are specific to SABnzbd. qBittorrent's equivalents live in its own hub.")
            }

            Section {
                NavigationLink {
                    SABnzbdSettingsView()
                        .environment(serviceManager)
                } label: {
                    NavigationMenuRow(
                        icon: "gearshape.fill",
                        color: .secondary,
                        title: "SABnzbd Settings",
                        subtitle: "Connection, speed limit, and queue controls"
                    )
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .paneAwareNavigationTitle("SABnzbd")
    }
}

struct QBittorrentClientHubView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService

    var body: some View {
        // Torrents live in the Downloads tab's title menu, for the same reason the
        // SABnzbd queue does.
        List {
            Section {
                NavigationLink {
                    TorrentStatsView()
                        .environment(syncService)
                } label: {
                    NavigationMenuRow(
                        icon: "chart.line.uptrend.xyaxis",
                        color: MoreDestinationAccent.transferStats.color,
                        title: "Transfer Stats",
                        subtitle: "Speed, session totals, and network info"
                    )
                }

                NavigationLink {
                    QBittorrentCategoriesAndTagsView()
                        .environment(syncService)
                        .environment(torrentService)
                } label: {
                    NavigationMenuRow(
                        icon: "tag.fill",
                        color: MoreDestinationAccent.categoriesAndTags.color,
                        title: "Categories & Tags",
                        subtitle: "Torrent organization labels"
                    )
                }

                NavigationLink {
                    QBittorrentRSSView()
                        .environment(torrentService)
                } label: {
                    NavigationMenuRow(
                        icon: "dot.radiowaves.left.and.right",
                        color: MoreDestinationAccent.rssFeeds.color,
                        title: "RSS Feeds",
                        subtitle: "Feeds and automatic download rules"
                    )
                }
            } footer: {
                Text("These tools are specific to qBittorrent. SABnzbd's equivalents live in its own hub.")
            }

            Section {
                NavigationLink {
                    QBittorrentSettingsView()
                        .environment(syncService)
                        .environment(torrentService)
                } label: {
                    NavigationMenuRow(
                        icon: "gearshape.fill",
                        color: .secondary,
                        title: "qBittorrent Settings",
                        subtitle: "Connection and client preferences"
                    )
                }

                NavigationLink {
                    QBittorrentLogView()
                        .environment(torrentService)
                } label: {
                    NavigationMenuRow(
                        icon: "doc.text.fill",
                        color: ServiceIdentity.qbittorrent.brandColor,
                        title: "qBittorrent Log",
                        subtitle: "Application events and warnings"
                    )
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .paneAwareNavigationTitle("qBittorrent")
    }
}
