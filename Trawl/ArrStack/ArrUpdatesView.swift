import SwiftUI

// MARK: - View

struct ArrUpdatesView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel = ArrUpdatesViewModel()
    @State private var selectedInstanceID: UUID?
    @State private var confirmingInstall: ArrInstanceRef?
    @State private var showSettings = false

    #if DEBUG
    init(previewUpdates: [UUID: ArrUpdatesViewModel.ServiceUpdatesData] = [:], selectedInstanceID: UUID? = nil) {
        let previewVM = ArrUpdatesViewModel()
        previewVM.setPreviewUpdates(previewUpdates)
        _viewModel = State(initialValue: previewVM)
        _selectedInstanceID = State(initialValue: selectedInstanceID)
    }
    #endif

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
        return services
    }

    private var isAnyConnecting: Bool {
        serviceManager.isInitializing || availableServices.contains { serviceManager.isConnecting($0) }
    }

    private var hasAnyConnected: Bool {
        availableServices.contains { serviceManager.isConnected($0) }
    }

    private var primarySettingsService: ArrServiceType? {
        availableServices.first { !serviceManager.isConnected($0) } ?? availableServices.first
    }

    /// Every server that reports a version - both halves of each pair, plus
    /// Prowlarr.
    private var availableInstances: [ArrInstanceRef] {
        serviceManager.visibleArrInstances.map(\.ref) + serviceManager.refs(for: .prowlarr)
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ServiceSetupView(title: "No Services Configured", message: "Add Sonarr, Radarr, or Prowlarr in Settings to check for updates.", systemImage: "arrow.down.app")
                .scrollableUnavailableState()
            } else if !hasAnyConnected {
                ArrServicesConnectionStatusView(
                    services: availableServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured services."
                )
            } else if let instance = selectedInstance {
                serviceContent(for: instance)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Updates")
        .navigationSubtitle(selectedInstance.map { serviceManager.scopeLabel(for: $0) } ?? "")
        .moreDestinationBackground(.updates)
        .safeAreaInset(edge: .top) {
            ArrInstanceScopeBar(instances: availableInstances, selection: $selectedInstanceID)
        }
        .onAppear {
            if selectedInstanceID == nil || !availableInstances.contains(where: { $0.id == selectedInstanceID }) {
                selectedInstanceID = availableInstances.first?.id
            }
        }
        // Preloads every server in parallel on appear; refreshes every 30 s.
        .loadServicesPeriodically(
            id: availableInstances.map(\.id.uuidString).joined(separator: "|"),
            keys: availableInstances
        ) { instance in
            await viewModel.load(instance: instance, serviceManager: serviceManager)
        }
        .sheet(isPresented: $showSettings) {
            if let service = primarySettingsService {
                NavigationStack {
                    ArrServiceSettingsView(serviceType: service)
                        .environment(serviceManager)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
        }
        .confirmationDialog(
            "Install Update",
            isPresented: Binding(
                get: { confirmingInstall != nil },
                set: { if !$0 { confirmingInstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let instance = confirmingInstall {
                Button("Install Now") {
                    let target = instance
                    confirmingInstall = nil
                    Task { await viewModel.install(instance: target, serviceManager: serviceManager) }
                }
                Button("Cancel", role: .cancel) { confirmingInstall = nil }
            }
        } message: {
            if let instance = confirmingInstall,
               let data = viewModel.allUpdates[instance.id],
               data.isDocker {
                Text("Warning: Internal updates are often disabled or discouraged for Docker instances. You should typically update by pulling a new image.")
            } else {
                Text("This will download and install the update. The service will restart automatically.")
            }
        }
    }

    @ViewBuilder
    private func serviceContent(for instance: ArrInstanceRef) -> some View {
        let data = viewModel.allUpdates[instance.id]
        let isLoading = viewModel.loadingServices.contains(instance.id)

        if let data, data.error == nil {
            changelogList(data: data, instance: instance)
        } else if isLoading || data == nil {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = data?.error {
            ServiceErrorView(
                title: "Updates Unavailable",
                message: error,
                identity: instance.serviceType.serviceIdentity,
                onRetry: { await viewModel.load(instance: instance, serviceManager: serviceManager) }
            )
        }
    }

    private func changelogList(data: ArrUpdatesViewModel.ServiceUpdatesData, instance: ArrInstanceRef) -> some View {
        let service = instance.serviceType
        return List {
            if data.allVersions.isEmpty {
                ContentUnavailableView(
                    "No Update History",
                    systemImage: "arrow.down.app",
                    description: Text("No version history available for \(service.displayName).")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(data.allVersions) { update in
                    Section {
                        ChangelogEntryRow(
                            update: update,
                            isInstalling: viewModel.installingServices.contains(instance.id)
                        ) {
                            confirmingInstall = instance
                        }
                    } header: {
                        UpdateSectionHeader(update: update, service: service)
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
        .refreshable { await viewModel.load(instance: instance, serviceManager: serviceManager) }
        .animation(.default, value: data.allVersions.map(\.id))
    }
}

// MARK: - Section Header

private struct UpdateSectionHeader: View {
    let update: ArrUpdateInfo
    let service: ArrServiceType

    var body: some View {
        HStack(spacing: 8) {
            Text("v\(update.version ?? "Unknown")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if update.installed == true {
                badge("Current", color: service.serviceIdentity.brandColor)
            } else if update.installable == true {
                badge("Available", color: .green)
            }

            Spacer()

            if let date = formattedDate(update.releaseDate) {
                Text(date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }

    private func badge(_ label: String, color: Color) -> some View {
        Text(label.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: .capsule)
    }

    private func formattedDate(_ raw: String?) -> String? {
        guard let raw, raw.count >= 10 else { return raw }
        let s = String(raw.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: s) else { return s }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

// MARK: - Changelog Entry Row

private struct ChangelogEntryRow: View {
    let update: ArrUpdateInfo
    let isInstalling: Bool
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let newItems = update.changes?.new ?? []
            let fixedItems = update.changes?.fixed ?? []

            if newItems.isEmpty && fixedItems.isEmpty {
                Text("No change notes for this release.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if !newItems.isEmpty {
                    changeGroup(title: "New", icon: "sparkles", color: .blue, items: newItems)
                }
                if !fixedItems.isEmpty {
                    changeGroup(title: "Fixed", icon: "wrench.and.screwdriver.fill", color: .orange, items: fixedItems)
                }
            }

            if update.installable == true && update.installed != true {
                Button(action: onInstall) {
                    HStack {
                        if isInstalling {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(isInstalling ? "Installing…" : "Install Update")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func changeGroup(title: String, icon: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class ArrUpdatesViewModel {
    struct ServiceUpdatesData {
        let currentVersion: String?
        let allVersions: [ArrUpdateInfo]
        let isDocker: Bool
        let error: String?
    }

    // Keyed by server rather than by service: each half of an HD/4K pair runs its
    // own build and updates on its own schedule, so "the Sonarr version" is two
    // different answers once a pair is configured.
    private(set) var allUpdates: [UUID: ServiceUpdatesData] = [:]
    private(set) var loadingServices: Set<UUID> = []
    private(set) var installingServices: Set<UUID> = []

    func load(instance: ArrInstanceRef, serviceManager: ArrServiceManager) async {
        #if DEBUG
        if ArrPreviewRuntime.isActive { return }
        #endif
        loadingServices.insert(instance.id)
        defer { loadingServices.remove(instance.id) }

        guard let client = serviceManager.sharedClient(for: instance) else {
            guard !serviceManager.isInitializing,
                  !serviceManager.isConnecting(instance.serviceType) else { return }
            allUpdates[instance.id] = ServiceUpdatesData(
                currentVersion: nil, allVersions: [], isDocker: false, error: "Not connected"
            )
            return
        }

        do {
            async let statusTask = client.getSystemStatus()
            async let updatesTask = client.getUpdates()
            let (status, updates) = try await (statusTask, updatesTask)
            allUpdates[instance.id] = ServiceUpdatesData(
                currentVersion: status.version,
                allVersions: updates,
                isDocker: status.isDocker ?? false,
                error: nil
            )
        } catch {
            allUpdates[instance.id] = ServiceUpdatesData(
                currentVersion: nil, allVersions: [], isDocker: false, error: error.localizedDescription
            )
        }
    }

    /// Installs on one server. Updating "Sonarr" has to mean updating a specific
    /// box: restarting the wrong half of a pair mid-download is a real cost.
    func install(instance: ArrInstanceRef, serviceManager: ArrServiceManager) async {
        installingServices.insert(instance.id)
        defer { installingServices.remove(instance.id) }

        do {
            switch instance.serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient(for: instance.id) else { return }
                _ = try await client.installUpdate()
            case .radarr:
                guard let client = serviceManager.radarrClient(for: instance.id) else { return }
                _ = try await client.installUpdate()
            case .prowlarr:
                guard let client = serviceManager.prowlarrClient else { return }
                _ = try await client.postCommand(name: "ApplicationUpdate")
            case .bazarr:
                return
            }
            InAppNotificationCenter.shared.showSuccess(
                title: "Update Started",
                message: "\(instance.displayName) update command sent."
            )
        } catch {
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error.localizedDescription)
        }
    }
}

#if DEBUG
extension ArrUpdatesViewModel {
    func setPreviewUpdates(_ data: [UUID: ServiceUpdatesData]) {
        allUpdates = data
        loadingServices = []
        installingServices = []
    }
}

#Preview("Updates - Loaded") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrUpdatesView(previewUpdates: [
                ArrInstanceRef.preview(.sonarr).id: .init(currentVersion: "4.0.12.2823", allVersions: ArrUpdateInfo.previewList, isDocker: true, error: nil),
                ArrInstanceRef.preview(.radarr).id: .init(currentVersion: "5.4.6.8723", allVersions: ArrUpdateInfo.previewList, isDocker: false, error: nil),
            ])
        }
    }
}

#Preview("Updates - Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrUpdatesView(
                previewUpdates: [
                    ArrInstanceRef.preview(.sonarr).id: .init(currentVersion: nil, allVersions: [], isDocker: false, error: "Update feed unavailable.")
                ],
                selectedInstanceID: ArrInstanceRef.preview(.sonarr).id
            )
        }
    }
}
#endif
