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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty else { return false }
        guard let portNum = Int(port), (1...65535).contains(portNum) else { return false }
        guard let connNum = Int(connections), connNum > 0 else { return false }
        return !isSaving
    }

    private var canTest: Bool {
        canSave && !isTesting
    }

    var body: some View {
        AppSheetShell(
            title: isEditing ? "Edit Server" : "Add Server",
            confirmTitle: isEditing ? "Save" : "Add",
            isConfirmDisabled: !canSave,
            isConfirmLoading: isSaving,
            onConfirm: { Task { await save() } },
            minContentHeight: 520,
            detents: [.large],
            dragIndicator: .visible
        ) {
            Form {
                Section("Server") {
                    LabeledContent("Name") {
                        TextField("Name", text: $name, prompt: Text("Server Name"))
                            .labeledContentField()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }

                    LabeledContent("Host") {
                        TextField("Host", text: $host, prompt: Text("news.example.com"))
                            .labeledContentField()
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }

                    LabeledContent("Port") {
                        TextField("Port", text: $port, prompt: Text("563"))
                            .labeledContentField()
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                }

                Section("Authentication") {
                    LabeledContent("Username") {
                        TextField("Username", text: $username, prompt: Text("Optional"))
                            .labeledContentField()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }

                    LabeledContent("Password") {
                        HStack(spacing: 8) {
                            Group {
                                if revealsPassword {
                                    TextField("Password", text: $password, prompt: Text("Optional"))
                                } else {
                                    SecureField("Password", text: $password, prompt: Text("Optional"))
                                }
                            }
                            .labeledContentField()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                            Button {
                                revealsPassword.toggle()
                            } label: {
                                Image(systemName: revealsPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(revealsPassword ? "Hide password" : "Show password")
                        }
                    }
                }

                Section {
                    LabeledContent("Connections") {
                        TextField("Connections", text: $connections, prompt: Text("8"))
                            .labeledContentField()
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }

                    Toggle("SSL / TLS", isOn: $ssl)
                    Toggle("Enabled", isOn: $enabled)
                    Toggle("Optional Server", isOn: $optional)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("An optional server is skipped when unreachable rather than failing the download.")
                }

                Section {
                    LabeledContent("Retention (days)") {
                        TextField("Retention", text: $retention, prompt: Text("Default"))
                            .labeledContentField()
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }

                    LabeledContent("Priority") {
                        TextField("Priority", text: $priority, prompt: Text("0"))
                            .labeledContentField()
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Leave empty to keep SABnzbd defaults. Priority 0 is highest; higher numbers are fallback servers.")
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, prompt: Text("Optional notes"), axis: .vertical)
                        .lineLimit(2...5)
                        #if os(macOS)
                        .labelsHidden()
                        #endif
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
                            Label(
                                isTesting ? "Testing Connection…" : "Test Connection",
                                systemImage: isTesting ? "arrow.triangle.2.circlepath" : "network"
                            )
                        }
                    }
                    .disabled(!canTest)

                    if let testResult {
                        Label(
                            testResult.message,
                            systemImage: testResult.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(testResult.succeeded ? .green : .red)
                    }
                } header: {
                    Text("Connection Test")
                } footer: {
                    Text("Opens a real connection with these settings. Nothing is saved.")
                }

                ValidationErrorSection(error: errorMessage)
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
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                    port: portValue,
                    username: username.isEmpty ? nil : username,
                    password: password.isEmpty ? nil : password,
                    connections: connectionsValue,
                    ssl: ssl
                )
            )
            let message = outcome.message.isEmpty
                ? (outcome.succeeded ? "Connection Succeeded" : "Connection Failed")
                : outcome.message
            testResult = TestResult(succeeded: outcome.succeeded, message: message)
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
