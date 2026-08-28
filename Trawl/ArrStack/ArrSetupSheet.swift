import SwiftUI
import SwiftData

struct ArrSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var profiles: [ArrServiceProfile]
    @State private var viewModel: ArrSetupViewModel?
    @State private var saveTask: Task<Void, Never>?
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

    #if DEBUG
    init(
        previewViewModel: ArrSetupViewModel,
        initialServiceType: ArrServiceType? = nil,
        existingProfile: ArrServiceProfile? = nil
    ) {
        self.initialServiceType = initialServiceType
        self.existingProfile = existingProfile
        self.onComplete = {}
        _viewModel = State(initialValue: previewViewModel)
    }
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    setupForm(vm: vm)
                } else {
                    ProgressView()
                }
            }
            .modalFormStyle(
                title: existingProfile.map { "Edit \($0.resolvedServiceType?.displayName ?? "Service")" } ?? (initialServiceType.map { "Add \($0.displayName)" } ?? "Add Service"),
                primaryTitle: "Save",
                isPrimaryDisabled: viewModel?.hostURL.isEmpty ?? true || viewModel?.apiKey.isEmpty ?? true || viewModel?.isValidating ?? false,
                isSaving: viewModel?.isSaving ?? false
            ) {
                guard let vm = viewModel else { return }
                saveTask?.cancel()
                vm.isSaving = true
                saveTask = Task {
                    let success = await vm.validateAndSave(modelContext: modelContext)
                    vm.isSaving = false
                    if success && !Task.isCancelled {
                        dismiss()
                        onComplete()
                    }
                }
            }
            .onDisappear {
                saveTask?.cancel()
            }
            .task(id: existingProfile?.id) {
                #if DEBUG
                if ArrPreviewRuntime.isActive, viewModel != nil { return }
                #endif
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
            (type != .prowlarr || canCreateProwlarr) && hasRoomForAnother(type)
        }
    }

    /// Whether another server of this type can be added.
    ///
    /// Sonarr and Radarr are capped at the HD/4K pair the blended library is
    /// built around. Editing an existing profile always passes: the cap is on
    /// adding a third, not on changing one of the two.
    private func hasRoomForAnother(_ type: ArrServiceType) -> Bool {
        if existingProfile?.resolvedServiceType == type { return true }
        guard let limit = ArrSetupViewModel.instanceLimit(for: type) else { return true }
        return profiles.filter { $0.resolvedServiceType == type }.count < limit
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
                ServerURLField(url: $vm.hostURL, title: "http://192.168.1.100:\(vm.serviceType.defaultPort)")

                SecureField("API Key", text: $vm.apiKey)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                TextField("Display Name (optional)", text: $vm.displayName)

                AllowUntrustedTLSToggle(allow: $vm.allowsUntrustedTLS)
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

                if let limit = ArrSetupViewModel.instanceLimit(for: vm.serviceType) {
                    let configured = profiles.filter { $0.resolvedServiceType == vm.serviceType }.count
                    if existingProfile == nil, configured == limit - 1 {
                        Text("This will be your second \(vm.serviceType.displayName) server. Both appear as one library, with each title labelled by the server holding it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

            ValidationErrorSection(error: vm.validationError)

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

#if DEBUG
#Preview("Setup - New Sonarr") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        ArrSetupSheet(previewViewModel: ArrSetupViewModel(previewState: .blank(.sonarr)))
    }
}

#Preview("Setup - Mid-Input") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.radarrOnly)) {
        ArrSetupSheet(previewViewModel: ArrSetupViewModel(previewState: .editing(.radarr)))
    }
}

#Preview("Setup - Validating") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        ArrSetupSheet(previewViewModel: ArrSetupViewModel(previewState: .validating(.radarr)))
    }
}

#Preview("Setup - Error") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        ArrSetupSheet(previewViewModel: ArrSetupViewModel(previewState: .error(.prowlarr, "Connection failed: API key rejected.")))
    }
}

#Preview("Setup - Connected") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrOnly)) {
        ArrSetupSheet(previewViewModel: ArrSetupViewModel(previewState: .connected(.sonarr)))
    }
}
#endif
