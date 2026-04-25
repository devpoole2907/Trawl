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
    @Environment(AppLockController.self) private var appLockController
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var servers: [ServerProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @State private var viewModel = SettingsViewModel()
    @State private var tmdbAPIKey: String = ""
    @State private var tmdbAPIKeySaveTask: Task<Void, Never>?
    @State private var didLoadTmdbAPIKey = false
    let showsDoneButton: Bool
    @Environment(\.navigateToQbittorrentSettings) private var navigateToQbittorrentSettings
    @Environment(\.navigateToSonarrSettings) private var navigateToSonarrSettings
    @Environment(\.navigateToRadarrSettings) private var navigateToRadarrSettings
    @Environment(\.navigateToProwlarrSettings) private var navigateToProwlarrSettings

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

                // Load TMDb API key from Keychain
                if let key = try? await KeychainHelper.shared.read(key: "tmdb.apiKey") {
                    tmdbAPIKey = key
                }
                didLoadTmdbAPIKey = true
            }
            .task(id: arrProfilesSyncKey) {
                arrServiceManager.syncProfiles(arrProfiles)
            }
            .onChange(of: tmdbAPIKey) { _, newValue in
                guard didLoadTmdbAPIKey else { return }
                tmdbAPIKeySaveTask?.cancel()
                tmdbAPIKeySaveTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        try? await KeychainHelper.shared.delete(key: "tmdb.apiKey")
                    } else {
                        try? await KeychainHelper.shared.save(key: "tmdb.apiKey", value: trimmed)
                    }
                }
            }
            .onDisappear {
                tmdbAPIKeySaveTask?.cancel()
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

    private var prowlarrProfile: ArrServiceProfile? {
        arrProfiles.first(where: { $0.resolvedServiceType == .prowlarr })
    }

    private var arrProfilesSyncKey: String {
        arrProfiles
            .map {
                "\($0.id.uuidString):\($0.serviceType):\($0.hostURL):\($0.isEnabled)"
            }
            .sorted()
            .joined(separator: "|")
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

                Button(action: navigateToProwlarrSettings) {
                    serviceRow(
                        icon: "magnifyingglass.circle.fill", color: .yellow,
                        name: prowlarrProfile?.displayName ?? "Prowlarr",
                        url: prowlarrProfile?.hostURL,
                        isConnected: arrServiceManager.prowlarrConnected,
                        isConfigured: prowlarrProfile != nil
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

                #if os(iOS)
                if viewModel.notificationsEnabled, let deviceToken = viewModel.deviceToken {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Account ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Text(deviceToken)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Button {
                                    UIPasteboard.general.string = deviceToken
                                    inAppNotificationCenter.showSuccess(title: "Copied", message: "ID copied to clipboard")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                        }

                        Text("Use the 'One-Tap Setup' inside Radarr or Sonarr settings to link your notifications automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                #endif
            }

            #if os(iOS)
            Section {
                Toggle(securityToggleTitle, isOn: Binding(
                    get: { appLockController.isEnabled },
                    set: { newValue in
                        Task {
                            if newValue {
                                _ = await appLockController.enable()
                            } else {
                                _ = await appLockController.disable()
                            }
                        }
                    }
                ))
                .disabled(!appLockController.availability.isUsable)

                if case .unavailable = appLockController.availability {
                    Label("Set up Face ID, Touch ID, Optic ID, or a passcode in System Settings to enable.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Security", systemImage: "lock.shield")
            } footer: {
                Text("Lock Trawl behind \(appLockController.biometryName) when the app opens or returns from the background.")
            }
            #endif

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

    private var securityToggleTitle: String {
        switch appLockController.availability {
        case .faceID:
            "Require Face ID"
        case .touchID:
            "Require Touch ID"
        case .opticID:
            "Require Optic ID"
        case .passcodeOnly:
            "Require Passcode"
        case .unavailable:
            "Require App Lock"
        }
    }

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
    @State private var globalDownloadLimit: Int64 = 0
    @State private var globalUploadLimit: Int64 = 0
    @State private var alternativeSpeedEnabled = false
    @State private var appPreferences: AppPreferences?
    @State private var didLoadSpeedLimits = false
    @State private var speedLimitErrorAlert: ErrorAlertItem?
    @State private var isUpdatingAlternativeSpeed = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ServerListView()
                        .environment(syncService)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Servers")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if let server = viewModel.serverProfile {
                                Text(server.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No qBittorrent servers configured")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if viewModel.serverProfile != nil {
                            Label(syncService.isPolling ? "Connected" : "Disconnected", systemImage: syncService.isPolling ? "circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(syncService.isPolling ? .green : .secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Manage multiple qBittorrent servers and switch the active one here.")
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

            Section {
                LabeledContent("Current Download") {
                    Text(formattedLimit(syncService.serverState?.dlRateLimit ?? globalDownloadLimit))
                        .foregroundStyle(.secondary)
                }

                Picker("Download Limit", selection: $globalDownloadLimit) {
                    ForEach(limitOptions(including: globalDownloadLimit), id: \.self) { limit in
                        Text(formattedLimit(limit)).tag(limit)
                    }
                }
                .onChange(of: globalDownloadLimit) {
                    guard didLoadSpeedLimits else { return }
                    Task { await updateGlobalDownloadLimit(globalDownloadLimit) }
                }

                LabeledContent("Current Upload") {
                    Text(formattedLimit(syncService.serverState?.upRateLimit ?? globalUploadLimit))
                        .foregroundStyle(.secondary)
                }

                Picker("Upload Limit", selection: $globalUploadLimit) {
                    ForEach(limitOptions(including: globalUploadLimit), id: \.self) { limit in
                        Text(formattedLimit(limit)).tag(limit)
                    }
                }
                .onChange(of: globalUploadLimit) {
                    guard didLoadSpeedLimits else { return }
                    Task { await updateGlobalUploadLimit(globalUploadLimit) }
                }

                Toggle("Alternative Speed Mode", isOn: $alternativeSpeedEnabled)
                    .onChange(of: alternativeSpeedEnabled) {
                        guard didLoadSpeedLimits, !isUpdatingAlternativeSpeed else { return }
                        Task { await updateAlternativeSpeedMode(alternativeSpeedEnabled) }
                    }
            } header: {
                Text("Speed Limits")
            } footer: {
                if let appPreferences {
                    let down = formattedLimit(appPreferences.altDownloadLimit ?? 0)
                    let up = formattedLimit(appPreferences.altUploadLimit ?? 0)
                    Text("Alternative mode uses \(down) down and \(up) up.")
                } else {
                    Text("Set global download and upload caps, or toggle qBittorrent's alternative speed mode.")
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
        .task {
            viewModel.configure(torrentService: torrentService, syncService: syncService)
            await viewModel.loadSettings(modelContext: modelContext)
            await loadSpeedLimitSettings()
        }
        .errorAlert(item: $speedLimitErrorAlert)
    }

    private func loadSpeedLimitSettings() async {
        do {
            async let downloadLimit = torrentService.getGlobalDownloadLimit()
            async let uploadLimit = torrentService.getGlobalUploadLimit()
            async let altMode = torrentService.isAlternativeSpeedEnabled()
            async let preferences = torrentService.getPreferences()

            globalDownloadLimit = try await downloadLimit
            globalUploadLimit = try await uploadLimit
            alternativeSpeedEnabled = try await altMode
            appPreferences = try await preferences
            speedLimitErrorAlert = nil

            // Defer setting didLoadSpeedLimits to avoid triggering onChange handlers
            await Task.yield()
            didLoadSpeedLimits = true
        } catch {
            speedLimitErrorAlert = ErrorAlertItem(
                title: "Couldn't Load Speed Limits",
                message: error.localizedDescription
            )
        }
    }

    private func updateGlobalDownloadLimit(_ limit: Int64) async {
        do {
            let currentValue = try await torrentService.getGlobalDownloadLimit()
            guard currentValue != limit else { return }
            try await torrentService.setGlobalDownloadLimit(limit: limit)
            await syncService.refreshNow()
            speedLimitErrorAlert = nil
        } catch {
            speedLimitErrorAlert = ErrorAlertItem(
                title: "Couldn't Set Download Limit",
                message: error.localizedDescription
            )
        }
    }

    private func updateGlobalUploadLimit(_ limit: Int64) async {
        do {
            let currentValue = try await torrentService.getGlobalUploadLimit()
            guard currentValue != limit else { return }
            try await torrentService.setGlobalUploadLimit(limit: limit)
            await syncService.refreshNow()
            speedLimitErrorAlert = nil
        } catch {
            speedLimitErrorAlert = ErrorAlertItem(
                title: "Couldn't Set Upload Limit",
                message: error.localizedDescription
            )
        }
    }

    private func updateAlternativeSpeedMode(_ enabled: Bool) async {
        guard !isUpdatingAlternativeSpeed else { return }
        isUpdatingAlternativeSpeed = true
        defer { isUpdatingAlternativeSpeed = false }

        do {
            let currentValue = try await torrentService.isAlternativeSpeedEnabled()
            guard currentValue != enabled else {
                isUpdatingAlternativeSpeed = false
                return
            }
            try await torrentService.toggleAlternativeSpeed()
            alternativeSpeedEnabled = try await torrentService.isAlternativeSpeedEnabled()
            await syncService.refreshNow()
            speedLimitErrorAlert = nil
        } catch {
            alternativeSpeedEnabled = (try? await torrentService.isAlternativeSpeedEnabled()) ?? alternativeSpeedEnabled
            speedLimitErrorAlert = ErrorAlertItem(
                title: "Couldn't Toggle Alternative Speed",
                message: error.localizedDescription
            )
        }
    }

    private func limitOptions(including currentLimit: Int64) -> [Int64] {
        let megabyte = Int64(1_048_576)
        var options: [Int64] = [
            0,
            megabyte,
            5 * megabyte,
            10 * megabyte,
            25 * megabyte,
            50 * megabyte,
            100 * megabyte
        ]
        if currentLimit > 0, !options.contains(currentLimit) {
            options.append(currentLimit)
            options.sort()
        }
        return options
    }

    private func formattedLimit(_ limit: Int64) -> String {
        limit == 0 ? "Unlimited" : ByteFormatter.formatSpeed(bytesPerSecond: limit)
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

private struct NavigateToSeriesTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToMoviesTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToQbittorrentSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToSonarrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToRadarrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToProwlarrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var navigateToSeriesTab: () -> Void {
        get { self[NavigateToSeriesTabKey.self] }
        set { self[NavigateToSeriesTabKey.self] = newValue }
    }

    var navigateToMoviesTab: () -> Void {
        get { self[NavigateToMoviesTabKey.self] }
        set { self[NavigateToMoviesTabKey.self] = newValue }
    }

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

    var navigateToProwlarrSettings: () -> Void {
        get { self[NavigateToProwlarrSettingsKey.self] }
        set { self[NavigateToProwlarrSettingsKey.self] = newValue }
    }
}
