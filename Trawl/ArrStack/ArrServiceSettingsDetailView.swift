import SwiftUI
import SwiftData

struct ArrServiceSettingsView: View {
    let serviceType: ArrServiceType

    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var allProfiles: [ArrServiceProfile]
    @State private var editorContext: ArrServiceEditorContext?
    @State private var systemStatus: ArrSystemStatus?
    @State private var isLoadingStatus = false
    @State private var systemStatusError: String?
    @State private var commandStatusMessage: String?
    @State private var isRunningCommand = false
    @State private var isSettingUpNotifications = false
    @State private var notificationSetupMessage: String?
    @State private var notificationSetupStatus: ArrNotificationSetupStatus?
    @State private var isViewActive = false

    #if os(iOS)
    @State private var deviceToken: String?
    #endif

    #if DEBUG
    init(
        serviceType: ArrServiceType,
        previewStatus: ArrSystemStatus? = nil,
        previewIsLoadingStatus: Bool = false,
        previewStatusError: String? = nil,
        previewNotificationStatus: ArrNotificationSetupStatus? = nil
    ) {
        self.serviceType = serviceType
        _systemStatus = State(initialValue: previewStatus)
        _isLoadingStatus = State(initialValue: previewIsLoadingStatus)
        _systemStatusError = State(initialValue: previewStatusError)
        _notificationSetupStatus = State(initialValue: previewNotificationStatus)
    }
    #endif

    private var profile: ArrServiceProfile? {
        serviceManager.resolvedProfile(for: serviceType, in: allProfiles, allowErroredFallback: true)
    }

