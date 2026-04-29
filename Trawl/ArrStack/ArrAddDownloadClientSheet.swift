import SwiftUI
import SwiftData

struct ArrDownloadClientEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var servers: [ServerProfile]

    let serviceType: ArrServiceType
    let existingClient: ArrDownloadClient?
    let onComplete: (ArrDownloadClient) -> Void

    @State private var name = ""
    @State private var category = ""
    @State private var host = ""
    @State private var port = "8080"
    @State private var username = ""
    @State private var password = ""
    @State private var useSsl = false
    @State private var selectedProfileID = Self.customProfileID
    @State private var isSaving = false
    @State private var isLoadingSchema = false
    @State private var schemaTemplate: ArrDownloadClient?
    @State private var errorMessage: String?
    @State private var hasLoadedInitialState = false

    private static let customProfileID = "custom"

    init(
        serviceType: ArrServiceType,
        existingClient: ArrDownloadClient? = nil,
        onComplete: @escaping (ArrDownloadClient) -> Void
    ) {
        self.serviceType = serviceType
        self.existingClient = existingClient
        self.onComplete = onComplete
    }

    private var isEditing: Bool { existingClient != nil }

    private var isQBittorrent: Bool {
        (existingClient?.implementation ?? "QBittorrent") == "QBittorrent"
    }

    private var qbitProfiles: [ServerProfile] {
        servers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var selectedProfile: ServerProfile? {
        qbitProfiles.first { $0.id.uuidString == selectedProfileID }
    }

    private var isCustom: Bool { selectedProfile == nil }

    private var categoryFieldName: String {
        serviceType == .sonarr ? "tvCategory" : "movieCategory"
    }

    private var canSave: Bool {
        !isSaving &&
        (!isLoadingSchema || isEditing) &&
        (isEditing || schemaTemplate != nil) &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    LabeledContent("Name") {
                        TextField("qBittorrent", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Category") {
                        TextField(serviceType == .sonarr ? "tv-sonarr" : "radarr", text: $category)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    if isQBittorrent {
                        Picker("qBittorrent Server", selection: $selectedProfileID) {
                            ForEach(qbitProfiles) { profile in
                                Text(profile.displayName).tag(profile.id.uuidString)
                            }
                            Text("Custom").tag(Self.customProfileID)
                        }
                    }

                    LabeledContent("Host") {
                        TextField("192.168.1.10", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .disabled(isQBittorrent && !isCustom)
                    }

                    LabeledContent("Port") {
                        TextField("8080", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .disabled(isQBittorrent && !isCustom)
                    }

                    LabeledContent("Username") {
                        TextField("admin", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Password") {
                        SecureField("password", text: $password)
                            .multilineTextAlignment(.trailing)
                    }

                    if !isQBittorrent || isCustom {
                        Toggle("Use SSL", isOn: $useSsl)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    if isQBittorrent && !isCustom {
                        Text("Host and port come from the selected qBittorrent profile. Credentials are prefilled from the saved login and can be edited before saving.")
                    } else if isQBittorrent {
                        Text("Choose Custom to manually enter connection details for a qBittorrent instance not already configured in Trawl.")
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
            .navigationTitle(isEditing ? "Edit \(existingClient?.name ?? "Download Client")" : "Add qBittorrent")
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
                await loadInitialState()
            }
            .onChange(of: selectedProfileID) { _, _ in
                guard hasLoadedInitialState else { return }
                Task { await applySelectedProfile() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Loading

    private func loadInitialState() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true

        if let existing = existingClient {
            populateFields(from: existing)
            if isQBittorrent {
                let existingHost = stringField("host", from: existing)
                let existingPort = intField("port", from: existing) ?? 8080
                selectedProfileID = matchedProfileID(host: existingHost, port: existingPort)
            }
        } else {
            await loadSchema()
            if let firstProfile = qbitProfiles.first {
                selectedProfileID = firstProfile.id.uuidString
            } else {
                selectedProfileID = Self.customProfileID
            }
            await applySelectedProfile()
        }
    }

    private func loadSchema() async {
        isLoadingSchema = true
        defer { isLoadingSchema = false }

        do {
            let schemas: [ArrDownloadClient]
            switch serviceType {
            case .sonarr:
                guard let client = serviceManager.sonarrClient else { throw ArrError.noServiceConfigured }
                schemas = try await client.getDownloadClientSchema()
            case .radarr:
                guard let client = serviceManager.radarrClient else { throw ArrError.noServiceConfigured }
                schemas = try await client.getDownloadClientSchema()
            case .prowlarr:
                schemaTemplate = nil
                return
            }
            schemaTemplate = schemas.first { $0.implementation == "QBittorrent" }
            if schemaTemplate == nil {
                errorMessage = "qBittorrent is not available as a download client type in \(serviceType.displayName)."
            }
        } catch {
            errorMessage = "Failed to load schema: \(error.localizedDescription)"
        }
    }

    private func populateFields(from client: ArrDownloadClient) {
        name = client.name ?? ""
        host = stringField("host", from: client)
        port = intField("port", from: client).map { String($0) } ?? "8080"
        useSsl = boolField("useSsl", from: client)
        username = stringField("username", from: client)
        password = stringField("password", from: client)
        category = stringField(categoryFieldName, from: client)
    }

    private func applySelectedProfile() async {
        errorMessage = nil
        guard let profile = selectedProfile else {
            host = ""
            port = "8080"
            useSsl = false
            username = ""
            password = ""
            return
        }

        let parsed = parseQBitURL(profile.hostURL)
        host = parsed.host
        port = String(parsed.port)
        useSsl = parsed.useSsl

        do {
            username = try await KeychainHelper.shared.read(key: profile.usernameKey) ?? ""
            password = try await KeychainHelper.shared.read(key: profile.passwordKey) ?? ""
        } catch {
            username = ""
            password = ""
        }

        if name.isEmpty {
            name = profile.displayName
        }
    }

    private func matchedProfileID(host: String, port: Int) -> String {
        let match = qbitProfiles.first { profile in
            let parsed = parseQBitURL(profile.hostURL)
            return parsed.host.lowercased() == host.lowercased() && parsed.port == port
        }
        return match?.id.uuidString ?? Self.customProfileID
    }

    private func parseQBitURL(_ urlString: String) -> (host: String, port: Int, useSsl: Bool) {
        guard let url = URL(string: urlString) else { return ("", 8080, false) }
        return (
            host: url.host ?? "",
            port: url.port ?? 8080,
            useSsl: url.scheme?.lowercased() == "https"
        )
    }

    // MARK: - Field extraction helpers

    private func stringField(_ fieldName: String, from client: ArrDownloadClient) -> String {
        guard let field = client.fields?.first(where: { $0.name == fieldName }),
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

    private func boolField(_ fieldName: String, from client: ArrDownloadClient) -> Bool {
        guard let field = client.fields?.first(where: { $0.name == fieldName }),
              let value = field.value,
              case .bool(let b) = value else { return false }
        return b
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            errorMessage = "Host is required."
            return
        }

        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portInt = Int(trimmedPort), portInt > 0 else {
            errorMessage = "Port must be a valid number."
            return
        }

        guard var payload = existingClient ?? schemaTemplate else {
            errorMessage = "Schema not loaded. Try dismissing and reopening."
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.name = trimmedName.isEmpty ? "qBittorrent" : trimmedName

        payload = payload.updatingField(named: "host", with: .string(trimmedHost))
        payload = payload.updatingField(named: "port", with: .int(portInt))
        payload = payload.updatingField(named: "useSsl", with: .bool(useSsl))

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        payload = payload.updatingField(named: "username", with: .string(trimmedUsername))

        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        payload = payload.updatingField(named: "password", with: .string(trimmedPassword))

        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        payload = payload.updatingField(named: categoryFieldName, with: .string(trimmedCategory))

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
            case .prowlarr:
                throw ArrError.noServiceConfigured
            }
            onComplete(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
