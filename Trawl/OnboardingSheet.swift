import SwiftUI
import SwiftData

struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = OnboardingViewModel()
    let onComplete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://192.168.1.100:8080", text: $viewModel.hostURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Display Name (optional)", text: $viewModel.displayName)
                }

                Section("Credentials") {
                    TextField("Username", text: $viewModel.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $viewModel.password)
                }

                if viewModel.isValidating {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Connecting...")
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let success = await viewModel.validateAndSave(modelContext: modelContext)
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
        }
    }
}
