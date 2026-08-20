import SwiftData
import SwiftUI

struct DownloadClientManagementView: View {
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Query(sort: \ServerProfile.dateAdded) private var qbittorrentServers: [ServerProfile]
    @Query(sort: \SABnzbdServiceProfile.dateAdded) private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @State private var showQBittorrentSetup = false
    @State private var showSABnzbdSetup = false

    var body: some View {
        List {
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

            // qBittorrent is multi-instance, so its add row is always available.
            // SABnzbd is deliberately single-instance — its row only appears
            // while no profile exists.
            Section {
                Button {
                    showQBittorrentSetup = true
                } label: {
                    NavigationMenuRow(
                        icon: "plus.circle.fill",
                        color: ServiceIdentity.qbittorrent.brandColor,
                        title: qbittorrentServers.isEmpty ? "Add qBittorrent" : "Add Another qBittorrent",
                        subtitle: "Connect a torrent client"
                    )
                }
                .buttonStyle(.plain)

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
        .sheet(isPresented: $showQBittorrentSetup) {
            OnboardingSheet(onComplete: {})
        }
        .sheet(isPresented: $showSABnzbdSetup) {
            SABnzbdSetupSheet {
                Task { await sabnzbdServiceManager.initialize(from: sabnzbdProfiles) }
            }
        }
    }
}
