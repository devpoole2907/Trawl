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
    @State private var showAddSheet = false
    @State private var reachability: [Int: Bool] = [:]
    @State private var isCheckingIDs: Set<Int> = []

    var body: some View {
        List {
            if isLoading && clients.isEmpty {
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
            } else if clients.isEmpty {
                ContentUnavailableView(
                    "No Download Clients",
                    systemImage: "arrow.down.circle",
                    description: Text("No download clients are configured in \(serviceType.displayName).")
                )
                .listRowBackground(Color.clear)
            } else {
                clientSections
            }
        }
        .navigationTitle("Download Clients")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Download Client", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ArrDownloadClientEditorSheet(serviceType: serviceType) { saved in
                clients.append(saved)
                clients.sort { ($0.name ?? "") < ($1.name ?? "") }
                checkReachability(for: saved)
                inAppNotificationCenter.showSuccess(
                    title: "Added",
                    message: "\(saved.name ?? "Download client") added to \(serviceType.displayName)."
                )
            }
            .environment(serviceManager)
        }
        .sheet(item: $clientBeingEdited) { client in
            ArrDownloadClientEditorSheet(serviceType: serviceType, existingClient: client) { saved in
                if let idx = clients.firstIndex(where: { $0.id == saved.id }) {
                    clients[idx] = saved
                }
                checkReachability(for: saved)
                inAppNotificationCenter.showSuccess(
                    title: "Updated",
                    message: "\(saved.name ?? "Download client") updated in \(serviceType.displayName)."
                )
            }
            .environment(serviceManager)
        }
        .refreshable {
            await loadClients()
            checkReachabilityForAll()
        }
        .task {
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
                Text("Remove '\(client.name ?? "this client")' from \(serviceType.displayName)?")
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
            Text("Only qBittorrent is currently supported when adding new download clients through Trawl.")
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
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                clients = try await client.getDownloadClients()
                    .sorted { ($0.name ?? "") < ($1.name ?? "") }
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                clients = try await client.getDownloadClients()
                    .sorted { ($0.name ?? "") < ($1.name ?? "") }
            case .prowlarr:
                clients = []
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Reachability

    private func checkReachabilityForAll() {
        let enabled = clients.filter { $0.enable }
        isCheckingIDs = Set(enabled.map { $0.id })
        for client in enabled {
            checkReachability(for: client)
        }
    }

    private func checkReachability(for client: ArrDownloadClient) {
        guard client.enable else { return }
        isCheckingIDs.insert(client.id)
        Task {
            do {
                switch serviceType {
                case .sonarr:
                    guard let apiClient = serviceManager.sonarrClient else {
                        reachability[client.id] = false
                        isCheckingIDs.remove(client.id)
                        return
                    }
                    try await apiClient.testDownloadClient(client)
                case .radarr:
                    guard let apiClient = serviceManager.radarrClient else {
                        reachability[client.id] = false
                        isCheckingIDs.remove(client.id)
                        return
                    }
                    try await apiClient.testDownloadClient(client)
                case .prowlarr:
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
        guard isTogglingID == nil else { return }
        isTogglingID = downloadClient.id
        defer { isTogglingID = nil }

        var updated = downloadClient
        updated.enable = !downloadClient.enable

        do {
            let saved: ArrDownloadClient
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                saved = try await client.updateDownloadClient(updated)
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                saved = try await client.updateDownloadClient(updated)
            case .prowlarr:
                return
            }
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
        guard isTestingID == nil else { return }
        isTestingID = downloadClient.id
        defer { isTestingID = nil }

        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                try await client.testDownloadClient(downloadClient)
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                try await client.testDownloadClient(downloadClient)
            case .prowlarr:
                return
            }
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
        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                try await client.deleteDownloadClient(id: downloadClient.id)
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                try await client.deleteDownloadClient(id: downloadClient.id)
            case .prowlarr:
                return
            }
            clients.removeAll { $0.id == downloadClient.id }
            reachability.removeValue(forKey: downloadClient.id)
            inAppNotificationCenter.showSuccess(
                title: "Deleted",
                message: "\(downloadClient.name ?? "Client") removed from \(serviceType.displayName)."
            )
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}