    private var serviceProfiles: [ArrServiceProfile] {
        allProfiles
            .filter { $0.resolvedServiceType == serviceType && $0.isEnabled }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var isConnected: Bool {
        switch serviceType {
        case .sonarr: serviceManager.sonarrConnected
        case .radarr: serviceManager.radarrConnected
        case .prowlarr: serviceManager.prowlarrConnected
        case .bazarr: profile.map { serviceManager.isConnected(.bazarr, profileID: $0.id) } ?? false
        }
    }

    private var serviceColor: Color {
        switch serviceType {
        case .sonarr: .purple
        case .radarr: .orange
        case .prowlarr: .yellow
        case .bazarr: .teal
        }
    }

    private var supportsCommands: Bool {
        serviceType != .prowlarr && serviceType != .bazarr
    }

    private var supportsNotifications: Bool {
        serviceType != .prowlarr && serviceType != .bazarr
    }

    var body: some View {
        List {
            Section {
                if let profile {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(profile.hostURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(
                            isConnected ? "Connected" : "Disconnected",
                            systemImage: "circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(isConnected ? .green : .red)
                        .labelStyle(.titleAndIcon)
                    }

                    if let version = profile.apiVersion {
                        LabeledContent("\(serviceType.displayName)") {
                            Text("v\(version)").foregroundStyle(.secondary)
                        }
                    }

                    if let error = serviceManager.connectionErrors[profile.id.uuidString] {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    Button("Edit Server", systemImage: "pencil") {
                        editorContext = .edit(profile)
                    }
                } else {
                    Button {
                        editorContext = .create(serviceType)
                    } label: {
                        Label("Add \(serviceType.displayName) Server", systemImage: "plus")
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                if profile == nil {
                    Text("Find your API key in \(serviceType.displayName) under Settings → General → Security.")
                }
            }

            if profile != nil {
                if serviceType != .prowlarr, serviceProfiles.count > 1 {
                    Section {
                        ForEach(serviceProfiles) { serviceProfile in
                            Button {
                                if isProfileConnected(serviceProfile.id) {
                                    setActiveProfile(serviceProfile.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(serviceProfile.displayName)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(serviceProfile.hostURL)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    if serviceProfile.id == activeProfileID {
                                        Label("Active", systemImage: "checkmark")
                                            .font(.caption)
                                            .foregroundStyle(serviceColor)
                                    } else {
                                        Image(systemName: isProfileConnected(serviceProfile.id) ? "circle.fill" : "circle")
                                            .font(.caption)
                                            .foregroundStyle(isProfileConnected(serviceProfile.id) ? .green : .red)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!isProfileConnected(serviceProfile.id))
                            .contextMenu {
                                Button("Make Active", systemImage: "checkmark.circle") {
                                    if isProfileConnected(serviceProfile.id) {
                                        setActiveProfile(serviceProfile.id)
                                    }
                                }
                                .disabled(!isProfileConnected(serviceProfile.id))

                                Button("Edit", systemImage: "pencil") {
                                    editorContext = .edit(serviceProfile)
                                }

                                Button("Remove", systemImage: "trash", role: .destructive) {
                                    Task { await deleteProfile(serviceProfile) }
                                }
                            }
                        }

                        Button("Add Another \(serviceType.displayName) Server", systemImage: "plus") {
                            editorContext = .create(serviceType)
                        }
                    } header: {
                        Text("Instances")
                    } footer: {
                        Text("Choose which \(serviceType.displayName) instance is active throughout Trawl.")
                    }
                }

                if let systemStatus {
                    Section("System Status") {
                        if let instanceName = systemStatus.instanceName ?? systemStatus.appName {
                            serviceInfoRow(label: "Instance", value: instanceName)
                        }
                        if let version = systemStatus.version {
                            serviceInfoRow(label: "Version", value: version)
                        }
                        if let osName = systemStatus.osName {
                            let osValue = [osName, systemStatus.osVersion].compactMap { $0 }.joined(separator: " ")
                            serviceInfoRow(label: "OS", value: osValue)
                        }
                        if let runtimeName = systemStatus.runtimeName {
                            let runtimeValue = [runtimeName, systemStatus.runtimeVersion].compactMap { $0 }.joined(separator: " ")
                            serviceInfoRow(label: "Runtime", value: runtimeValue)
                        }
                        if let urlBase = systemStatus.urlBase, !urlBase.isEmpty {
                            serviceInfoRow(label: "URL Base", value: urlBase)
                        }
                    }
                } else if isLoadingStatus {
                    Section("System Status") {
                        HStack {
                            ProgressView()
                            Text("Loading system status...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let systemStatusError {
                    Section("System Status") {
                        Label(systemStatusError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                if supportsNotifications, isConnected {
                    Section("Notifications") {
                        Button {
                            setupNotifications()
                        } label: {
                            if isSettingUpNotifications {
                                HStack {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Setting up...")
                                }
                            } else {
                                Label("One-Tap Notification Setup", systemImage: "bell.badge.fill")
                            }
                        }
                        #if os(iOS)
                        .disabled(isSettingUpNotifications || deviceToken == nil)
                        #else
                        .disabled(true)
                        #endif

                        #if os(iOS)
                        if deviceToken == nil {
                            Text("Enable notifications in Trawl settings first.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Automatically creates or updates a 'Trawl' webhook in your \(serviceType.displayName) settings.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        #endif

                        if let notificationSetupStatus {
                            notificationSetupStatusRow(notificationSetupStatus)
                        }
                    }
                }

                Section {
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        Task {
                            if let p = profile {
                                await serviceManager.connectService(p)
                                await loadSystemStatus()
                            }
                        }
                    }
                }

                if supportsCommands {
                    Section {
                        Button("Refresh All", systemImage: "arrow.clockwise") {
                            Task { await runCommand(named: "Refresh All", action: refreshAll) }
                        }
                        .disabled(isRunningCommand)

                        Button("RSS Sync", systemImage: "dot.radiowaves.left.and.right") {
                            Task { await runCommand(named: "RSS Sync", action: rssSync) }
                        }
                        .disabled(isRunningCommand)

                        Button("Search All Missing", systemImage: "magnifyingglass") {
                            Task { await runCommand(named: "Search All Missing", action: searchAllMissing) }
                        }
                        .disabled(isRunningCommand)
                    } header: {
                        Text("Commands")
                    } footer: {
                        if let commandStatusMessage {
                            Text(commandStatusMessage)
                        } else {
                            Text("Send maintenance commands directly to \(serviceType.displayName).")
                        }
                    }
                }

                Section {
                    Button(removeButtonTitle, systemImage: "trash", role: .destructive) {
                        if let profile {
                            Task {
                                await deleteProfile(profile)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(serviceType.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .sheet(item: $editorContext) { context in
            ArrSetupSheet(initialServiceType: context.initialServiceType, existingProfile: context.profile, onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
        .onAppear {
            isViewActive = true
        }
        .onDisappear {
            isViewActive = false
        }
        .task(id: "\(profile?.id.uuidString ?? "none")-\(isConnected)") {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await loadSystemStatus()
            #if os(iOS)
            deviceToken = await NotificationService.shared.deviceToken
            #endif
            await loadNotificationSetupStatus()
        }
        .refreshable {
            await loadSystemStatus()
            await loadNotificationSetupStatus()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: NotificationConstants.apnsTokenReceivedNotification)) { notification in
            if let token = notification.object as? String {
                deviceToken = token
                Task { await loadNotificationSetupStatus() }
            }
        }
        #endif
    }

    private var activeProfileID: UUID? {
        switch serviceType {
        case .sonarr:
            serviceManager.activeSonarrInstanceID
        case .radarr:
            serviceManager.activeRadarrInstanceID
        case .prowlarr:
            serviceManager.activeProwlarrProfileID
        case .bazarr:
            serviceManager.activeBazarrProfileID
        }
    }

    private func isProfileConnected(_ profileID: UUID) -> Bool {
        serviceManager.isConnected(serviceType, profileID: profileID)
    }

    private func setActiveProfile(_ profileID: UUID) {
        switch serviceType {
        case .sonarr:
            serviceManager.setActiveSonarr(profileID)
        case .radarr:
            serviceManager.setActiveRadarr(profileID)
        case .prowlarr:
            break
        case .bazarr:
            serviceManager.setActiveBazarr(profileID)
        }
    }

    private func deleteProfile(_ profile: ArrServiceProfile) async {
        let viewModel = ArrSetupViewModel(serviceManager: serviceManager)
        await viewModel.deleteProfile(profile, modelContext: modelContext)
    }

    private var removeButtonTitle: String {
        guard let profile else { return "Remove \(serviceType.displayName)" }
        guard serviceType != .prowlarr, serviceProfiles.count > 1 else { return "Remove \(serviceType.displayName)" }
        return "Remove \(profile.displayName)"
    }

    private func loadSystemStatus() async {
        guard profile != nil else {
            systemStatus = nil
            systemStatusError = nil
            isLoadingStatus = false
            return
        }

        if serviceType == .bazarr {
            guard let entry = serviceManager.activeBazarrEntry, let client = entry.client else {
                systemStatus = nil
                systemStatusError = "No connected Bazarr instance"
                isLoadingStatus = false
                return
            }
            isLoadingStatus = true
            defer { isLoadingStatus = false }
            do {
                let bazarrStatus = try await client.getSystemStatus()
                systemStatus = ArrSystemStatus(
                    appName: "Bazarr",
                    instanceName: "Bazarr",
                    version: bazarrStatus.bazarrVersion,
                    buildTime: nil,
                    isDebug: nil,
                    isProduction: nil,
                    isAdmin: nil,
                    isUserInteractive: nil,
                    startupPath: bazarrStatus.bazarrDirectory,
                    appData: bazarrStatus.bazarrConfigDirectory,
                    osName: bazarrStatus.operatingSystem,
                    osVersion: nil,
                    isDocker: nil,
                    isLinux: nil,
                    isOsx: nil,
                    isWindows: nil,
                    urlBase: nil,
                    runtimeVersion: bazarrStatus.pythonVersion,
                    runtimeName: "Python"
                )
                systemStatusError = nil
            } catch {
                systemStatus = nil
                systemStatusError = error.localizedDescription
            }
            return
        }

        let client: ArrServiceStatusProviding? = switch serviceType {
        case .sonarr:
            serviceManager.sonarrClient
        case .radarr:
            serviceManager.radarrClient
        case .prowlarr:
            serviceManager.prowlarrClient
        case .bazarr:
            nil
        }

        guard let client else {
            systemStatus = nil
            systemStatusError = nil
            isLoadingStatus = false
            return
        }

        isLoadingStatus = true
        defer { isLoadingStatus = false }

        do {
            systemStatus = try await client.getSystemStatus()
            systemStatusError = nil
        } catch {
            systemStatus = nil
            systemStatusError = error.localizedDescription
        }
    }

    // MARK: - Actions

    private func setupNotifications() {
        guard supportsNotifications else { return }
        guard let profile else { return }

        isSettingUpNotifications = true
        notificationSetupMessage = nil
        Task {
            #if os(iOS)
            let token = await NotificationService.shared.deviceToken
            #else
            let token: String? = nil
            #endif

            guard let token else {
                isSettingUpNotifications = false
                return
            }

            let url = NotificationService.shared.workerURL

            do {
                try await serviceManager.setupNotifications(for: profile, workerURL: url, deviceToken: token)
                notificationSetupStatus = .configured
                if isViewActive {
                    inAppNotificationCenter.showSuccess(title: "Success", message: "Notifications configured in \(serviceType.displayName)")
                }
            } catch {
                await loadNotificationSetupStatus()
                if isViewActive {
                    inAppNotificationCenter.showError(title: "Setup Failed", message: error.localizedDescription)
                }
                isSettingUpNotifications = false
                return
            }
            await loadNotificationSetupStatus()
            isSettingUpNotifications = false
        }
    }

    private func loadNotificationSetupStatus() async {
        guard supportsNotifications, isConnected, let profile else {
            notificationSetupStatus = nil
            return
        }

        #if os(iOS)
        let token = if let deviceToken {
            deviceToken
        } else {
            await NotificationService.shared.deviceToken
        }
        #else
        let token: String? = nil
        #endif

        guard let token, !token.isEmpty else {
            notificationSetupStatus = nil
            return
        }

        do {
            notificationSetupStatus = try await serviceManager.notificationSetupStatus(
                for: profile,
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            )
        } catch {
            notificationSetupStatus = nil
        }
    }

    @ViewBuilder
    private func notificationSetupStatusRow(_ status: ArrNotificationSetupStatus) -> some View {
        switch status {
        case .configured:
            Label("Trawl webhook is configured.", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .needsUpdate:
            Label("Trawl webhook exists but needs updating.", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .notAdded:
            Label("Trawl webhook has not been added yet.", systemImage: "minus.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func serviceInfoRow(label: String, value: String) -> some View {
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

    private func runCommand(named name: String, action: @escaping () async throws -> Void) async {
        isRunningCommand = true
        commandStatusMessage = nil
        do {
            try await action()
            commandStatusMessage = "\(name) command sent."
        } catch {
            commandStatusMessage = "\(name) failed: \(error.localizedDescription)"
        }
        isRunningCommand = false
    }

    private func refreshAll() async throws {
        switch serviceType {
        case .sonarr:
            let viewModel = SonarrViewModel(serviceManager: serviceManager)
            try await viewModel.refreshSeries()
        case .radarr:
            let viewModel = RadarrViewModel(serviceManager: serviceManager)
            try await viewModel.refreshMovies()
        case .prowlarr, .bazarr:
            break
        }
    }

    private func rssSync() async throws {
        switch serviceType {
        case .sonarr:
            let viewModel = SonarrViewModel(serviceManager: serviceManager)
            try await viewModel.rssSync()
        case .radarr:
            let viewModel = RadarrViewModel(serviceManager: serviceManager)
            try await viewModel.rssSync()
        case .prowlarr, .bazarr:
            break
        }
    }

    private func searchAllMissing() async throws {
        switch serviceType {
        case .sonarr:
            let viewModel = SonarrViewModel(serviceManager: serviceManager)
            try await viewModel.searchAllMissing(noun: "series")
        case .radarr:
            let viewModel = RadarrViewModel(serviceManager: serviceManager)
            try await viewModel.searchAllMissing(noun: "movies")
        case .prowlarr, .bazarr:
            break
        }
    }

}

private enum ArrServiceEditorContext: Identifiable {
    case create(ArrServiceType)
    case edit(ArrServiceProfile)

    var id: String {
        switch self {
        case .create(let serviceType):
            "create-\(serviceType.rawValue)"
        case .edit(let profile):
            "edit-\(profile.id.uuidString)"
        }
    }

    var initialServiceType: ArrServiceType? {
        switch self {
        case .create(let serviceType):
            serviceType
        case .edit:
            nil
        }
    }

    var profile: ArrServiceProfile? {
        switch self {
        case .create:
            nil
        case .edit(let profile):
            profile
        }
    }
}

private protocol ArrServiceStatusProviding: Sendable {
    func getSystemStatus() async throws -> ArrSystemStatus
}

extension SonarrAPIClient: ArrServiceStatusProviding {}
extension RadarrAPIClient: ArrServiceStatusProviding {}
extension ProwlarrAPIClient: ArrServiceStatusProviding {}

// MARK: - All-services settings view

#if DEBUG
#Preview("Service Detail - Connected") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        NavigationStack {
            ArrServiceSettingsView(
                serviceType: .sonarr,
                previewStatus: .preview,
                previewNotificationStatus: .configured
            )
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Service Detail - Loading") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.radarrOnly)) {
        NavigationStack {
            ArrServiceSettingsView(
                serviceType: .radarr,
                previewIsLoadingStatus: true
            )
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Service Detail - Unconfigured") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        NavigationStack {
            ArrServiceSettingsView(serviceType: .prowlarr)
        }
        .environment(InAppNotificationCenter.shared)
    }
}
#endif
