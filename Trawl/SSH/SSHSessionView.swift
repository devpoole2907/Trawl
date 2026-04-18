import SwiftUI
import SwiftData

@MainActor
@Observable
final class SSHSessionStore {
    var activeProfile: SSHProfile?
    var titleOverride: String?
    var wantsKeyboard = false

    let connection = SSHConnection()
    let bridge = SSHTerminalBridge()
    private let liveActivityManager = SSHLiveActivityManager()

    var pendingFingerprint: String?
    private var fingerprintContinuation: CheckedContinuation<Bool, Never>?

    var sessionTitle: String {
        titleOverride ?? activeProfile?.displayName ?? "SSH"
    }

    var sessionSubtitle: String {
        guard let activeProfile else { return "No Active Session" }
        return "\(activeProfile.username)@\(activeProfile.hostDisplay)"
    }

    var hasSession: Bool {
        activeProfile != nil
    }

    var statusText: String {
        switch connection.state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        case .failed: "Failed"
        }
    }

    var statusColor: Color {
        switch connection.state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        case .failed: .red
        }
    }

    init() {
        bridge.sendToSSH = { [connection] data in
            connection.send(data)
        }
        bridge.onResize = { [connection] cols, rows in
            connection.resize(cols: cols, rows: rows)
        }
        bridge.onTitleChange = { [weak self] title in
            guard !title.isEmpty else { return }
            self?.titleOverride = title
            self?.syncLiveActivity()
        }
        bridge.onKeyboardVisibilityChange = { [weak self] isVisible in
            self?.wantsKeyboard = isVisible
        }

        connection.onOutput = { [bridge] bytes in
            bridge.receive(bytes: bytes)
        }
        connection.onClose = { [weak self] in
            self?.wantsKeyboard = false
            self?.syncLiveActivity()
        }
        connection.onStateChange = { [weak self] _ in
            self?.syncLiveActivity()
        }
    }

    func prepareSession(for profile: SSHProfile) async {
        if activeProfile?.id != profile.id {
            // Resume any pending fingerprint continuation before switching
            confirmFingerprint(accepted: false)
            await connection.disconnect()
            titleOverride = nil
            wantsKeyboard = false
        }

        activeProfile = profile
        syncLiveActivity()
    }

    func connectIfNeeded(modelContext: ModelContext) async {
        guard let activeProfile else { return }

        switch connection.state {
        case .connected:
            wantsKeyboard = true
            return
        case .connecting:
            return
        case .disconnected, .failed:
            break
        }

        await connect(to: activeProfile, modelContext: modelContext)
    }

    func reconnect(modelContext: ModelContext) async {
        guard let activeProfile else { return }
        // Resume any pending fingerprint continuation before reconnecting
        confirmFingerprint(accepted: false)
        await connection.disconnect()
        titleOverride = nil
        wantsKeyboard = false
        await connect(to: activeProfile, modelContext: modelContext)
    }

    func focusSession() {
        wantsKeyboard = true
    }

    func hideKeyboard() {
        wantsKeyboard = false
        bridge.hideKeyboard()
    }

    func disconnect() async {
        // Resume any pending fingerprint continuation before disconnecting
        confirmFingerprint(accepted: false)
        bridge.hideKeyboard()
        await connection.disconnect()
        activeProfile = nil
        titleOverride = nil
        wantsKeyboard = false
        syncLiveActivity()
    }

    func presentFingerprintConfirmation(_ fingerprint: String) async -> Bool {
        // If a continuation already exists, resume it with false before creating a new one
        if fingerprintContinuation != nil {
            confirmFingerprint(accepted: false)
        }

        pendingFingerprint = fingerprint
        return await withCheckedContinuation { continuation in
            self.fingerprintContinuation = continuation
        }
    }

    func confirmFingerprint(accepted: Bool) {
        fingerprintContinuation?.resume(returning: accepted)
        fingerprintContinuation = nil
        pendingFingerprint = nil
    }

    private func connect(to profile: SSHProfile, modelContext: ModelContext) async {
        activeProfile = profile
        titleOverride = nil
        wantsKeyboard = false

        connection.onNewFingerprint = { [weak self] fingerprint in
            guard let self, self.activeProfile?.id == profile.id else { return false }
            let accepted = await self.presentFingerprintConfirmation(fingerprint)
            if accepted {
                let previousFingerprint = profile.knownHostFingerprint
                profile.knownHostFingerprint = fingerprint
                do {
                    try modelContext.save()
                } catch {
                    // Revert fingerprint on save failure
                    profile.knownHostFingerprint = previousFingerprint
                    // Treat as rejected since we couldn't persist the trust decision
                    return false
                }
            }
            return accepted
        }

        do {
            let auth = try await resolveAuth(for: profile)
            try await connection.connect(
                host: profile.host,
                port: profile.port,
                username: profile.username,
                auth: auth,
                knownFingerprint: profile.knownHostFingerprint
            )
            guard activeProfile?.id == profile.id else { return }
            wantsKeyboard = true
            syncLiveActivity()
        } catch {
            guard activeProfile?.id == profile.id else { return }
            // Mark connection as failed with the error message
            connection.markFailed(error.localizedDescription)
            syncLiveActivity()
        }
    }

    private func resolveAuth(for profile: SSHProfile) async throws -> SSHAuth {
        switch profile.authType {
        case .password:
            let password = try await KeychainHelper.shared.read(key: profile.passwordKey) ?? ""
            return .password(password)
        case .privateKey:
            let key = try await KeychainHelper.shared.read(key: profile.privateKeyKey) ?? ""
            let passphrase = try await KeychainHelper.shared.read(key: profile.passphraseKey)
            return .privateKey(pem: key, passphrase: passphrase)
        }
    }

    private func syncLiveActivity() {
        liveActivityManager.sync(
            profileID: activeProfile?.id.uuidString,
            hostDisplay: activeProfile?.hostDisplay ?? "",
            title: sessionTitle,
            subtitle: sessionSubtitle,
            statusText: statusText
        )
    }
}

