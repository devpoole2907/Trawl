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
                    if serviceManager.hasSonarrInstance {
                        NavigationLink(value: MoreDestination.arrNamingConfig(service: .sonarr)) {
                            NavigationMenuRow(
                                icon: ServiceIdentity.sonarr.systemImage,
                                color: ServiceIdentity.sonarr.brandColor,
                                title: "Sonarr Naming",
                                subtitle: "Episode and series folder formats"
                            )
                        }
                    }

                    if serviceManager.hasRadarrInstance {
                        NavigationLink(value: MoreDestination.arrNamingConfig(service: .radarr)) {
                            NavigationMenuRow(
                                icon: ServiceIdentity.radarr.systemImage,
                                color: ServiceIdentity.radarr.brandColor,
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
                                color: ServiceIdentity.sonarr.brandColor,
                                title: "Sonarr Quality Profiles",
                                subtitle: "Allowed qualities and upgrade rules for series"
                            )
                        }
                    }

                    if serviceManager.hasRadarrInstance {
                        NavigationLink(value: MoreDestination.qualityProfiles(service: .radarr)) {
                            NavigationMenuRow(
                                icon: "slider.horizontal.3",
                                color: ServiceIdentity.radarr.brandColor,
                                title: "Radarr Quality Profiles",
                                subtitle: "Allowed qualities and upgrade rules for movies"
                            )
                        }
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
