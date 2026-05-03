import SwiftUI
import SwiftData

struct ArrRemotePathMappingListView: View {
    let serviceType: ArrServiceType

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var mappings: [ArrRemotePathMapping] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var mappingBeingEdited: ArrRemotePathMapping?
    @State private var mappingPendingDelete: ArrRemotePathMapping?
    @State private var showAddSheet = false

    var body: some View {
        List {
            if isLoading && mappings.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Loading remote path mappings…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else if mappings.isEmpty {
                ContentUnavailableView(
                    "No Remote Path Mappings",
                    systemImage: "arrow.triangle.swap",
                    description: Text("Add a mapping when \(serviceType.displayName) and your download client are on different machines or use different paths.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(mappings) { mapping in
                        Button {
                            mappingBeingEdited = mapping
                        } label: {
                            mappingRow(mapping)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                mappingPendingDelete = mapping
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                mappingBeingEdited = mapping
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                mappingBeingEdited = mapping
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                mappingPendingDelete = mapping
                            }
                        }
                    }
                } footer: {
                    Text("Mappings translate paths reported by your download client into paths \(serviceType.displayName) can access. Use * as the host to match any download client.")
                }
            }
        }
        .navigationTitle("Remote Path Mappings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if serviceType != .prowlarr {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Mapping", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: serviceType != .prowlarr ? $showAddSheet : .constant(false)) {
            ArrRemotePathMappingEditorSheet(serviceType: serviceType) { saved in
                mappings.append(saved)
                mappings.sort { $0.host < $1.host }
                inAppNotificationCenter.showSuccess(
                    title: "Added",
                    message: "Remote path mapping added to \(serviceType.displayName)."
                )
            }
            .environment(serviceManager)
        }
        .sheet(item: serviceType != .prowlarr ? $mappingBeingEdited : .constant(nil)) { mapping in
            ArrRemotePathMappingEditorSheet(serviceType: serviceType, existingMapping: mapping) { saved in
                if let idx = mappings.firstIndex(where: { $0.id == saved.id }) {
                    mappings[idx] = saved
                    mappings.sort { $0.host < $1.host }
                }
                inAppNotificationCenter.showSuccess(
                    title: "Updated",
                    message: "Remote path mapping updated in \(serviceType.displayName)."
                )
            }
            .environment(serviceManager)
        }
        .refreshable { await loadMappings() }
        .task { await loadMappings() }
        .confirmationDialog(
            "Delete Mapping?",
            isPresented: Binding(
                get: { mappingPendingDelete != nil },
                set: { if !$0 { mappingPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let mapping = mappingPendingDelete else { return }
                mappingPendingDelete = nil
                Task { await deleteMapping(mapping) }
            }
            Button("Cancel", role: .cancel) { mappingPendingDelete = nil }
        } message: {
            if let mapping = mappingPendingDelete {
                Text("Remove the mapping from '\(mapping.remotePath)' to '\(mapping.localPath)'?")
            }
        }
    }

    private func mappingRow(_ mapping: ArrRemotePathMapping) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(mapping.host == "*" ? "Any Host" : mapping.host)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(mapping.host == "*" ? .secondary : .primary)
            }

