import SwiftData
import SwiftUI

struct SABnzbdSetupSheet: View {
    var profile: SABnzbdServiceProfile?
    var onComplete: (() -> Void)?

    init(profile: SABnzbdServiceProfile? = nil, onComplete: (() -> Void)? = nil) {
        self.profile = profile
        self.onComplete = onComplete
    }

    var body: some View {
        AppSheetShell(
            title: profile == nil ? "Add SABnzbd" : "Edit SABnzbd",
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            SABnzbdConnectionFormView(profile: profile, onComplete: onComplete)
        }
    }
}

struct SABnzbdConnectionFormView: View {
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
        Form {
            Section {
                Text("Connect Trawl directly to SABnzbd using its full API key.")
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
                    title: "SABnzbd URL (e.g. http://192.168.1.50:8080)",
                    macLabel: "SABnzbd URL"
                )

                AllowUntrustedTLSToggle(allow: $viewModel.allowsUntrustedTLS)
            }

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
                Text("Find the API key in SABnzbd under Config > General > Security. The NZB key does not provide management access.")
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
        .tint(ServiceIdentity.sabnzbd.brandColor)
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

