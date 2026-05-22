import SwiftUI
import SwiftData

struct ArrRemotePathMappingListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter

    @State private var mappings: [RemotePathMappingEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var mappingBeingEdited: RemotePathMappingEntry?
    @State private var mappingPendingDelete: RemotePathMappingEntry?
    @State private var showAddSheet = false

    private var availableServices: [ArrServiceType] {
        [
            serviceManager.sonarrClient == nil ? nil : ArrServiceType.sonarr,
            serviceManager.radarrClient == nil ? nil : ArrServiceType.radarr,
            serviceManager.activeBazarrEntry?.client == nil ? nil : ArrServiceType.bazarr
        ].compactMap(\.self)
    }

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
                    description: Text("Add a mapping when Sonarr, Radarr, Bazarr, and your download client are on different machines or use different paths.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(mappings) { entry in
                        Button {
                            mappingBeingEdited = entry
                        } label: {
                            mappingRow(entry)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                mappingPendingDelete = entry
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                mappingBeingEdited = entry
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") {
                                mappingBeingEdited = entry
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                mappingPendingDelete = entry
                            }
                        }
                    }
                } footer: {
                    Text("Mappings translate paths reported by another service into paths the selected app can access. Use * as the host for Sonarr or Radarr to match any download client.")
                }
            }
        }
        .navigationTitle("Remote Path Mappings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        #endif
        .moreDestinationBackground(.remotePathMappings)
        .toolbar {
            if !availableServices.isEmpty {
                ToolbarItem(placement: platformTopBarTrailingPlacement) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Mapping", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: !availableServices.isEmpty ? $showAddSheet : .constant(false)) {
            ArrRemotePathMappingEditorSheet(availableServices: availableServices) { serviceType, saved in
                mappings.append(RemotePathMappingEntry(serviceType: serviceType, mapping: saved))
                sortMappings()
                inAppNotificationCenter.showSuccess(
                    title: "Added",
                    message: "Remote path mapping added to \(serviceType.displayName)."
                )
            }
            .environment(serviceManager)
        }
        .sheet(item: $mappingBeingEdited) { entry in
            ArrRemotePathMappingEditorSheet(
                availableServices: [entry.serviceType],
                initialServiceType: entry.serviceType,
                existingMapping: entry.mapping
            ) { serviceType, saved in
                if let idx = mappings.firstIndex(where: { $0.id == entry.id }) {
                    mappings[idx] = RemotePathMappingEntry(serviceType: serviceType, mapping: saved)
                    sortMappings()
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
            if let entry = mappingPendingDelete {
                Text("Remove the \(entry.serviceType.displayName) mapping from '\(entry.mapping.remotePath)' to '\(entry.mapping.localPath)'?")
            }
        }
    }

    private func mappingRow(_ entry: RemotePathMappingEntry) -> some View {
        let mapping = entry.mapping
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: entry.serviceType.serviceIdentity.systemImage)
                    .font(.caption)
                    .foregroundStyle(entry.serviceType.serviceIdentity.brandColor)
                    .frame(width: 18)
                Text(entry.serviceType.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.serviceType.serviceIdentity.brandColor)

                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

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
            let sonarrClient = serviceManager.sonarrClient
            let radarrClient = serviceManager.radarrClient
            let bazarrClient = serviceManager.activeBazarrEntry?.client

            async let sonarrMappings: [RemotePathMappingEntry] = {
                guard let client = sonarrClient else { return [] }
                return try await client.getRemotePathMappings().map {
                    RemotePathMappingEntry(serviceType: .sonarr, mapping: $0)
                }
            }()

            async let radarrMappings: [RemotePathMappingEntry] = {
                guard let client = radarrClient else { return [] }
                return try await client.getRemotePathMappings().map {
                    RemotePathMappingEntry(serviceType: .radarr, mapping: $0)
                }
            }()

            async let bazarrMappings: [RemotePathMappingEntry] = {
                guard let client = bazarrClient else { return [] }
                return try await client.getRemotePathMappings().map {
                    RemotePathMappingEntry(serviceType: .bazarr, mapping: $0)
                }
            }()

            let loadedMappings = try await sonarrMappings + radarrMappings + bazarrMappings
            mappings = loadedMappings
            sortMappings()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func sortMappings() {
        mappings.sort {
            if $0.serviceType != $1.serviceType {
                return $0.serviceType.displayName < $1.serviceType.displayName
            }
            return $0.mapping.host.localizedCaseInsensitiveCompare($1.mapping.host) == .orderedAscending
        }
    }

    private func deleteMapping(_ entry: RemotePathMappingEntry) async {
        do {
            switch entry.serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                try await client.deleteRemotePathMapping(id: entry.mapping.id)
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                try await client.deleteRemotePathMapping(id: entry.mapping.id)
            case .prowlarr:
                return
            case .bazarr:
                guard let client = serviceManager.activeBazarrEntry?.client else { throw ArrError.noServiceConfigured }
                try await client.deleteRemotePathMapping(id: entry.mapping.id)
            }
            if entry.serviceType == .bazarr {
                await loadMappings()
            } else {
                mappings.removeAll { $0.id == entry.id }
            }
            inAppNotificationCenter.showSuccess(
                title: "Deleted",
                message: "Remote path mapping removed from \(entry.serviceType.displayName)."
            )
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

private struct RemotePathMappingEntry: Identifiable {
    let serviceType: ArrServiceType
    let mapping: ArrRemotePathMapping

    var id: String { "\(serviceType.rawValue)-\(mapping.id)" }
}

// MARK: - Editor Sheet

struct ArrRemotePathMappingEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var servers: [ServerProfile]

    let availableServices: [ArrServiceType]
    let initialServiceType: ArrServiceType?
    let existingMapping: ArrRemotePathMapping?
    let onComplete: (ArrServiceType, ArrRemotePathMapping) -> Void

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var host = ""
    @State private var remotePath = ""
    @State private var localPath = ""
    @State private var selectedHostID = Self.customID
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasLoadedInitialState = false

    private static let wildcardID = "wildcard"
    private static let customID = "custom"
    private static let bazarrSonarrID = "bazarr-sonarr"
    private static let bazarrRadarrID = "bazarr-radarr"

    init(
        availableServices: [ArrServiceType],
        initialServiceType: ArrServiceType? = nil,
        existingMapping: ArrRemotePathMapping? = nil,
        onComplete: @escaping (ArrServiceType, ArrRemotePathMapping) -> Void
    ) {
        self.availableServices = availableServices
        self.initialServiceType = initialServiceType
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
        (selectedService == .sonarr || selectedService == .radarr || selectedService == .bazarr) &&
        !isSaving &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        AppSheetShell(
            title: isEditing ? "Edit Mapping" : "Add Mapping",
            confirmTitle: isEditing ? "Update" : "Save",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { Task { await save() } },
            detents: [.medium, .large]
        ) {
            Form {
                if availableServices.count > 1 && !isEditing {
                    Section {
                        Picker("Service", selection: $selectedService) {
                            ForEach(availableServices, id: \.self) { service in
                                Text(service.displayName).tag(service)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    if selectedService == .bazarr {
                        Picker("Source App", selection: $selectedHostID) {
                            Text("Sonarr").tag(Self.bazarrSonarrID)
                            Text("Radarr").tag(Self.bazarrRadarrID)
                        }
                        .disabled(isEditing)
                    } else {
                        Picker("Host", selection: $selectedHostID) {
                            ForEach(qbitProfiles) { profile in
                                Text(profile.displayName).tag(profile.id.uuidString)
                            }
                            Text("Any Host (*)").tag(Self.wildcardID)
                            Text("Custom").tag(Self.customID)
                        }
                    }

                    if isCustom && selectedService != .bazarr {
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
                    Text(selectedService == .bazarr ? "Source" : "Host")
                } footer: {
                    if selectedService == .bazarr {
                        Text("Bazarr keeps separate path mappings for Sonarr TV paths and Radarr movie paths.")
                    } else if selectedHostID == Self.wildcardID {
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
                    if selectedService == .bazarr {
                        Text("Remote path is what Sonarr or Radarr reports. Local path is where Bazarr can access the same files.")
                    } else {
                        Text("Remote path is what the download client reports. Local path is where \(selectedService.displayName) can access the same files.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .task {
                guard !hasLoadedInitialState else { return }
                hasLoadedInitialState = true
                selectedService = initialServiceType ?? availableServices.first ?? .sonarr
                if let existing = existingMapping {
                    remotePath = existing.remotePath
                    localPath = existing.localPath
                    selectedHostID = matchedHostID(for: existing.host)
                    if isCustom { host = existing.host }
                } else if selectedService == .bazarr {
                    selectedHostID = Self.bazarrSonarrID
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
            .onChange(of: selectedService) { _, _ in
                guard hasLoadedInitialState else { return }
                if selectedService == .bazarr {
                    selectedHostID = Self.bazarrSonarrID
                } else if selectedHostID == Self.bazarrSonarrID || selectedHostID == Self.bazarrRadarrID {
                    selectedHostID = qbitProfiles.first?.id.uuidString ?? Self.wildcardID
                }
                applySelectedHostID()
            }
        }
    }

    private func normalizedHost(from hostURL: String) -> String {
        URL(string: hostURL)?.host ?? hostURL
    }

    private func applySelectedHostID() {
        if selectedService == .bazarr {
            host = selectedHostID == Self.bazarrRadarrID ? "Radarr" : "Sonarr"
        } else if selectedHostID == Self.wildcardID {
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
        if existingHost.localizedCaseInsensitiveCompare("Radarr") == .orderedSame { return Self.bazarrRadarrID }
        if existingHost.localizedCaseInsensitiveCompare("Sonarr") == .orderedSame { return Self.bazarrSonarrID }
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
            switch selectedService {
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
            case .prowlarr:
                throw ArrError.noServiceConfigured
            case .bazarr:
                guard let client = serviceManager.activeBazarrEntry?.client else { throw ArrError.noServiceConfigured }
                saved = isEditing
                    ? try await client.updateRemotePathMapping(payload)
                    : try await client.createRemotePathMapping(payload)
            }
            onComplete(selectedService, saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
