import SwiftUI
import SwiftData

// MARK: - Per-service settings view (reusable)

struct ArrServiceSettingsView: View {
    let serviceType: ArrServiceType

    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var allProfiles: [ArrServiceProfile]
    @State private var showAddSheet = false
    @State private var systemStatus: ArrSystemStatus?
    @State private var isLoadingStatus = false
    @State private var systemStatusError: String?
    @State private var diskSpaces: [ArrDiskSpaceSnapshot] = []
    @State private var diskSpaceError: String?
    @State private var availableUpdates: [ArrUpdateInfo] = []
    @State private var isLoadingUpdates = false
    @State private var showUpdateConfirmation = false
    @State private var commandStatusMessage: String?
    @State private var isRunningCommand = false
    @State private var isSettingUpNotifications = false
    @State private var notificationSetupMessage: String?
    @State private var isViewActive = false
    
    #if os(iOS)
    @State private var deviceToken: String?
    #endif

    private var profile: ArrServiceProfile? {
        serviceManager.resolvedProfile(for: serviceType, in: allProfiles, allowErroredFallback: false)
    }

    private var isConnected: Bool {
        switch serviceType {
        case .sonarr: serviceManager.sonarrConnected
        case .radarr: serviceManager.radarrConnected
        case .prowlarr: serviceManager.prowlarrConnected
        }
    }

    private var serviceColor: Color {
        switch serviceType {
        case .sonarr: .purple
        case .radarr: .orange
        case .prowlarr: .yellow
        }
    }

    private var supportsDiskSpace: Bool {
        serviceType != .prowlarr
    }

    private var supportsCommands: Bool {
        serviceType != .prowlarr
    }

