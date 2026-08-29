import SwiftUI

struct ArrDownloadClientListView: View {
    let serviceType: ArrServiceType

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var clients: [ArrDownloadClient] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var clientPendingDelete: ArrDownloadClient?
    @State private var clientBeingEdited: ArrDownloadClient?
    @State private var isTogglingID: Int?
    @State private var isTestingID: Int?
    @State private var pendingAddClient: PendingAddClient?
    @State private var showSettings = false
    @State private var reachability: [Int: Bool] = [:]
    @State private var isCheckingIDs: Set<Int> = []
    /// Which server's download clients are on screen. Download clients are
    /// configured per server, and an HD/4K pair usually has different categories
    /// pointed at different folders - so "the Sonarr download clients" is two
    /// lists once a pair exists.
    @State private var selectedInstanceID: UUID?

    init(serviceType: ArrServiceType) {
        self.serviceType = serviceType
    }

    #if DEBUG
    init(
        serviceType: ArrServiceType,
        previewClients: [ArrDownloadClient],
        isLoading: Bool = false,
        loadError: String? = nil,
        reachability: [Int: Bool] = [:]
    ) {
        self.serviceType = serviceType
        _clients = State(initialValue: previewClients)
        _isLoading = State(initialValue: isLoading)
        _loadError = State(initialValue: loadError)
        _reachability = State(initialValue: reachability)
    }
    #endif

    private var supportsDownloadClients: Bool {
        serviceType == .sonarr || serviceType == .radarr
    }

    private var isServiceConnecting: Bool {
        serviceManager.isInitializing || serviceManager.isConnecting(serviceType)
    }

