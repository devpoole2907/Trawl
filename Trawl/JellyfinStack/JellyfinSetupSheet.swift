import SwiftUI
import SwiftData

struct JellyfinSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(JellyfinCredentialHandoff.self) private var credentialHandoff: JellyfinCredentialHandoff?
    @State private var viewModel = JellyfinSetupViewModel()

    var profile: JellyfinServiceProfile?
    var onComplete: (() -> Void)?
    #if DEBUG
    private var skipsInitialSeed = false
    #endif

    init(profile: JellyfinServiceProfile? = nil, onComplete: (() -> Void)? = nil) {
        self.profile = profile
        self.onComplete = onComplete
    }

    var body: some View {
        AppSheetShell(
            title: profile == nil ? "Add Jellyfin" : "Edit Jellyfin",
            confirmTitle: profile == nil ? "Connect" : "Save Connection",
            isConfirmDisabled: !viewModel.canConnect,
            isConfirmLoading: viewModel.isAuthenticating,
            onConfirm: connect,
            confirmPlacement: .prominentBottom,
            detents: [.large],
            dragIndicator: .visible
        ) {
            Form {
                ServiceSetupBlurb("Connect directly to a Jellyfin server with an administrator account or API key.")

                ServiceServerSection(
                    displayName: $viewModel.displayName,
                    url: $viewModel.hostURL,
                    urlTitle: "Jellyfin URL (e.g. http://192.168.1.50:8096)",
                    urlMacLabel: "Jellyfin URL",
                    allowsUntrustedTLS: $viewModel.allowsUntrustedTLS
                )

                Section {
                    Picker("Method", selection: $viewModel.authMode) {
                        Text("Password").tag(JellyfinAuthMode.userPass)
                        Text("API Key").tag(JellyfinAuthMode.apiKey)
                    }
                    .pickerStyle(.segmented)

                    switch viewModel.authMode {
                    case .apiKey:
                        SecureField("API Key", text: $viewModel.apiKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .textContentType(.password)
                            #endif
                            .autocorrectionDisabled()
                    case .userPass:
                        TextField("Username", text: $viewModel.username)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .textContentType(.username)
                            #endif
                            .autocorrectionDisabled()

                        SecureField("Password", text: $viewModel.password)
                            #if os(iOS)
                            .textContentType(.password)
                            #endif
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    authenticationFooter
                }

                ValidationErrorSection(error: viewModel.error)
            }
            .tint(ServiceIdentity.jellyfin.brandColor)
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
        }
        .task(id: profile?.id) {
            #if DEBUG
            if skipsInitialSeed { return }
            #endif
            viewModel.seed(from: profile)
        }
    }

    private func connect() {
        Task {
            let success = await viewModel.connect(modelContext: modelContext)
            if success {
                // Seerr signs in with this same Jellyfin account, so the Seerr sheet
                // can offer to reuse it rather than making the user type it twice.
                // Only a real sign-in produces something Seerr can use - an API key
                // is not a credential it can present.
                if viewModel.authMode == .userPass {
                    credentialHandoff?.store(
                        username: viewModel.username.trimmingCharacters(in: .whitespacesAndNewlines),
                        password: viewModel.password
                    )
                }
                onComplete?()
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var authenticationFooter: some View {
        switch viewModel.authMode {
        case .apiKey:
            Text("Create an API key in Jellyfin Dashboard → API Keys. API key setup is recommended for server administration.")
        case .userPass:
            Text("Sign in with a Jellyfin administrator account. Trawl stores the returned access token in Keychain.")
        }
    }
}

#if DEBUG
extension JellyfinSetupSheet {
    init(
        previewViewModel: JellyfinSetupViewModel,
        profile: JellyfinServiceProfile? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        self.profile = profile
        self.onComplete = onComplete
        self._viewModel = State(initialValue: previewViewModel)
        self.skipsInitialSeed = true
    }
}
#endif

struct JellyfinSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(JellyfinServiceManager.self) private var jellyfinServiceManager
    @Environment(InAppNotificationCenter.self) private var inAppNotificationCenter
    @Query private var profiles: [JellyfinServiceProfile]
    @State private var showingConnectionSheet = false
    @State private var settingsError: String?
    @State private var showRemoveConfirmation = false
    @State private var showRestartConfirmation = false
    @State private var showShutdownConfirmation = false
    #if DEBUG
    private var isPreview = false
    #endif

    private var profile: JellyfinServiceProfile? {
        profiles.first(where: { $0.isEnabled }) ?? profiles.first
    }

    private var isConnected: Bool {
        jellyfinServiceManager.isConnected
    }

    private var connectionError: String? {
        settingsError ?? jellyfinServiceManager.connectionError
    }

    var body: some View {
        List {
            Section {
                if let profile {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(profile.hostURL)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Label(
                            isConnected ? "Connected" : "Disconnected",
                            systemImage: "circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(isConnected ? .green : .red)
                        .labelStyle(.titleAndIcon)
                    }

                    if let authLabel = profile.authMode.settingsLabel {
                        LabeledContent("Authentication") {
                            Text(authLabel).foregroundStyle(.secondary)
                        }
                    }

                    if let error = connectionError, !isConnected {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }

                    Button("Edit Server", systemImage: "pencil") {
                        showingConnectionSheet = true
                    }
                } else {
                    Button {
                        showingConnectionSheet = true
                    } label: {
                        Label("Add Jellyfin Server", systemImage: "plus")
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                if profile == nil {
                    Text("Connect with an admin API key or Jellyfin administrator account.")
                }
            }

            if let profile {
                Section("System Info") {
                    if let systemInfo = jellyfinServiceManager.cachedSystemInfo {
                        jellyfinInfoRow(label: "Server", value: systemInfo.serverName ?? profile.serverName)
                        jellyfinInfoRow(label: "Version", value: systemInfo.version ?? profile.serverVersion)
                        jellyfinInfoRow(label: "Operating System", value: systemInfo.operatingSystem)
                        jellyfinInfoRow(label: "Product", value: systemInfo.productName)
                        jellyfinInfoRow(label: "Server ID", value: systemInfo.id)
                        if let port = systemInfo.webSocketPortNumber {
                            jellyfinInfoRow(label: "WebSocket Port", value: String(port))
                        }
                    } else if profile.serverName != nil || profile.serverVersion != nil {
                        jellyfinInfoRow(label: "Server", value: profile.serverName)
                        jellyfinInfoRow(label: "Version", value: profile.serverVersion)
                    } else if jellyfinServiceManager.isConnecting {
                        HStack {
                            ProgressView()
                            Text("Loading system info...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Reconnect to load system information.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink {
                        ContentUnavailableView(
                            "Linked Applications",
                            systemImage: "app.connected.to.app.below.fill",
                            description: Text("Sonarr and Radarr library matching will be added in a later Jellyfin admin phase.")
                        )
                    } label: {
                        Label("Linked Applications", systemImage: "app.connected.to.app.below.fill")
                    }
                } header: {
                    Text("Automation")
                }

                Section("Server Control") {
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        Task {
                            await jellyfinServiceManager.connectService(profile)
                            settingsError = nil
                        }
                    }
                    .disabled(jellyfinServiceManager.isConnecting)

                    Button(role: .destructive) {
                        showRestartConfirmation = true
                    } label: {
                        Label("Restart Server", systemImage: "arrow.circlepath")
                    }
                    .disabled(jellyfinServiceManager.activeClient == nil)
                    .confirmationDialog(
                        "Restart Server",
                        isPresented: $showRestartConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Restart", role: .destructive) {
                            Task { await restartServer() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will disconnect all active sessions. The server may take a moment to become available again.")
                    }

                    Button(role: .destructive) {
                        showShutdownConfirmation = true
                    } label: {
                        Label("Shutdown Server", systemImage: "power")
                    }
                    .disabled(jellyfinServiceManager.activeClient == nil)
                    .confirmationDialog(
                        "Shutdown Server",
                        isPresented: $showShutdownConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Shutdown", role: .destructive) {
                            Task { await shutdownServer() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will disconnect all active sessions and power off the server.")
                    }
                }

                Section {
                    Button("Remove Jellyfin Server", systemImage: "trash", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                }
            }
        }
        .navigationTitle("Jellyfin")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .task(id: syncKey) {
            #if DEBUG
            if isPreview { return }
            #endif
            await jellyfinServiceManager.initialize(from: profiles)
        }
        .refreshable {
            if let profile {
                await jellyfinServiceManager.connectService(profile)
            }
        }
        .sheet(isPresented: $showingConnectionSheet) {
            JellyfinSetupSheet(
                profile: profile,
                onComplete: {
                    Task {
                        await jellyfinServiceManager.initialize(from: profiles)
                    }
                }
            )
        }
        .confirmationDialog(
            "Remove Jellyfin Server?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await removeProfile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out and removes your saved Jellyfin connection from Trawl.")
        }
    }

    private var syncKey: String {
        profiles
            .map { "\($0.id.uuidString):\($0.hostURL):\($0.isEnabled):\($0.authModeRaw)" }
            .sorted()
            .joined(separator: "|")
    }

    private func removeProfile() async {
        guard let profile else { return }
        var keychainDeleted = false
        do {
            try await KeychainHelper.shared.delete(key: profile.accessTokenKey)
            keychainDeleted = true
            modelContext.delete(profile)
            try modelContext.save()
            jellyfinServiceManager.disconnect()
            settingsError = nil
        } catch {
            modelContext.rollback()
            if keychainDeleted {
                jellyfinServiceManager.disconnect()
            }
            settingsError = error.localizedDescription
            inAppNotificationCenter.showError(
                title: "Remove Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }

    private func restartServer() async {
        guard let client = jellyfinServiceManager.activeClient else {
            inAppNotificationCenter.showError(
                title: "Restart Failed",
                message: "Jellyfin is not connected.",
                source: .inApp
            )
            return
        }

        inAppNotificationCenter.showProgress(
            title: "Restarting Server",
            message: "Jellyfin is restarting...",
            key: "jellyfin_restart",
            source: .inApp
        )
        do {
            try await client.restartServer()
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_restart",
                title: "Restart Initiated",
                message: "Jellyfin is restarting. It may be unavailable for a moment."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_restart",
                title: "Restart Failed",
                message: error.localizedDescription
            )
        }
    }

    private func shutdownServer() async {
        guard let client = jellyfinServiceManager.activeClient else {
            inAppNotificationCenter.showError(
                title: "Shutdown Failed",
                message: "Jellyfin is not connected.",
                source: .inApp
            )
            return
        }

        inAppNotificationCenter.showProgress(
            title: "Shutting Down",
            message: "Jellyfin is shutting down...",
            key: "jellyfin_shutdown",
            source: .inApp
        )
        do {
            try await client.shutdownServer()
            inAppNotificationCenter.replaceProgressWithSuccess(
                key: "jellyfin_shutdown",
                title: "Shutdown Initiated",
                message: "Jellyfin is shutting down."
            )
        } catch {
            inAppNotificationCenter.replaceProgressWithError(
                key: "jellyfin_shutdown",
                title: "Shutdown Failed",
                message: error.localizedDescription
            )
        }
    }

    @ViewBuilder
    private func jellyfinInfoRow(label: String, value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).foregroundStyle(.secondary)
            }
            #if os(iOS)
            .contextMenu {
                Button("Copy") {
                    UIPasteboard.general.string = value
                }
            }
            #endif
        }
    }
}

#if DEBUG
extension JellyfinSettingsView {
    init(preview: Bool) {
        self.isPreview = preview
    }
}
#endif

private extension JellyfinAuthMode {
    var settingsLabel: String? {
        switch self {
        case .apiKey:
            return "API Key"
        case .userPass:
            return "Username & Password"
        }
    }
}

#if DEBUG
#Preview("Jellyfin Setup - Initial") {
    PreviewHost(profiles: .empty, jellyfin: .preview(.notConfigured)) {
        JellyfinSetupSheet()
    }
}

#Preview("Jellyfin Setup - Mid Input") {
    PreviewHost(profiles: .empty, jellyfin: .preview(.notConfigured)) {
        JellyfinSetupSheet(
            previewViewModel: JellyfinSetupViewModel(
                previewHostURL: "http://192.168.1.50:8096",
                previewUsername: "admin",
                previewPassword: "password",
                previewAuthMode: .userPass,
                previewDisplayName: "Home Jellyfin"
            )
        )
    }
}

#Preview("Jellyfin Setup - Authenticating") {
    PreviewHost(profiles: .empty, jellyfin: .preview(.connecting)) {
        JellyfinSetupSheet(
            previewViewModel: JellyfinSetupViewModel(
                previewHostURL: "http://192.168.1.50:8096",
                previewAPIKey: "preview-api-key",
                previewIsAuthenticating: true
            )
        )
    }
}

#Preview("Jellyfin Setup - Error") {
    PreviewHost(profiles: .empty, jellyfin: .preview(.error("Could not reach Jellyfin at 192.168.1.50:8096."))) {
        JellyfinSetupSheet(
            previewViewModel: JellyfinSetupViewModel(
                previewHostURL: "http://nope.invalid:8096",
                previewAPIKey: "preview-api-key",
                previewError: "Could not reach server. Check the URL and try again."
            )
        )
    }
}

#Preview("Jellyfin Settings - Connected") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack { JellyfinSettingsView(preview: true) }
    }
}

#Preview("Jellyfin Settings - Not Configured") {
    PreviewHost(profiles: .empty, jellyfin: .preview(.notConfigured)) {
        NavigationStack { JellyfinSettingsView(preview: true) }
    }
}

#Preview("Jellyfin Settings - Connection Error") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.error("Session expired. Please reconnect."))) {
        NavigationStack { JellyfinSettingsView(preview: true) }
    }
}

#Preview("Jellyfin Settings - Reauthentication") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.requiresReauthentication)) {
        NavigationStack { JellyfinSettingsView(preview: true) }
    }
}
#endif
