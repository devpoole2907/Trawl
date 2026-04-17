import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
import CoreServices
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Query private var servers: [ServerProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @State private var viewModel = SettingsViewModel()
    @AppStorage("tmdb.apiKey") private var tmdbAPIKey: String = ""
    let showsDoneButton: Bool
    @Environment(\.navigateToQbittorrentSettings) private var navigateToQbittorrentSettings
    @Environment(\.navigateToSonarrSettings) private var navigateToSonarrSettings
    @Environment(\.navigateToRadarrSettings) private var navigateToRadarrSettings

    init(showsDoneButton: Bool = true) {
        self.showsDoneButton = showsDoneButton
    }

    var body: some View {
        settingsForm
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task {
                viewModel.configure(torrentService: torrentService, syncService: syncService, arrServiceManager: arrServiceManager)
                await viewModel.loadSettings(modelContext: modelContext)
            }
    }

    // MARK: - Computed

    private var activeServer: ServerProfile? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var sonarrProfile: ArrServiceProfile? {
        arrProfiles.first(where: { $0.resolvedServiceType == .sonarr })
    }

    private var radarrProfile: ArrServiceProfile? {
        arrProfiles.first(where: { $0.resolvedServiceType == .radarr })
    }

    // MARK: - Form

    private var settingsForm: some View {
        Form {
            Section("Services") {
                Button(action: navigateToQbittorrentSettings) {
                    serviceRow(
                        icon: "arrow.down.circle.fill", color: .blue,
                        name: activeServer?.displayName ?? "qBittorrent",
                        url: activeServer?.hostURL,
                        isConnected: syncService.isPolling,
                        isConfigured: activeServer != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: navigateToSonarrSettings) {
                    serviceRow(
                        icon: "tv.fill", color: .purple,
                        name: sonarrProfile?.displayName ?? "Sonarr",
                        url: sonarrProfile?.hostURL,
                        isConnected: arrServiceManager.sonarrConnected,
                        isConfigured: sonarrProfile != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: navigateToRadarrSettings) {
                    serviceRow(
                        icon: "film.fill", color: .orange,
                        name: radarrProfile?.displayName ?? "Radarr",
                        url: radarrProfile?.hostURL,
                        isConnected: arrServiceManager.radarrConnected,
                        isConfigured: radarrProfile != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section {
                SecureField("API Key", text: $tmdbAPIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            } header: {
                Label("TMDb", systemImage: "flame")
            } footer: {
                Text("Required for Popular This Week on the Search tab. Get a free key at themoviedb.org.")
            }

            Section("Notifications") {
                Toggle("Download Notifications", isOn: $viewModel.notificationsEnabled)
                    .onChange(of: viewModel.notificationsEnabled) {
                        Task { await viewModel.toggleNotifications() }
                    }
                if viewModel.notificationsEnabled && !viewModel.notificationPermissionGranted {
                    Label("Notification permission not granted. Enable in System Settings.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            Section("Storage") {
                LabeledContent("Arr Artwork Cache") {
                    Text(viewModel.artworkCacheSizeDescription)
                        .foregroundStyle(.secondary)
                }

                Button("Clear Artwork Cache", systemImage: "trash") {
                    Task { await viewModel.clearArtworkCache() }
                }
                .disabled(viewModel.isClearingArtworkCache)
            }

            #if os(macOS)
            Section("Magnet Links") {
                MagnetLinkSettingsRow()
            }
            #endif

            if let appVersion = viewModel.appVersion {
                Section("About") {
                    LabeledContent("Trawl") {
                        Text(appVersion).foregroundStyle(.secondary)
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }

    // MARK: - Helpers

    private func serviceRow(icon: String, color: Color, name: String, url: String?, isConnected: Bool, isConfigured: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                if let url {
                    Text(url)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not configured")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: isConfigured ? "circle.fill" : "plus.circle")
                .font(.caption)
                .foregroundStyle(isConfigured ? (isConnected ? Color.green : Color.red) : Color.secondary.opacity(0.5))
        }
    }

    private func settingsInfoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

}

// MARK: - qBittorrent Settings Sub-page

struct QBittorrentSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @State private var viewModel = SettingsViewModel()
    @State private var showOnboarding = false

    var body: some View {
        Form {
            Section {
                if let server = viewModel.serverProfile {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(server.hostURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if syncService.isPolling {
                            Label("Connected", systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .labelStyle(.titleAndIcon)
                        } else {
                            Label("Disconnected", systemImage: "circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if let lastConnected = server.lastConnected {
                        LabeledContent("Last Connected") {
                            Text(lastConnected.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Edit Server", systemImage: "pencil") {
                        showOnboarding = true
                    }
                } else {
                    Button("Add qBittorrent Server", systemImage: "plus") {
                        showOnboarding = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Enter the full Web UI address including port. Example: http://192.168.1.100:8080")
            }

            Section("Downloads") {
                LabeledContent("Refresh Interval") {
                    Text("\(String(format: "%.0f", viewModel.pollingInterval))s")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewModel.pollingInterval, in: 1...10, step: 1) {
                    Text("Refresh Interval")
                }
                .onChange(of: viewModel.pollingInterval) {
                    viewModel.updatePollingInterval()
                }
            }

            Section("Details") {
                if let qbVersion = viewModel.qbVersion {
                    LabeledContent("qBittorrent") {
                        Text(qbVersion).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Connection") {
                    Text(syncService.serverState?.connectionStatus ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
                if let dhtNodes = syncService.serverState?.dhtNodes {
                    LabeledContent("DHT Nodes") {
                        Text("\(dhtNodes)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("qBittorrent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(serverProfile: viewModel.serverProfile, onComplete: {
                Task { await viewModel.loadSettings(modelContext: modelContext) }
            })
        }
        .task {
            viewModel.configure(torrentService: torrentService, syncService: syncService)
            await viewModel.loadSettings(modelContext: modelContext)
        }
    }
}

// MARK: - macOS Magnet Link Row

#if os(macOS)
private struct MagnetLinkSettingsRow: View {
    @State private var isDefault = false

    var body: some View {
        Group {
            if isDefault {
                Label("Trawl is the default magnet handler", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Set as Default Magnet Handler") {
                    setAsDefault()
                }
            }
        }
        .onAppear { isDefault = checkIsDefault() }
    }

    private func checkIsDefault() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let current = LSCopyDefaultHandlerForURLScheme("magnet" as CFString)?.takeRetainedValue() as String?
        return current == bundleID
    }

    private func setAsDefault() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultHandlerForURLScheme("magnet" as CFString, bundleID as CFString)
        isDefault = checkIsDefault()
    }
}
#endif

// MARK: - Destinations

private struct NavigateToQbittorrentSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToSonarrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToRadarrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var navigateToQbittorrentSettings: () -> Void {
        get { self[NavigateToQbittorrentSettingsKey.self] }
        set { self[NavigateToQbittorrentSettingsKey.self] = newValue }
    }

    var navigateToSonarrSettings: () -> Void {
        get { self[NavigateToSonarrSettingsKey.self] }
        set { self[NavigateToSonarrSettingsKey.self] = newValue }
    }

    var navigateToRadarrSettings: () -> Void {
        get { self[NavigateToRadarrSettingsKey.self] }
        set { self[NavigateToRadarrSettingsKey.self] = newValue }
    }
}
