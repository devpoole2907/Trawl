import SwiftData
import SwiftUI

struct CleanuparrSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = CleanuparrSetupViewModel()

    var profile: CleanuparrServiceProfile?
    var onComplete: (() -> Void)?

    init(profile: CleanuparrServiceProfile? = nil, onComplete: (() -> Void)? = nil) {
        self.profile = profile
        self.onComplete = onComplete
    }

    var body: some View {
        AppSheetShell(
            title: profile == nil ? "Add Cleanuparr" : "Edit Cleanuparr",
            confirmTitle: profile == nil ? "Connect" : "Save Connection",
            isConfirmDisabled: !viewModel.canConnect,
            isConfirmLoading: viewModel.isConnecting,
            onConfirm: connect,
            confirmPlacement: .prominentBottom,
            detents: [.large],
            dragIndicator: .visible
        ) {
            Form {
                ServiceSetupBlurb("Connect Trawl to Cleanuparr's documented, read-only Stats and Health APIs.")

                ServiceServerSection(
                    displayName: $viewModel.displayName,
                    url: $viewModel.hostURL,
                    urlTitle: "Cleanuparr URL (e.g. http://192.168.1.50:11011)",
                    urlMacLabel: "Cleanuparr URL",
                    allowsUntrustedTLS: $viewModel.allowsUntrustedTLS
                )

                Section {
                    SecureField("API Key", text: $viewModel.apiKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .textContentType(.password)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Find the API key in Cleanuparr under Account Settings. Base-path URLs are supported.")
                }

                ValidationErrorSection(error: viewModel.error)
            }
            .tint(ServiceIdentity.cleanuparr.brandColor)
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
        .task(id: profile?.id) {
            await viewModel.seed(from: profile)
        }
    }

    private func connect() {
        Task {
            let success = await viewModel.connect(modelContext: modelContext)
            if success {
                onComplete?()
                dismiss()
            }
        }
    }
}
