import SwiftUI
import SwiftData

struct ArrServiceSettingsView: View {
    let serviceType: ArrServiceType

    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]
    @State private var editorContext: ArrServiceEditorContext?
    @State private var systemStatus: ArrSystemStatus?
    @State private var isLoadingStatus = false
    @State private var systemStatusError: String?
    @State private var commandStatusMessage: String?
    @State private var isRunningCommand = false
    #if DEBUG
    private let previewNotificationStatus: ArrNotificationSetupStatus?
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
        self.previewNotificationStatus = previewNotificationStatus
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

                if serviceType.supportsWebhookNotifications, isConnected {
                    Section("Notifications") {
                        NavigationLink {
                            ArrWebhookNotificationConfigView(
                                serviceType: serviceType,
                                profile: profile,
                                isConnected: isConnected
                            )
                        } label: {
                            #if DEBUG
                            ArrWebhookNotificationHubRow(
                                serviceType: serviceType,
                                profile: profile,
                                isConnected: isConnected,
                                previewStatus: previewNotificationStatus
                            )
                            #else
                            ArrWebhookNotificationHubRow(
                                serviceType: serviceType,
                                profile: profile,
                                isConnected: isConnected
                            )
                            #endif
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
        .task(id: "\(profile?.id.uuidString ?? "none")-\(isConnected)") {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await loadSystemStatus()
        }
        .refreshable {
            await loadSystemStatus()
        }
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

extension ArrServiceType {
    static let webhookNotificationServices: [ArrServiceType] = [.sonarr, .radarr, .prowlarr]

    var supportsWebhookNotifications: Bool {
        Self.webhookNotificationServices.contains(self)
    }
}

struct ArrWebhookNotificationHubRow: View {
    let serviceType: ArrServiceType
    let profile: ArrServiceProfile?
    let isConnected: Bool

    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var status: ArrNotificationSetupStatus?
    #if os(iOS)
    @State private var deviceToken: String?
    #endif

    init(
        serviceType: ArrServiceType,
        profile: ArrServiceProfile?,
        isConnected: Bool,
        previewStatus: ArrNotificationSetupStatus? = nil
    ) {
        self.serviceType = serviceType
        self.profile = profile
        self.isConnected = isConnected
        _status = State(initialValue: previewStatus)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: serviceType.serviceIdentity.systemImage)
                .foregroundStyle(serviceType.serviceIdentity.brandColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(serviceType.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text(profile?.displayName ?? "No server configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                statusLabel
                    .font(.caption2)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .task(id: taskID) {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await refreshStatus()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: NotificationConstants.apnsTokenReceivedNotification)) { notification in
            if let token = notification.object as? String {
                deviceToken = token
                Task { await loadStatus() }
            }
        }
        #endif
    }

    @ViewBuilder
    private var statusLabel: some View {
        if profile == nil {
            Label("Add a \(serviceType.displayName) server first", systemImage: "minus.circle.fill")
                .foregroundStyle(.secondary)
        } else if !isConnected {
            Label("\(serviceType.displayName) is unavailable", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if status == nil {
            Label("Open to configure triggers and tags", systemImage: "slider.horizontal.3")
                .foregroundStyle(.secondary)
        } else if let status {
            notificationSetupStatusRow(status)
        }
    }

    private var taskID: String {
        #if os(iOS)
        "\(serviceType.rawValue)-\(profile?.id.uuidString ?? "none")-\(isConnected)-\(deviceToken ?? "nil")"
        #else
        "\(serviceType.rawValue)-\(profile?.id.uuidString ?? "none")-\(isConnected)"
        #endif
    }

    @MainActor
    private func refreshStatus() async {
        #if os(iOS)
        deviceToken = await NotificationService.shared.deviceToken
        #endif
        await loadStatus()
    }

    @MainActor
    private func loadStatus() async {
        guard isConnected, let profile else {
            status = nil
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
            status = nil
            return
        }

        status = try? await serviceManager.notificationSetupStatus(
            for: profile,
            workerURL: NotificationService.shared.workerURL,
            deviceToken: token
        )
    }
}

struct ArrWebhookNotificationConfigView: View {
    let serviceType: ArrServiceType
    let profile: ArrServiceProfile?
    let isConnected: Bool

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var draft = ArrWebhookNotificationDraft()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var loadError: String?
    #if os(iOS)
    @State private var deviceToken: String?
    #endif

    private var availableTags: [ArrTag] {
        guard let profile else { return [] }
        return serviceManager.tags(for: profile)
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var canSave: Bool {
        serviceType.supportsWebhookNotifications && isConnected && profile != nil && !isSaving && !isLoading && hasDeviceToken
    }

    private var canTest: Bool {
        canSave && !isTesting
    }

    private var hasDeviceToken: Bool {
        #if os(iOS)
        deviceToken?.isEmpty == false
        #else
        false
        #endif
    }

    var body: some View {
        Form {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if profile == nil || !isConnected || !hasDeviceToken {
                Section {
                    Label(unavailableMessage, systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(ArrWebhookNotificationTrigger.triggers(for: serviceType)) { trigger in
                    Toggle(isOn: binding(for: trigger)) {
                        Label(trigger.title, systemImage: trigger.systemImage)
                    }
                }
            } header: {
                Text("Notification Triggers")
            } footer: {
                Text("Select which events should trigger this notification")
            }

            Section {
                if availableTags.isEmpty {
                    Text("No tags available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableTags) { tag in
                        Button {
                            toggleTag(tag.id)
                        } label: {
                            HStack {
                                Text(tag.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if draft.tagIDs.contains(tag.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(serviceType.serviceIdentity.brandColor)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("Only send notifications for \(serviceType.mediaNounPlural) with at least one matching tag")
            }

            Section {
                Button {
                    Task { await testNotification() }
                } label: {
                    if isTesting {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Testing...")
                        }
                    } else {
                        Label("Test", systemImage: "paperplane")
                    }
                }
                .disabled(!canTest)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle("\(serviceType.displayName) Notifications")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .task(id: "\(profile?.id.uuidString ?? "none")-\(isConnected)") {
            #if DEBUG
            if ArrPreviewRuntime.isActive {
                draft = .preview(serviceType: serviceType)
                return
            }
            #endif
            await load()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: NotificationConstants.apnsTokenReceivedNotification)) { notification in
            if let token = notification.object as? String {
                deviceToken = token
                Task { await load() }
            }
        }
        #endif
    }

    private var unavailableMessage: String {
        if profile == nil {
            return "Add a \(serviceType.displayName) server before configuring notifications."
        }
        if !isConnected {
            return "\(serviceType.displayName) needs to be connected before webhook setup."
        }
        if !hasDeviceToken {
            return "Enable notifications in Trawl settings first."
        }
        return "Notification configuration is unavailable."
    }

    @MainActor
    private func load() async {
        guard serviceType.supportsWebhookNotifications, isConnected, let profile else { return }
        isLoading = true
        defer { isLoading = false }

        #if os(iOS)
        deviceToken = await NotificationService.shared.deviceToken
        #endif

        guard let token = currentDeviceToken else { return }

        do {
            let notification = try await serviceManager.trawlNotification(
                for: profile,
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            )
            draft = ArrWebhookNotificationDraft(notification: notification, serviceType: serviceType)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var currentDeviceToken: String? {
        #if os(iOS)
        guard let deviceToken, !deviceToken.isEmpty else { return nil }
        return deviceToken
        #else
        return nil
        #endif
    }

    private func binding(for trigger: ArrWebhookNotificationTrigger) -> Binding<Bool> {
        Binding(
            get: { draft.isEnabled(trigger) },
            set: { draft.setEnabled($0, for: trigger) }
        )
    }

    private func toggleTag(_ tagID: Int) {
        if draft.tagIDs.contains(tagID) {
            draft.tagIDs.remove(tagID)
        } else {
            draft.tagIDs.insert(tagID)
        }
    }

    @MainActor
    private func save() async {
        guard let profile, let token = currentDeviceToken else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            try await serviceManager.saveTrawlNotification(
                draft.notification(name: nil, serviceType: serviceType),
                for: profile,
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            )
            inAppNotificationCenter.showSuccess(title: "Saved", message: "\(serviceType.displayName) notifications updated.")
            await load()
        } catch {
            inAppNotificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
        }
    }

    @MainActor
    private func testNotification() async {
        guard let profile, let token = currentDeviceToken else { return }
        isTesting = true
        defer { isTesting = false }

        do {
            try await serviceManager.testTrawlNotification(
                draft.notification(name: nil, serviceType: serviceType),
                for: profile,
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            )
            inAppNotificationCenter.showSuccess(title: "Test Sent", message: "\(serviceType.displayName) accepted the webhook test.")
        } catch {
            inAppNotificationCenter.showError(title: "Test Failed", message: error.localizedDescription)
        }
    }
}

private struct ArrWebhookNotificationDraft {
    var id: Int?
    var onGrab = true
    var onDownload = true
    var onUpgrade = true
    var onRename = true
    var onHealthIssue = true
    var onApplicationUpdate = true
    var onSeriesAdd = false
    var onSeriesDelete = false
    var onEpisodeFileDelete = false
    var onEpisodeFileDeleteForUpgrade = false
    var onMovieAdded = false
    var onMovieDelete = false
    var onMovieFileDelete = false
    var onMovieFileDeleteForUpgrade = false
    var includeHealthWarnings = true
    var tagIDs: Set<Int> = []

    init() {}

    init(notification: ArrNotification, serviceType: ArrServiceType) {
        id = notification.id
        onGrab = notification.onGrab ?? true
        onDownload = notification.onDownload ?? true
        onUpgrade = notification.onUpgrade ?? true
        onRename = notification.onRename ?? true
        onHealthIssue = notification.onHealthIssue ?? true
        onApplicationUpdate = notification.onApplicationUpdate ?? true
        onSeriesAdd = notification.onSeriesAdd ?? false
        onSeriesDelete = notification.onSeriesDelete ?? false
        onEpisodeFileDelete = notification.onEpisodeFileDelete ?? false
        onEpisodeFileDeleteForUpgrade = notification.onEpisodeFileDeleteForUpgrade ?? false
        onMovieAdded = notification.onMovieAdded ?? false
        onMovieDelete = notification.onMovieDelete ?? false
        onMovieFileDelete = notification.onMovieFileDelete ?? false
        onMovieFileDeleteForUpgrade = notification.onMovieFileDeleteForUpgrade ?? false
        includeHealthWarnings = notification.includeHealthWarnings ?? true
        tagIDs = Set(notification.tags)

        if serviceType == .sonarr {
            onMovieAdded = false
            onMovieDelete = false
            onMovieFileDelete = false
            onMovieFileDeleteForUpgrade = false
        } else if serviceType == .radarr {
            onSeriesAdd = false
            onSeriesDelete = false
            onEpisodeFileDelete = false
            onEpisodeFileDeleteForUpgrade = false
        } else if serviceType == .prowlarr {
            onGrab = false
            onDownload = false
            onUpgrade = false
            onRename = false
            onSeriesAdd = false
            onSeriesDelete = false
            onEpisodeFileDelete = false
            onEpisodeFileDeleteForUpgrade = false
            onMovieAdded = false
            onMovieDelete = false
            onMovieFileDelete = false
            onMovieFileDeleteForUpgrade = false
        }
    }

    static func preview(serviceType: ArrServiceType) -> ArrWebhookNotificationDraft {
        var draft = ArrWebhookNotificationDraft()
        draft.tagIDs = serviceType == .sonarr ? [1, 3] : [2]
        return draft
    }

    func isEnabled(_ trigger: ArrWebhookNotificationTrigger) -> Bool {
        switch trigger.key {
        case .grab: onGrab
        case .download: onDownload
        case .upgrade: onUpgrade
        case .rename: onRename
        case .healthIssue: onHealthIssue
        case .applicationUpdate: onApplicationUpdate
        case .seriesAdd: onSeriesAdd
        case .seriesDelete: onSeriesDelete
        case .episodeFileDelete: onEpisodeFileDelete
        case .episodeFileDeleteForUpgrade: onEpisodeFileDeleteForUpgrade
        case .movieAdded: onMovieAdded
        case .movieDelete: onMovieDelete
        case .movieFileDelete: onMovieFileDelete
        case .movieFileDeleteForUpgrade: onMovieFileDeleteForUpgrade
        case .includeHealthWarnings: includeHealthWarnings
        }
    }

    mutating func setEnabled(_ isEnabled: Bool, for trigger: ArrWebhookNotificationTrigger) {
        switch trigger.key {
        case .grab: onGrab = isEnabled
        case .download: onDownload = isEnabled
        case .upgrade: onUpgrade = isEnabled
        case .rename: onRename = isEnabled
        case .healthIssue: onHealthIssue = isEnabled
        case .applicationUpdate: onApplicationUpdate = isEnabled
        case .seriesAdd: onSeriesAdd = isEnabled
        case .seriesDelete: onSeriesDelete = isEnabled
        case .episodeFileDelete: onEpisodeFileDelete = isEnabled
        case .episodeFileDeleteForUpgrade: onEpisodeFileDeleteForUpgrade = isEnabled
        case .movieAdded: onMovieAdded = isEnabled
        case .movieDelete: onMovieDelete = isEnabled
        case .movieFileDelete: onMovieFileDelete = isEnabled
        case .movieFileDeleteForUpgrade: onMovieFileDeleteForUpgrade = isEnabled
        case .includeHealthWarnings: includeHealthWarnings = isEnabled
        }
    }

    func notification(name: String?, serviceType: ArrServiceType) -> ArrNotification {
        let isSonarr = serviceType == .sonarr
        let isRadarr = serviceType == .radarr
        let isProwlarr = serviceType == .prowlarr

        return ArrNotification(
            id: id,
            name: name ?? "Trawl",
            onGrab: isProwlarr ? nil : onGrab,
            onDownload: isProwlarr ? nil : onDownload,
            onUpgrade: isProwlarr ? nil : onUpgrade,
            onRename: isProwlarr ? nil : onRename,
            onHealthIssue: onHealthIssue,
            onApplicationUpdate: onApplicationUpdate,
            onSeriesAdd: isSonarr ? onSeriesAdd : nil,
            onSeriesDelete: isSonarr ? onSeriesDelete : nil,
            onEpisodeFileDelete: isSonarr ? onEpisodeFileDelete : nil,
            onEpisodeFileDeleteForUpgrade: isSonarr ? onEpisodeFileDeleteForUpgrade : nil,
            onMovieAdded: isRadarr ? onMovieAdded : nil,
            onMovieDelete: isRadarr ? onMovieDelete : nil,
            onMovieFileDelete: isRadarr ? onMovieFileDelete : nil,
            onMovieFileDeleteForUpgrade: isRadarr ? onMovieFileDeleteForUpgrade : nil,
            includeHealthWarnings: includeHealthWarnings,
            implementation: "Webhook",
            configContract: "WebhookSettings",
            fields: [],
            tags: Array(tagIDs).sorted()
        )
    }
}

private struct ArrWebhookNotificationTrigger: Identifiable {
    enum Key {
        case grab
        case download
        case upgrade
        case rename
        case healthIssue
        case applicationUpdate
        case seriesAdd
        case seriesDelete
        case episodeFileDelete
        case episodeFileDeleteForUpgrade
        case movieAdded
        case movieDelete
        case movieFileDelete
        case movieFileDeleteForUpgrade
        case includeHealthWarnings
    }

    let key: Key
    let title: String
    let systemImage: String

    var id: String { "\(key)" }

    static func triggers(for serviceType: ArrServiceType) -> [ArrWebhookNotificationTrigger] {
        if serviceType == .prowlarr {
            return [
                .init(key: .healthIssue, title: "Health Issue", systemImage: "heart.text.square.fill"),
                .init(key: .includeHealthWarnings, title: "Include Health Warnings", systemImage: "exclamationmark.triangle.fill"),
                .init(key: .applicationUpdate, title: "Application Update", systemImage: "arrow.down.app.fill")
            ]
        }

        var common: [ArrWebhookNotificationTrigger] = [
            .init(key: .grab, title: "Grab", systemImage: "tray.and.arrow.down.fill"),
            .init(key: .download, title: "Import", systemImage: "square.and.arrow.down.fill"),
            .init(key: .upgrade, title: "Upgrade", systemImage: "arrow.up.circle.fill"),
            .init(key: .rename, title: "Rename", systemImage: "textformat"),
            .init(key: .healthIssue, title: "Health Issue", systemImage: "heart.text.square.fill"),
            .init(key: .includeHealthWarnings, title: "Include Health Warnings", systemImage: "exclamationmark.triangle.fill"),
            .init(key: .applicationUpdate, title: "Application Update", systemImage: "arrow.down.app.fill")
        ]

        switch serviceType {
        case .sonarr:
            common.insert(contentsOf: [
                .init(key: .seriesAdd, title: "Series Added", systemImage: "plus.rectangle.on.folder.fill"),
                .init(key: .seriesDelete, title: "Series Deleted", systemImage: "trash.fill"),
                .init(key: .episodeFileDelete, title: "Episode File Deleted", systemImage: "xmark.bin.fill"),
                .init(key: .episodeFileDeleteForUpgrade, title: "Episode File Deleted for Upgrade", systemImage: "arrow.triangle.2.circlepath")
            ], at: 4)
        case .radarr:
            common.insert(contentsOf: [
                .init(key: .movieAdded, title: "Movie Added", systemImage: "plus.rectangle.on.folder.fill"),
                .init(key: .movieDelete, title: "Movie Deleted", systemImage: "trash.fill"),
                .init(key: .movieFileDelete, title: "Movie File Deleted", systemImage: "xmark.bin.fill"),
                .init(key: .movieFileDeleteForUpgrade, title: "Movie File Deleted for Upgrade", systemImage: "arrow.triangle.2.circlepath")
            ], at: 4)
        case .prowlarr, .bazarr:
            break
        }

        return common
    }
}

private extension ArrServiceType {
    var mediaNounPlural: String {
        switch self {
        case .sonarr: "series"
        case .radarr: "movies"
        case .prowlarr: "indexers"
        case .bazarr: "items"
        }
    }
}

@ViewBuilder
private func notificationSetupStatusRow(_ status: ArrNotificationSetupStatus) -> some View {
    switch status {
    case .configured:
        Label("Trawl webhook is configured", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    case .needsUpdate:
        Label("Trawl webhook needs updating", systemImage: "arrow.triangle.2.circlepath.circle.fill")
            .foregroundStyle(.orange)
    case .notAdded:
        Label("Trawl webhook has not been added", systemImage: "minus.circle.fill")
            .foregroundStyle(.secondary)
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