struct SSHSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SSHSessionStore.self) private var sshSessionStore

    @State private var showDisconnectConfirm = false

    var body: some View {
        Group {
            if let profile = sshSessionStore.activeProfile {
                switch sshSessionStore.connection.state {
                case .connecting:
                    connectingView(profile: profile)
                case .connected, .disconnected:
                    terminalContent
                case .failed(let message):
                    failedView(message: message)
                }
            } else {
                missingSessionView
            }
        }
        .navigationTitle(sshSessionStore.sessionTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .alert("Disconnect?", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await sshSessionStore.disconnect()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current terminal session will be closed.")
        }
        .alert("New Host Fingerprint", isPresented: Binding(
            get: { sshSessionStore.pendingFingerprint != nil },
            set: { if !$0 { sshSessionStore.confirmFingerprint(accepted: false) } }
        )) {
            Button("Trust & Connect") {
                sshSessionStore.confirmFingerprint(accepted: true)
            }
            Button("Cancel", role: .cancel) {
                sshSessionStore.confirmFingerprint(accepted: false)
            }
        } message: {
            if let fp = sshSessionStore.pendingFingerprint {
                Text("The host is providing a fingerprint that hasn't been seen before:\n\n\(fp)\n\nDo you want to trust this host?")
            }
        }
        .task(id: sshSessionStore.activeProfile?.id) {
            await sshSessionStore.connectIfNeeded(modelContext: modelContext)
        }
        .onAppear {
            if sshSessionStore.connection.state == .connected {
                sshSessionStore.focusSession()
            }
        }
        .onDisappear {
            sshSessionStore.wantsKeyboard = false
        }
    }

    // MARK: - Sub-views

    private var terminalContent: some View {
        SwiftTermView(
            bridge: sshSessionStore.bridge,
            wantsKeyboard: sshSessionStore.wantsKeyboard,
            colorScheme: colorScheme
        )
        .padding(6)
        .background(terminalBackground)
    }

    private func connectingView(profile: SSHProfile) -> some View {
        ZStack {
            terminalBackground.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.green)
                    .controlSize(.large)
                Text(profile.hostDisplay)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var missingSessionView: some View {
        ContentUnavailableView {
            Label("No Active SSH Session", systemImage: "terminal")
        } description: {
            Text("Choose a saved host to start a terminal session.")
        }
    }

    private func failedView(message: String) -> some View {
        ZStack {
            terminalBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.red)
                }

                VStack(spacing: 6) {
                    Text("Connection Failed")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }

                Button {
                    Task { await sshSessionStore.reconnect(modelContext: modelContext) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 32)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button {
                showDisconnectConfirm = true
            } label: {
                Label("Disconnect", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .font(.system(size: 18))
            }
        }
    }

    private var terminalBackground: Color {
        .clear
    }
}
