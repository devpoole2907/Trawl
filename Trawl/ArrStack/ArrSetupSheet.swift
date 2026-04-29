import SwiftUI
import SwiftData

struct ArrSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var profiles: [ArrServiceProfile]
    @State private var viewModel: ArrSetupViewModel?
    let initialServiceType: ArrServiceType?
    let existingProfile: ArrServiceProfile?
    let onComplete: () -> Void

    init(
        initialServiceType: ArrServiceType? = nil,
        existingProfile: ArrServiceProfile? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.initialServiceType = initialServiceType
        self.existingProfile = existingProfile
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    setupForm(vm: vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(existingProfile.map { "Edit \($0.resolvedServiceType?.displayName ?? "Service")" } ?? (initialServiceType.map { "Add \($0.displayName)" } ?? "Add Service"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let vm = viewModel else { return }
                        Task {
                            if await vm.validateAndSave(modelContext: modelContext) {
                                dismiss()
                                onComplete()
                            }
                        }
                    }
                    .disabled(viewModel?.hostURL.isEmpty ?? true || viewModel?.apiKey.isEmpty ?? true || viewModel?.isValidating ?? false)
                }
            }
            .presentationDetents([.medium, .large])
            .task(id: existingProfile?.id) {
                let vm = ArrSetupViewModel(serviceManager: serviceManager)
                if let existingProfile {
                    await vm.loadExisting(existingProfile)
                } else if let initialServiceType {
                    vm.serviceType = initialServiceType
                }
                viewModel = vm
            }
        }
    }

    private var canCreateProwlarr: Bool {
        existingProfile?.resolvedServiceType == .prowlarr
            || !profiles.contains { $0.resolvedServiceType == .prowlarr }
    }

    private var availableServiceTypes: [ArrServiceType] {
        ArrServiceType.allCases.filter { type in
            type != .prowlarr || canCreateProwlarr
        }
    }

    @ViewBuilder
    private func setupForm(vm: ArrSetupViewModel) -> some View {
        @Bindable var vm = vm
        Form {
            if initialServiceType == nil && existingProfile == nil {
                Section("Service Type") {
                    Picker("Type", selection: $vm.serviceType) {
                        ForEach(availableServiceTypes) { type in
                            Label(type.displayName, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section("Connection") {
                TextField("http://192.168.1.100:\(vm.serviceType.defaultPort)", text: $vm.hostURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("API Key", text: $vm.apiKey)
                    .textInputAutocapitalization(.never)

                TextField("Display Name (optional)", text: $vm.displayName)

                Toggle("Allow Self-Signed Certificates", isOn: $vm.allowsUntrustedTLS)
            }

            Section {
                Text("Find your API key in \(vm.serviceType.displayName) under Settings → General → Security. Enable self-signed certificates only for services you manage yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if vm.serviceType == .prowlarr {
                    Text("Trawl supports a single Prowlarr server. Saving Prowlarr settings updates the existing server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if vm.isValidating {
                Section {
                    HStack {
                        ProgressView()
                        Text("Testing connection...")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = vm.validationError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let status = vm.validatedStatus {
                Section("Connected") {
                    if let appName = status.appName {
                        HStack {
                            Text("App")
                            Spacer()
                            Text(appName).foregroundStyle(.secondary)
                        }
                    }
                    if let version = status.version {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text(version).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
