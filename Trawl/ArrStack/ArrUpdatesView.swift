import SwiftUI

// MARK: - View

struct ArrUpdatesView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel = ArrUpdatesViewModel()
    @State private var selectedService: ArrServiceType?
    @State private var confirmingInstall: ArrServiceType?
    @State private var showSettings = false

    #if DEBUG
    init(previewUpdates: [ArrServiceType: ArrUpdatesViewModel.ServiceUpdatesData] = [:], selectedService: ArrServiceType? = .sonarr) {
        let previewVM = ArrUpdatesViewModel()
        previewVM.setPreviewUpdates(previewUpdates)
        _viewModel = State(initialValue: previewVM)
        _selectedService = State(initialValue: selectedService)
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

    private var segmentItems: [TrawlSegmentBarItem<ArrServiceType>] {
        availableServices.map { TrawlSegmentBarItem($0.displayName, value: $0) }
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "arrow.down.app",
                    description: Text("Add Sonarr, Radarr, or Prowlarr in Settings to check for updates.")
                )
            } else if !hasAnyConnected {
                ArrServicesConnectionStatusView(
                    services: availableServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured services."
                )
            } else if let service = selectedService {
                serviceContent(for: service)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Updates")
        .navigationSubtitle(selectedService?.displayName ?? "")
        .moreDestinationBackground(.updates)
        .safeAreaInset(edge: .top) {
            if availableServices.count > 1, let selected = selectedService {
                TrawlSegmentBar(
                    "Service",
                    selection: Binding(
                        get: { selected },
                        set: { newService in withAnimation { selectedService = newService } }
                    ),
                    items: segmentItems,
                    alignment: .center
                )
            }
        }
        .onAppear {
            if selectedService == nil || !availableServices.contains(selectedService!) {
                selectedService = availableServices.first
            }
        }
        // Preloads all services in parallel on appear; refreshes every 30 s.
        .loadServicesPeriodically(
            id: availableServices.map { "\($0.rawValue):\(serviceManager.isConnected($0))" }.joined(),
            keys: availableServices
        ) { service in
            await viewModel.load(service: service, serviceManager: serviceManager)
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
            if let service = confirmingInstall {
                Button("Install Now") {
                    let s = service
                    confirmingInstall = nil
                    Task { await viewModel.install(service: s, serviceManager: serviceManager) }
                }
                Button("Cancel", role: .cancel) { confirmingInstall = nil }
            }
        } message: {
            if let service = confirmingInstall,
               let data = viewModel.allUpdates[service],
               data.isDocker {
                Text("Warning: Internal updates are often disabled or discouraged for Docker instances. You should typically update by pulling a new image.")
            } else {
                Text("This will download and install the update. The service will restart automatically.")
            }
        }
    }

    @ViewBuilder
    private func serviceContent(for service: ArrServiceType) -> some View {
        let data = viewModel.allUpdates[service]
        let isLoading = viewModel.loadingServices.contains(service)

        if let data, data.error == nil {
            changelogList(data: data, service: service)
        } else if isLoading || data == nil {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = data?.error {
            ContentUnavailableView(
                "Could Not Load Updates",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        }
    }

    @ViewBuilder
    private func changelogList(data: ArrUpdatesViewModel.ServiceUpdatesData, service: ArrServiceType) -> some View {
        List {
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
                            isInstalling: viewModel.installingServices.contains(service)
                        ) {
                            confirmingInstall = service
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
        .refreshable { await viewModel.load(service: service, serviceManager: serviceManager) }
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

    private(set) var allUpdates: [ArrServiceType: ServiceUpdatesData] = [:]
    private(set) var loadingServices: Set<ArrServiceType> = []
    private(set) var installingServices: Set<ArrServiceType> = []

    func load(service: ArrServiceType, serviceManager: ArrServiceManager) async {
        #if DEBUG
        if ArrPreviewRuntime.isActive { return }
        #endif
        loadingServices.insert(service)
        defer { loadingServices.remove(service) }

        let client: (any SharedArrClient)? = switch service {
        case .sonarr: serviceManager.sonarrClient
        case .radarr: serviceManager.radarrClient
        case .prowlarr: serviceManager.prowlarrClient
        case .bazarr: nil
        }

        guard let client else {
            guard !serviceManager.isInitializing, !serviceManager.isConnecting(service) else { return }
            allUpdates[service] = ServiceUpdatesData(
                currentVersion: nil, allVersions: [], isDocker: false, error: "Not connected"
            )
            return
        }

        do {
            async let statusTask = client.getSystemStatus()
            async let updatesTask = client.getUpdates()
            let (status, updates) = try await (statusTask, updatesTask)
            allUpdates[service] = ServiceUpdatesData(
                currentVersion: status.version,
                allVersions: updates,
                isDocker: status.isDocker ?? false,
                error: nil
            )
        } catch {
            allUpdates[service] = ServiceUpdatesData(
                currentVersion: nil, allVersions: [], isDocker: false, error: error.localizedDescription
            )
        }
    }

    func install(service: ArrServiceType, serviceManager: ArrServiceManager) async {
        installingServices.insert(service)
        defer { installingServices.remove(service) }

        do {
            switch service {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { return }
                _ = try await client.installUpdate()
            case .radarr:
                guard let client = serviceManager.radarrClient else { return }
                _ = try await client.installUpdate()
            case .prowlarr:
                guard let client = serviceManager.prowlarrClient else { return }
                _ = try await client.postCommand(name: "ApplicationUpdate")
            case .bazarr:
                return
            }
            InAppNotificationCenter.shared.showSuccess(
                title: "Update Started",
                message: "\(service.displayName) update command sent."
            )
        } catch {
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error.localizedDescription)
        }
    }
}

#if DEBUG
extension ArrUpdatesViewModel {
    func setPreviewUpdates(_ data: [ArrServiceType: ServiceUpdatesData]) {
        allUpdates = data
        loadingServices = []
        installingServices = []
    }
}

#Preview("Updates - Loaded") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrUpdatesView(previewUpdates: [
                .sonarr: .init(currentVersion: "4.0.12.2823", allVersions: ArrUpdateInfo.previewList, isDocker: true, error: nil),
                .radarr: .init(currentVersion: "5.4.6.8723", allVersions: ArrUpdateInfo.previewList, isDocker: false, error: nil),
            ])
        }
    }
}

#Preview("Updates - Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrUpdatesView(
                previewUpdates: [
                    .sonarr: .init(currentVersion: nil, allVersions: [], isDocker: false, error: "Update feed unavailable.")
                ],
                selectedService: .sonarr
            )
        }
    }
}
#endif
