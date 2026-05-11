import SwiftUI

struct ArrMediaManagementView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        List {
            namingSection
        }
        #if os(iOS)
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Media Management")
        .moreDestinationBackground(.mediaManagement)
    }

    @ViewBuilder
    private var namingSection: some View {
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
