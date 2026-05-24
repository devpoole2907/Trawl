import SwiftUI
import SwiftData

struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = OnboardingViewModel()
    @State private var saveTask: Task<Void, Never>?
    let serverProfile: ServerProfile?
    let onComplete: () -> Void
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    init(serverProfile: ServerProfile? = nil, onComplete: @escaping () -> Void) {
        self.serverProfile = serverProfile
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            onboardingForm
            .modalFormStyle(
                title: serverProfile == nil ? "Add Server" : "Edit Server",
                primaryTitle: "Connect",
                isPrimaryDisabled: viewModel.isValidating,
                isSaving: viewModel.isValidating
            ) {
                saveTask?.cancel()
                saveTask = Task {
                    let success = await viewModel.validateAndSave(modelContext: modelContext, editingServer: serverProfile)
                    if success && !Task.isCancelled {
                        dismiss()
                        onComplete()
                    }
                }
            }
            .onDisappear {
                saveTask?.cancel()
            }
            #if os(macOS)
            .frame(minWidth: 560, idealWidth: 620, minHeight: 480)
            #endif
            .task {
                #if DEBUG
                guard !skipsAutomaticLoading else { return }
                #endif
                guard let serverProfile else { return }
                await viewModel.loadExistingServer(serverProfile)
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
                ServerURLField(url: $viewModel.hostURL)

                TextField("Display Name (optional)", text: $viewModel.displayName)

                AllowUntrustedTLSToggle(allow: $viewModel.allowsUntrustedTLS)
            } header: {
                Text("Server")
            } footer: {
                if viewModel.hasAttemptedSubmit && viewModel.hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Server address is required.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else {
                    Text("Enter the full Web UI address, including port if needed. Example: http://192.168.1.100:8080. Enable self-signed certificates only for servers you control.")
                }
            }

            CredentialsSection(
                username: $viewModel.username,
                password: $viewModel.password,
                footerMessage: (viewModel.hasAttemptedSubmit && (viewModel.username.isEmpty || viewModel.password.isEmpty)) ? "Username and password are required." : nil
            )

            ValidationErrorSection(error: viewModel.validationError)

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

#if DEBUG
extension OnboardingSheet {
    init(
        previewViewModel: OnboardingViewModel,
        serverProfile: ServerProfile? = nil
    ) {
        self.init(serverProfile: serverProfile, onComplete: {})
        self._viewModel = State(initialValue: previewViewModel)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Initial") {
    PreviewHost(profiles: .empty) {
        OnboardingSheet(previewViewModel: OnboardingViewModel())
    }
}

#Preview("Mid Input") {
    PreviewHost(profiles: .empty) {
        OnboardingSheet(previewViewModel: OnboardingViewModel(
            previewHostURL: "http://192.168.1.50:8080",
            previewUsername: "admin",
            previewPassword: "password",
            previewDisplayName: "Home qBittorrent"
        ))
    }
}

#Preview("Authenticating") {
    PreviewHost(profiles: .empty) {
        OnboardingSheet(previewViewModel: OnboardingViewModel(
            previewHostURL: "http://192.168.1.50:8080",
            previewUsername: "admin",
            previewPassword: "password",
            isValidating: true
        ))
    }
}

#Preview("Connection Error") {
    PreviewHost(profiles: .empty) {
        OnboardingSheet(previewViewModel: OnboardingViewModel(
            previewHostURL: "http://nope.invalid:8080",
            previewUsername: "admin",
            previewPassword: "password",
            validationError: "Connection failed: The server could not be reached.",
            hasAttemptedSubmit: true
        ))
    }
}

#Preview("Edit Server") {
    let server = ServerProfile.preview(displayName: "Seedbox", hostURL: "https://seedbox.example.com")
    PreviewHost(profiles: .qBittorrentOnly) {
        OnboardingSheet(previewViewModel: OnboardingViewModel(
            previewHostURL: server.hostURL,
            previewUsername: "admin",
            previewPassword: "password",
            previewDisplayName: server.displayName,
            allowsUntrustedTLS: false
        ), serverProfile: server)
    }
}
#endif
