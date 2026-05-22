import SwiftUI
import SwiftData

struct SeerrLinkedApplicationEditorSheet: View {
    let apiClient: SeerrAPIClient
    let context: SeerrLinkedAppEditorContext
    let onSaved: (SeerrDVRSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var allProfiles: [ArrServiceProfile]

    @State private var form: FormState
    @State private var selectedRemoteProfileID = Self.customRemoteProfileID
    @State private var seededAPIKey = ""
    @State private var hasLoadedRemoteSelection = false
    @State private var profiles: [SeerrQualityProfile] = []
    @State private var rootFolders: [SeerrRootFolder] = []
    @State private var availableTags: [SeerrDVRTag] = []
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isLoadingMetadata = false
    @State private var statusMessage: StatusMessage?
    @State private var errorAlert: ErrorAlertItem?

    private static let customRemoteProfileID = "custom"

    init(
        apiClient: SeerrAPIClient,
        context: SeerrLinkedAppEditorContext,
        onSaved: @escaping (SeerrDVRSettings) -> Void
    ) {
        self.apiClient = apiClient
        self.context = context
        self.onSaved = onSaved
        _form = State(initialValue: FormState(context: context))
    }

    private var kind: SeerrDVRKind { context.kind }
    private var isEditing: Bool {
        if case .edit = context { return true }
        return false
    }

    private var remoteServiceType: ArrServiceType {
        switch kind {
        case .sonarr: .sonarr
        case .radarr: .radarr
        }
    }

    private var remoteProfiles: [ArrServiceProfile] {
        allProfiles
            .filter { $0.resolvedServiceType == remoteServiceType && $0.isEnabled }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedRemoteProfile: ArrServiceProfile? {
        remoteProfiles.first { $0.id.uuidString == selectedRemoteProfileID }
    }

    private var isUsingSavedServer: Bool {
        !isEditing && selectedRemoteProfile != nil
    }

    var body: some View {
        AppSheetShell(
            title: navigationTitle,
            confirmTitle: isEditing ? "Update" : "Save",
            isConfirmDisabled: !form.isValid,
            isConfirmLoading: isSaving,
            onConfirm: { Task { await save() } }
        ) {
            Form {
                generalSection
                connectionSection
                librarySection
                tagsSection
                advancedSection
                behaviorSection
            }
            .errorAlert(item: $errorAlert)
            .task {
                await loadRemoteSelectionIfNeeded()
                if isEditing, case .edit(let entry) = context {
                    await loadServiceMetadata(for: entry.settings.id)
                }
            }
            .onChange(of: selectedRemoteProfileID) { _, _ in
                guard hasLoadedRemoteSelection, !isEditing else { return }
                Task { await applySelectedRemoteProfile() }
            }
        }
    }

    private var navigationTitle: String {
        switch context {
        case .create(let kind): return "Link \(kind.displayName)"
        case .edit: return "Edit \(kind.displayName) Server"
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section {
            if !isEditing && !remoteProfiles.isEmpty {
                Picker("\(kind.displayName) Server", selection: $selectedRemoteProfileID) {
                    ForEach(remoteProfiles) { profile in
                        Text(profile.displayName).tag(profile.id.uuidString)
                    }
                    Text("Custom").tag(Self.customRemoteProfileID)
                }
            }

            Toggle("Default Server", isOn: $form.isDefault)
            Toggle("4K Server", isOn: $form.is4k)
        } header: {
            Text("General")
        } footer: {
            Text("Toggle 4K Server only if you have a separate 4K instance. Leave unchecked for a single server.")
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Server Name") {
                TextField("\(kind.displayName) instance", text: $form.name)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(isUsingSavedServer)
            }

            LabeledContent("Hostname or IP") {
                TextField("192.168.1.50", text: $form.hostname)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(isUsingSavedServer)
            }

            LabeledContent("Port") {
                TextField(kind == .sonarr ? "8989" : "7878", text: $form.portText)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .disabled(isUsingSavedServer)
            }

            Toggle("Use SSL", isOn: $form.useSsl)
                .disabled(isUsingSavedServer)

            LabeledContent("API Key") {
                SecureField("API key", text: $form.apiKey)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(isUsingSavedServer)
            }

            LabeledContent("URL Base") {
                TextField("/\(kind.rawValue)", text: $form.baseUrl)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .disabled(isUsingSavedServer)
            }

            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    if isTesting {
                        ProgressView()
                            .padding(.trailing, 4)
                    }
                    Label("Test Connection", systemImage: "checkmark.circle")
                }
            }
            .disabled(!form.canTest || isTesting)

            if let statusMessage {
                Label(statusMessage.text, systemImage: statusMessage.iconName)
                    .font(.subheadline)
                    .foregroundStyle(statusMessage.tint)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Find your API key in \(kind.displayName) under Settings → General → Security. Set URL Base only if you've configured one in \(kind.displayName)'s host settings (e.g. /\(kind.rawValue)). Leave blank otherwise.")
        }
    }

    @ViewBuilder
    private var librarySection: some View {
        if !profiles.isEmpty || !rootFolders.isEmpty || isLoadingMetadata {
            Section {
                if isLoadingMetadata {
                    HStack {
                        ProgressView()
                        Text("Loading profiles…")
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Quality Profile", selection: $form.activeProfileId) {
                    if form.activeProfileId == nil {
                        Text("Select…").tag(Optional<Int>.none)
                    }
                    ForEach(profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.id))
                    }
                }

                Picker("Root Folder", selection: $form.activeDirectory) {
                    if form.activeDirectory.isEmpty {
                        Text("Select…").tag("")
                    }
                    ForEach(rootFolderPickerOptions, id: \.safeID) { folder in
                        Text(folder.displayPath).tag(folder.path ?? "")
                    }
                }

                if kind == .radarr {
                    Picker("Minimum Availability", selection: $form.minimumAvailability) {
                        ForEach(SeerrRadarrAvailability.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Test the connection if you don't see your profiles or root folders.")
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        if !availableTags.isEmpty {
            Section {
                NavigationLink {
                    SeerrTagPickerView(tags: availableTags, selection: $form.tagIDs)
                } label: {
                    LabeledContent("Tags") {
                        Text(tagSummary)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("Select tags to apply to releases sent to \(kind.displayName).")
            }
        }
    }

    private var advancedSection: some View {
        Section {
            LabeledContent("External URL") {
                TextField("https://...", text: $form.externalUrl)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("External URL is used for clickable links on media pages when the hostname is not reachable from outside your network.")
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle("Enable Scan", isOn: $form.syncEnabled)
            Toggle("Enable Automatic Search", isOn: $form.automaticSearchEnabled)
            Toggle("Tag Requests", isOn: $form.tagRequests)
        } header: {
            Text("Behavior")
        } footer: {
            Text("Enable Scan checks \(kind.displayName) for existing media and request status so users can't request content already available. Automatic Search triggers a search in \(kind.displayName) when a request is approved. Tag Requests adds a tag with the requester's user ID and display name.")
        }
    }

    private var tagSummary: String {
        if form.tagIDs.isEmpty { return "None" }
        if form.tagIDs.count == 1, let only = form.tagIDs.first {
            return availableTags.first(where: { $0.id == only })?.displayLabel ?? "1 tag"
        }
        return "\(form.tagIDs.count) tags"
    }

    private var rootFolderPickerOptions: [SeerrRootFolder] {
        guard !form.activeDirectory.isEmpty else { return rootFolders }
        let selected = normalizedRootFolderPath(form.activeDirectory)
        if rootFolders.contains(where: { normalizedRootFolderPath($0.path ?? "") == selected }) {
            return rootFolders
        }
        return [SeerrRootFolder(id: nil, path: form.activeDirectory, freeSpace: nil)] + rootFolders
    }

    // MARK: - Actions

    private func loadRemoteSelectionIfNeeded() async {
        guard !hasLoadedRemoteSelection else { return }
        defer { hasLoadedRemoteSelection = true }
        guard !isEditing else {
            seededAPIKey = form.apiKey
            return
        }

        if let first = remoteProfiles.first {
            selectedRemoteProfileID = first.id.uuidString
            await applySelectedRemoteProfile()
        } else {
            selectedRemoteProfileID = Self.customRemoteProfileID
        }
    }

    private func applySelectedRemoteProfile() async {
        withAnimation(.snappy) {
            statusMessage = nil
            profiles = []
            rootFolders = []
            availableTags = []
        }

        guard selectedRemoteProfileID != Self.customRemoteProfileID else {
            clearCustomServerFields()
            return
        }
        guard let selectedRemoteProfile else { return }

        do {
            let parsed = try ParsedSeerrLinkedServerURL(
                profileURL: selectedRemoteProfile.hostURL,
                defaultPort: remoteServiceType.defaultPort
            )
            form.name = selectedRemoteProfile.displayName
            form.hostname = parsed.host
            form.portText = parsed.port
            form.useSsl = parsed.isSSL
            form.baseUrl = parsed.baseURL == "/" ? "" : parsed.baseURL
        } catch {
            withAnimation(.snappy) {
                statusMessage = StatusMessage(
                    text: error.localizedDescription,
                    iconName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
            return
        }

        do {
            let loaded = try await KeychainHelper.shared.read(key: selectedRemoteProfile.apiKeyKeychainKey) ?? ""
            form.apiKey = loaded
            seededAPIKey = loaded
        } catch {
            form.apiKey = ""
            seededAPIKey = ""
            withAnimation(.snappy) {
                statusMessage = StatusMessage(
                    text: "Couldn't load the saved API key: \(error.localizedDescription)",
                    iconName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }
    }

    private func clearCustomServerFields() {
        form.name = ""
        form.hostname = ""
        form.portText = kind == .sonarr ? "8989" : "7878"
        form.useSsl = false
        form.apiKey = ""
        form.baseUrl = ""
        form.activeProfileId = nil
        form.activeDirectory = ""
        seededAPIKey = ""
    }

    private func testConnection() async {
        guard let port = Int(form.portText) else { return }
        withAnimation(.snappy) {
            statusMessage = nil
        }
        isTesting = true
        do {
            let result = try await apiClient.testDVRConnection(
                kind,
                body: SeerrDVRTestBody(
                    hostname: form.hostname,
                    port: port,
                    apiKey: form.apiKey,
                    useSsl: form.useSsl,
                    baseUrl: form.baseUrl.isEmpty ? nil : form.baseUrl
                )
            )
            apply(profiles: result.profiles, rootFolders: result.rootFolders, tags: result.tags)
            withAnimation(.snappy) {
                statusMessage = StatusMessage(
                    text: "Connection successful.",
                    iconName: "checkmark.circle.fill",
                    tint: .green
                )
            }
        } catch {
            withAnimation(.snappy) {
                statusMessage = StatusMessage(
                    text: error.localizedDescription,
                    iconName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }
        isTesting = false
    }

    private func loadServiceMetadata(for id: Int) async {
        isLoadingMetadata = true
        do {
            let response = try await apiClient.getDVRService(kind, id: id)
            apply(
                profiles: response.profiles,
                rootFolders: response.rootFolders,
                tags: response.tags
            )
        } catch {
            withAnimation(.snappy) {
                statusMessage = StatusMessage(
                    text: "Couldn't load profiles: \(error.localizedDescription)",
                    iconName: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }
        }
        isLoadingMetadata = false
    }

    private func apply(
        profiles: [SeerrQualityProfile]?,
        rootFolders: [SeerrRootFolder]?,
        tags: [SeerrDVRTag]?
    ) {
        if let profiles { self.profiles = profiles }
        if let rootFolders {
            self.rootFolders = rootFolders
            reconcileActiveDirectory(with: rootFolders)
        }
        if let tags { self.availableTags = tags }
    }

    private func reconcileActiveDirectory(with rootFolders: [SeerrRootFolder]) {
        guard !form.activeDirectory.isEmpty else { return }
        let selected = normalizedRootFolderPath(form.activeDirectory)
        guard let match = rootFolders.first(where: { normalizedRootFolderPath($0.path ?? "") == selected }),
              let path = match.path,
              path != form.activeDirectory else { return }
        form.activeDirectory = path
    }

    private func normalizedRootFolderPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func save() async {
        guard let payload = form.makePayload(kind: kind) else {
            errorAlert = ErrorAlertItem(title: "Missing Information", message: "Fill in the required fields before saving.")
            return
        }
        isSaving = true
        do {
            let saved: SeerrDVRSettings
            switch context {
            case .create:
                saved = try await apiClient.createDVRSettings(kind, body: payload)
            case .edit(let entry):
                saved = try await apiClient.updateDVRSettings(kind, id: entry.settings.id, body: payload)
            }
            onSaved(saved)
            dismiss()
        } catch {
            errorAlert = ErrorAlertItem(
                title: "Save Failed",
                message: error.localizedDescription
            )
        }
        isSaving = false
    }
}

// MARK: - Form State

private struct FormState {
    var name: String
    var hostname: String
    var portText: String
    var useSsl: Bool
    var apiKey: String
    var baseUrl: String
    var isDefault: Bool
    var is4k: Bool
    var activeProfileId: Int?
    var activeDirectory: String
    var minimumAvailability: String
    var tagIDs: Set<Int>
    var externalUrl: String
    var syncEnabled: Bool
    var automaticSearchEnabled: Bool
    var tagRequests: Bool

    // Sonarr-only fields preserved verbatim across edits
    var preservedAnimeProfileId: Int?
    var preservedAnimeDirectory: String?
    var preservedLanguageProfileId: Int?
    var preservedAnimeLanguageProfileId: Int?
    var preservedSeasonFolders: Bool?

    init(context: SeerrLinkedAppEditorContext) {
        switch context {
        case .create(let kind):
            self.name = ""
            self.hostname = ""
            self.portText = kind == .sonarr ? "8989" : "7878"
            self.useSsl = false
            self.apiKey = ""
            self.baseUrl = ""
            self.isDefault = false
            self.is4k = false
            self.activeProfileId = nil
            self.activeDirectory = ""
            self.minimumAvailability = SeerrRadarrAvailability.released.rawValue
            self.tagIDs = []
            self.externalUrl = ""
            self.syncEnabled = true
            self.automaticSearchEnabled = true
            self.tagRequests = false
            self.preservedAnimeProfileId = nil
            self.preservedAnimeDirectory = nil
            self.preservedLanguageProfileId = nil
            self.preservedAnimeLanguageProfileId = nil
            self.preservedSeasonFolders = kind == .sonarr ? true : nil
        case .edit(let entry):
            let s = entry.settings
            self.name = s.name
            self.hostname = s.hostname
            self.portText = String(s.port)
            self.useSsl = s.useSsl ?? false
            self.apiKey = s.apiKey
            self.baseUrl = s.baseUrl ?? ""
            self.isDefault = s.isDefault ?? false
            self.is4k = s.is4k ?? false
            self.activeProfileId = s.activeProfileId
            self.activeDirectory = s.activeDirectory
            self.minimumAvailability = s.minimumAvailability ?? SeerrRadarrAvailability.released.rawValue
            self.tagIDs = Set(s.tags ?? [])
            self.externalUrl = s.externalUrl ?? ""
            self.syncEnabled = s.syncEnabled ?? true
            // Overseerr stores `preventSearch`; Trawl exposes it as the inverse "Enable Automatic Search".
            self.automaticSearchEnabled = !(s.preventSearch ?? false)
            self.tagRequests = s.tagRequests ?? false
            self.preservedAnimeProfileId = s.activeAnimeProfileId
            self.preservedAnimeDirectory = s.activeAnimeDirectory
            self.preservedLanguageProfileId = s.activeLanguageProfileId
            self.preservedAnimeLanguageProfileId = s.activeAnimeLanguageProfileId
            self.preservedSeasonFolders = s.enableSeasonFolders
        }
    }

    var canTest: Bool {
        !hostname.isEmpty && Int(portText) != nil && !apiKey.isEmpty
    }

    var isValid: Bool {
        canTest
        && !name.isEmpty
        && activeProfileId != nil
        && !activeDirectory.isEmpty
    }

    func makePayload(kind: SeerrDVRKind) -> SeerrDVRSettings? {
        guard
            let port = Int(portText),
            let activeProfileId
        else {
            return nil
        }

        var payload = SeerrDVRSettings(
            id: 0,
            name: name,
            hostname: hostname,
            port: port,
            apiKey: apiKey,
            useSsl: useSsl,
            baseUrl: baseUrl.isEmpty ? nil : baseUrl,
            activeProfileId: activeProfileId,
            activeProfileName: nil,
            activeDirectory: activeDirectory,
            is4k: is4k,
            isDefault: isDefault,
            externalUrl: externalUrl.isEmpty ? nil : externalUrl,
            syncEnabled: syncEnabled,
            preventSearch: !automaticSearchEnabled,
            tagRequests: tagRequests,
            tags: Array(tagIDs).sorted()
        )

        if kind == .radarr {
            payload.minimumAvailability = minimumAvailability
        }

        if kind == .sonarr {
            payload.activeAnimeProfileId = preservedAnimeProfileId
            payload.activeAnimeDirectory = preservedAnimeDirectory
            payload.activeLanguageProfileId = preservedLanguageProfileId
            payload.activeAnimeLanguageProfileId = preservedAnimeLanguageProfileId
            payload.enableSeasonFolders = preservedSeasonFolders ?? true
        }

        return payload
    }
}

private struct StatusMessage {
    let text: String
    let iconName: String
    let tint: Color
}

private struct ParsedSeerrLinkedServerURL {
    let host: String
    let port: String
    let baseURL: String
    let isSSL: Bool

    init(profileURL: String, defaultPort: Int) throws {
        guard let components = URLComponents(string: profileURL),
              let scheme = components.scheme,
              let parsedHost = components.host else {
            throw ArrError.invalidURL
        }

        host = parsedHost
        isSSL = scheme == "https"
        let fallbackPort = isSSL ? 443 : defaultPort
        port = String(components.port ?? fallbackPort)
        baseURL = components.path.isEmpty ? "/" : components.path
    }
}

// MARK: - Tag Picker

private struct SeerrTagPickerView: View {
    let tags: [SeerrDVRTag]
    @Binding var selection: Set<Int>

    var body: some View {
        List {
            ForEach(tags) { tag in
                Button {
                    toggle(tag.id)
                } label: {
                    HStack {
                        Image(systemName: selection.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(tag.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(tag.displayLabel)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Tags")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}
