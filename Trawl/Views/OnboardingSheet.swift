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
        AppSheetShell(
            title: serverProfile == nil ? "Add qBittorrent" : "Edit qBittorrent",
            confirmTitle: serverProfile == nil ? "Connect" : "Save Connection",
            // Deliberately not gated on a complete form. Pressing it with a field
            // empty is how this sheet says which one - `hasAttemptedSubmit` turns
            // the relevant footer red - and a disabled button explains nothing.
            isConfirmDisabled: viewModel.isValidating,
            isConfirmLoading: viewModel.isValidating,
            onConfirm: connect,
            confirmPlacement: .prominentBottom,
            detents: [.large],
            dragIndicator: .visible
        ) {
            Form {
                ServiceSetupBlurb("Connect Trawl to your qBittorrent Web UI.")

                ServiceServerSection(
                    displayName: $viewModel.displayName,
                    url: $viewModel.hostURL,
                    urlTitle: "qBittorrent URL (e.g. http://192.168.1.100:8080)",
                    urlMacLabel: "qBittorrent URL",
                    allowsUntrustedTLS: $viewModel.allowsUntrustedTLS,
                    footer: "Enter the full Web UI address, including port if needed. Enable self-signed certificates only for servers you control.",
                    footerError: hostIsMissing ? "Server address is required." : nil
                )

                CredentialsSection(
                    username: $viewModel.username,
                    password: $viewModel.password,
                    headerTitle: "Authentication",
                    footerMessage: credentialsAreMissing ? "Username and password are required." : nil
                )

                ValidationErrorSection(error: viewModel.validationError)
            }
            .tint(ServiceIdentity.qbittorrent.brandColor)
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
        .onDisappear {
            saveTask?.cancel()
        }
        .task {
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            guard let serverProfile else { return }
            await viewModel.loadExistingServer(serverProfile)
        }
    }

    private var hostIsMissing: Bool {
        viewModel.hasAttemptedSubmit
            && viewModel.hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var credentialsAreMissing: Bool {
        viewModel.hasAttemptedSubmit && (viewModel.username.isEmpty || viewModel.password.isEmpty)
    }

    private func connect() {
        saveTask?.cancel()
        saveTask = Task {
            let success = await viewModel.validateAndSave(
                modelContext: modelContext,
                editingServer: serverProfile
            )
            if success && !Task.isCancelled {
                dismiss()
                onComplete()
            }
        }
    }
}

#if DEBUG
extension OnboardingSheet {
    init(
        previewViewModel: OnboardingViewModel,
        serverProfile: ServerProfile? = nil
    ) {
        self.serverProfile = serverProfile
        self.onComplete = {}
        _viewModel = State(initialValue: previewViewModel)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Add qBittorrent") {
    OnboardingSheet(previewViewModel: OnboardingViewModel())
}

#Preview("Add qBittorrent - Validating") {
    OnboardingSheet(previewViewModel: {
        let vm = OnboardingViewModel()
        vm.hostURL = "http://192.168.1.100:8080"
        vm.username = "admin"
        vm.password = "adminadmin"
        vm.isValidating = true
        return vm
    }())
}

#Preview("Add qBittorrent - Error") {
    OnboardingSheet(previewViewModel: {
        let vm = OnboardingViewModel()
        vm.hostURL = "http://nope.invalid:8080"
        vm.username = "admin"
        vm.password = "adminadmin"
        vm.validationError = "Could not reach the Web UI. Check the address and try again."
        return vm
    }())
}
#endif
