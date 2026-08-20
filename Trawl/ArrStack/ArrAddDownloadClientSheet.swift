import SwiftUI
import SwiftData

struct ArrDownloadClientEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var servers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]

    let serviceType: ArrServiceType
    let existingClient: ArrDownloadClient?
    let onComplete: (ArrDownloadClient) -> Void

    @State private var name = ""
    @State private var category = ""
    /// Every non-category schema field, keyed by field name. The sheet is schema-driven:
    /// Sonarr/Radarr decide which connection fields exist for the chosen implementation.
    @State private var fieldValues: [String: ArrIndexerFieldValue] = [:]
    @State private var schemas: [ArrDownloadClient] = []
    @State private var selectedImplementation = ""
    @State private var selectedProfileID = Self.customProfileID
    @State private var showAdvanced = false
    @State private var isSaving = false
    @State private var isLoadingSchema = false
    @State private var errorMessage: String?
    @State private var hasLoadedInitialState = false

    private static let customProfileID = "custom"

    init(
        serviceType: ArrServiceType,
        existingClient: ArrDownloadClient? = nil,
        initialImplementation: String? = nil,
        onComplete: @escaping (ArrDownloadClient) -> Void
    ) {
        self.serviceType = serviceType
        self.existingClient = existingClient
        self.onComplete = onComplete
        // The add menu already asked which client the user wants, so open on it.
        // loadSchema() keeps this selection as long as the Arr actually offers it.
        _selectedImplementation = State(initialValue: initialImplementation ?? "")
    }

    #if DEBUG
    init(
        serviceType: ArrServiceType,
        previewClient: ArrDownloadClient? = nil,
        previewSchema: ArrDownloadClient? = .preview,
        previewSchemas: [ArrDownloadClient]? = nil,
        errorMessage: String? = nil
    ) {
        self.serviceType = serviceType
        self.existingClient = previewClient
        self.onComplete = { _ in }

        let list = previewSchemas ?? [previewSchema].compactMap { $0 }
        let seed = previewClient ?? previewSchema ?? list.first

        _schemas = State(initialValue: list)
        _selectedImplementation = State(initialValue: seed?.implementation ?? "")
        _name = State(initialValue: seed?.name ?? seed?.implementationName ?? "")
        _category = State(initialValue: serviceType == .sonarr ? "tv-sonarr" : "radarr")
        _fieldValues = State(initialValue: Self.defaultValues(from: seed))
        _errorMessage = State(initialValue: errorMessage)
        _hasLoadedInitialState = State(initialValue: true)
    }
    #endif

    private var isEditing: Bool { existingClient != nil }

    /// The client whose field metadata drives the form: the client being edited, or the
    /// schema for the implementation the user picked.
    private var activeTemplate: ArrDownloadClient? {
        if let existingClient { return existingClient }
        return schemas.first { $0.implementation == selectedImplementation }
    }

    private var activeImplementation: String {
        existingClient?.implementation ?? selectedImplementation
    }

    private var implementationDisplayName: String {
        activeTemplate?.implementationName ?? activeImplementation
    }

    // MARK: - Profile prefill

    /// Trawl only knows credentials for the clients it integrates with itself.
    private enum PrefillKind {
        case qbittorrent
        case sabnzbd
        case none
    }

    private var prefillKind: PrefillKind {
        switch activeImplementation.lowercased() {
        case "qbittorrent": .qbittorrent
        case "sabnzbd": .sabnzbd
        default: .none
        }
    }

    private var profileOptions: [(id: String, title: String)] {
        switch prefillKind {
        case .qbittorrent:
            servers
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map { (id: $0.id.uuidString, title: $0.displayName) }
        case .sabnzbd:
            sabnzbdProfiles
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map { (id: $0.id.uuidString, title: $0.displayName) }
        case .none:
            []
        }
    }

    private var hasProfilePicker: Bool { !profileOptions.isEmpty }

    private var isCustom: Bool {
        selectedProfileID == Self.customProfileID || !hasProfilePicker
    }

    private var categoryFieldName: String {
        serviceType == .sonarr ? "tvCategory" : "movieCategory"
    }

    private var supportsCategory: Bool {
        activeTemplate?.fields?.contains { $0.name == categoryFieldName } ?? false
    }

    /// Fields the profile picker owns while a saved profile is selected.
    private static let profileOwnedFields: Set<String> = ["host", "port", "urlBase", "useSsl"]

    private var visibleFields: [ArrIndexerField] {
        (activeTemplate?.fields ?? []).filter { field in
            guard let fieldName = field.name, fieldName != categoryFieldName else { return false }
            guard field.hidden != "hidden", field.type != "info" else { return false }
            if !showAdvanced && field.advanced == true { return false }
            return true
        }
    }

    private var infoFields: [ArrIndexerField] {
        (activeTemplate?.fields ?? []).filter { $0.type == "info" && $0.hidden != "hidden" }
    }

    private var hasAdvancedFields: Bool {
        (activeTemplate?.fields ?? []).contains {
            $0.advanced == true && $0.hidden != "hidden" && $0.type != "info" && $0.name != categoryFieldName
        }
    }

    private var canSave: Bool {
        !isSaving &&
        (!isLoadingSchema || isEditing) &&
        activeTemplate != nil &&
        !stringValue(for: "host").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sheetTitle: String {
        if isEditing { return "Edit \(existingClient?.name ?? "Download Client")" }
        let implementation = implementationDisplayName
        return implementation.isEmpty ? "Add Download Client" : "Add \(implementation)"
    }

    var body: some View {
        AppSheetShell(
            title: sheetTitle,
            confirmTitle: isEditing ? "Update" : "Save",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { Task { await save() } },
            detents: [.medium, .large]
        ) {
            Form {
                if !isEditing {
                    implementationSection
                }

                Section("General") {
                    LabeledContent("Name") {
                        TextField(implementationDisplayName.isEmpty ? "Name" : implementationDisplayName, text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    if supportsCategory {
                        LabeledContent("Category") {
                            TextField(serviceType == .sonarr ? "tv-sonarr" : "radarr", text: $category)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                if !infoFields.isEmpty {
                    Section {
                        ForEach(Array(infoFields.enumerated()), id: \.offset) { _, field in
                            if let text = field.value?.displayString {
                                Text(text)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if activeTemplate != nil {
                    connectionSection
                }

                if hasAdvancedFields {
                    Section {
                        Toggle("Show Advanced Settings", isOn: $showAdvanced)
                    }
                }

                if isLoadingSchema {
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text("Loading schema…")
                                .foregroundStyle(.secondary)
                        }
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
                await loadInitialState()
            }
            .onChange(of: selectedImplementation) { _, _ in
                guard hasLoadedInitialState, !isEditing else { return }
                Task { await applySelectedImplementation() }
            }
            .onChange(of: selectedProfileID) { _, _ in
                guard hasLoadedInitialState else { return }
                Task { await applySelectedProfile() }
            }
        }
    }

    // MARK: - Sections

    /// Sonarr/Radarr return one schema per supported client, each carrying its protocol,
    /// so the picker is sectioned the same way the download client list is.
    @ViewBuilder
    private var implementationSection: some View {
        Section {
            Picker("Client Type", selection: $selectedImplementation) {
                ForEach(ArrIndexerProtocol.allSchemaSections, id: \.self) { section in
                    let matches = schemas.filter { schemaSection(for: $0) == section }
                    if !matches.isEmpty {
                        Section(section.sectionTitle) {
                            ForEach(matches, id: \.schemaPickerID) { schema in
                                Text(schema.implementationName ?? schema.implementation ?? "Unknown")
                                    .tag(schema.implementation ?? "")
                            }
                        }
                    }
                }
            }
            .disabled(schemas.isEmpty)
        } header: {
            Text("Client")
        } footer: {
            if schemas.isEmpty && !isLoadingSchema {
                Text("\(serviceType.displayName) returned no download client types.")
            } else {
                Text("Torrent and Usenet clients offered by \(serviceType.displayName).")
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            if hasProfilePicker {
                Picker(prefillKind == .sabnzbd ? "SABnzbd Server" : "qBittorrent Server", selection: $selectedProfileID) {
                    ForEach(profileOptions, id: \.id) { option in
                        Text(option.title).tag(option.id)
                    }
                    Text("Custom").tag(Self.customProfileID)
                }
            }

            ForEach(Array(visibleFields.enumerated()), id: \.offset) { _, field in
                fieldRow(for: field)
            }
        } header: {
            Text("Connection")
        } footer: {
            if hasProfilePicker && !isCustom {
                Text("Host and port come from the selected \(implementationDisplayName) profile. Credentials are prefilled from the saved login and can be edited before saving.")
            } else if hasProfilePicker {
                Text("Choose Custom to manually enter connection details for a \(implementationDisplayName) instance not already configured in Trawl.")
            }
        }
    }

    @ViewBuilder
    private func fieldRow(for field: ArrIndexerField) -> some View {
        let key = field.name ?? ""
        let label = field.label ?? key
        let isLocked = hasProfilePicker && !isCustom && Self.profileOwnedFields.contains(key)

        switch field.type {
        case "checkbox":
            Toggle(label, isOn: boolBinding(for: key))
                .disabled(isLocked)
        case "password":
            LabeledContent(label) {
                SecureField(label, text: stringBinding(for: key))
                    .multilineTextAlignment(.trailing)
                    .disabled(isLocked)
            }
        case "number":
            LabeledContent(label) {
                TextField(label, text: numberStringBinding(for: key))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .disabled(isLocked)
            }
        case "select":
            if let options = field.selectOptions, !options.isEmpty {
                Picker(label, selection: intBinding(for: key)) {
                    ForEach(options) { option in
                        Text(option.name ?? "\(option.value ?? 0)").tag(option.value ?? 0)
                    }
                }
                .disabled(isLocked)
            } else {
                LabeledContent(label) {
                    TextField(label, text: stringBinding(for: key))
                        .multilineTextAlignment(.trailing)
                        .disabled(isLocked)
                }
            }
        default:
            LabeledContent(label) {
                TextField(field.placeholder ?? label, text: portAwareBinding(for: key))
                    #if os(iOS)
                    .keyboardType(key == "port" ? .numberPad : .URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .disabled(isLocked)
            }
        }
    }

    // MARK: - Bindings

    private func stringValue(for key: String) -> String {
        switch fieldValues[key] {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        default: ""
        }
    }

    private func stringBinding(for key: String) -> Binding<String> {
        Binding(
            get: { stringValue(for: key) },
            set: { fieldValues[key] = .string($0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .bool(let value) = fieldValues[key] { return value }
                return false
            },
            set: { fieldValues[key] = .bool($0) }
        )
    }

    private func intBinding(for key: String) -> Binding<Int> {
        Binding(
            get: {
                if case .int(let value) = fieldValues[key] { return value }
                return 0
            },
            set: { fieldValues[key] = .int($0) }
        )
    }

    private func numberStringBinding(for key: String) -> Binding<String> {
        Binding(
            get: {
                switch fieldValues[key] {
                case .int(let value): value == 0 ? "" : String(value)
                case .double(let value): String(value)
                case .string(let value): value
                default: ""
                }
            },
            set: { newValue in
                if let intValue = Int(newValue) {
                    fieldValues[key] = .int(intValue)
                } else if newValue.isEmpty {
                    fieldValues[key] = .int(0)
                }
            }
        )
    }

    /// Sonarr/Radarr type `port` as a plain textbox but the value must round-trip as a
    /// number, so it gets the numeric binding regardless of the declared type.
    private func portAwareBinding(for key: String) -> Binding<String> {
        key == "port" ? numberStringBinding(for: key) : stringBinding(for: key)
    }

    // MARK: - Loading

    private func loadInitialState() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true

        if let existing = existingClient {
            name = existing.name ?? ""
            category = stringField(categoryFieldName, from: existing)
            fieldValues = Self.defaultValues(from: existing)
            selectedProfileID = matchedProfileID()
        } else {
            await loadSchema()
            await applySelectedImplementation()
        }
    }

    private func loadSchema() async {
        isLoadingSchema = true
        defer { isLoadingSchema = false }

        do {
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                schemas = try await client.getDownloadClientSchema()
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                schemas = try await client.getDownloadClientSchema()
            case .prowlarr, .bazarr:
                schemas = []
                return
            }

            schemas.sort { lhs, rhs in
                (lhs.implementationName ?? "").localizedCaseInsensitiveCompare(rhs.implementationName ?? "") == .orderedAscending
            }

            // qBittorrent stays the default when it's offered, so the existing add flow is
            // unchanged for torrent users; otherwise fall back to the first schema returned.
            if selectedImplementation.isEmpty || !schemas.contains(where: { $0.implementation == selectedImplementation }) {
                let preferred = schemas.first { $0.implementation == "QBittorrent" } ?? schemas.first
                selectedImplementation = preferred?.implementation ?? ""
            }

            if schemas.isEmpty {
                errorMessage = "\(serviceType.displayName) did not return any download client types."
            }
        } catch {
            errorMessage = "Failed to load schema: \(error.localizedDescription)"
        }
    }

    /// Reseeds the form from the newly selected schema, then applies profile prefill.
    private func applySelectedImplementation() async {
        guard !isEditing else { return }
        errorMessage = nil

        let template = activeTemplate
        fieldValues = Self.defaultValues(from: template)
        category = stringField(categoryFieldName, from: template)
        name = template?.implementationName ?? template?.name ?? ""

        selectedProfileID = profileOptions.first?.id ?? Self.customProfileID
        await applySelectedProfile()
    }

    private func applySelectedProfile() async {
        errorMessage = nil
        guard !isCustom else { return }

        switch prefillKind {
        case .qbittorrent:
            guard let profile = servers.first(where: { $0.id.uuidString == selectedProfileID }) else { return }
            applyConnection(parseServerURL(profile.hostURL))
            do {
                fieldValues["username"] = .string(try await KeychainHelper.shared.read(key: profile.usernameKey) ?? "")
                fieldValues["password"] = .string(try await KeychainHelper.shared.read(key: profile.passwordKey) ?? "")
            } catch {
                fieldValues["username"] = .string("")
                fieldValues["password"] = .string("")
            }
            if name.isEmpty { name = profile.displayName }

        case .sabnzbd:
            guard let profile = sabnzbdProfiles.first(where: { $0.id.uuidString == selectedProfileID }) else { return }
            applyConnection(parseServerURL(profile.hostURL))
            do {
                fieldValues["apiKey"] = .string(try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey) ?? "")
            } catch {
                fieldValues["apiKey"] = .string("")
            }
            if name.isEmpty { name = profile.displayName }

        case .none:
            break
        }
    }

    private func applyConnection(_ parsed: (host: String, port: Int, useSsl: Bool, urlBase: String)) {
        fieldValues["host"] = .string(parsed.host)
        fieldValues["port"] = .int(parsed.port)
        fieldValues["useSsl"] = .bool(parsed.useSsl)
        fieldValues["urlBase"] = .string(parsed.urlBase)
    }

    /// Matches the client being edited back to a Trawl profile so the picker opens on the
    /// right row instead of always saying "Custom".
    private func matchedProfileID() -> String {
        guard let existing = existingClient else { return Self.customProfileID }
        let host = stringField("host", from: existing).lowercased()
        let port = intField("port", from: existing) ?? 0

        let hostURLs: [(id: String, hostURL: String)]
        switch prefillKind {
        case .qbittorrent: hostURLs = servers.map { (id: $0.id.uuidString, hostURL: $0.hostURL) }
        case .sabnzbd: hostURLs = sabnzbdProfiles.map { (id: $0.id.uuidString, hostURL: $0.hostURL) }
        case .none: return Self.customProfileID
        }

        let match = hostURLs.first { candidate in
            let parsed = parseServerURL(candidate.hostURL)
            return parsed.host.lowercased() == host && parsed.port == port
        }
        return match?.id ?? Self.customProfileID
    }

    private func parseServerURL(_ urlString: String) -> (host: String, port: Int, useSsl: Bool, urlBase: String) {
        guard let url = URL(string: urlString) else { return ("", 8080, false, "") }
        let scheme = url.scheme?.lowercased()
        let usesSsl = scheme == "https"
        let defaultPort = usesSsl ? 443 : (scheme == "http" ? 80 : 8080)
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return (
            host: url.host ?? "",
            port: url.port ?? defaultPort,
            useSsl: usesSsl,
            urlBase: path.isEmpty ? "" : "/\(path)"
        )
    }

    // MARK: - Field extraction helpers

    private static func defaultValues(from client: ArrDownloadClient?) -> [String: ArrIndexerFieldValue] {
        var values: [String: ArrIndexerFieldValue] = [:]
        for field in client?.fields ?? [] {
            guard let fieldName = field.name, let value = field.value else { continue }
            values[fieldName] = value
        }
        return values
    }

    private func schemaSection(for client: ArrDownloadClient) -> ArrIndexerProtocol {
        client.protocol ?? .unknown
    }

    private func stringField(_ fieldName: String, from client: ArrDownloadClient?) -> String {
        guard let field = client?.fields?.first(where: { $0.name == fieldName }),
              let value = field.value else { return "" }
        if case .string(let s) = value { return s }
        return value.displayString ?? ""
    }

    private func intField(_ fieldName: String, from client: ArrDownloadClient) -> Int? {
        guard let field = client.fields?.first(where: { $0.name == fieldName }),
              let value = field.value else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    private func normalizedURLBase(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "" : "/\(trimmed)"
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        let trimmedHost = stringValue(for: "host").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            errorMessage = "Host is required."
            return
        }

        guard var payload = existingClient ?? activeTemplate else {
            errorMessage = "Schema not loaded. Try dismissing and reopening."
            return
        }

        if payload.fields?.contains(where: { $0.name == "port" }) == true {
            guard case .int(let portInt) = fieldValues["port"] ?? .null, portInt > 0 else {
                errorMessage = "Port must be a valid number."
                return
            }
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.name = trimmedName.isEmpty ? implementationDisplayName : trimmedName

        for field in payload.fields ?? [] {
            guard let fieldName = field.name else { continue }

            if fieldName == categoryFieldName {
                payload = payload.updatingField(
                    named: fieldName,
                    with: .string(category.trimmingCharacters(in: .whitespacesAndNewlines))
                )
                continue
            }

            guard var value = fieldValues[fieldName] else { continue }
            if case .string(let raw) = value {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                value = .string(fieldName == "urlBase" ? normalizedURLBase(trimmed) : trimmed)
            }
            payload = payload.updatingField(named: fieldName, with: value)
        }

        if !isEditing {
            payload.enable = true
        }

        do {
            let saved: ArrDownloadClient
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                saved = isEditing
                    ? try await client.updateDownloadClient(payload)
                    : try await client.createDownloadClient(payload)
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                saved = isEditing
                    ? try await client.updateDownloadClient(payload)
                    : try await client.createDownloadClient(payload)
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

private extension ArrIndexerProtocol {
    /// Section order for the client type picker, mirroring the download client list.
    static var allSchemaSections: [ArrIndexerProtocol] { [.torrent, .usenet, .unknown] }
}

private extension ArrDownloadClient {
    /// Schema rows share `id == 0`, so the picker needs a stable identity of its own.
    var schemaPickerID: String { implementation ?? implementationName ?? "unknown-\(id)" }
}

#if DEBUG
/// A SABnzbd schema shaped like the one Sonarr/Radarr return: API key instead of
/// username/password, and no SSL toggle outside the advanced set.
private let sabnzbdPreviewSchema: ArrDownloadClient = {
    let json: [String: Any] = [
        "id": 0,
        "name": "",
        "implementationName": "SABnzbd",
        "implementation": "Sabnzbd",
        "configContract": "SabnzbdSettings",
        "enable": true,
        "supportsCategories": true,
        "protocol": "usenet",
        "fields": [
            ["name": "host", "label": "Host", "value": "localhost", "type": "textbox"],
            ["name": "port", "label": "Port", "value": 8080, "type": "textbox"],
            ["name": "urlBase", "label": "URL Base", "value": "", "type": "textbox", "advanced": true],
            ["name": "apiKey", "label": "API Key", "value": "", "type": "password"],
            ["name": "username", "label": "Username", "value": "", "type": "textbox"],
            ["name": "useSsl", "label": "Use SSL", "value": false, "type": "checkbox"],
            ["name": "tvCategory", "label": "Category", "value": "tv-sonarr", "type": "textbox"],
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(ArrDownloadClient.self, from: data)
}()

#Preview("Download Client Editor - Add") {
    PreviewHost(profiles: .allServices, arr: .preview(.sonarrOnly)) {
        ArrDownloadClientEditorSheet(serviceType: .sonarr, previewSchema: .preview)
    }
}

#Preview("Download Client Editor - Add SABnzbd") {
    PreviewHost(profiles: .allServices, arr: .preview(.sonarrOnly)) {
        ArrDownloadClientEditorSheet(
            serviceType: .sonarr,
            previewSchema: sabnzbdPreviewSchema,
            previewSchemas: [.preview, sabnzbdPreviewSchema]
        )
    }
}

#Preview("Download Client Editor - Edit") {
    PreviewHost(profiles: .allServices, arr: .preview(.sonarrOnly)) {
        ArrDownloadClientEditorSheet(serviceType: .sonarr, previewClient: .preview, previewSchema: .preview)
    }
}

#Preview("Download Client Editor - Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.sonarrOnly)) {
        ArrDownloadClientEditorSheet(
            serviceType: .sonarr,
            previewSchema: .preview,
            errorMessage: "Sonarr did not return any download client types."
        )
    }
}
#endif
