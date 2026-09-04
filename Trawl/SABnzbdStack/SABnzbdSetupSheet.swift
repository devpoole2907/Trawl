import SwiftData
import SwiftUI

struct SABnzbdSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SABnzbdSetupViewModel()

    var profile: SABnzbdServiceProfile?
    var onComplete: (() -> Void)?

    init(profile: SABnzbdServiceProfile? = nil, onComplete: (() -> Void)? = nil) {
        self.profile = profile
        self.onComplete = onComplete
    }

    var body: some View {
        AppSheetShell(
            title: profile == nil ? "Add SABnzbd" : "Edit SABnzbd",
            confirmTitle: profile == nil ? "Connect" : "Save Connection",
            isConfirmDisabled: !viewModel.canConnect,
            isConfirmLoading: viewModel.isConnecting,
            onConfirm: connect,
            confirmPlacement: .prominentBottom,
            detents: [.large],
            dragIndicator: .visible
        ) {
            Form {
                ServiceSetupBlurb("Connect Trawl directly to SABnzbd using its full API key.")

                ServiceServerSection(
                    displayName: $viewModel.displayName,
                    url: $viewModel.hostURL,
                    urlTitle: "SABnzbd URL (e.g. http://192.168.1.50:8080)",
                    urlMacLabel: "SABnzbd URL",
                    allowsUntrustedTLS: $viewModel.allowsUntrustedTLS
                )

                Section {
                    SecureField("Full API Key", text: $viewModel.apiKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .textContentType(.password)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Find the API key in SABnzbd under Config → General → Security. The NZB key does not provide management access.")
                }

                ValidationErrorSection(error: viewModel.error)
            }
            .tint(ServiceIdentity.sabnzbd.brandColor)
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
