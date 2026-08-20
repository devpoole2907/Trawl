import SwiftUI

/// Library Management — everything about what lands on disk and how it is named.
/// Absorbs the former "Media & Import" hub (root folders, imports, naming, quality)
/// and gains subtitles and Jellyfin libraries, so those children live in exactly one
/// place. Disk Space moved out to the System hub.
struct ArrMediaManagementView: View {
    var subtitleBadgeCount: Int = 0
    var hasJellyfin: Bool = false
    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        List {
            Section("Storage & Import") {
                NavigationLink(value: MoreDestination.rootFolders) {
                    NavigationMenuRow(
                        icon: "folder.fill",
                        color: MoreDestinationAccent.rootFolders.color,
                        title: "Root Folders",
                        subtitle: "Library paths across Sonarr and Radarr"
                    )
                }

                NavigationLink(value: MoreDestination.libraryImport) {
                    NavigationMenuRow(
                        icon: "square.and.arrow.down.on.square.fill",
                        color: MoreDestinationAccent.libraryImport.color,
                        title: "Library Import",
                        subtitle: "Import an existing organized library"
                    )
                }

                NavigationLink(value: MoreDestination.manualImport) {
                    NavigationMenuRow(
                        icon: "tray.and.arrow.down.fill",
                        color: MoreDestinationAccent.manualImport.color,
                        title: "Manual Import",
                        subtitle: "Import files into titles already in your library"
                    )
                }
            }

            if serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance {
                Section("Profiles & Naming") {
                    NavigationLink(value: MoreDestination.arrNaming) {
                        NavigationMenuRow(
                            icon: "character.cursor.ibeam",
                            color: MoreDestinationAccent.sonarrNaming.color,
                            title: "Naming",
                            subtitle: "Episode, series, and movie file name formats"
                        )
                    }

                    NavigationLink(value: MoreDestination.qualityProfiles) {
                        NavigationMenuRow(
                            icon: "slider.horizontal.3",
                            color: MoreDestinationAccent.qualityProfiles.color,
                            title: "Quality Profiles",
                            subtitle: "Allowed qualities and upgrade rules"
                        )
                    }

                    NavigationLink(value: MoreDestination.qualityDefinitions) {
                        NavigationMenuRow(
                            icon: "chart.bar.fill",
                            color: MoreDestinationAccent.qualityDefinitions.color,
                            title: "Quality Definitions",
                            subtitle: "File size limits per quality level"
                        )
                    }
                }
            }

            Section("Subtitles & Media Server") {
                NavigationLink(value: MoreDestination.subtitleManagement) {
                    NavigationMenuRow(
                        icon: "captions.bubble.fill",
                        color: MoreDestinationAccent.subtitleManagement.color,
                        title: "Subtitles",
                        subtitle: subtitleBadgeCount > 0
                            ? "\(subtitleBadgeCount) items need subtitles"
                            : "Subtitle languages, providers, and history"
                    )
                }

                NavigationLink(value: MoreDestination.jellyfinLibraries) {
                    NavigationMenuRow(
                        icon: "folder.fill",
                        color: MoreDestinationAccent.jellyfin.color,
                        title: "Jellyfin Libraries",
                        subtitle: hasJellyfin ? "Media libraries and scans" : "Requires Jellyfin"
                    )
                }
            }
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Library Management")
        .moreDestinationBackground(.mediaManagement)
    }

}

#if DEBUG
#Preview("Media Management - Configured") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrMediaManagementView()
        }
    }
}

#Preview("Media Management - Empty") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        NavigationStack {
            ArrMediaManagementView()
        }
    }
}
#endif
