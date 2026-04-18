import SwiftUI
import SwiftData

// MARK: - Per-service settings view (reusable)

struct ArrServiceSettingsView: View {
    let serviceType: ArrServiceType

    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]
    @State private var showAddSheet = false
    @State private var systemStatus: ArrSystemStatus?
    @State private var isLoadingStatus = false
    @State private var diskSpaces: [ArrDiskSpaceSnapshot] = []
    @State private var commandStatusMessage: String?
    @State private var isRunningCommand = false

    private var profile: ArrServiceProfile? {
        allProfiles.first { $0.resolvedServiceType == serviceType }
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
            ArrSetupSheet(initialServiceType: serviceType, onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
        .task(id: profile?.id) {
            await loadSystemStatus()
            await loadDiskSpace()
        }
        .task(id: isConnected) {
            await loadSystemStatus()
            await loadDiskSpace()
        }
    }

    private func loadDiskSpace() async {
        let client: ArrDiskSpaceProviding? = switch serviceType {
        case .sonarr: serviceManager.sonarrClient
        case .radarr: serviceManager.radarrClient
        case .prowlarr: nil
        }
        guard let client else { diskSpaces = []; return }
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
        } catch {
            diskSpaces = []
        }
    }

    private func loadSystemStatus() async {
        guard profile != nil else {
            systemStatus = nil
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
            isLoadingStatus = false
            return
        }

        isLoadingStatus = true
        defer { isLoadingStatus = false }

        systemStatus = try? await client.getSystemStatus()
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