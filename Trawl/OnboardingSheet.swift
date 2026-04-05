import SwiftUI
import SwiftData

struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = OnboardingViewModel()
    let serverProfile: ServerProfile?
    let onComplete: () -> Void

    init(serverProfile: ServerProfile? = nil, onComplete: @escaping () -> Void) {
        self.serverProfile = serverProfile
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Connect Trawl to your qBittorrent Web UI.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Server address", text: $viewModel.hostURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)

                    TextField("Display Name (optional)", text: $viewModel.displayName)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Enter the full Web UI address, including the port if needed. Example: http://192.168.1.100:8080")
                }

                Section("Credentials") {
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)

                    SecureField("Password", text: $viewModel.password)
                        .textContentType(.password)
                }

                if viewModel.isValidating {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Checking connection…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = viewModel.validationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        Task {
                            let success = await viewModel.validateAndSave(modelContext: modelContext, editingServer: serverProfile)
                            if success {
                                dismiss()
                                onComplete()
                            }
                        }
                    }
                    .disabled(viewModel.hostURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty || viewModel.isValidating)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .task {
                guard let serverProfile else { return }
                let username = try? await KeychainHelper.shared.read(key: serverProfile.usernameKey)
                let password = try? await KeychainHelper.shared.read(key: serverProfile.passwordKey)
                viewModel.loadExistingServer(serverProfile, username: username ?? "", password: password ?? "")
            }
        }
    }
}
