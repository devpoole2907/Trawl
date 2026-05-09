import SwiftUI
import SwiftData

struct SeerrSetupSheet: View {
    var onComplete: (() -> Void)?
    
    var body: some View {
        NavigationStack {
            SeerrConnectionFormView(onComplete: onComplete, showsCancelButton: true)
        }
    }
}

private struct SeerrConnectionFormView: View {
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
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            }

            Section("Credentials") {
                TextField("Jellyfin Username", text: $viewModel.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
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
        .tint(.indigo)
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

struct SeerrSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Query private var profiles: [SeerrServiceProfile]
    @State private var showingConnectionSheet = false
    @State private var publicSettings: SeerrPublicSettings?
    @State private var settingsError: String?
    @State private var showRemoveConfirmation = false

    private var profile: SeerrServiceProfile? {
        profiles.first(where: { $0.isEnabled }) ?? profiles.first
    }

    private var isConnected: Bool { seerrServiceManager.isConnected }

    private var connectionError: String? {
        settingsError ?? seerrServiceManager.connectionError
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

                    if let title = publicSettings?.applicationTitle, !title.isEmpty {
                        LabeledContent("Application") {
                            Text(title).foregroundStyle(.secondary)
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
                        Label("Add Seerr Server", systemImage: "plus")
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                if profile == nil {
                    Text("Sign in with the Jellyfin admin account configured on your Seerr instance.")
                }
            }

            if profile != nil {
                if let publicSettings {
                    Section("System Status") {
                        if let title = publicSettings.applicationTitle, !title.isEmpty {
                            seerrInfoRow(label: "Instance", value: title)
                        }
                        seerrInfoRow(label: "Media Server", value: publicSettings.mediaServerLabel)
                        if let initialized = publicSettings.initialized {
                            seerrInfoRow(label: "Initialized", value: initialized ? "Yes" : "No")
                        }
                    }
                } else if isConnected {
                    Section("System Status") {
                        HStack {
                            ProgressView()
                            Text("Loading system status...")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let settingsError {
                    Section("System Status") {
                        Label(settingsError, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                if isConnected, let client = seerrServiceManager.activeClient {
                    Section {
                        NavigationLink {
                            SeerrLinkedApplicationsView(apiClient: client)
                        } label: {
                            Label("Linked Applications", systemImage: "app.connected.to.app.below.fill")
                        }
                    } header: {
                        Text("Automation")
                    } footer: {
                        Text("Link Sonarr or Radarr so Seerr can route approved requests to them.")
                    }
                }

                Section {
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        Task {
                            if let profile {
                                await seerrServiceManager.connectService(profile)
                                await loadPublicSettings()
                            }
                        }
                    }
                    .disabled(seerrServiceManager.isConnecting)
                }

                Section {
                    Button("Remove Seerr Server", systemImage: "trash", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                }
            }
        }
        .navigationTitle("Seerr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .task(id: syncKey) {
            await seerrServiceManager.initialize(from: profiles)
            await loadPublicSettings()
        }
        .refreshable {
            if let profile {
                await seerrServiceManager.connectService(profile)
            }
            await loadPublicSettings()
        }
        .sheet(isPresented: $showingConnectionSheet) {
            NavigationStack {
                SeerrConnectionFormView(
                    onComplete: {
                        Task {
                            await seerrServiceManager.initialize(from: profiles)
                            await loadPublicSettings()
                        }
                    },
                    showsCancelButton: true
                )
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Remove Seerr Server?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await removeProfile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs out and removes your saved Seerr connection from Trawl.")
        }
    }

    private var syncKey: String {
        profiles
            .map { "\($0.id.uuidString):\($0.hostURL):\($0.isEnabled)" }
            .sorted()
            .joined(separator: "|")
    }

    private func loadPublicSettings() async {
        guard let client = seerrServiceManager.activeClient else {
            publicSettings = nil
            return
        }

        do {
            publicSettings = try await client.getPublicSettings()
            settingsError = nil
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func removeProfile() async {
        guard let profile else { return }
        try? await KeychainHelper.shared.delete(key: profile.sessionCookieKey)
        modelContext.delete(profile)
        try? modelContext.save()
        seerrServiceManager.disconnect()
        publicSettings = nil
        settingsError = nil
    }

    @ViewBuilder
    private func seerrInfoRow(label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private extension SeerrPublicSettings {
    var mediaServerLabel: String {
        if isJellyfin { return "Jellyfin" }
        if isPlex { return "Plex" }
        if isEmby { return "Emby" }
        return "Unknown"
    }
}
