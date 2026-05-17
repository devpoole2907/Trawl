import SwiftUI

struct ArrMediaManagementView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        List {
            Section {
                NavigationLink(value: MoreDestination.rootFolders) {
                    NavigationMenuRow(
                        icon: "folder.fill",
                        color: .indigo,
                        title: "Root Folders",
                        subtitle: "Library paths across Sonarr and Radarr"
                    )
                }
            }

            if serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance {
                Section {
                    NavigationLink(value: MoreDestination.arrNaming) {
                        NavigationMenuRow(
                            icon: "character.cursor.ibeam",
                            color: .purple,
                            title: "Naming",
                            subtitle: "Episode, series, and movie file name formats"
                        )
                    }
                }
            }

            if serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance {
                Section {
                    NavigationLink(value: MoreDestination.qualityProfiles) {
                        NavigationMenuRow(
                            icon: "slider.horizontal.3",
                            color: .cyan,
                            title: "Quality Profiles",
                            subtitle: "Allowed qualities and upgrade rules"
                        )
                    }

                    NavigationLink(value: MoreDestination.qualityDefinitions) {
                        NavigationMenuRow(
                            icon: "chart.bar.fill",
                            color: .mint,
                            title: "Quality Definitions",
                            subtitle: "File size limits per quality level"
                        )
                    }
                }
            }

            Section {
                NavigationLink(value: MoreDestination.manualImport) {
                    NavigationMenuRow(
                        icon: "tray.and.arrow.down.fill",
                        color: .blue,
                        title: "Manual Import",
                        subtitle: "Browse and import files from root folders"
                    )
                }
            }

            Section {
                NavigationLink(value: MoreDestination.diskSpace) {
                    NavigationMenuRow(
                        icon: "internaldrive.fill",
                        color: .teal,
                        title: "Disk Space",
                        subtitle: "Storage usage across Sonarr and Radarr"
                    )
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
