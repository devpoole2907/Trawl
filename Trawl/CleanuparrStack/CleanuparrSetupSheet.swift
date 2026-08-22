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
        Form {
            Section {
                Text("Connect Trawl to Cleanuparr's documented, read-only Stats and Health APIs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Server") {
                TextField("Display Name", text: $viewModel.displayName)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .autocorrectionDisabled()

                ServerURLField(
                    url: $viewModel.hostURL,
                    title: "Cleanuparr URL (e.g. http://192.168.1.50:11011)"
                )

                AllowUntrustedTLSToggle(allow: $viewModel.allowsUntrustedTLS)
            }

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

            Section {
                Button {
                    Task {
                        let success = await viewModel.connect(modelContext: modelContext)
                        if success {
                            onComplete?()
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if viewModel.isConnecting {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text(profile == nil ? "Connect" : "Save Connection")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(!viewModel.canConnect)
            }
        }
        .tint(ServiceIdentity.cleanuparr.brandColor)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .task(id: profile?.id) {
            await viewModel.seed(from: profile)
        }
    }
}
