import SwiftUI
import SwiftData

struct SeerrSetupSheet: View {
    var onComplete: (() -> Void)?
    
    var body: some View {
        NavigationStack {
            SeerrSettingsView(onComplete: onComplete, showsCancelButton: true)
        }
    }
}

struct SeerrSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = SeerrSetupViewModel()

    var onComplete: (() -> Void)?
    var showsCancelButton = false

    var body: some View {
        Form {
            Section {
                Text("Connect Trawl to your Seerr instance as an Admin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Server") {
                TextField("Seerr URL (e.g. http://192.168.1.50:5055)", text: $viewModel.hostURL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Credentials") {
                TextField("Jellyfin Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Jellyfin Password", text: $viewModel.password)
            }

            if let error = viewModel.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                Button {
                    Task {
                        let success = await viewModel.login(modelContext: modelContext)
                        if success {
                            onComplete?()
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if viewModel.isAuthenticating {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text("Sign In")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(viewModel.hostURL.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty || viewModel.isAuthenticating)
            }
        }
        .navigationTitle("Add Seerr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(showsCancelButton ? .inline : .large)
        .listStyle(.insetGrouped)
        #endif
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
