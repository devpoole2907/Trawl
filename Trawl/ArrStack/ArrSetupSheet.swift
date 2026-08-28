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
                    vm.qualityTier = selectableTiers(for: initialServiceType).first ?? .hd
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

    /// Whether another server of this type can be added — that is, whether it
    /// still has a free quality tier.
    private func hasRoomForAnother(_ type: ArrServiceType) -> Bool {
        if existingProfile?.resolvedServiceType == type { return true }
        guard ArrSetupViewModel.usesQualityTiers(type) else { return true }
        return !freeTiers(for: type).isEmpty
    }

    /// The tiers this service has no server for yet. Editing keeps its own tier
    /// available, so a user can re-save an existing server without being told its
    /// tier is taken by itself.
    private func freeTiers(for type: ArrServiceType) -> [ArrQualityTier] {
        let taken = Set(
            profiles
                .filter { $0.resolvedServiceType == type && $0.id != existingProfile?.id }
                .map(\.qualityTier)
        )
        return ArrQualityTier.allCases.filter { !taken.contains($0) }
    }

    /// Tiers that are valid for the profile currently being created or edited.
    /// A new second server therefore opens directly on the one remaining slot,
    /// while an edit keeps its current tier available.
    private func selectableTiers(for type: ArrServiceType) -> [ArrQualityTier] {
        let free = freeTiers(for: type)
        guard let existingProfile, existingProfile.resolvedServiceType == type else {
            return free
        }
        return ArrQualityTier.allCases.filter {
            $0 == existingProfile.qualityTier || free.contains($0)
        }
    }

    /// Explains what the tier choice means in terms of what the user will see,
    /// rather than restating the setting.
    private func tierFooter(vm: ArrSetupViewModel) -> String {
        let other: ArrQualityTier = vm.qualityTier == .hd ? .uhd : .hd
        if profiles.contains(where: {
            $0.resolvedServiceType == vm.serviceType && $0.qualityTier == other && $0.id != existingProfile?.id
        }) {
            return "Your \(other.label) \(vm.serviceType.displayName) is already set up. Both servers appear as one library, with each title showing whether it's available in HD, 4K, or both."
        }
        return "Trawl holds one \(vm.serviceType.displayName) for HD and one for 4K, blended into a single library. Add the other later to see both."
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

            if ArrSetupViewModel.usesQualityTiers(vm.serviceType) {
                Section {
                    Picker("Library", selection: $vm.qualityTier) {
                        ForEach(selectableTiers(for: vm.serviceType)) { tier in
                            Text(tier.longLabel).tag(tier)
                        }
                    }
                } header: {
                    Text("Quality")
                } footer: {
                    Text(tierFooter(vm: vm))
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
