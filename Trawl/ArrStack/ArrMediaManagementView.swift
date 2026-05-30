import SwiftUI

struct ArrMediaManagementView: View {
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

                NavigationLink(value: MoreDestination.manualImport) {
                    NavigationMenuRow(
                        icon: "tray.and.arrow.down.fill",
                        color: MoreDestinationAccent.manualImport.color,
                        title: "Manual Import",
                        subtitle: "Browse and import files from root folders"
                    )
                }

                NavigationLink(value: MoreDestination.diskSpace) {
                    NavigationMenuRow(
                        icon: "internaldrive.fill",
                        color: MoreDestinationAccent.diskSpace.color,
                        title: "Disk Space",
                        subtitle: "Storage usage across Sonarr and Radarr"
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
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Media & Import")
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
