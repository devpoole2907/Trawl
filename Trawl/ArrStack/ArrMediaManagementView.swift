import SwiftUI

struct ArrMediaManagementView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        List {
            if serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance {
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
                }
            }

            if serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance {
                Section {
                    if serviceManager.hasSonarrInstance {
                        NavigationLink(value: MoreDestination.qualityProfiles(service: .sonarr)) {
                            NavigationMenuRow(
                                icon: "slider.horizontal.3",
                                color: .purple,
                                title: "Sonarr Quality Profiles",
                                subtitle: "Allowed qualities and upgrade rules for series"
                            )
                        }
                    }

                    if serviceManager.hasRadarrInstance {
                        NavigationLink(value: MoreDestination.qualityProfiles(service: .radarr)) {
                            NavigationMenuRow(
                                icon: "slider.horizontal.3",
                                color: .orange,
                                title: "Radarr Quality Profiles",
                                subtitle: "Allowed qualities and upgrade rules for movies"
                            )
                        }
                    }
                }
            }

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
        .navigationTitle("Media Management")
        .moreDestinationBackground(.mediaManagement)
    }

}
