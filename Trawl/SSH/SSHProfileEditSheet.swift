import SwiftUI
import SwiftData

struct SSHProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SSHSessionStore.self) private var sshSessionStore

    let existing: SSHProfile?

    @State private var displayName  = ""
    @State private var host         = ""
    @State private var portString   = "22"
    @State private var username     = ""
    @State private var authType: SSHAuthType = .password

    @State private var password         = ""
    @State private var privateKeyPEM    = ""
    @State private var keyPassphrase    = ""

    @State private var isSaving = false
    @State private var showDeleteConfirm = false
    @State private var hasAttemptedSubmit = false
    @State private var saveError: String?

    private var isEditing: Bool { existing != nil }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var port: Int {
        Int(portString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
    }

    private var credentialMissing: Bool {
        switch authType {
        case .password:   password.isEmpty
        case .privateKey: privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canSave: Bool {
        !trimmedHost.isEmpty && !trimmedUsername.isEmpty && !credentialMissing
    }

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                authSection

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Remove Server", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Server" : "New SSH Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .confirmationDialog(
                "Remove \"\(existing?.displayName ?? "this server")\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) { Task { await delete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the server and its stored credentials.")
            }
            .alert(
                "Couldn't Save Server",
                isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                ),
                presenting: saveError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .task { await loadExisting() }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            TextField("Display Name (optional)", text: $displayName)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif

            TextField("Host or IP", text: $host)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .textContentType(.URL)
                #endif
                .autocorrectionDisabled()

            TextField("Port", text: $portString)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            TextField("Username", text: $username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                #endif
                .autocorrectionDisabled()
        } header: {
            Text("Server")
        } footer: {
            if hasAttemptedSubmit && trimmedHost.isEmpty {
                fieldError("Host is required.")
            } else if hasAttemptedSubmit && trimmedUsername.isEmpty {
                fieldError("Username is required.")
            } else {
                Text("Example: 192.168.1.1 or myserver.local")
            }
        }
    }

    private var authSection: some View {
        Section {
            Picker("Method", selection: $authType) {
                ForEach(SSHAuthType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            switch authType {
            case .password:
                SecureField("Password", text: $password)
                    #if os(iOS)
                    .textContentType(.password)
                    #endif

            case .privateKey:
                TextField(
                    "Paste PEM contents (e.g. ~/.ssh/id_ed25519)",
                    text: $privateKeyPEM,
                    axis: .vertical
                )
                .lineLimit(4...10)
                .font(.system(.footnote, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

                SecureField("Passphrase (optional)", text: $keyPassphrase)
                    #if os(iOS)
                    .textContentType(.password)
                    #endif
            }
        } header: {
            Text("Authentication")
        } footer: {
            if hasAttemptedSubmit && credentialMissing {
                fieldError(authType == .password
                    ? "Password is required."
                    : "Private key is required.")
            } else {
                Text("Credentials are stored securely in the system Keychain.")
            }
        }
    }

    private func fieldError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .font(.footnote)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView()
            } else {
                Button("Save") {
                    hasAttemptedSubmit = true
                    guard canSave else { return }
                    Task { await save() }
                }
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Load existing

    private func loadExisting() async {
        guard let profile = existing else { return }
        displayName = profile.displayName
        host        = profile.host
        portString  = String(profile.port)
        username    = profile.username
        authType    = profile.authType

        do {
            switch profile.authType {
            case .password:
                password = try await KeychainHelper.shared.read(key: profile.passwordKey) ?? ""
            case .privateKey:
                privateKeyPEM = try await KeychainHelper.shared.read(key: profile.privateKeyKey) ?? ""
                keyPassphrase = try await KeychainHelper.shared.read(key: profile.passphraseKey) ?? ""
            }
        } catch {
            saveError = "Could not load saved credentials from Keychain: \(error.localizedDescription)"
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let resolvedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? trimmedHost
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        let profile: SSHProfile
        if let existing {
            existing.displayName = resolvedName
            existing.host        = trimmedHost
            existing.port        = port
            existing.username    = trimmedUsername
            existing.authTypeRaw = authType.rawValue
            profile = existing
        } else {
            profile = SSHProfile(
                displayName: resolvedName,
                host: trimmedHost,
                port: port,
                username: trimmedUsername,
                authType: authType
            )
            modelContext.insert(profile)
        }

        do {
            try await writeCredentials(for: profile)
            try modelContext.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Persists only the credentials relevant to the current auth method and
    /// clears any that no longer apply. `KeychainHelper.save` is an upsert,
    /// so no pre-delete pass is needed for values being written.
    private func writeCredentials(for profile: SSHProfile) async throws {
        switch authType {
        case .password:
            if password.isEmpty {
                try await KeychainHelper.shared.delete(key: profile.passwordKey)
            } else {
                try await KeychainHelper.shared.save(key: profile.passwordKey, value: password)
            }
            // Clear key-auth leftovers when switching methods
            try await KeychainHelper.shared.delete(key: profile.privateKeyKey)
            try await KeychainHelper.shared.delete(key: profile.passphraseKey)

        case .privateKey:
            let trimmedKey = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedKey.isEmpty {
                try await KeychainHelper.shared.delete(key: profile.privateKeyKey)
            } else {
                try await KeychainHelper.shared.save(key: profile.privateKeyKey, value: trimmedKey)
            }

            if keyPassphrase.isEmpty {
                try await KeychainHelper.shared.delete(key: profile.passphraseKey)
            } else {
                try await KeychainHelper.shared.save(key: profile.passphraseKey, value: keyPassphrase)
            }
            // Clear password leftovers when switching methods
            try await KeychainHelper.shared.delete(key: profile.passwordKey)
        }
    }

    // MARK: - Delete

    private func delete() async {
        guard let profile = existing else { return }
        if sshSessionStore.activeProfile?.id == profile.id {
            sshSessionStore.disconnect()
        }
        try? await KeychainHelper.shared.delete(key: profile.passwordKey)
        try? await KeychainHelper.shared.delete(key: profile.privateKeyKey)
        try? await KeychainHelper.shared.delete(key: profile.passphraseKey)
        modelContext.delete(profile)
        try? modelContext.save()
        dismiss()
    }
}