            HStack(spacing: 6) {
                Text(mapping.remotePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(mapping.localPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private func loadMappings() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                mappings = try await client.getRemotePathMappings()
                    .sorted { $0.host < $1.host }
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                mappings = try await client.getRemotePathMappings()
                    .sorted { $0.host < $1.host }
            case .prowlarr, .bazarr:
                mappings = []
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func deleteMapping(_ mapping: ArrRemotePathMapping) async {
        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                try await client.deleteRemotePathMapping(id: mapping.id)
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                try await client.deleteRemotePathMapping(id: mapping.id)
            case .prowlarr, .bazarr:
                return
            }
            mappings.removeAll { $0.id == mapping.id }
            inAppNotificationCenter.showSuccess(
                title: "Deleted",
                message: "Remote path mapping removed from \(serviceType.displayName)."
            )
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

// MARK: - Editor Sheet

struct ArrRemotePathMappingEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var servers: [ServerProfile]

    let serviceType: ArrServiceType
    let existingMapping: ArrRemotePathMapping?
    let onComplete: (ArrRemotePathMapping) -> Void

    @State private var host = ""
    @State private var remotePath = ""
    @State private var localPath = ""
    @State private var selectedHostID = Self.customID
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasLoadedInitialState = false

    private static let wildcardID = "wildcard"
    private static let customID = "custom"

    init(
        serviceType: ArrServiceType,
        existingMapping: ArrRemotePathMapping? = nil,
        onComplete: @escaping (ArrRemotePathMapping) -> Void
    ) {
        self.serviceType = serviceType
        self.existingMapping = existingMapping
        self.onComplete = onComplete
    }

    private var isEditing: Bool { existingMapping != nil }

    private var qbitProfiles: [ServerProfile] {
        servers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedProfile: ServerProfile? {
        qbitProfiles.first { $0.id.uuidString == selectedHostID }
    }

    private var isCustom: Bool {
        selectedHostID == Self.customID
    }

    private var canSave: Bool {
        !isSaving &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Host", selection: $selectedHostID) {
                        ForEach(qbitProfiles) { profile in
                            Text(profile.displayName).tag(profile.id.uuidString)
                        }
                        Text("Any Host (*)").tag(Self.wildcardID)
                        Text("Custom").tag(Self.customID)
                    }

                    if isCustom {
                        LabeledContent("Hostname") {
                            TextField("192.168.1.10", text: $host)
                                #if os(iOS)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                #endif
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Host")
                } footer: {
                    if selectedHostID == Self.wildcardID {
                        Text("* matches any download client host.")
                    } else if isCustom {
                        Text("Enter the hostname exactly as the download client reports it.")
                    } else {
                        Text("Host is taken from the selected qBittorrent profile.")
                    }
                }

                Section {
                    LabeledContent("Remote Path") {
                        TextField("/downloads/", text: $remotePath)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Local Path") {
                        TextField("/media/downloads/", text: $localPath)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Paths")
                } footer: {
                    Text("Remote path is what the download client reports. Local path is where \(serviceType.displayName) can access the same files.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Mapping" : "Add Mapping")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(isEditing ? "Update" : "Save") {
                            Task { await save() }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .task {
                guard !hasLoadedInitialState else { return }
                hasLoadedInitialState = true
                if let existing = existingMapping {
                    remotePath = existing.remotePath
                    localPath = existing.localPath
                    selectedHostID = matchedHostID(for: existing.host)
                    if isCustom { host = existing.host }
                } else {
                    if let first = qbitProfiles.first {
                        selectedHostID = first.id.uuidString
                    } else {
                        selectedHostID = Self.wildcardID
                    }
                }
                applySelectedHostID()
            }
            .onChange(of: selectedHostID) { _, _ in
                guard hasLoadedInitialState else { return }
                applySelectedHostID()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func normalizedHost(from hostURL: String) -> String {
        URL(string: hostURL)?.host ?? hostURL
    }

    private func applySelectedHostID() {
        if selectedHostID == Self.wildcardID {
            host = "*"
        } else if selectedHostID == Self.customID {
            // Preserve current host value when custom is selected
            // No-op: keep existing host value
        } else if let profile = selectedProfile {
            host = normalizedHost(from: profile.hostURL)
        } else {
            host = ""
        }
    }

    private func matchedHostID(for existingHost: String) -> String {
        if existingHost == "*" { return Self.wildcardID }
        if let match = qbitProfiles.first(where: { profile in
            normalizedHost(from: profile.hostURL).lowercased() == existingHost.lowercased()
        }) {
            return match.id.uuidString
        }
        return Self.customID
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        let payload = ArrRemotePathMapping(
            id: existingMapping?.id ?? 0,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines),
            localPath: localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            let saved: ArrRemotePathMapping
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                saved = isEditing
                    ? try await client.updateRemotePathMapping(payload)
                    : try await client.createRemotePathMapping(payload)
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                saved = isEditing
                    ? try await client.updateRemotePathMapping(payload)
                    : try await client.createRemotePathMapping(payload)
            case .prowlarr, .bazarr:
                throw ArrError.noServiceConfigured
            }
            onComplete(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
