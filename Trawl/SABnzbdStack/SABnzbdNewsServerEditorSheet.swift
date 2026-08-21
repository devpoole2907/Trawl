import SwiftUI

/// Creates or edits one SABnzbd news server.
///
/// The password field is prefilled when editing, because `get_config` returns it
/// and submitting a blank one would wipe a working server's credentials. It stays
/// masked behind a reveal toggle rather than being shown outright.
struct SABnzbdNewsServerEditorSheet: View {
    /// `nil` creates a new server.
    let existingServer: SABnzbdNewsServer?
    let onSaved: () -> Void

    @Environment(SABnzbdServiceManager.self) private var serviceManager
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "563"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var connections: String = "8"
    @State private var ssl: Bool = true
    @State private var enabled: Bool = true
    @State private var optional: Bool = false
    @State private var retention: String = ""
    @State private var priority: String = ""
    @State private var notes: String = ""

    @State private var revealsPassword = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var errorMessage: String?

    private struct TestResult {
        let succeeded: Bool
        let message: String
    }

    private var isEditing: Bool { existingServer != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int(port) != nil
            && Int(connections) != nil
            && !isSaving
    }

    var body: some View {
        AppSheetShell(
            title: isEditing ? "Edit Server" : "Add Server",
            detents: [.large],
            dragIndicator: .visible
        ) {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Host", text: $host)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    HStack {
                        Group {
                            if revealsPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                        Button {
                            revealsPassword.toggle()
                        } label: {
                            Image(systemName: revealsPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Connection") {
                    TextField("Connections", text: $connections)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle("SSL", isOn: $ssl)
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Optional", isOn: $optional)
                }

                Section {
                    TextField("Retention (days)", text: $retention)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("Priority", text: $priority)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    TextField("Notes", text: $notes, axis: .vertical)
                } header: {
                    Text("Optional")
                } footer: {
                    Text("Leave retention and priority empty to keep SABnzbd's defaults. An optional server is skipped when it's unreachable rather than failing the download.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text("Test Server")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(!canSave)

                    if let testResult {
                        Label(testResult.message, systemImage: testResult.succeeded ? "checkmark.circle" : "xmark.circle")
                            .font(.footnote)
                            .foregroundStyle(testResult.succeeded ? .green : .red)
                    }
                } footer: {
                    Text("Opens a real connection with these settings. Nothing is saved.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isEditing ? "Save Changes" : "Add Server")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(!canSave)
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .tint(ServiceIdentity.sabnzbd.brandColor)
            .onAppear(perform: seedFields)
        }
    }

    private func seedFields() {
        guard let existingServer, name.isEmpty else { return }
        name = existingServer.name
        host = existingServer.host
        port = String(existingServer.port)
        username = existingServer.username ?? ""
        password = existingServer.password ?? ""
        connections = String(existingServer.connections)
        ssl = existingServer.ssl
        enabled = existingServer.enabled
        optional = existingServer.optional
        retention = existingServer.retention.map(String.init) ?? ""
        priority = existingServer.priority.map(String.init) ?? ""
        notes = existingServer.notes ?? ""
    }

    private func test() async {
        guard let portValue = Int(port), let connectionsValue = Int(connections) else { return }

        isTesting = true
        testResult = nil
        defer { isTesting = false }

        do {
            let outcome = try await serviceManager.testNewsServer(
                SABnzbdNewsServer(
                    name: name,
                    host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: portValue,
                    username: username.isEmpty ? nil : username,
                    password: password.isEmpty ? nil : password,
                    connections: connectionsValue,
                    ssl: ssl
                )
            )
            testResult = TestResult(succeeded: outcome.succeeded, message: outcome.message)
        } catch {
            testResult = TestResult(succeeded: false, message: error.localizedDescription)
        }
    }

    private func save() async {
        guard let portValue = Int(port), let connectionsValue = Int(connections) else { return }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = SABnzbdNewsServer(
            name: trimmedName,
            displayName: existingServer?.displayName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portValue,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            connections: connectionsValue,
            ssl: ssl,
            sslVerify: existingServer?.sslVerify,
            enabled: enabled,
            optional: optional,
            retention: Int(retention),
            timeout: existingServer?.timeout,
            priority: Int(priority),
            notes: notes.isEmpty ? nil : notes
        )

        do {
            try await serviceManager.saveNewsServer(server, originalName: existingServer?.name)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
