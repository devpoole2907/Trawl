import SwiftUI

// MARK: - View

struct ArrUpdatesView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(\.sidebarNavigationColumn) private var sidebarColumn
    @Environment(\.hasDetailPane) private var hasDetailPane
    @Environment(ArrUpdatesBrowserState.self) private var sharedBrowser: ArrUpdatesBrowserState?
    @State private var localBrowser = ArrUpdatesBrowserState()

    private var browser: ArrUpdatesBrowserState {
        sidebarColumn == nil ? localBrowser : (sharedBrowser ?? localBrowser)
    }

    private var viewModel: ArrUpdatesViewModel {
        browser.viewModel
    }

    private var selectedInstanceID: UUID? {
        get { browser.selectedInstanceID }
        nonmutating set { browser.selectedInstanceID = newValue }
    }

    private var selectedVersion: String? {
        get { browser.selectedVersion }
        nonmutating set { browser.selectedVersion = newValue }
    }

    @State private var confirmingInstall: ArrInstanceRef?
    @State private var showSettings = false

    #if DEBUG
    init(previewUpdates: [UUID: ArrUpdatesViewModel.ServiceUpdatesData] = [:], selectedInstanceID: UUID? = nil) {
        let browser = ArrUpdatesBrowserState()
        browser.selectedInstanceID = selectedInstanceID
        browser.viewModel.setPreviewUpdates(previewUpdates)
        _localBrowser = State(initialValue: browser)
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

    private var navigationSubtitleText: String {
        selectedInstance.map { serviceManager.scopeLabel(for: $0) } ?? ""
    }

    private var instanceBinding: Binding<UUID?> {
        Binding(
            get: { selectedInstanceID },
            set: {
                selectedInstanceID = $0
                selectedVersion = nil
            }
        )
    }

    var body: some View {
        TrawlListDetailPanes(title: "Updates", subtitle: navigationSubtitleText) {
            updatesListContent
        } detail: {
            selectedUpdateDetail
        }
    }

    // MARK: - List Content

    private var updatesListContent: some View {
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
        .moreDestinationBackground(.updates)
        .safeAreaInset(edge: .top) {
            if !availableInstances.isEmpty {
                ArrInstanceScopeBar(instances: availableInstances, selection: instanceBinding)
            }
        }
        .toolbar {
            if sidebarColumn != .detail, let instance = selectedInstance {
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    if viewModel.loadingServices.contains(instance.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await viewModel.load(instance: instance, serviceManager: serviceManager) }
                        } label: {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .onAppear {
            guard sidebarColumn != .detail else { return }
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
                .macSheetSizing()
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
            if hasDetailPane {
                selectableChangelogList(data: data, instance: instance)
            } else {
                inlineChangelogList(data: data, instance: instance)
            }
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

    /// Selectable release list for the content column in 3-column split view.
    private func selectableChangelogList(data: ArrUpdatesViewModel.ServiceUpdatesData, instance: ArrInstanceRef) -> some View {
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
                    Button {
                        selectedVersion = update.version
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("v\(update.version ?? "Unknown")")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    if update.installed == true {
                                        badge("Current", color: service.serviceIdentity.brandColor)
                                    } else if update.installable == true {
                                        badge("Available", color: .green)
                                    }
                                }

                                let newCount = update.changes?.new?.count ?? 0
                                let fixedCount = update.changes?.fixed?.count ?? 0
                                if newCount > 0 || fixedCount > 0 {
                                    HStack(spacing: 6) {
                                        if newCount > 0 {
                                            Text("\(newCount) new")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                        }
                                        if fixedCount > 0 {
                                            Text("\(fixedCount) fixed")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }

                            Spacer(minLength: 8)

                            if let date = formattedDate(update.releaseDate) {
                                Text(date)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedVersion == update.version
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
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
        .onChange(of: data.allVersions.map(\.version)) { _, versions in
            if let version = selectedVersion, !versions.compactMap({ $0 }).contains(version) {
                selectedVersion = nil
            }
        }
    }

    /// Inline changelog list with expandable sections for compact iPhone.
    private func inlineChangelogList(data: ArrUpdatesViewModel.ServiceUpdatesData, instance: ArrInstanceRef) -> some View {
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

    // MARK: - Detail Content

    @ViewBuilder
    private var selectedUpdateDetail: some View {
        if let instance = selectedInstance,
           let data = viewModel.allUpdates[instance.id],
           let update = data.allVersions.first(where: { $0.version == selectedVersion }) {
            UpdateDetailPane(
                update: update,
                instance: instance,
                service: instance.serviceType,
                isInstalling: viewModel.installingServices.contains(instance.id),
                onInstall: { confirmingInstall = instance }
            )
            .id("\(instance.id.uuidString)-\(update.version ?? "")")
        } else {
            listDetailPlaceholder("Select a Release", systemImage: "arrow.down.app")
        }
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

// MARK: - Detail Pane

private struct UpdateDetailPane: View {
    let update: ArrUpdateInfo
    let instance: ArrInstanceRef
    let service: ArrServiceType
    let isInstalling: Bool
    let onInstall: () -> Void

    /// `Form` + `TrawlEntityHeader` + `serviceSettingsFormStyle()`, matching
    /// `ArrQualityProfileDetailView` and the other detail panes. Was two hand-rolled
    /// `ultraThinMaterial` cards in a `ScrollView`, which took no part in the Mac
    /// grouping - `formStyle` reaches `Form` only.
    var body: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: "v\(update.version ?? "Unknown")",
                    subtitle: service.displayName,
                    systemImage: "arrow.down.circle",
                    tint: service.serviceIdentity.brandColor,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            Section {
                LabeledContent("Server") {
                    ArrInstanceBadge(label: instance.qualifiedLabel, ordinal: instance.ordinal)
                }
                if let date = formattedDate(update.releaseDate) {
                    LabeledContent("Released") {
                        Text(date).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Release")
            }

            if update.installable == true && update.installed != true {
                Section {
                    Button(action: onInstall) {
                        HStack {
                            if isInstalling {
                                ProgressView().controlSize(.small).tint(.white)
                            }
                            Label(
                                isInstalling ? "Installing Update…" : "Install Update Now",
                                systemImage: "arrow.down.circle.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                }
            }

            Section {
                let newItems = update.changes?.new ?? []
                let fixedItems = update.changes?.fixed ?? []

                if newItems.isEmpty && fixedItems.isEmpty {
                    Text("No change notes provided for this release.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    if !newItems.isEmpty {
                        changeSection(title: "New Features", icon: "sparkles", color: .blue, items: newItems)
                    }
                    if !fixedItems.isEmpty {
                        changeSection(title: "Bug Fixes", icon: "wrench.and.screwdriver.fill", color: .orange, items: fixedItems)
                    }
                }
            } header: {
                Text("Release Notes")
            }
        }
        .serviceSettingsFormStyle()
        .paneAwareNavigationTitle("v\(update.version ?? "Unknown")", subtitle: service.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            // macOS shares one toolbar between the split view's list and detail
            // columns. The spacer keeps these actions at the trailing edge,
            // clear of the list column's toolbar group.
            ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
            if update.installable == true && update.installed != true {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button(action: onInstall) {
                        if isInstalling {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Install Update", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .disabled(isInstalling)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            #else
            if update.installable == true && update.installed != true {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button(action: onInstall) {
                        if isInstalling {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Install Update", systemImage: "arrow.down.circle.fill")
                        }
                    }
                    .disabled(isInstalling)
                }
            }
            #endif
        }
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges = [
            ArrDetailBadge(
                icon: service.systemImage,
                label: instance.qualifiedLabel,
                color: service.serviceIdentity.brandColor
            )
        ]
        if update.installed == true {
            badges.append(
                ArrDetailBadge(
                    icon: "checkmark.circle.fill",
                    label: "Current Version",
                    color: service.serviceIdentity.brandColor
                )
            )
        } else if update.installable == true {
            badges.append(ArrDetailBadge(icon: "arrow.down.circle.fill", label: "Update Available", color: .green))
        }
        return badges
    }


    private func changeSection(title: String, icon: String, color: Color, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)

            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
                break
            }
            InAppNotificationCenter.shared.showSuccess(
                title: "Update Started",
                message: "Update is being installed for \(serviceManager.scopeLabel(for: instance)).",
                source: .inApp
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Update Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }
}

#if DEBUG
extension ArrUpdatesViewModel {
    func setPreviewUpdates(_ updates: [UUID: ServiceUpdatesData]) {
        self.allUpdates = updates
    }
}

#Preview("Updates - Available") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        NavigationStack {
            ArrUpdatesView(
                previewUpdates: [
                    ArrInstanceRef.preview(.sonarr).id: ArrUpdatesViewModel.ServiceUpdatesData(
                        currentVersion: "4.0.0.100",
                        allVersions: ArrUpdateInfo.previewList,
                        isDocker: false,
                        error: nil
                    )
                ]
            )
        }
    }
}

#Preview("Updates - Up to date") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        NavigationStack {
            ArrUpdatesView(
                previewUpdates: [
                    ArrInstanceRef.preview(.sonarr).id: ArrUpdatesViewModel.ServiceUpdatesData(
                        currentVersion: "4.0.0.900",
                        allVersions: [ArrUpdateInfo.preview],
                        isDocker: false,
                        error: nil
                    )
                ]
            )
        }
    }
}
#endif