    private var qualityProfiles: [ArrQualityProfile] {
        switch serviceType {
        case .sonarr:
            serviceManager.sonarrQualityProfiles
        case .radarr:
            serviceManager.radarrQualityProfiles
        case .prowlarr:
            []
        }
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
                        showAddSheet = true
                    }
                } else {
                    Button {
                        showAddSheet = true
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

                if serviceType != .prowlarr, isConnected {
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

                        if let notificationSetupMessage {
                            Label(notificationSetupMessage, systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }

                if serviceType == .prowlarr, isConnected {
                    Section {
                        NavigationLink {
                            ProwlarrApplicationsListView()
                                .environment(serviceManager)
                        } label: {
                            Label("Linked Applications", systemImage: "app.connected.to.app.below.fill")
                        }
                    } header: {
                        Text("Automation")
                    } footer: {
                        Text("Link Sonarr or Radarr so Prowlarr can sync indexers directly into those services.")
                    }
                }

                if !qualityProfiles.isEmpty {
                    Section {
                        NavigationLink {
                            ArrQualityProfilesListView(serviceType: serviceType)
                        } label: {
                            HStack {
                                Label("Quality Profiles", systemImage: "slider.horizontal.3")
                                Spacer()
                                Text("\(qualityProfiles.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Library Defaults")
                    } footer: {
                        Text("Review what each profile allows before assigning it to series or movies.")
                    }
                }

                if let update = availableUpdates.first(where: { $0.installed == false }) {
                    Section("Update Available") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("v\(update.version ?? "Unknown")")
                                    .fontWeight(.bold)
                                Spacer()
                                if let date = update.releaseDate {
                                    Text(date.prefix(10))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let changes = update.changes {
                                if let new = changes.new, !new.isEmpty {
                                    Text("New:").font(.caption).fontWeight(.semibold).padding(.top, 4)
                                    ForEach(new.prefix(3), id: \.self) { change in
                                        Text("• \(change)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Button {
                                showUpdateConfirmation = true
                            } label: {
                                Label("Install Update", systemImage: "arrow.down.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 8)
                            .disabled(isRunningCommand)
                        }
                    }
                }

                if supportsDiskSpace && !diskSpaces.isEmpty {
                    Section("Disk Space") {
                        ForEach(diskSpaces) { disk in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(disk.path)
                                        .font(.subheadline)
                                        .lineLimit(2)
                                    Spacer()
                                    if let freeSpace = disk.freeSpace {
                                        Text(ByteFormatter.format(bytes: freeSpace) + " free")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let totalSpace = disk.totalSpace, totalSpace > 0, let freeSpace = disk.freeSpace {
                                    ProgressView(value: Double(totalSpace - freeSpace), total: Double(totalSpace))
                                        .tint(freeSpace > totalSpace / 5 ? .blue : .orange)
                                    serviceInfoRow(
                                        label: "Used",
                                        value: "\(ByteFormatter.format(bytes: totalSpace - freeSpace)) of \(ByteFormatter.format(bytes: totalSpace))"
                                    )
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else if supportsDiskSpace, let diskSpaceError {
                    Section("Disk Space") {
                        Label(diskSpaceError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
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
                    Button("Remove \(serviceType.displayName)", systemImage: "trash", role: .destructive) {
                        if let profile {
                            Task {
                                let vm = ArrSetupViewModel(serviceManager: serviceManager)
                                await vm.deleteProfile(profile, modelContext: modelContext)
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
        .sheet(isPresented: $showAddSheet) {
            ArrSetupSheet(initialServiceType: serviceType, existingProfile: profile, onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
        .confirmationDialog(
            "Install Update",
            isPresented: $showUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Install Now") {
                Task { await runCommand(named: "Install Update", action: installUpdate) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if systemStatus?.isDocker == true {
                Text("Warning: Internal updates are often disabled or discouraged for Docker instances. You should typically update by pulling a new image.")
            } else {
                Text("This will download and install the update. The service will restart automatically.")
            }
        }
        .onAppear {
            isViewActive = true
        }
        .onDisappear {
            isViewActive = false
        }
        .task(id: "\(profile?.id.uuidString ?? "none")-\(isConnected)") {
            await loadSystemStatus()
            await loadDiskSpace()
            await loadUpdates()
            #if os(iOS)
            deviceToken = await NotificationService.shared.deviceToken
            #endif
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: NotificationConstants.apnsTokenReceivedNotification)) { notification in
            if let token = notification.object as? String {
                deviceToken = token
            }
        }
        #endif
    }

    private func loadDiskSpace() async {
        let client: ArrDiskSpaceProviding? = switch serviceType {
        case .sonarr: serviceManager.sonarrClient
        case .radarr: serviceManager.radarrClient
        case .prowlarr: nil
        }
        guard let client else {
            diskSpaces = []
            diskSpaceError = nil
            return
        }
        do {
            let raw = try await client.getDiskSpace()
            diskSpaces = raw.map {
                ArrDiskSpaceSnapshot(
                    serviceType: serviceType,
                    path: $0.path ?? "Unknown",
                    label: $0.label,
                    freeSpace: $0.freeSpace,
                    totalSpace: $0.totalSpace
                )
            }
            diskSpaceError = nil
        } catch {
            diskSpaces = []
            diskSpaceError = error.localizedDescription
        }
    }

    private func loadSystemStatus() async {
        guard profile != nil else {
            systemStatus = nil
            systemStatusError = nil
            isLoadingStatus = false
            return
        }

        let client: ArrServiceStatusProviding? = switch serviceType {
        case .sonarr:
            serviceManager.sonarrClient
        case .radarr:
            serviceManager.radarrClient
        case .prowlarr:
            serviceManager.prowlarrClient
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

    private func loadUpdates() async {
        let client: ArrUpdatesProviding? = switch serviceType {
        case .sonarr: serviceManager.sonarrClient
        case .radarr: serviceManager.radarrClient
        case .prowlarr: nil
        }
        guard let client else {
            availableUpdates = []
            return
        }
        isLoadingUpdates = true
        defer { isLoadingUpdates = false }
        do {
            availableUpdates = try await client.getUpdates()
        } catch {
            availableUpdates = []
        }
    }

    // MARK: - Actions

    private func setupNotifications() {
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
                notificationSetupMessage = "Webhook configured for \(serviceType.displayName)."
                if isViewActive {
                    inAppNotificationCenter.showSuccess(title: "Success", message: "Notifications configured in \(serviceType.displayName)")
                }
            } catch {
                notificationSetupMessage = nil
                if isViewActive {
                    inAppNotificationCenter.showError(title: "Setup Failed", message: error.localizedDescription)
                }
            }
            isSettingUpNotifications = false
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
        case .prowlarr:
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
        case .prowlarr:
            break
        }
    }

    private func searchAllMissing() async throws {
        switch serviceType {
        case .sonarr:
            let viewModel = SonarrViewModel(serviceManager: serviceManager)
            try await viewModel.searchAllMissing()
        case .radarr:
            let viewModel = RadarrViewModel(serviceManager: serviceManager)
            try await viewModel.searchAllMissing()
        case .prowlarr:
            break
        }
    }

    private func installUpdate() async throws {
        switch serviceType {
        case .sonarr:
            let viewModel = SonarrViewModel(serviceManager: serviceManager)
            try await viewModel.installUpdate()
        case .radarr:
            let viewModel = RadarrViewModel(serviceManager: serviceManager)
            try await viewModel.installUpdate()
        case .prowlarr:
            break
        }
    }
}

private protocol ArrServiceStatusProviding: Sendable {
    func getSystemStatus() async throws -> ArrSystemStatus
}

extension SonarrAPIClient: ArrServiceStatusProviding {}
extension RadarrAPIClient: ArrServiceStatusProviding {}
extension ProwlarrAPIClient: ArrServiceStatusProviding {}

private protocol ArrDiskSpaceProviding: Sendable {
    func getDiskSpace() async throws -> [ArrDiskSpace]
}

extension SonarrAPIClient: ArrDiskSpaceProviding {}
extension RadarrAPIClient: ArrDiskSpaceProviding {}

private protocol ArrUpdatesProviding: Sendable {
    func getUpdates() async throws -> [ArrUpdateInfo]
}

extension SonarrAPIClient: ArrUpdatesProviding {}
extension RadarrAPIClient: ArrUpdatesProviding {}

// MARK: - All-services settings view

struct ArrServicesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var profiles: [ArrServiceProfile]
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section("Connected Services") {
                if profiles.isEmpty {
                    Text("No services configured. Tap + to add Sonarr, Radarr, or Prowlarr.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        ServiceProfileRow(
                            profile: profile,
                            isConnected: isConnected(profile)
                        )
                    }
                    .onDelete(perform: deleteProfiles)
                }
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Service", systemImage: "plus.circle")
                }
            }

            Section("Status") {
                HStack {
                    Label("Sonarr", systemImage: "tv")
                    Spacer()
                    Image(systemName: serviceManager.sonarrConnected ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(serviceManager.sonarrConnected ? .green : .red)
                    Text(serviceManager.sonarrConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Radarr", systemImage: "film")
                    Spacer()
                    Image(systemName: serviceManager.radarrConnected ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(serviceManager.radarrConnected ? .green : .red)
                    Text(serviceManager.radarrConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Prowlarr", systemImage: "magnifyingglass.circle")
                    Spacer()
                    Image(systemName: serviceManager.prowlarrConnected ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(serviceManager.prowlarrConnected ? .green : .red)
                    Text(serviceManager.prowlarrConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !serviceManager.connectionErrors.isEmpty {
                Section("Errors") {
                    ForEach(serviceManager.connectionErrors.sorted(by: { $0.key < $1.key }), id: \.key) { _, error in
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Arr Services")
        .sheet(isPresented: $showAddSheet) {
            ArrSetupSheet(onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
    }

    private func isConnected(_ profile: ArrServiceProfile) -> Bool {
        guard let serviceType = profile.resolvedServiceType else { return false }
        switch serviceType {
        case .sonarr: return serviceManager.sonarrConnected
        case .radarr: return serviceManager.radarrConnected
        case .prowlarr: return serviceManager.prowlarrConnected
        }
    }

    private func deleteProfiles(at offsets: IndexSet) {
        for index in offsets {
            let profile = profiles[index]
            Task {
                let vm = ArrSetupViewModel(serviceManager: serviceManager)
                await vm.deleteProfile(profile, modelContext: modelContext)
            }
        }
    }
}

private struct ArrQualityProfilesListView: View {
    let serviceType: ArrServiceType
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @State private var editorSession: ArrQualityProfileEditorSession?
    @State private var profilePendingDelete: ArrQualityProfile?
    @State private var isSaving = false

    private var profiles: [ArrQualityProfile] {
        switch serviceType {
        case .sonarr:
            serviceManager.sonarrQualityProfiles
        case .radarr:
            serviceManager.radarrQualityProfiles
        case .prowlarr:
            []
        }
    }

    private var sortedProfiles: [ArrQualityProfile] {
        profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                ForEach(sortedProfiles) { profile in
                    NavigationLink {
                        ArrQualityProfileDetailView(
                            serviceType: serviceType,
                            profile: profile,
                            onEdit: {
                                editorSession = .edit(profile)
                            },
                            onDuplicate: {
                                editorSession = .duplicate(from: profile)
                            },
                            onDelete: {
                                profilePendingDelete = profile
                            }
                        )
                    } label: {
                        ArrQualityProfileSummaryRow(profile: profile)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            editorSession = .duplicate(from: profile)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            editorSession = .edit(profile)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)

                        Button(role: .destructive) {
                            profilePendingDelete = profile
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") {
                            editorSession = .edit(profile)
                        }
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            editorSession = .duplicate(from: profile)
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            profilePendingDelete = profile
                        }
                    }
                }
            } footer: {
                Text("Quality profiles define which releases qualify, whether upgrades are allowed, and where upgrades stop.")
            }
        }
        .navigationTitle("Quality Profiles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let firstProfile = sortedProfiles.first {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorSession = .duplicate(from: firstProfile)
                    } label: {
                        Label("Duplicate Profile", systemImage: "plus")
                    }
                    .disabled(isSaving)
                }
            }
        }
        .sheet(item: $editorSession) { session in
            NavigationStack {
                ArrQualityProfileEditorView(
                    serviceType: serviceType,
                    session: session,
                    isSaving: isSaving,
                    onSave: { draft in
                        await save(draft)
                    }
                )
            }
        }
        .confirmationDialog(
            "Delete Quality Profile",
            isPresented: Binding(
                get: { profilePendingDelete != nil },
                set: { if !$0 { profilePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let profilePendingDelete else { return }
                Task { await delete(profilePendingDelete) }
            }
            Button("Cancel", role: .cancel) {
                profilePendingDelete = nil
            }
        } message: {
            if let profilePendingDelete {
                Text("Delete '\(profilePendingDelete.name)' from \(serviceType.displayName)?")
            }
        }
    }

    private func save(_ draft: ArrQualityProfileDraft) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }

        let profile = draft.makeProfile()

        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return false }
                if draft.apiID == nil {
                    _ = try await client.createQualityProfile(profile)
                } else {
                    _ = try await client.updateQualityProfile(profile)
                }
            case .radarr:
                guard let client = serviceManager.radarrClient else { return false }
                if draft.apiID == nil {
                    _ = try await client.createQualityProfile(profile)
                } else {
                    _ = try await client.updateQualityProfile(profile)
                }
            case .prowlarr:
                return false
            }

            await serviceManager.refreshConfiguration()
            editorSession = nil
            let verb = draft.apiID == nil ? "created" : "updated"
            inAppNotificationCenter.showSuccess(title: "Saved", message: "Quality profile \(verb) in \(serviceType.displayName).")
            return true
        } catch {
            inAppNotificationCenter.showError(title: "Save Failed", message: error.localizedDescription)
            return false
        }
    }

    private func delete(_ profile: ArrQualityProfile) async {
        guard !isSaving else { return }
        isSaving = true
        defer {
            isSaving = false
            profilePendingDelete = nil
        }

        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                try await client.deleteQualityProfile(id: profile.id)
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                try await client.deleteQualityProfile(id: profile.id)
            case .prowlarr:
                return
            }

            await serviceManager.refreshConfiguration()
            inAppNotificationCenter.showSuccess(title: "Deleted", message: "Removed '\(profile.name)' from \(serviceType.displayName).")
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

struct ArrQualityProfileDetailView: View {
    let serviceType: ArrServiceType
    let profile: ArrQualityProfile
    var onEdit: (() -> Void)? = nil
    var onDuplicate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var allowedQualities: [ArrQualityProfileQuality] {
        profile.flattenedQualities.filter(\.allowed)
    }

    private var blockedQualities: [ArrQualityProfileQuality] {
        profile.flattenedQualities.filter { !$0.allowed }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Service") {
                    Label(serviceType.displayName, systemImage: serviceType.systemImage)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Upgrade Allowed") {
                    Text(profile.upgradeAllowed == true ? "Yes" : "No")
                        .foregroundStyle(profile.upgradeAllowed == true ? .green : .secondary)
                }

                LabeledContent("Cutoff") {
                    Text(profile.cutoffDisplayName)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Allowed Qualities") {
                    Text("\(allowedQualities.count)")
                        .foregroundStyle(.secondary)
                }

                if !blockedQualities.isEmpty {
                    LabeledContent("Blocked Qualities") {
                        Text("\(blockedQualities.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(profile.name)
            } footer: {
                Text("Use this profile when adding or editing library items to control what release qualities are accepted.")
            }

            if !allowedQualities.isEmpty {
                Section("Allowed Qualities") {
                    ForEach(allowedQualities) { quality in
                        qualityRow(for: quality, tint: .green)
                    }
                }
            }

            if !blockedQualities.isEmpty {
                Section("Blocked Qualities") {
                    ForEach(blockedQualities) { quality in
                        qualityRow(for: quality, tint: .orange)
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let onEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") {
                        onEdit()
                    }
                }
            }

            if onDuplicate != nil || onDelete != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let onDuplicate {
                            Button("Duplicate", systemImage: "plus.square.on.square") {
                                onDuplicate()
                            }
                        }
                        if let onDelete {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                onDelete()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func qualityRow(for quality: ArrQualityProfileQuality, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: quality.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(quality.displayName)
                if let detail = quality.detailText {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ArrQualityProfileSummaryRow: View {
    let profile: ArrQualityProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(profile.cutoffDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label("\(profile.allowedQualityCount) allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label(profile.upgradeAllowed == true ? "Upgrades On" : "Upgrades Off", systemImage: "arrow.up.circle")
                    .foregroundStyle(profile.upgradeAllowed == true ? .blue : .secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

private struct ArrQualityProfileQuality: Identifiable, Hashable {
    let id: String
    let displayName: String
    let qualityID: Int?
    let detailText: String?
    let allowed: Bool
}

private struct ArrQualityProfileEditorSession: Identifiable {
    let id = UUID()
    let draft: ArrQualityProfileDraft

    static func edit(_ profile: ArrQualityProfile) -> ArrQualityProfileEditorSession {
        .init(draft: ArrQualityProfileDraft(profile: profile))
    }

    static func duplicate(from profile: ArrQualityProfile) -> ArrQualityProfileEditorSession {
        .init(draft: ArrQualityProfileDraft(
            apiID: nil,
            name: "\(profile.name) Copy",
            upgradeAllowed: profile.upgradeAllowed ?? true,
            cutoff: profile.cutoff,
            items: profile.items ?? []
        ))
    }
}

private struct ArrQualityProfileDraft: Sendable {
    var apiID: Int?
    var name: String
    var upgradeAllowed: Bool
    var cutoff: Int?
    var items: [ArrQualityProfileItem]

    init(profile: ArrQualityProfile) {
        apiID = profile.id
        name = profile.name
        upgradeAllowed = profile.upgradeAllowed ?? true
        cutoff = profile.cutoff
        items = profile.items ?? []
    }

    init(apiID: Int?, name: String, upgradeAllowed: Bool, cutoff: Int?, items: [ArrQualityProfileItem]) {
        self.apiID = apiID
        self.name = name
        self.upgradeAllowed = upgradeAllowed
        self.cutoff = cutoff
        self.items = items
    }

    func makeProfile() -> ArrQualityProfile {
        ArrQualityProfile(
            id: apiID ?? 0,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            upgradeAllowed: upgradeAllowed,
            cutoff: cutoff,
            items: items
        )
    }
}

private struct ArrQualityProfileEditorView: View {
    let serviceType: ArrServiceType
    let session: ArrQualityProfileEditorSession
    let isSaving: Bool
    let onSave: @Sendable (ArrQualityProfileDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ArrQualityProfileDraft

    init(
        serviceType: ArrServiceType,
        session: ArrQualityProfileEditorSession,
        isSaving: Bool,
        onSave: @escaping @Sendable (ArrQualityProfileDraft) async -> Bool
    ) {
        self.serviceType = serviceType
        self.session = session
        self.isSaving = isSaving
        self.onSave = onSave
        _draft = State(initialValue: session.draft)
    }

    private var sortedQualities: [ArrQualityProfileQuality] {
        draft.makeProfile().flattenedQualities.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var allowedQualityChoices: [ArrQualityProfileQuality] {
        sortedQualities.filter(\.allowed)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                Toggle("Allow Upgrades", isOn: $draft.upgradeAllowed)

                Picker("Cutoff", selection: cutoffBinding) {
                    Text("None").tag(Optional<Int>.none)
                    ForEach(allowedQualityChoices) { quality in
                        let qualityTag: Int? = quality.qualityID
                        Text(quality.displayName).tag(qualityTag)
                    }
                }
                .disabled(allowedQualityChoices.isEmpty || !draft.upgradeAllowed)
            } header: {
                Text("Profile")
            } footer: {
                Text("Cutoff determines the best quality \(serviceType.displayName) should keep upgrading toward.")
            }

            Section {
                ForEach(sortedQualities) { quality in
                    Toggle(isOn: allowedBinding(for: quality)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.displayName)
                            if let detail = quality.detailText {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Allowed Qualities")
            }
        }
        .navigationTitle(session.draft.apiID == nil ? "Duplicate Profile" : "Edit Profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task {
                        if await onSave(draft) {
                            dismiss()
                        }
                    }
                }
                .disabled(!canSave || isSaving)
            }
        }
        .onChange(of: draft.upgradeAllowed) { _, isEnabled in
            if !isEnabled {
                draft.cutoff = nil
            } else if draft.cutoff == nil {
                draft.cutoff = allowedQualityChoices.first?.qualityID
            }
        }
        .onChange(of: draft.makeProfile().flattenedQualities) { _, _ in
            if let cutoff = draft.cutoff,
               !allowedQualityChoices.contains(where: { $0.qualityID == cutoff }) {
                draft.cutoff = allowedQualityChoices.first?.qualityID
            }
        }
    }

    private var cutoffBinding: Binding<Int?> {
        Binding(
            get: { draft.cutoff },
            set: { draft.cutoff = $0 }
        )
    }

    private func allowedBinding(for quality: ArrQualityProfileQuality) -> Binding<Bool> {
        Binding(
            get: { quality.qualityID.flatMap { draft.isQualityAllowed(id: $0) } ?? quality.allowed },
            set: { newValue in
                guard let qualityID = quality.qualityID else { return }
                draft.setQualityAllowed(id: qualityID, allowed: newValue)
                if draft.cutoff == qualityID, !newValue {
                    draft.cutoff = allowedQualityChoices.first(where: { $0.qualityID != qualityID })?.qualityID
                } else if draft.cutoff == nil, newValue, draft.upgradeAllowed {
                    draft.cutoff = qualityID
                }
            }
        )
    }
}

private extension ArrQualityProfile {
    var flattenedQualities: [ArrQualityProfileQuality] {
        var seen = Set<String>()
        return flatten(items: items, inheritedAllowed: nil).filter { seen.insert($0.id).inserted }
    }

    var allowedQualityCount: Int {
        flattenedQualities.filter(\.allowed).count
    }

    var cutoffDisplayName: String {
        guard let cutoff else { return "None" }
        if let matched = flattenedQualities.first(where: { $0.id.hasPrefix("quality-\(cutoff)-") }) {
            return matched.displayName
        }
        return "Quality #\(cutoff)"
    }

    private func flatten(items: [ArrQualityProfileItem]?, inheritedAllowed: Bool?) -> [ArrQualityProfileQuality] {
        guard let items else { return [] }

        return items.reduce(into: [ArrQualityProfileQuality]()) { result, item in
            let resolvedAllowed = item.allowed ?? inheritedAllowed
            let childItems = flatten(items: item.items, inheritedAllowed: resolvedAllowed)

            guard let quality = item.quality else {
                result.append(contentsOf: childItems)
                return
            }

            let name = quality.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let qualityName = (name?.isEmpty == false ? name : nil) ?? "Quality #\(quality.id ?? 0)"
            let source = quality.source?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolution = quality.resolution.map { "\($0)p" }
            let detailParts = [source, resolution].reduce(into: [String]()) { partialResult, value in
                if let value, !value.isEmpty {
                    partialResult.append(value)
                }
            }

            let qualityID = "quality-\(quality.id ?? -1)-\(qualityName)"
            let entry = ArrQualityProfileQuality(
                id: qualityID,
                displayName: qualityName,
                qualityID: quality.id,
                detailText: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
                allowed: resolvedAllowed ?? false
            )

            result.append(entry)
            result.append(contentsOf: childItems)
        }
    }
}

private extension ArrQualityProfileDraft {
    mutating func setQualityAllowed(id: Int, allowed: Bool) {
        items = items.map { $0.settingAllowed(id: id, allowed: allowed) }
    }

    func isQualityAllowed(id: Int) -> Bool {
        items.firstAllowedValue(for: id) ?? false
    }
}

private extension Array where Element == ArrQualityProfileItem {
    func firstAllowedValue(for qualityID: Int, inheritedAllowed: Bool? = nil) -> Bool? {
        for item in self {
            let resolved = item.allowed ?? inheritedAllowed
            if item.quality?.id == qualityID {
                return resolved
            }
            if let nested = item.items?.firstAllowedValue(for: qualityID, inheritedAllowed: resolved) {
                return nested
            }
        }
        return nil
    }
}

private extension ArrQualityProfileItem {
    func settingAllowed(id qualityID: Int, allowed: Bool) -> ArrQualityProfileItem {
        var updated = self
        if updated.quality?.id == qualityID {
            updated.allowed = allowed
        }
        if let nestedItems = updated.items {
            updated.items = nestedItems.map { $0.settingAllowed(id: qualityID, allowed: allowed) }
        }
        return updated
    }
}

// MARK: - Service Profile Row

private struct ServiceProfileRow: View {
    let profile: ArrServiceProfile
    let isConnected: Bool

    var body: some View {
        HStack {
            if let serviceType = profile.resolvedServiceType {
                Image(systemName: serviceType.systemImage)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.subheadline)
                Text(profile.hostURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: isConnected ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isConnected ? .green : .red)
                if let version = profile.apiVersion {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var iconColor: Color {
        guard let serviceType = profile.resolvedServiceType else { return .secondary }
        switch serviceType {
        case .sonarr: return .blue
        case .radarr: return .purple
        case .prowlarr: return .yellow
        }
    }
}

struct ProwlarrApplicationsListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var viewModel: ProwlarrApplicationsViewModel
    @State private var editorContext: ProwlarrApplicationEditorContext?
    @State private var applicationPendingDelete: ProwlarrApplication?

    init() {
        // Initialize viewModel synchronously in init to ensure it's available for .sheet(item:)
        let placeholder = ProwlarrApplicationsViewModel(serviceManager: ArrServiceManager())
        _viewModel = State(initialValue: placeholder)
    }

    var body: some View {
        content(viewModel: viewModel)
        .navigationTitle("Linked Apps")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            // Replace placeholder with actual service manager
            viewModel = ProwlarrApplicationsViewModel(serviceManager: serviceManager)
            await viewModel.loadApplications()
            await viewModel.loadSchemaIfNeeded()
        }
        .sheet(item: $editorContext) { context in
            ProwlarrApplicationEditorSheet(viewModel: viewModel, context: context)
        }
        .alert(
            "Remove Linked App?",
            isPresented: Binding(
                get: { applicationPendingDelete != nil },
                set: { if !$0 { applicationPendingDelete = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let applicationPendingDelete, let viewModel else { return }
                let name = applicationPendingDelete.name ?? applicationPendingDelete.linkedAppType?.displayName ?? "Application"
                self.applicationPendingDelete = nil

                Task {
                    let removed = await viewModel.deleteApplication(applicationPendingDelete)
                    if removed {
                        InAppNotificationCenter.shared.showSuccess(title: "Linked App Removed", message: "\(name) was removed from Prowlarr.")
                    } else if let error = viewModel.errorMessage {
                        InAppNotificationCenter.shared.showError(title: "Remove Failed", message: error)
                        viewModel.clearError()
                    }
                }
            }

            Button("Cancel", role: .cancel) {
                applicationPendingDelete = nil
            }
        } message: {
            Text("This removes the application link from Prowlarr and stops future indexer syncs.")
        }
    }

    private func content(viewModel: ProwlarrApplicationsViewModel) -> some View {
        List {
            if viewModel.isLoadingApplications && viewModel.supportedApplications.isEmpty {
                Section {
                    ProgressView("Loading linked applications…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else if viewModel.supportedApplications.isEmpty {
                ContentUnavailableView(
                    "No Linked Apps",
                    systemImage: "app.connected.to.app.below.fill",
                    description: Text("Link Sonarr or Radarr so Prowlarr can keep their indexers in sync.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.supportedApplications) { application in
                        Button {
                            editorContext = .edit(application)
                        } label: {
                            ProwlarrApplicationRow(application: application)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                applicationPendingDelete = application
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                editorContext = .edit(application)
                            }

                            Button("Remove", systemImage: "trash", role: .destructive) {
                                applicationPendingDelete = application
                            }
                        }
                    }
                } footer: {
                    Text("Prowlarr will sync indexers to these applications using the selected sync level.")
                }
            }
        }
        .refreshable {
            await viewModel.loadApplications()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editorContext = .create(.sonarr)
                    } label: {
                        Label("Link Sonarr", systemImage: ProwlarrLinkedAppType.sonarr.systemImage)
                    }

                    Button {
                        editorContext = .create(.radarr)
                    } label: {
                        Label("Link Radarr", systemImage: ProwlarrLinkedAppType.radarr.systemImage)
                    }
                } label: {
                    Label("Add Linked App", systemImage: "plus")
                }
                .disabled(!serviceManager.prowlarrConnected)
            }
        }
    }
}

private struct ProwlarrApplicationRow: View {
    let application: ProwlarrApplication

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: appType?.systemImage ?? "app.connected.to.app.below.fill")
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(application.name ?? appType?.displayName ?? "Linked App")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                if let baseURL = application.stringFieldValue(named: "baseUrl"), !baseURL.isEmpty {
                    Text(baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(application.syncLevel?.displayName ?? "Sync level unavailable")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var appType: ProwlarrLinkedAppType? {
        application.linkedAppType
    }

    private var iconColor: Color {
        switch appType {
        case .sonarr:
            .blue
        case .radarr:
            .orange
        case nil:
            .secondary
        }
    }
}

enum ProwlarrApplicationEditorContext: Identifiable {
    case create(ProwlarrLinkedAppType)
    case edit(ProwlarrApplication)

    var id: String {
        switch self {
        case .create(let type):
            "create-\(type.rawValue)"
        case .edit(let application):
            "edit-\(application.id)"
        }
    }

    var appType: ProwlarrLinkedAppType {
        switch self {
        case .create(let type):
            type
        case .edit(let application):
            application.linkedAppType ?? .sonarr
        }
    }

    var application: ProwlarrApplication? {
        switch self {
        case .create:
            nil
        case .edit(let application):
            application
        }
    }
}

struct ProwlarrApplicationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]

    let viewModel: ProwlarrApplicationsViewModel
    let context: ProwlarrApplicationEditorContext

    @State private var name = ""
    @State private var syncLevel: ProwlarrApplicationSyncLevel = .fullSync
    @State private var selectedTagIDs: Set<Int> = []
    @State private var prowlarrURL = ""
    @State private var selectedRemoteProfileID = Self.customProfileID
    @State private var remoteURL = ""
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var localErrorMessage: String?
    @State private var hasLoadedInitialState = false

    private static let customProfileID = "custom"

    private var application: ProwlarrApplication? {
        context.application
    }

    private var appType: ProwlarrLinkedAppType {
        context.appType
    }

    private var remoteServiceType: ArrServiceType {
        switch appType {
        case .sonarr:
            .sonarr
        case .radarr:
            .radarr
        }
    }

    private var remoteProfiles: [ArrServiceProfile] {
        allProfiles
            .filter { $0.resolvedServiceType == remoteServiceType && $0.isEnabled }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var currentProwlarrProfile: ArrServiceProfile? {
        serviceManager.resolvedProfile(for: .prowlarr, in: allProfiles)
    }

    private var selectedRemoteProfile: ArrServiceProfile? {
        remoteProfiles.first { $0.id.uuidString == selectedRemoteProfileID }
    }

    private var isUsingCustomRemoteServer: Bool {
        selectedRemoteProfile == nil
    }

    private var canSave: Bool {
        !isSaving &&
        !prowlarrURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    LabeledContent("Name") {
                        TextField("Application name", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Sync Level", selection: $syncLevel) {
                        ForEach(ProwlarrApplicationSyncLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }

                    Text(syncLevel.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Tags") {
                    if viewModel.availableTags.isEmpty {
                        Text("No Prowlarr tags available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.availableTags) { tag in
                            Toggle(
                                tag.label,
                                isOn: Binding(
                                    get: { selectedTagIDs.contains(tag.id) },
                                    set: { isSelected in
                                        if isSelected {
                                            selectedTagIDs.insert(tag.id)
                                        } else {
                                            selectedTagIDs.remove(tag.id)
                                        }
                                    }
                                )
                            )
                        }
                    }

                    Text("Only indexers with one or more matching tags will sync to this application. Leave tags empty to sync all eligible indexers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Prowlarr Server") {
                        TextField("https://prowlarr.local", text: $prowlarrURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("\(appType.displayName) Server", selection: $selectedRemoteProfileID) {
                        ForEach(remoteProfiles) { profile in
                            Text(profile.displayName).tag(profile.id.uuidString)
                        }
                        Text("Custom").tag(Self.customProfileID)
                    }

                    LabeledContent("\(appType.displayName) URL") {
                        TextField("https://\(appType.rawValue).local", text: $remoteURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .disabled(!isUsingCustomRemoteServer)
                    }

                    LabeledContent("API Key") {
                        SecureField("API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    if isUsingCustomRemoteServer {
                        Text("Choose Custom to manually enter a server URL instead of using one already configured in Trawl.")
                    } else {
                        Text("The server URL comes from the selected \(appType.displayName) profile. The API key is prefilled from Keychain and can still be edited before saving.")
                    }
                }

                if let errorMessage = localErrorMessage ?? viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(application == nil ? "Link \(appType.displayName)" : "Edit \(appType.displayName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(application == nil ? "Save" : "Update") {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .task {
                await loadInitialStateIfNeeded()
            }
            .onChange(of: selectedRemoteProfileID) { _, newProfileID in
                guard hasLoadedInitialState else { return }
                if let application, newProfileID == Self.customProfileID {
                    remoteURL = application.stringFieldValue(named: "baseUrl") ?? remoteURL
                    if apiKey.isEmpty {
                        apiKey = application.stringFieldValue(named: "apiKey") ?? ""
                    }
                    return
                }
                Task { await applySelectedRemoteProfile() }
            }
        }
    }

    private func loadInitialStateIfNeeded() async {
        guard !hasLoadedInitialState else { return }

        localErrorMessage = nil
        if viewModel.availableTags.isEmpty {
            await viewModel.loadApplications()
        }
        await viewModel.loadSchemaIfNeeded()

        if let application {
            name = application.name ?? application.linkedAppType?.displayName ?? appType.displayName
            syncLevel = application.syncLevel ?? .fullSync
            selectedTagIDs = Set(application.tags ?? [])
            prowlarrURL = application.stringFieldValue(named: "prowlarrUrl") ?? currentProwlarrProfile?.hostURL ?? ""
            remoteURL = application.stringFieldValue(named: "baseUrl") ?? ""
            apiKey = application.stringFieldValue(named: "apiKey") ?? ""

            let normalizedRemoteURL = try? ServerURLValidator.normalizedURLString(from: remoteURL)
            if let matchingProfile = remoteProfiles.first(where: { profile in
                let normalizedProfileURL = try? ServerURLValidator.normalizedURLString(from: profile.hostURL)
                return normalizedRemoteURL != nil && normalizedProfileURL == normalizedRemoteURL
            }) {
                selectedRemoteProfileID = matchingProfile.id.uuidString
            } else {
                selectedRemoteProfileID = Self.customProfileID
            }
        } else {
            name = remoteProfiles.first?.displayName ?? appType.displayName
            syncLevel = .fullSync
            selectedTagIDs = []
            prowlarrURL = currentProwlarrProfile?.hostURL ?? ""
            selectedRemoteProfileID = remoteProfiles.first?.id.uuidString ?? Self.customProfileID
        }

        hasLoadedInitialState = true
        await applySelectedRemoteProfile()
    }

    private func applySelectedRemoteProfile() async {
        localErrorMessage = nil

        guard let selectedRemoteProfile else {
            if application == nil {
                remoteURL = ""
            }
            if application == nil {
                apiKey = ""
            }
            return
        }

        remoteURL = selectedRemoteProfile.hostURL
        guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            apiKey = try await KeychainHelper.shared.read(key: selectedRemoteProfile.apiKeyKeychainKey) ?? ""
        } catch {
            apiKey = ""
            localErrorMessage = "Couldn't load the saved API key: \(error.localizedDescription)"
        }
    }

    private func save() async {
        guard !isSaving else { return }

        localErrorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProwlarrURLInput = prowlarrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemoteURLInput = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedProwlarrURLInput.isEmpty else {
            localErrorMessage = "Prowlarr server URL is required."
            return
        }

        guard !trimmedRemoteURLInput.isEmpty else {
            localErrorMessage = "\(appType.displayName) server URL is required."
            return
        }

        guard !trimmedAPIKey.isEmpty else {
            localErrorMessage = "API key is required."
            return
        }

        let normalizedProwlarrURL: String
        let normalizedRemoteURL: String

        do {
            normalizedProwlarrURL = try ServerURLValidator.normalizedURLString(from: trimmedProwlarrURLInput)
            normalizedRemoteURL = try ServerURLValidator.normalizedURLString(from: trimmedRemoteURLInput)
        } catch {
            localErrorMessage = error.localizedDescription
            return
        }

        guard var payload = application ?? viewModel.schema(for: appType) else {
            localErrorMessage = "Prowlarr didn't return a schema for \(appType.displayName)."
            return
        }

        payload.id = application?.id ?? 0
        payload.name = trimmedName.isEmpty ? (selectedRemoteProfile?.displayName ?? appType.displayName) : trimmedName
        payload.syncLevel = syncLevel
        payload.tags = Array(selectedTagIDs).sorted()
        payload.implementation = payload.implementation ?? appType.implementationName
        payload.implementationName = payload.implementationName ?? appType.implementationName
        payload.configContract = payload.configContract ?? appType.configContract
        payload = payload.updatingField(named: "prowlarrUrl", with: .string(normalizedProwlarrURL))
        payload = payload.updatingField(named: "baseUrl", with: .string(normalizedRemoteURL))
        payload = payload.updatingField(named: "apiKey", with: .string(trimmedAPIKey))

        isSaving = true
        defer { isSaving = false }

        let didSave = await viewModel.saveApplication(payload)
        if didSave {
            let action = application == nil ? "linked in" : "updated in"
            InAppNotificationCenter.shared.showSuccess(
                title: "Saved",
                message: "\(payload.name ?? appType.displayName) was \(action) Prowlarr."
            )
            dismiss()
        } else if let errorMessage = viewModel.errorMessage {
            localErrorMessage = errorMessage
        }
    }
}