    private var availableInstances: [ArrInstanceRef] {
        serviceManager.refs(for: serviceType).filter { serviceManager.isConnected(serviceType, profileID: $0.id) }
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    private var selectedLabel: String {
        selectedInstance.map { serviceManager.scopeLabel(for: $0) } ?? serviceType.displayName
    }

    /// Every read and mutation on this screen goes through the selected server.
    private var scopedClient: (any SharedArrClient)? {
        selectedInstance.flatMap { serviceManager.sharedClient(for: $0) }
    }

    var body: some View {
        List {
            if !serviceManager.isConnected(serviceType) {
                Section {
                    ConnectionIssueRow(
                        identity: serviceType.serviceIdentity,
                        title: isServiceConnecting ? "Connecting to \(serviceType.displayName)" : "\(serviceType.displayName) Unreachable",
                        message: serviceManager.connectionError(serviceType) ?? "Check your server connection and try again.",
                        isConnecting: isServiceConnecting,
                        onRetry: { Task { await serviceManager.retry(serviceType) } },
                        onEdit: {
                            withAnimation(.snappy) {
                                showSettings = true
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else if isLoading && clients.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Loading download clients…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else if !supportsDownloadClients {
                ContentUnavailableView(
                    "Not Supported",
                    systemImage: "nosign",
                    description: Text("\(serviceType.displayName) does not support download client management in Trawl.")
                )
                .listRowBackground(Color.clear)
            } else if clients.isEmpty {
                ContentUnavailableView(
                    "No Download Clients",
                    systemImage: "arrow.down.circle",
                    description: Text("No download clients are configured in \(selectedLabel).")
                )
                .listRowBackground(Color.clear)
            } else {
                clientSections
            }
        }
        // Attached directly to the List, above the .sheet modifiers below: a sheet inherits
        // its presenter's environment, so a RefreshAction placed outside them would give the
        // editor sheet a pull-to-refresh it never asked for.
        .refreshable {
            await loadClients()
            checkReachabilityForAll()
        }
        .navigationTitle("Download Clients")
        .navigationSubtitle(serviceType.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        #endif
        .moreDestinationBackground(.downloadClients)
        .toolbar {
            if supportsDownloadClients {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Menu {
                        // Trawl integrates with qBittorrent and SABnzbd directly, so these are
                        // the two it can prefill host/credentials for. The sheet's own Client
                        // Type picker still exposes every implementation the Arr offers.
                        ForEach(PendingAddClient.allCases) { choice in
                            Button(choice.title, systemImage: choice.icon) {
                                pendingAddClient = choice
                            }
                        }
                    } label: {
                        Label("Add Download Client", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: supportsDownloadClients ? $pendingAddClient : .constant(nil)) { choice in
            ArrDownloadClientEditorSheet(
                serviceType: serviceType,
                instanceID: selectedInstance?.id,
                initialImplementation: choice.implementation
            ) { saved in
                clients.append(saved)
                clients.sort { ($0.name ?? "") < ($1.name ?? "") }
                checkReachability(for: saved)
                inAppNotificationCenter.showSuccess(
                    title: "Added",
                    message: "\(saved.name ?? "Download client") added to \(selectedLabel)."
                )
            }
            .environment(serviceManager)
        }
        .sheet(isPresented: $showSettings) {
            ArrServiceSettingsSheet(serviceType: serviceType, isPresented: $showSettings)
                .environment(serviceManager)
        }
        .sheet(item: supportsDownloadClients ? $clientBeingEdited : .constant(nil)) { client in
            ArrDownloadClientEditorSheet(
                serviceType: serviceType,
                instanceID: selectedInstance?.id,
                existingClient: client
            ) { saved in
                if let idx = clients.firstIndex(where: { $0.id == saved.id }) {
                    clients[idx] = saved
                }
                checkReachability(for: saved)
                inAppNotificationCenter.showSuccess(
                    title: "Updated",
                    message: "\(saved.name ?? "Download client") updated in \(selectedLabel)."
                )
            }
            .environment(serviceManager)
        }
        .safeAreaInset(edge: .top) {
            ArrInstanceScopeBar(instances: availableInstances, selection: $selectedInstanceID)
        }
        .task(id: selectedInstance?.id) {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await loadClients()
            checkReachabilityForAll()
        }
        .confirmationDialog(
            "Delete Download Client?",
            isPresented: Binding(
                get: { clientPendingDelete != nil },
                set: { if !$0 { clientPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let client = clientPendingDelete else { return }
                clientPendingDelete = nil
                Task { await deleteClient(client) }
            }
            Button("Cancel", role: .cancel) {
                clientPendingDelete = nil
            }
        } message: {
            if let client = clientPendingDelete {
                Text("Remove '\(client.name ?? "this client")' from \(selectedLabel)?")
            }
        }
    }

    @ViewBuilder
    private var clientSections: some View {
        let torrent = clients.filter { $0.protocol == .torrent }
        let usenet = clients.filter { $0.protocol == .usenet }
        let other = clients.filter { $0.protocol == nil || $0.protocol == .unknown }

        if !torrent.isEmpty {
            Section("Torrent") {
                ForEach(torrent) { client in
                    Button { clientBeingEdited = client } label: { clientRow(client) }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .swipeActions(edge: .leading) {
                            Button { Task { await testClient(client) } } label: {
                                Label("Test", systemImage: "checkmark.circle")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                clientPendingDelete = client
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button { Task { await toggleEnable(client) } } label: {
                                Label(
                                    client.enable ? "Disable" : "Enable",
                                    systemImage: client.enable ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(client.enable ? .orange : .green)

                            Button { clientBeingEdited = client } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { clientBeingEdited = client }

                            Button { Task { await toggleEnable(client) } } label: {
                                Label(
                                    client.enable ? "Disable" : "Enable",
                                    systemImage: client.enable ? "pause.circle" : "play.circle"
                                )
                            }

                            Button { Task { await testClient(client) } } label: {
                                Label("Test", systemImage: "checkmark.circle")
                            }

                            Divider()

                            Button("Delete", systemImage: "trash", role: .destructive) {
                                clientPendingDelete = client
                            }
                        }
                }
            }
        }
        if !usenet.isEmpty {
            Section("Usenet") {
                ForEach(usenet) { client in
                    Button { clientBeingEdited = client } label: { clientRow(client) }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .swipeActions(edge: .leading) {
                            Button { Task { await testClient(client) } } label: {
                                Label("Test", systemImage: "checkmark.circle")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                clientPendingDelete = client
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button { Task { await toggleEnable(client) } } label: {
                                Label(
                                    client.enable ? "Disable" : "Enable",
                                    systemImage: client.enable ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(client.enable ? .orange : .green)

                            Button { clientBeingEdited = client } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { clientBeingEdited = client }
                            Button { Task { await toggleEnable(client) } } label: {
                                Label(
                                    client.enable ? "Disable" : "Enable",
                                    systemImage: client.enable ? "pause.circle" : "play.circle"
                                )
                            }
                            Button { Task { await testClient(client) } } label: {
                                Label("Test", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { clientPendingDelete = client }
                        }
                }
            }
        }
        if !other.isEmpty {
            Section("Other") {
                ForEach(other) { client in
                    Button { clientBeingEdited = client } label: { clientRow(client) }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .swipeActions(edge: .leading) {
                            Button { Task { await testClient(client) } } label: {
                                Label("Test", systemImage: "checkmark.circle")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { clientPendingDelete = client } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button { Task { await toggleEnable(client) } } label: {
                                Label(
                                    client.enable ? "Disable" : "Enable",
                                    systemImage: client.enable ? "pause.circle" : "play.circle"
                                )
                            }
                            .tint(client.enable ? .orange : .green)

                            Button { clientBeingEdited = client } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { clientBeingEdited = client }
                            Button { Task { await toggleEnable(client) } } label: {
                                Label(
                                    client.enable ? "Disable" : "Enable",
                                    systemImage: client.enable ? "pause.circle" : "play.circle"
                                )
                            }
                            Button { Task { await testClient(client) } } label: {
                                Label("Test", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { clientPendingDelete = client }
                        }
                }
            }
        }

        Section {
        } footer: {
            Text("Trawl can prefill connection details for qBittorrent and SABnzbd. Other client types can still be added, but you'll need to enter their host and credentials yourself.")
        }
    }

    /// The two clients Trawl itself integrates with, offered up front by the add menu.
    private enum PendingAddClient: String, CaseIterable, Identifiable {
        case qbittorrent
        case sabnzbd

        var id: String { rawValue }

        /// Must match the `implementation` value Sonarr/Radarr return in their schema.
        var implementation: String {
            switch self {
            case .qbittorrent: "QBittorrent"
            case .sabnzbd: "Sabnzbd"
            }
        }

        var title: String {
            switch self {
            case .qbittorrent: "qBittorrent"
            case .sabnzbd: "SABnzbd"
            }
        }

        var icon: String {
            switch self {
            case .qbittorrent: "arrow.down.circle"
            case .sabnzbd: "newspaper"
            }
        }
    }

    private func clientRow(_ client: ArrDownloadClient) -> some View {
        HStack(spacing: 12) {
            reachabilityIcon(for: client)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(client.name ?? "Unknown")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 4) {
                    if let implName = client.implementationName, !implName.isEmpty {
                        Text(implName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let host = client.hostDisplayValue, !host.isEmpty {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        let portSuffix = client.portDisplayValue.map { ":\($0)" } ?? ""
                        Text("\(host)\(portSuffix)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if isTogglingID == client.id || isTestingID == client.id {
                ProgressView()
                    .scaleEffect(0.8)
            } else if let priority = client.priority {
                Text("P\(priority)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func reachabilityIcon(for client: ArrDownloadClient) -> some View {
        if !client.enable {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        } else if isCheckingIDs.contains(client.id) {
            ProgressView()
                .scaleEffect(0.7)
        } else if let reached = reachability[client.id] {
            Image(systemName: reached ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(reached ? .green : .red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green.opacity(0.4))
        }
    }

    // MARK: - Data

    private func loadClients() async {
        isLoading = true
        loadError = nil
        reachability = [:]
        defer { isLoading = false }

        do {
            guard supportsDownloadClients else {
                clients = []
                return
            }
            guard let client = scopedClient else { throw ArrError.noServiceConfigured }
            clients = try await client.getDownloadClients()
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Reachability

    private func checkReachabilityForAll() {
        guard supportsDownloadClients else { return }
        let enabled = clients.filter { $0.enable }
        isCheckingIDs = Set(enabled.map { $0.id })
        for client in enabled {
            checkReachability(for: client)
        }
    }

    private func checkReachability(for client: ArrDownloadClient) {
        guard supportsDownloadClients else { return }
        guard client.enable else { return }
        isCheckingIDs.insert(client.id)
        Task {
            do {
                switch serviceType {
                case .sonarr, .radarr:
                    guard let apiClient = scopedClient else {
                        reachability[client.id] = false
                        isCheckingIDs.remove(client.id)
                        return
                    }
                    try await apiClient.testDownloadClient(client)
                case .prowlarr:
                    reachability[client.id] = false
                    isCheckingIDs.remove(client.id)
                    return
                case .bazarr:
                    reachability[client.id] = false
                    isCheckingIDs.remove(client.id)
                    return
                }
                reachability[client.id] = true
            } catch {
                reachability[client.id] = false
            }
            isCheckingIDs.remove(client.id)
        }
    }

    // MARK: - Actions

    private func toggleEnable(_ downloadClient: ArrDownloadClient) async {
        guard supportsDownloadClients else { return }
        guard isTogglingID == nil else { return }
        isTogglingID = downloadClient.id
        defer { isTogglingID = nil }

        var updated = downloadClient
        updated.enable = !downloadClient.enable

        do {
            let saved: ArrDownloadClient
            guard supportsDownloadClients else { return }
            guard let client = scopedClient else { throw ArrError.noServiceConfigured }
            saved = try await client.updateDownloadClient(updated)
            if let idx = clients.firstIndex(where: { $0.id == saved.id }) {
                clients[idx] = saved
            }
            if saved.enable {
                checkReachability(for: saved)
            } else {
                reachability.removeValue(forKey: saved.id)
            }
        } catch {
            inAppNotificationCenter.showError(title: "Update Failed", message: error.localizedDescription)
        }
    }

    private func testClient(_ downloadClient: ArrDownloadClient) async {
        guard supportsDownloadClients else { return }
        guard isTestingID == nil else { return }
        isTestingID = downloadClient.id
        defer { isTestingID = nil }

        do {
            guard supportsDownloadClients else { return }
            guard let client = scopedClient else { throw ArrError.noServiceConfigured }
            try await client.testDownloadClient(downloadClient)
            reachability[downloadClient.id] = true
            inAppNotificationCenter.showSuccess(
                title: "Test Passed",
                message: "\(downloadClient.name ?? "Client") connected successfully."
            )
        } catch {
            reachability[downloadClient.id] = false
            inAppNotificationCenter.showError(title: "Test Failed", message: error.localizedDescription)
        }
    }

    private func deleteClient(_ downloadClient: ArrDownloadClient) async {
        guard supportsDownloadClients else { return }
        do {
            guard supportsDownloadClients else { return }
            guard let client = scopedClient else { throw ArrError.noServiceConfigured }
            try await client.deleteDownloadClient(id: downloadClient.id)
            clients.removeAll { $0.id == downloadClient.id }
            reachability.removeValue(forKey: downloadClient.id)
            inAppNotificationCenter.showSuccess(
                title: "Deleted",
                message: "\(downloadClient.name ?? "Client") removed from \(selectedLabel)."
            )
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

#if DEBUG
#Preview("Download Clients - Loaded") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        NavigationStack {
            ArrDownloadClientListView(
                serviceType: .sonarr,
                previewClients: ArrDownloadClient.previewList,
                reachability: [1: true, 2: false, 3: true]
            )
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Download Clients - Empty") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        NavigationStack {
            ArrDownloadClientListView(serviceType: .sonarr, previewClients: [])
        }
        .environment(InAppNotificationCenter.shared)
    }
}

#Preview("Download Clients - Unsupported") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrDownloadClientListView(serviceType: .prowlarr, previewClients: [])
        }
        .environment(InAppNotificationCenter.shared)
    }
}
#endif
