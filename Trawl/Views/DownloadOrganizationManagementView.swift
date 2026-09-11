import SwiftUI

/// The shared organization controls for qBittorrent and SABnzbd.
///
/// Categories belong together because both clients expose them, while tags and
/// scripts remain separate because each is owned by only one client. On a regular
/// width window this is the middle column of Trawl's root split view; compact
/// navigation pushes the same detail screens.
enum DownloadOrganizationDestination: Hashable {
    case categories
    case tags
    case scripts
}

struct DownloadOrganizationManagementView: View {
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(TrawlColumnSelection<DownloadOrganizationDestination>.self) private var sharedSelection: TrawlColumnSelection<DownloadOrganizationDestination>?
    @State private var localSelection = TrawlColumnSelection<DownloadOrganizationDestination>()

    private var selectionStore: TrawlColumnSelection<DownloadOrganizationDestination> {
        sidebarColumn == nil ? localSelection : (sharedSelection ?? localSelection)
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    @ViewBuilder
    var body: some View {
        if sidebarColumn == nil {
            panes
                .navigationDestination(for: DownloadOrganizationDestination.self) { destination in
                    detail(for: destination)
                }
        } else {
            panes
        }
    }

    private var panes: some View {
        TrawlListDetailPanes(title: "Categories, Tags & Scripts") {
            List(selection: showsDetailPane ? selectionStore.binding : nil) {
                Section {
                    organizationRow(.categories) {
                        NavigationMenuRow(
                            icon: "tag.fill",
                            color: MoreDestinationAccent.categoriesAndTags.color,
                            title: "Categories",
                            subtitle: "qBittorrent and SABnzbd download rules"
                        )
                    }

                    organizationRow(.tags) {
                        NavigationMenuRow(
                            icon: "number",
                            color: MoreDestinationAccent.categoriesAndTags.color,
                            title: "Tags",
                            subtitle: "qBittorrent torrent labels"
                        )
                    }

                    organizationRow(.scripts) {
                        NavigationMenuRow(
                            icon: "terminal",
                            color: ServiceIdentity.sabnzbd.brandColor,
                            title: "Scripts",
                            subtitle: "SABnzbd post-processing scripts"
                        )
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        } detail: {
            selectedDetail
        }
    }

    @ViewBuilder
    private func organizationRow<Label: View>(
        _ destination: DownloadOrganizationDestination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if showsDetailPane {
            label().tag(destination)
        } else {
            NavigationLink(value: destination, label: label)
        }
    }

    @ViewBuilder
    private var selectedDetail: some View {
        if let selection = selectionStore.selection {
            detail(for: selection)
        } else {
            listDetailPlaceholder("Select a Setting", systemImage: "tag")
        }
    }

    @ViewBuilder
    private func detail(for destination: DownloadOrganizationDestination) -> some View {
        switch destination {
        case .categories:
            DownloadOrganizationCategoriesView()
        case .tags:
            QBittorrentCategoriesAndTagsView(section: .tags)
                .navigationTitle("Tags")
                .navigationSubtitle("qBittorrent")
        case .scripts:
            SABnzbdCategoriesView(section: .scripts)
                .navigationTitle("Scripts")
                .navigationSubtitle("SABnzbd")
        }
    }
}

private struct DownloadOrganizationCategoriesView: View {
    @State private var selectedClient = ServiceIdentity.qbittorrent

    var body: some View {
        // Keep both category configurations mounted. Switching clients now changes
        // the data shown by this one detail screen instead of replacing its view
        // hierarchy, navigation state, and toolbar.
        ZStack {
            QBittorrentCategoriesAndTagsView(
                section: .categories,
                isPresented: selectedClient == .qbittorrent
            )
            .opacity(selectedClient == .qbittorrent ? 1 : 0)
            .allowsHitTesting(selectedClient == .qbittorrent)
            .accessibilityHidden(selectedClient != .qbittorrent)

            SABnzbdCategoriesView(
                section: .categories,
                isPresented: selectedClient == .sabnzbd
            )
            .opacity(selectedClient == .sabnzbd ? 1 : 0)
            .allowsHitTesting(selectedClient == .sabnzbd)
            .accessibilityHidden(selectedClient != .sabnzbd)
        }
        .navigationTitle("Categories")
        .navigationSubtitle(selectedClient.displayName)
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Client",
                selection: $selectedClient,
                items: [
                    TrawlSegmentBarItem("qBittorrent", value: .qbittorrent),
                    TrawlSegmentBarItem("SABnzbd", value: .sabnzbd)
                ],
                alignment: .center
            )
        }
    }
}
