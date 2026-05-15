import SwiftUI
import SwiftData

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
                guard let applicationPendingDelete else { return }
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
            } else if let errorMessage = viewModel.errorMessage, !viewModel.isLoadingApplications, viewModel.supportedApplications.isEmpty {
                ContentUnavailableView(
                    "Could Not Load Apps",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .listRowBackground(Color.clear)
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
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                applicationPendingDelete = application
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }

                            Button {
                                editorContext = .edit(application)
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
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
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
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
    @State private var seededAPIKey = ""
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
        AppSheetShell(
            title: application == nil ? "Link \(appType.displayName)" : "Edit \(appType.displayName)",
            confirmTitle: application == nil ? "Save" : "Update",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { Task { await save() } }
        ) {
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
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
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
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .disabled(!isUsingCustomRemoteServer)
                    }

                    LabeledContent("API Key") {
                        SecureField("API key", text: $apiKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
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
            .task {
                await loadInitialStateIfNeeded()
            }
            .onChange(of: selectedRemoteProfileID) { _, newProfileID in
                guard hasLoadedInitialState else { return }
                if let application, newProfileID == Self.customProfileID {
                    remoteURL = application.stringFieldValue(named: "baseUrl") ?? remoteURL
                    let restoredKey = application.stringFieldValue(named: "apiKey") ?? ""
                    apiKey = restoredKey
                    seededAPIKey = restoredKey
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
            seededAPIKey = apiKey

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

        // Only preserve apiKey if the user manually edited it away from the last seeded value.
        // When the picker switches to a different profile, refresh the key for that profile.
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKey.isEmpty || trimmedKey == seededAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        do {
            let loaded = try await KeychainHelper.shared.read(key: selectedRemoteProfile.apiKeyKeychainKey) ?? ""
            apiKey = loaded
            seededAPIKey = loaded
        } catch {
            apiKey = ""
            seededAPIKey = ""
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
