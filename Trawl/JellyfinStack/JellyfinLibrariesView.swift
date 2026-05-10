import SwiftUI

struct JellyfinLibrariesView: View {
    let apiClient: JellyfinAPIClient
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var folders: [JellyfinVirtualFolder] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var scanningAll = false

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && folders.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if folders.isEmpty {
                ContentUnavailableView(
                    "No Libraries",
                    systemImage: "folder",
                    description: Text("No media libraries were returned by Jellyfin.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(folders) { folder in
                        libraryRow(folder)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .background(MoreDestinationGradientBackground(accent: .seerr))
        .navigationTitle("Libraries")
        .refreshable { await loadLibraries() }
        .task { await loadLibraries() }
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button {
                    Task { await scanAllLibraries() }
                } label: {
                    if scanningAll {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Scan All", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(scanningAll || folders.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func libraryRow(_ folder: JellyfinVirtualFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.collectionIcon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.body)
                if let locations = folder.locations.first {
                    Text(locations)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task { await scanLibrary(folder) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func loadLibraries() async {
        isLoading = true
        errorMessage = nil
        do {
            folders = try await apiClient.getVirtualFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func scanLibrary(_ folder: JellyfinVirtualFolder) async {
        inAppNotificationCenter.showProgress(
            title: "Scanning \(folder.name)",
            message: "Triggering library scan…",
            key: "jellyfin_scan_\(folder.itemId)",
            source: .inApp
        )
        do {
            try await apiClient.refreshItem(id: folder.itemId)
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_scan_\(folder.itemId)",
                title: "Scan Started",
                message: "Scan of \(folder.name) has been triggered."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_scan_\(folder.itemId)",
                title: "Scan Failed",
                message: error.localizedDescription
            )
        }
    }

    private func scanAllLibraries() async {
        scanningAll = true
        inAppNotificationCenter.showProgress(
            title: "Scanning All Libraries",
            message: "Triggering full library scan…",
            key: "jellyfin_scan_all",
            source: .inApp
        )
        do {
            try await apiClient.refreshAllLibraries()
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_scan_all",
                title: "Scan Started",
                message: "Full library scan has been triggered."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_scan_all",
                title: "Scan Failed",
                message: error.localizedDescription
            )
        }
        scanningAll = false
    }
}
