import SwiftUI
import SwiftData

struct JellyfinSetupSheet: View {
    var onComplete: (() -> Void)?

    var body: some View {
        AppSheetShell(
            title: "Add Jellyfin",
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            JellyfinConnectionFormView(
                profile: nil,
                onComplete: onComplete
            )
        }
    }
}

private struct JellyfinConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = JellyfinSetupViewModel()

    var profile: JellyfinServiceProfile?
    var onComplete: (() -> Void)?

    private var submitTitle: String {
        profile == nil ? "Connect" : "Save Connection"
    }

    var body: some View {
        Form {
            Section {
                Text("Connect directly to a Jellyfin server with an administrator account or API key.")
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
                    title: "Jellyfin URL (e.g. http://192.168.1.50:8096)"
                )

                AllowUntrustedTLSToggle(allow: $viewModel.allowsUntrustedTLS)
            }

            Section {
                Picker("Authentication", selection: $viewModel.authMode) {
                    Text("API Key").tag(JellyfinAuthMode.apiKey)
                    Text("Password").tag(JellyfinAuthMode.userPass)
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
                        if viewModel.isAuthenticating {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text(submitTitle)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(!viewModel.canConnect)
            }
        }
        .tint(ServiceIdentity.jellyfin.brandColor)
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .task(id: profile?.id) {
            viewModel.seed(from: profile)
        }
    }

    @ViewBuilder
    private var authenticationFooter: some View {
        switch viewModel.authMode {
        case .apiKey:
            Text("Create an API key in Jellyfin Dashboard > API Keys. API key setup is recommended for server administration.")
        case .userPass:
            Text("Sign in with a Jellyfin administrator account. Trawl stores the returned access token in Keychain.")
        }
    }
}

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
            await jellyfinServiceManager.initialize(from: profiles)
        }
        .refreshable {
            if let profile {
                await jellyfinServiceManager.connectService(profile)
            }
        }
        .sheet(isPresented: $showingConnectionSheet) {
            AppSheetShell(
                title: profile == nil ? "Add Jellyfin" : "Edit Jellyfin",
                detents: [.medium, .large],
                dragIndicator: .visible
            ) {
                JellyfinConnectionFormView(
                    profile: profile,
                    onComplete: {
                        Task {
                            await jellyfinServiceManager.initialize(from: profiles)
                        }
                    }
                )
            }
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
