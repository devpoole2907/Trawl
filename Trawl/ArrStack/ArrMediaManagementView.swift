import SwiftUI

struct ArrMediaManagementView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        List {
            if serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance {
                namingSection
            }

            filesSection

            storageSection
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Media Management")
        .moreDestinationBackground(.mediaManagement)
    }

    @ViewBuilder
    private var namingSection: some View {
        Section {
            if serviceManager.hasSonarrInstance {
                NavigationLink(value: MoreDestination.arrNamingConfig(service: .sonarr)) {
                    NavigationMenuRow(
                        icon: "tv.fill",
                        color: .purple,
                        title: "Sonarr Naming",
                        subtitle: "Episode and series folder formats"
                    )
                }
            }

            if serviceManager.hasRadarrInstance {
                NavigationLink(value: MoreDestination.arrNamingConfig(service: .radarr)) {
                    NavigationMenuRow(
                        icon: "film.fill",
                        color: .orange,
                        title: "Radarr Naming",
                        subtitle: "Movie file and folder formats"
                    )
                }
            }
        } header: {
            Text("Naming")
        } footer: {
            Text("Control whether files are renamed on import and how they are named.")
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        Section("Files") {
            NavigationLink(value: MoreDestination.rootFolders) {
                NavigationMenuRow(
                    icon: "folder.fill",
                    color: .indigo,
                    title: "Root Folders",
                    subtitle: "Library paths across Sonarr and Radarr"
                )
            }

            NavigationLink(value: MoreDestination.manualImport) {
                NavigationMenuRow(
                    icon: "tray.and.arrow.down.fill",
                    color: .blue,
                    title: "Manual Import",
                    subtitle: "Browse and import files from root folders"
                )
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section("Storage") {
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

}
