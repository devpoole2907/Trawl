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
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sonarr Naming")
                                .font(.body)
                            Text("Episode and series folder formats")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        serviceIcon(systemImage: "tv.fill", color: .purple)
                    }
                }
            }

            if serviceManager.hasRadarrInstance {
                NavigationLink(value: MoreDestination.arrNamingConfig(service: .radarr)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Radarr Naming")
                                .font(.body)
                            Text("Movie file and folder formats")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        serviceIcon(systemImage: "film.fill", color: .orange)
                    }
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
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Root Folders")
                            .font(.body)
                        Text("Library paths across Sonarr and Radarr")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    serviceIcon(systemImage: "folder.fill", color: .indigo)
                }
            }

            NavigationLink(value: MoreDestination.manualImport) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manual Import")
                            .font(.body)
                        Text("Browse and import files from root folders")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    serviceIcon(systemImage: "tray.and.arrow.down.fill", color: .blue)
                }
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section("Storage") {
            NavigationLink(value: MoreDestination.diskSpace) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disk Space")
                            .font(.body)
                        Text("Storage usage across Sonarr and Radarr")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    serviceIcon(systemImage: "internaldrive.fill", color: .teal)
                }
            }
        }
    }

    private func serviceIcon(systemImage: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
        }
    }
}
