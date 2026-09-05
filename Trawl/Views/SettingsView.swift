import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(AppLockController.self) private var appLockController
    @Query private var servers: [ServerProfile]
    @Query private var arrProfiles: [ArrServiceProfile]
    @State private var viewModel = SettingsViewModel()
    @AppStorage("startupTab") private var startupTab: String = RootTab.downloads.displayName
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif
    @AppStorage("themeOverride") private var themeOverride: ThemeOverride = .system
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    let showsDoneButton: Bool
    @Environment(\.navigateToQbittorrentSettings) private var navigateToQbittorrentSettings
    @Environment(\.navigateToSABnzbdSettings) private var navigateToSABnzbdSettings
    @Environment(\.navigateToSonarrSettings) private var navigateToSonarrSettings
    @Environment(\.navigateToRadarrSettings) private var navigateToRadarrSettings
    @Environment(\.navigateToProwlarrSettings) private var navigateToProwlarrSettings
    @Environment(\.navigateToBazarrSettings) private var navigateToBazarrSettings
    @Environment(\.navigateToSeerrSettings) private var navigateToSeerrSettings
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Query private var seerrProfiles: [SeerrServiceProfile]
    @Environment(\.navigateToJellyfinSettings) private var navigateToJellyfinSettings
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Query private var jellyfinProfiles: [JellyfinServiceProfile]
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @Environment(\.navigateToCleanuparrSettings) private var navigateToCleanuparrSettings
    @Environment(CleanuparrServiceManager.self) private var cleanuparrServiceManager
    @Query private var cleanuparrProfiles: [CleanuparrServiceProfile]
    /// Which service's settings the detail pane is showing, at regular width. Nil on
    /// iPhone and in the Settings sheet, where the row pushes instead.
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(TrawlColumnSelection<MoreDestination>.self) private var sharedSelection: TrawlColumnSelection<MoreDestination>?
    @State private var localSelection = TrawlColumnSelection<MoreDestination>()
    private var selectionStore: TrawlColumnSelection<MoreDestination> {
        sidebarColumn == nil ? localSelection : (sharedSelection ?? localSelection)
    }
    private var selectedService: MoreDestination? { selectionStore.selection }
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif
    
    init(showsDoneButton: Bool = true) {
        self.showsDoneButton = showsDoneButton
    }

    private var showsDetailPane: Bool { sidebarColumn != nil }

    var body: some View {
        // Two panes at regular width. Settings is a list of servers you open one at a
        // time to check a URL or a key, and pushing over the list for each of them
        // hides the very thing the check is against - the other servers' state.
        TrawlListDetailPanes(title: "Settings") {
            settingsList
        } detail: {
            selectedServiceDetail
        }
    }

    /// The right-hand pane: whichever service's settings are selected. The same
    /// screens the rows open without a pane, so both routes run one code path.
    @ViewBuilder
    private var selectedServiceDetail: some View {
        switch selectedService {
        case .qbittorrentSettings:
            QBittorrentSettingsView()
                .environment(syncService)
                .environment(torrentService)
        case .sabnzbdSettings:
            SABnzbdSettingsView()
                .environment(sabnzbdServiceManager)
        case .sonarrSettings:
            ArrServiceSettingsView(serviceType: .sonarr)
                .environment(arrServiceManager)
        case .radarrSettings:
            ArrServiceSettingsView(serviceType: .radarr)
                .environment(arrServiceManager)
        case .prowlarrSettings:
            ArrServiceSettingsView(serviceType: .prowlarr)
                .environment(arrServiceManager)
        case .bazarrSettings:
            ArrServiceSettingsView(serviceType: .bazarr)
                .environment(arrServiceManager)
        case .seerrSettings:
            SeerrSettingsView()
        case .jellyfinSettings:
            JellyfinSettingsView()
        case .cleanuparrSettings:
            CleanuparrSettingsView()
                .environment(cleanuparrServiceManager)
        default:
            listDetailPlaceholder("Select a Service", systemImage: "gearshape")
        }
    }

    /// Opens a service's settings: selects it beside a detail pane, and pushes
    /// through the chrome's own route without one.
    private func openService(_ destination: MoreDestination, push: @escaping () -> Void) {
        if showsDetailPane {
            selectionStore.selection = destination
        } else {
            push()
        }
    }

    /// The selected row's tint. `Form` has no `selection:`, so the highlight is
    /// drawn rather than inherited - the rows are buttons, not list tags.
    @ViewBuilder
    private func serviceRowBackground(_ destination: MoreDestination) -> some View {
        if showsDetailPane && selectedService == destination {
            Color.accentColor.opacity(0.15)
        } else {
            Color.clear
        }
    }

    private var settingsList: some View {
        settingsForm
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
                #if DEBUG
                guard !skipsAutomaticLoading else { return }
                #endif
                viewModel.configure(torrentService: torrentService, syncService: syncService, arrServiceManager: arrServiceManager)
                await viewModel.loadSettings(modelContext: modelContext)
            }
            .task(id: arrProfilesSyncKey) {
                arrServiceManager.syncProfiles(arrProfiles)
            }
            .moreDestinationBackground(.settings)
    }

    // MARK: - Computed

    private var activeServer: ServerProfile? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var sonarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .sonarr, in: arrProfiles)
    }

    private var radarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .radarr, in: arrProfiles)
    }

    private var prowlarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .prowlarr, in: arrProfiles)
    }

    private var sonarrProfiles: [ArrServiceProfile] {
        arrProfiles.filter { $0.resolvedServiceType == .sonarr && $0.isEnabled }
    }

    private var radarrProfiles: [ArrServiceProfile] {
        arrProfiles.filter { $0.resolvedServiceType == .radarr && $0.isEnabled }
    }

    private var prowlarrProfiles: [ArrServiceProfile] {
        arrProfiles.filter { $0.resolvedServiceType == .prowlarr && $0.isEnabled }
    }

    private var bazarrProfile: ArrServiceProfile? {
        arrServiceManager.resolvedProfile(for: .bazarr, in: arrProfiles)
    }

    private var bazarrProfiles: [ArrServiceProfile] {
        arrProfiles.filter { $0.resolvedServiceType == .bazarr && $0.isEnabled }
    }

    private var seerrProfile: SeerrServiceProfile? {
        seerrProfiles.first(where: { $0.isEnabled }) ?? seerrProfiles.first
    }

    private var jellyfinProfile: JellyfinServiceProfile? {
        jellyfinProfiles.first(where: { $0.isEnabled }) ?? jellyfinProfiles.first
    }

    private var sabnzbdProfile: SABnzbdServiceProfile? {
        sabnzbdProfiles.first(where: { $0.isEnabled }) ?? sabnzbdProfiles.first
    }

    private var cleanuparrProfile: CleanuparrServiceProfile? {
        cleanuparrProfiles.first(where: { $0.isEnabled }) ?? cleanuparrProfiles.first
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
                Button {
                    openService(.qbittorrentSettings, push: navigateToQbittorrentSettings)
                } label: {
                    serviceRow(
                        icon: ServiceIdentity.qbittorrent.systemImage, color: ServiceIdentity.qbittorrent.brandColor,
                        name: activeServer?.displayName ?? "qBittorrent",
                        url: activeServer?.hostURL,
                        isConnected: syncService.isPolling,
                        isConfigured: activeServer != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.qbittorrentSettings))

                Button {
                    openService(.sabnzbdSettings, push: navigateToSABnzbdSettings)
                } label: {
                    serviceRow(
                        icon: ServiceIdentity.sabnzbd.systemImage, color: ServiceIdentity.sabnzbd.brandColor,
                        name: sabnzbdProfile?.displayName ?? "SABnzbd",
                        url: sabnzbdProfile?.hostURL,
                        isConnected: sabnzbdServiceManager.isConnected,
                        isConfigured: sabnzbdProfile != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.sabnzbdSettings))

                Button {
                    openService(.sonarrSettings, push: navigateToSonarrSettings)
                } label: {
                    arrServiceRow(
                        identity: .sonarr,
                        defaultName: "Sonarr",
                        serviceType: .sonarr,
                        profiles: sonarrProfiles,
                        resolved: sonarrProfile,
                        isConnected: arrServiceManager.sonarrConnected
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.sonarrSettings))

                Button {
                    openService(.radarrSettings, push: navigateToRadarrSettings)
                } label: {
                    arrServiceRow(
                        identity: .radarr,
                        defaultName: "Radarr",
                        serviceType: .radarr,
                        profiles: radarrProfiles,
                        resolved: radarrProfile,
                        isConnected: arrServiceManager.radarrConnected
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.radarrSettings))

                Button {
                    openService(.prowlarrSettings, push: navigateToProwlarrSettings)
                } label: {
                    serviceRow(
                        icon: ServiceIdentity.prowlarr.systemImage, color: ServiceIdentity.prowlarr.brandColor,
                        name: prowlarrProfile?.displayName ?? "Prowlarr",
                        url: prowlarrProfile?.hostURL,
                        isConnected: arrServiceManager.prowlarrConnected,
                        isConfigured: prowlarrProfile != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.prowlarrSettings))

                Button {
                    openService(.bazarrSettings, push: navigateToBazarrSettings)
                } label: {
                    arrServiceRow(
                        identity: .bazarr,
                        defaultName: "Bazarr",
                        serviceType: .bazarr,
                        profiles: bazarrProfiles,
                        resolved: bazarrProfile,
                        isConnected: arrServiceManager.hasAnyConnectedBazarrInstance
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.bazarrSettings))

                Button {
                    openService(.seerrSettings, push: navigateToSeerrSettings)
                } label: {
                    serviceRow(
                        icon: ServiceIdentity.seerr.systemImage, color: ServiceIdentity.seerr.brandColor,
                        name: seerrProfile?.displayName ?? "Seerr",
                        url: seerrProfile?.hostURL,
                        isConnected: seerrServiceManager.isConnected,
                        isConfigured: seerrProfile != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.seerrSettings))

                Button {
                    openService(.jellyfinSettings, push: navigateToJellyfinSettings)
                } label: {
                    serviceRow(
                        icon: ServiceIdentity.jellyfin.systemImage, color: ServiceIdentity.jellyfin.brandColor,
                        name: jellyfinProfile?.displayName ?? "Jellyfin",
                        url: jellyfinProfile?.hostURL,
                        isConnected: jellyfinServiceManager.isConnected,
                        isConfigured: jellyfinProfile != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.jellyfinSettings))

                Button {
                    openService(.cleanuparrSettings, push: navigateToCleanuparrSettings)
                } label: {
                    serviceRow(
                        icon: ServiceIdentity.cleanuparr.systemImage, color: ServiceIdentity.cleanuparr.brandColor,
                        name: cleanuparrProfile?.displayName ?? "Cleanuparr",
                        url: cleanuparrProfile?.hostURL,
                        isConnected: cleanuparrServiceManager.isConnected,
                        isConfigured: cleanuparrProfile != nil
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(serviceRowBackground(.cleanuparrSettings))
            }

            #if os(iOS)
            Section {
                Toggle(securityToggleTitle, isOn: Binding(
                    get: { appLockController.isEnabled },
                    set: { newValue in
                        guard !appLockController.isAuthenticating else { return }
                        Task {
                            if newValue {
                                _ = await appLockController.enable()
                            } else {
                                _ = await appLockController.disable()
                            }
                        }
                    }
                ))
                .disabled(!appLockController.availability.isUsable || appLockController.isAuthenticating)

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

            Section("Appearance") {
                // Only where there are tabs to start on. The sidebar chrome - iPad at
                // regular width, and every Mac window - has no tab bar at all, so the
                // setting was offering a choice that could not be honoured. An iPad
                // in a narrow multitasking slot is compact and does get the tab bar,
                // which is why this follows the size class rather than the idiom.
                #if os(iOS)
                if hSizeClass == .compact {
                    Picker("Startup Tab", selection: $startupTab) {
                        ForEach(RootTab.startupChoices, id: \.self) { tab in
                            Text(tab.displayName).tag(tab.displayName)
                        }
                    }
                }
                #endif

                Picker("Theme", selection: $themeOverride) {
                    ForEach(ThemeOverride.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }

                #if os(iOS)
                // A Mac has no haptic engine to drive, and `.sensoryFeedback` is a no-op
                // there, so on macOS this was a switch that turned nothing off.
                Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                #endif
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
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .formStyle(.grouped)
        #endif

    }

    // MARK: - Helpers

    #if os(iOS)
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
    #endif

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
                    Text("Not set up")
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

    /// One row per *service*, listing every server configured for it.
    ///
    /// A pair of servers is one library split across two boxes, not one server
    /// with a spare. This row used to say "Sonarr 4K (2 instances)" over
    /// "Active: <url>", which asserted three wrong things: that the pair is named
    /// after whichever server happened to be selected, that one of them is the
    /// real one, and - by omission - that the other one's address and health are
    /// not worth showing. There is no active instance any more; the app talks to
    /// both. So both are listed, each with its tier and its own connection state.
    private func arrServiceRow(
        identity: ServiceIdentity,
        defaultName: String,
        serviceType: ArrServiceType,
        profiles: [ArrServiceProfile],
        resolved: ArrServiceProfile?,
        isConnected: Bool
    ) -> some View {
        // Ordered by tier, not by the order they were added, so Default is always
        // the line above 4K - the same ordering the badges use everywhere else.
        let ordered = profiles.sorted { $0.qualityTier.ordinalForDisplay < $1.qualityTier.ordinalForDisplay }

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: identity.systemImage)
                .font(.title2)
                .foregroundStyle(identity.brandColor)
                .frame(width: 32)

            if ordered.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    // The service, not a server: with two configured, neither
                    // server's display name can stand for the pair.
                    Text(defaultName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    ForEach(ordered) { profile in
                        HStack(spacing: 8) {
                            // Tiered services are named by their tier, which is
                            // what the badges say everywhere else. A tierless one
                            // reports the default tier for every server, so badging
                            // by tier would label both halves "Default"; its
                            // servers are told apart by the names the user gave
                            // them.
                            ArrInstanceBadge(
                                label: ArrSetupViewModel.usesQualityTiers(serviceType)
                                    ? profile.qualityTier.label
                                    : profile.displayName,
                                ordinal: profile.qualityTier.ordinalForDisplay
                            )
                            Text(profile.hostURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            // Per line, because an aggregate dot cannot say which
                            // of the two is down - and one server being unreachable
                            // is exactly what you open this screen to find out.
                            statusDot(isConfigured: true, isConnected: arrServiceManager.isConnected(serviceType, profileID: profile.id))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolved?.displayName ?? defaultName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if let resolved {
                        Text(resolved.hostURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Not set up")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                statusDot(isConfigured: resolved != nil, isConnected: isConnected)
            }
        }
    }

    private func statusDot(isConfigured: Bool, isConnected: Bool) -> some View {
        Image(systemName: isConfigured ? "circle.fill" : "plus.circle")
            .font(.caption)
            .foregroundStyle(isConfigured ? (isConnected ? Color.green : Color.red) : Color.secondary.opacity(0.5))
            .accessibilityLabel(isConfigured ? (isConnected ? "Connected" : "Not connected") : "Not set up")
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
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var viewModel = SettingsViewModel()
    @State private var globalDownloadLimit: Int64 = 0
    @State private var globalUploadLimit: Int64 = 0
    @State private var alternativeSpeedEnabled = false
    @State private var appPreferences: AppPreferences?
    @State private var defaultSavePath = ""
    @State private var didLoadSpeedLimits = false
    @State private var speedLimitErrorAlert: ErrorAlertItem?
    @State private var isUpdatingAlternativeSpeed = false
    @State private var isUpdatingDefaultSavePath = false
    
    @State private var serverToEdit: ServerProfile?
    @State private var showAddSheet = false
    @State private var showRemoveConfirmation = false
    @State private var isDeleting = false
    
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    init() {}
    
    @MainActor
    private func deleteServer(_ server: ServerProfile) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer {
            isDeleting = false
        }

        do {
            try await KeychainHelper.shared.delete(key: server.usernameKey)
            try await KeychainHelper.shared.delete(key: server.passwordKey)
        } catch {
            return
        }

        modelContext.delete(server)

        do {
            try modelContext.save()
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Couldn't Delete Server",
                message: error.localizedDescription
            )
        }
    }

    var body: some View {
        Form {
            Section {
                if let server = viewModel.serverProfile {
                    Button {
                        serverToEdit = server
                    } label: {
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
                            Label(syncService.isPolling ? "Connected" : "Disconnected", systemImage: syncService.isPolling ? "circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(syncService.isPolling ? .green : .secondary)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        serverToEdit = server
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }
                } else {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                if viewModel.serverProfile == nil {
                    Text("Connect your qBittorrent server to manage torrents in Trawl.")
                }
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
                // An example value, not a label: macOS draws a field's title beside it, where this
                // reads as another entry that has already been added.
                TextField("", text: $defaultSavePath, prompt: Text("/downloads"))
                    .labelsHidden()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(isUpdatingDefaultSavePath)

                Button {
                    Task { await updateDefaultSavePath() }
                } label: {
                    if isUpdatingDefaultSavePath {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Update Save Location")
                    }
                }
                .disabled(!canUpdateDefaultSavePath)
            } header: {
                Text("Default Save Location")
            } footer: {
                Text("Sets qBittorrent's server-wide default save path for new torrents.")
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
            
            if viewModel.serverProfile != nil {
                Section {
                    Button("Remove qBittorrent Server", systemImage: "trash", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                    .confirmationDialog(
                        "Remove qBittorrent Server?",
                        isPresented: $showRemoveConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Remove", role: .destructive) {
                            Task {
                                if let profile = viewModel.serverProfile {
                                    await deleteServer(profile)
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes the saved qBittorrent connection and credentials from Trawl.")
                    }
                }
            }
        }
        .navigationTitle("qBittorrent")
        .serviceSettingsFormStyle()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $serverToEdit) { server in
            OnboardingSheet(serverProfile: server) {}
        }
        .sheet(isPresented: $showAddSheet) {
            OnboardingSheet(serverProfile: nil) {}
        }
        .task {
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            viewModel.configure(torrentService: torrentService, syncService: syncService)
            await viewModel.loadSettings(modelContext: modelContext)
            await loadSpeedLimitSettings()
        }
        .errorAlert(item: $speedLimitErrorAlert)
    }

    private var hasKnownQBittorrentConnectionFailure: Bool {
        if !syncService.isPolling {
            return true
        }

        guard let lastError = syncService.lastError else {
            return false
        }

        switch lastError {
        case .authFailed, .networkError, .noServerConfigured, .connectionTestFailed:
            return true
        case .invalidResponse, .decodingError, .serverError:
            return false
        }
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
            defaultSavePath = appPreferences?.savePath ?? ""
            speedLimitErrorAlert = nil

            // Defer setting didLoadSpeedLimits to avoid triggering onChange handlers
            await Task.yield()
            didLoadSpeedLimits = true
        } catch {
            guard !hasKnownQBittorrentConnectionFailure else {
                speedLimitErrorAlert = nil
                return
            }

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

    private var canUpdateDefaultSavePath: Bool {
        let trimmedPath = defaultSavePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentPath = appPreferences?.savePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !isUpdatingDefaultSavePath && !trimmedPath.isEmpty && trimmedPath != currentPath
    }

    private func updateDefaultSavePath() async {
        guard !isUpdatingDefaultSavePath else { return }

        let trimmedPath = defaultSavePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            speedLimitErrorAlert = ErrorAlertItem(
                title: "Save Location Required",
                message: "Enter a default save location before saving."
            )
            return
        }

        // Store previous persisted values for rollback BEFORE any mutations
        let previousAppPreferences = appPreferences
        let previousDefaultSavePath = appPreferences?.savePath ?? ""
        let previousSyncDefaultSavePath = syncService.defaultSavePath
        let previousProfileDefaultSavePath = viewModel.serverProfile?.defaultSavePath

        isUpdatingDefaultSavePath = true
        defer { isUpdatingDefaultSavePath = false }

        // Step 1: remote write - if this fails the server was never updated, roll back fully.
        do {
            try await torrentService.setDefaultSavePath(path: trimmedPath)
        } catch {
            speedLimitErrorAlert = ErrorAlertItem(
                title: "Couldn't Update Save Location",
                message: error.localizedDescription
            )
            return
        }

        // Step 2: apply provisional local state and persist immediately.
        // The remote already accepted the new path, so we write trimmedPath even if the refresh below fails.
        defaultSavePath = trimmedPath
        syncService.defaultSavePath = trimmedPath
        viewModel.serverProfile?.defaultSavePath = trimmedPath

        do {
            try modelContext.save()
        } catch {
            // Local persistence failed - roll back all in-memory mirrors.
            appPreferences = previousAppPreferences
            defaultSavePath = previousDefaultSavePath
            syncService.defaultSavePath = previousSyncDefaultSavePath
            viewModel.serverProfile?.defaultSavePath = previousProfileDefaultSavePath
            inAppNotificationCenter.showError(
                title: "Couldn't Save Changes",
                message: error.localizedDescription
            )
            return
        }

        // Step 3: best-effort refresh to get the server-confirmed path.
        // A failure here is a partial success: the server has the new path, local state is persisted.
        if let refreshedPreferences = try? await torrentService.getPreferences() {
            appPreferences = refreshedPreferences
            let confirmedPath = refreshedPreferences.savePath ?? trimmedPath
            defaultSavePath = confirmedPath
            syncService.defaultSavePath = confirmedPath
            viewModel.serverProfile?.defaultSavePath = confirmedPath
            if confirmedPath != trimmedPath {
                _ = try? modelContext.save()
            }
            speedLimitErrorAlert = nil
        } else {
            speedLimitErrorAlert = ErrorAlertItem(
                title: "Save Location Updated",
                message: "Server accepted the new path, but Trawl couldn't refresh local state right now."
            )
        }

        inAppNotificationCenter.showSuccess(
            title: "Save Location Updated",
            message: defaultSavePath
        )
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
        MagnetLinkHandler.isDefault
    }

    private func setAsDefault() {
        Task { @MainActor in
            // Re-read either way: on failure to reflect that nothing changed, on
            // success because the system is the source of truth for the handler.
            try? await MagnetLinkHandler.setAsDefault()
            isDefault = checkIsDefault()
        }
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

private struct NavigateToDownloadsTabKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

/// Optional, unlike its neighbours, and that is the whole point: it is present only
/// on the chrome that has Setup Check as a destination to go to. Nil means "this
/// chrome has nowhere to send you", which is the compact one's situation and the
/// reason it still presents the wizard as a sheet.
private struct NavigateToSetupCheckKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct NavigateToSABnzbdSettingsKey: EnvironmentKey {
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

private struct NavigateToBazarrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToSeerrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToJellyfinSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToCleanuparrSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct NavigateToSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

/// Opens a library title in the detail column beside the list.
///
/// Nil on the tab chrome, which has no detail column - there a caller pushes the
/// title onto its own stack instead, which is the right move when the screen you are
/// on fills the window. On iPad the two panes are side by side, and pushing a *third*
/// title on top of the second one buries the list the user is picking from.
private struct SelectLibraryTitleKey: EnvironmentKey {
    static let defaultValue: ((ArrMergeKey) -> Void)? = nil
}

private struct OpenMediaInSearchKey: EnvironmentKey {
    static let defaultValue: ((ArrMediaDestination) -> Void)? = nil
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

    var navigateToDownloadsTab: () -> Void {
        get { self[NavigateToDownloadsTabKey.self] }
        set { self[NavigateToDownloadsTabKey.self] = newValue }
    }

    /// Selects the sidebar's Setup Check destination, where the chrome has one.
    var navigateToSetupCheck: (() -> Void)? {
        get { self[NavigateToSetupCheckKey.self] }
        set { self[NavigateToSetupCheckKey.self] = newValue }
    }

    var navigateToSABnzbdSettings: () -> Void {
        get { self[NavigateToSABnzbdSettingsKey.self] }
        set { self[NavigateToSABnzbdSettingsKey.self] = newValue }
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

    var navigateToBazarrSettings: () -> Void {
        get { self[NavigateToBazarrSettingsKey.self] }
        set { self[NavigateToBazarrSettingsKey.self] = newValue }
    }

    var navigateToSeerrSettings: () -> Void {
        get { self[NavigateToSeerrSettingsKey.self] }
        set { self[NavigateToSeerrSettingsKey.self] = newValue }
    }

    var navigateToJellyfinSettings: () -> Void {
        get { self[NavigateToJellyfinSettingsKey.self] }
        set { self[NavigateToJellyfinSettingsKey.self] = newValue }
    }

    var navigateToCleanuparrSettings: () -> Void {
        get { self[NavigateToCleanuparrSettingsKey.self] }
        set { self[NavigateToCleanuparrSettingsKey.self] = newValue }
    }

    var navigateToSettings: () -> Void {
        get { self[NavigateToSettingsKey.self] }
        set { self[NavigateToSettingsKey.self] = newValue }
    }

    var selectLibraryTitle: ((ArrMergeKey) -> Void)? {
        get { self[SelectLibraryTitleKey.self] }
        set { self[SelectLibraryTitleKey.self] = newValue }
    }

    var openMediaInSearch: ((ArrMediaDestination) -> Void)? {
        get { self[OpenMediaInSearchKey.self] }
        set { self[OpenMediaInSearchKey.self] = newValue }
    }
}

#if DEBUG
extension SettingsView {
    init(
        previewViewModel: SettingsViewModel,
        showsDoneButton: Bool = true
    ) {
        self.init(showsDoneButton: showsDoneButton)
        self._viewModel = State(initialValue: previewViewModel)
        self.skipsAutomaticLoading = true
    }
}

extension QBittorrentSettingsView {
    init(
        previewViewModel: SettingsViewModel,
        globalDownloadLimit: Int64 = 0,
        globalUploadLimit: Int64 = 5_242_880,
        alternativeSpeedEnabled: Bool = true,
        defaultSavePath: String = "/downloads"
    ) {
        self.init()
        self._viewModel = State(initialValue: previewViewModel)
        self._globalDownloadLimit = State(initialValue: globalDownloadLimit)
        self._globalUploadLimit = State(initialValue: globalUploadLimit)
        self._alternativeSpeedEnabled = State(initialValue: alternativeSpeedEnabled)
        self._defaultSavePath = State(initialValue: defaultSavePath)
        self._didLoadSpeedLimits = State(initialValue: true)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Settings Fully Configured") {
    PreviewHost(
        profiles: .allServices,
        arr: .preview(.allConfigured),
        jellyfin: .preview(.connected),
        seerr: .preview(.connected)
    ) {
        NavigationStack {
            SettingsView(previewViewModel: SettingsViewModel())
        }
    }
}

#Preview("Settings Nothing Configured") {
    PreviewHost(
        profiles: .empty,
        arr: .preview(.noneConfigured),
        jellyfin: .preview(.notConfigured),
        seerr: .preview(.notConfigured)
    ) {
        NavigationStack {
            SettingsView(previewViewModel: SettingsViewModel(
                notificationsEnabled: false,
                notificationPermissionGranted: false,
                serverProfile: nil,
                qbVersion: nil,
                deviceToken: nil
            ))
        }
    }
}

#Preview("qBittorrent Settings") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            QBittorrentSettingsView(previewViewModel: SettingsViewModel())
        }
    }
}

#Preview("qBittorrent Settings Empty") {
    PreviewHost(profiles: .empty) {
        NavigationStack {
            QBittorrentSettingsView(previewViewModel: SettingsViewModel(
                serverProfile: nil,
                qbVersion: nil
            ), globalDownloadLimit: 0, globalUploadLimit: 0, alternativeSpeedEnabled: false, defaultSavePath: "")
        }
    }
}
#endif



