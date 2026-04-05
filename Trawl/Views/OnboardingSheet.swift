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
            onboardingForm
            .navigationTitle(serverProfile == nil ? "Add Server" : "Edit Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
                    .disabled(viewModel.isValidating)
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #if os(macOS)
            .frame(minWidth: 560, idealWidth: 620, minHeight: 480)
            #endif
            .task {
                guard let serverProfile else { return }
                let username = try? await KeychainHelper.shared.read(key: serverProfile.usernameKey)
                let password = try? await KeychainHelper.shared.read(key: serverProfile.passwordKey)
                viewModel.loadExistingServer(serverProfile, username: username ?? "", password: password ?? "")
            }
        }
    }

    private var onboardingForm: some View {
        Form {
            Section {
                Text("Connect Trawl to your qBittorrent Web UI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Server address", text: $viewModel.hostURL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .textContentType(.URL)
                    #endif
                    .autocorrectionDisabled()

                TextField("Display Name (optional)", text: $viewModel.displayName)
            } header: {
                Text("Server")
            } footer: {
                if viewModel.hasAttemptedSubmit && viewModel.hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Server address is required.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else {
                    Text("Enter the full Web UI address, including port if needed. Example: http://192.168.1.100:8080")
                }
            }

            Section {
                TextField("Username", text: $viewModel.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    #endif
                    .autocorrectionDisabled()

                SecureField("Password", text: $viewModel.password)
                    #if os(iOS)
                    .textContentType(.password)
                    #endif
            } header: {
                Text("Credentials")
            } footer: {
                if viewModel.hasAttemptedSubmit && (viewModel.username.isEmpty || viewModel.password.isEmpty) {
                    Label("Username and password are required.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            if let error = viewModel.validationError {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)

                        Text(error)
                            .foregroundStyle(.primary)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
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
        }
        #if os(macOS)
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: 680, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }
}
