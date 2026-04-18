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

    private var port: Int? {
        let trimmed = portString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 1 && value <= 65535 else {
            return nil
        }
        return value
    }

    private var isValidPort: Bool {
        port != nil
    }

    private var credentialMissing: Bool {
        switch authType {
        case .password:   password.isEmpty
        case .privateKey: privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canSave: Bool {
        !trimmedHost.isEmpty && !trimmedUsername.isEmpty && !credentialMissing && isValidPort
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
            } else if hasAttemptedSubmit && !isValidPort {
                fieldError("Port must be a number between 1 and 65535.")
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

        if let existing {
            let previousDisplayName = existing.displayName
            let previousHost = existing.host
            let previousPort = existing.port
            let previousUsername = existing.username
            let previousAuthTypeRaw = existing.authTypeRaw

            do {
                // Snapshot existing credentials; if this fails, abort the save
                let previousCredentials = try await snapshotCredentials(for: existing)

                do {
                    try await writeCredentials(for: existing)
                    existing.displayName = resolvedName
                    existing.host = trimmedHost
                    existing.port = port ?? 22
                    existing.username = trimmedUsername
                    existing.authTypeRaw = authType.rawValue
                    try modelContext.save()
                    dismiss()
                } catch {
                    // Restore credentials on failure
                    existing.displayName = previousDisplayName
                    existing.host = previousHost
                    existing.port = previousPort
                    existing.username = previousUsername
                    existing.authTypeRaw = previousAuthTypeRaw
                    modelContext.rollback()
                    await restoreCredentials(previousCredentials, for: existing)
                    saveError = error.localizedDescription
                }
            } catch {
                // Keychain snapshot failed; abort without changing anything
                saveError = "Could not read existing credentials: \(error.localizedDescription)"
            }
            return
        }

        let profile = SSHProfile(
                displayName: resolvedName,
                host: trimmedHost,
                port: port ?? 22,
                username: trimmedUsername,
                authType: authType
        )

        do {
            try await writeCredentials(for: profile)
            modelContext.insert(profile)
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            await clearCredentials(for: profile)
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

    private func snapshotCredentials(for profile: SSHProfile) async throws -> SSHCredentialSnapshot {
        let helper = KeychainHelper.shared
        let passwordValue = try await helper.read(key: profile.passwordKey)
        let privateKeyValue = try await helper.read(key: profile.privateKeyKey)
        let passphraseValue = try await helper.read(key: profile.passphraseKey)
        return SSHCredentialSnapshot(
            password: passwordValue,
            privateKey: privateKeyValue,
            passphrase: passphraseValue
        )
    }

    private func restoreCredentials(_ snapshot: SSHCredentialSnapshot, for profile: SSHProfile) async {
        let helper = KeychainHelper.shared
        do {
            if let password = snapshot.password {
                try await helper.save(key: profile.passwordKey, value: password)
            } else {
                try await helper.delete(key: profile.passwordKey)
            }

            if let privateKey = snapshot.privateKey {
                try await helper.save(key: profile.privateKeyKey, value: privateKey)
            } else {
                try await helper.delete(key: profile.privateKeyKey)
            }

            if let passphrase = snapshot.passphrase {
                try await helper.save(key: profile.passphraseKey, value: passphrase)
            } else {
                try await helper.delete(key: profile.passphraseKey)
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func clearCredentials(for profile: SSHProfile) async {
        let helper = KeychainHelper.shared
        try? await helper.delete(key: profile.passwordKey)
        try? await helper.delete(key: profile.privateKeyKey)
        try? await helper.delete(key: profile.passphraseKey)
    }

    // MARK: - Delete

    private func delete() async {
        guard let profile = existing else { return }

        // Disconnect if this profile is currently active
        if sshSessionStore.activeProfile?.id == profile.id {
            await sshSessionStore.disconnect()
        }

        do {
            // Remove from SwiftData context and save
            modelContext.delete(profile)
            try modelContext.save()

            // Only delete keychain items after successful save
            do {
                try await KeychainHelper.shared.delete(key: profile.passwordKey)
            } catch {
                // Log but don't fail - keychain item may not exist
            }

            do {
                try await KeychainHelper.shared.delete(key: profile.privateKeyKey)
            } catch {
                // Log but don't fail - keychain item may not exist
            }

            do {
                try await KeychainHelper.shared.delete(key: profile.passphraseKey)
            } catch {
                // Log but don't fail - keychain item may not exist
            }

            dismiss()
        } catch {
            // Roll back the context on failure
            modelContext.rollback()
            saveError = "Could not delete profile: \(error.localizedDescription)"
        }
    }
}

private struct SSHCredentialSnapshot: Sendable {
    let password: String?
    let privateKey: String?
    let passphrase: String?
}
