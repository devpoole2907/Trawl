import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

// MARK: - SSHSessionItem

/// Encapsulates a single SSH session: one profile, one connection, one terminal bridge.
@MainActor
@Observable
final class SSHSessionItem: Identifiable {
    let id = UUID()
    let profile: SSHProfile
    let connection: SSHConnection
    let bridge: SSHTerminalBridge
    var titleOverride: String?
    var wantsKeyboard = false
    var pendingFingerprint: String?
    private var fingerprintContinuation: CheckedContinuation<Bool, Never>?

    var sessionTitle: String { titleOverride ?? profile.displayName }
    var sessionSubtitle: String { "\(profile.username)@\(profile.hostDisplay)" }

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

    init(profile: SSHProfile) {
        self.profile = profile
        self.connection = SSHConnection()
        self.bridge = SSHTerminalBridge()

        // Wire terminal bridge ↔ SSH connection
        bridge.sendToSSH = { [connection] data in connection.send(data) }
        bridge.onResize = { [connection] cols, rows in connection.resize(cols: cols, rows: rows) }
        bridge.onTitleChange = { [weak self] title in
            guard !title.isEmpty else { return }
            self?.titleOverride = title
        }
        bridge.onKeyboardVisibilityChange = { [weak self] isVisible in
            self?.wantsKeyboard = isVisible
        }
        connection.onOutput = { [bridge] bytes in bridge.receive(bytes: bytes) }
    }

    // MARK: - Session lifecycle

    func connectIfNeeded(modelContext: ModelContext) async {
        switch connection.state {
        case .connected:
            wantsKeyboard = true
            return
        case .connecting:
            return
        case .disconnected, .failed:
            break
        }
        await connect(modelContext: modelContext)
    }

    func reconnect(modelContext: ModelContext) async {
        confirmFingerprint(accepted: false)
        await connection.disconnect()
        titleOverride = nil
        wantsKeyboard = false
        await connect(modelContext: modelContext)
    }

    func disconnect() async {
        confirmFingerprint(accepted: false)
        bridge.hideKeyboard()
        await connection.disconnect()
        titleOverride = nil
        wantsKeyboard = false
    }

    func focusSession() { wantsKeyboard = true }

    func hideKeyboard() {
        wantsKeyboard = false
        bridge.hideKeyboard()
    }

    // MARK: - Fingerprint

    func presentFingerprintConfirmation(_ fingerprint: String) async -> Bool {
        if fingerprintContinuation != nil { confirmFingerprint(accepted: false) }
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

    // MARK: - Private connection logic

    private func connect(modelContext: ModelContext) async {
        titleOverride = nil
        wantsKeyboard = false

        connection.onNewFingerprint = { [weak self] fingerprint in
            guard let self else { return false }
            let accepted = await self.presentFingerprintConfirmation(fingerprint)
            if accepted {
                let previous = self.profile.knownHostFingerprint
                self.profile.knownHostFingerprint = fingerprint
                do {
                    try modelContext.save()
                } catch {
                    self.profile.knownHostFingerprint = previous
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
            wantsKeyboard = true
        } catch {
            connection.markFailed(error.localizedDescription)
        }
    }

    private func resolveAuth(for profile: SSHProfile) async throws -> SSHAuth {
        switch profile.authType {
        case .password:
            guard let password = try await KeychainHelper.shared.read(key: profile.passwordKey),
                  !password.isEmpty else {
                throw SSHCredentialError.missingPassword
            }
            return .password(password)
        case .privateKey:
            guard let key = try await KeychainHelper.shared.read(key: profile.privateKeyKey),
                  !key.isEmpty else {
                throw SSHCredentialError.missingPrivateKey
            }
            let passphrase = try await KeychainHelper.shared.read(key: profile.passphraseKey)
            return .privateKey(pem: key, passphrase: passphrase)
        }
    }
}

// MARK: - SSHSessionStore

@MainActor
@Observable
final class SSHSessionStore {
    private(set) var sessions: [SSHSessionItem] = []
    var activeSession: SSHSessionItem?
    private let liveActivityManager = SSHLiveActivityManager()

    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    // MARK: Computed properties for ContentView / MoreView accessory bar

    var hasSession: Bool { !sessions.isEmpty }

    var activeProfile: SSHProfile? { activeSession?.profile }

    var sessionTitle: String {
        sessions.count > 1 ? "\(sessions.count) Sessions" : (activeSession?.sessionTitle ?? "SSH")
    }

    var sessionSubtitle: String {
        if sessions.count > 1 {
            let connected = sessions.filter { $0.connection.state == .connected }.count
            return "\(connected) connected"
        }
        return activeSession?.sessionSubtitle ?? "No Active Session"
    }

    var statusText: String {
        sessions.count > 1 ? "Active" : (activeSession?.statusText ?? "Disconnected")
    }

    var statusColor: Color {
        sessions.count > 1 ? .green : (activeSession?.statusColor ?? .secondary)
    }

    var wantsKeyboard: Bool {
        get { activeSession?.wantsKeyboard ?? false }
        set { activeSession?.wantsKeyboard = newValue }
    }

    // MARK: Session management

    @discardableResult
    func addSession(for profile: SSHProfile) -> SSHSessionItem {
        // Reuse an existing session for the same profile
        if let existing = sessions.first(where: { $0.profile.id == profile.id }) {
            activeSession = existing
            return existing
        }
        let item = SSHSessionItem(profile: profile)
        item.connection.onClose = { [weak self, weak item] in
            item?.wantsKeyboard = false
            self?.syncLiveActivity()
        }
        item.connection.onStateChange = { [weak self, weak item] newState in
            guard let self else { return }
            self.syncLiveActivity()
            #if os(iOS)
            switch newState {
            case .connected:
                if let item { SSHBackgroundService.shared.register(id: item.id, connection: item.connection) }
                self.updateBackgroundService()
            case .disconnected, .failed:
                if let item { SSHBackgroundService.shared.unregister(id: item.id) }
            case .connecting:
                break
            }
            #endif
        }
        sessions.append(item)
        activeSession = item
        syncLiveActivity()
        return item
    }

    func closeSession(_ item: SSHSessionItem) async {
        sessions.removeAll { $0.id == item.id }
        if activeSession?.id == item.id {
            activeSession = sessions.last
        }
        syncLiveActivity()
        await item.disconnect()
    }

    /// Closes all sessions. Called from the main disconnect button.
    func disconnect() async {
        let itemsToDisconnect = sessions
        sessions.removeAll()
        activeSession = nil
        syncLiveActivity()
        for item in itemsToDisconnect {
            await item.disconnect()
        }
    }

    func focusSession() { activeSession?.focusSession() }

    func hideKeyboard() {
        activeSession?.hideKeyboard()
        for item in sessions where item.id != activeSession?.id {
            item.hideKeyboard()
        }
    }

    // MARK: - Background task keep-alive

    #if os(iOS)
    func beginBackgroundKeepAlive() {
        guard backgroundTaskID == .invalid,
              sessions.contains(where: { $0.connection.state == .connected }) else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SSHKeepAlive") { [weak self] in
            self?.endBackgroundKeepAlive()
        }
    }

    func endBackgroundKeepAlive() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func updateBackgroundService() {
        SSHBackgroundService.shared.setLiveActivitySync { [weak self] in
            self?.syncLiveActivity()
        }
    }
    #endif

    // MARK: - Live Activity

    func syncLiveActivity() {
        guard let rep = activeSession ?? sessions.first else {
            liveActivityManager.sync(
                sessionCount: 0,
                profileID: nil,
                hostDisplay: "",
                title: "SSH",
                subtitle: "No Active Session",
                statusText: "Disconnected"
            )
            return
        }
        liveActivityManager.sync(
            sessionCount: sessions.count,
            profileID: rep.profile.id.uuidString,
            hostDisplay: rep.profile.hostDisplay,
            title: sessionTitle,
            subtitle: sessionSubtitle,
            statusText: statusText
        )
    }
}

// MARK: - SSHSessionContainerView

/// Top-level view shown in the SSH sheet. Shows a session tab strip when > 1 session.
struct SSHSessionContainerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SSHSessionStore.self) private var store

    @State private var showDisconnectAllConfirm = false
    @State private var showingAddSession = false

    var body: some View {
        VStack(spacing: 0) {
            if let session = store.activeSession {
                SSHSessionView(session: session)
                    .id(session.id)
            } else {
                missingSessionView
            }
        }
        .navigationTitle(store.activeSession?.sessionTitle ?? "SSH")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarTitleMenu {
            ForEach(store.sessions) { session in
                Button {
                    store.activeSession = session
                } label: {
                    Text(session.sessionTitle)
                    if store.activeSession?.id == session.id {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            Button {
                showingAddSession = true
            } label: {
                Label("Add Session", systemImage: "plus")
            }
            if let activeSession = store.activeSession {
                Button(role: .destructive) {
                    Task { await store.closeSession(activeSession) }
                } label: {
                    Label("Close Session", systemImage: "xmark")
                }
            }
        }
        .toolbar { toolbarContent }
        .alert("Close All Sessions?", isPresented: $showDisconnectAllConfirm) {
            Button("Close All", role: .destructive) {
                Task {
                    await store.disconnect()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(store.sessions.count) terminal sessions will be closed.")
        }
        .sheet(isPresented: $showingAddSession) {
            NavigationStack {
                SSHProfileListView { profile in
                    store.addSession(for: profile)
                    showingAddSession = false
                }
            }
            .presentationDetents([.large])
            .presentationCornerRadius(24)
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                store.beginBackgroundKeepAlive()
            case .active:
                store.endBackgroundKeepAlive()
                if !store.sessions.isEmpty {
                    Task {
                        for session in store.sessions {
                            await session.connectIfNeeded(modelContext: modelContext)
                        }
                    }
                }
            default:
                break
            }
        }
        #endif
        .onChange(of: store.sessions.count) { _, count in
            if count == 0 { dismiss() }
        }
    }

    // MARK: Empty state

    private var missingSessionView: some View {
        ContentUnavailableView {
            Label("No Active SSH Session", systemImage: "terminal")
        } description: {
            Text("Choose a saved host to start a terminal session.")
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            if store.sessions.count > 1 {
                Button {
                    showDisconnectAllConfirm = true
                } label: {
                    Label("Close All", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                        .font(.system(size: 18))
                }
            } else {
                Button {
                    Task {
                        await store.disconnect()
                        dismiss()
                    }
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.red)
                        .font(.system(size: 18))
                }
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            if store.sessions.count == 1 {
                Button {
                    showingAddSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .foregroundStyle(.green)
            }
        }
    }
}

// MARK: - SSHSessionView (per-session terminal)

struct SSHSessionView: View {
    let session: SSHSessionItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SSHSessionStore.self) private var store

    var body: some View {
        Group {
            switch session.connection.state {
            case .connecting:
                connectingView
            case .connected, .disconnected:
                terminalContent
            case .failed(let message):
                failedView(message: message)
            }
        }
        .alert("New Host Fingerprint", isPresented: Binding(
            get: { session.pendingFingerprint != nil },
            set: { if !$0 { session.confirmFingerprint(accepted: false) } }
        )) {
            Button("Trust & Connect") { session.confirmFingerprint(accepted: true) }
            Button("Cancel", role: .cancel) { session.confirmFingerprint(accepted: false) }
        } message: {
            if let fp = session.pendingFingerprint {
                Text("The host is presenting a fingerprint that hasn't been seen before:\n\n\(fp)\n\nDo you want to trust this host?")
            }
        }
        .task(id: session.id) {
            await session.connectIfNeeded(modelContext: modelContext)
        }
        .onAppear {
            if session.connection.state == .connected {
                session.focusSession()
            }
        }
        .onDisappear {
            session.wantsKeyboard = false
        }
    }

    // MARK: Sub-views

    private var terminalContent: some View {
        SwiftTermView(
            bridge: session.bridge,
            wantsKeyboard: session.wantsKeyboard,
            colorScheme: colorScheme
        )
        .padding(6)
    }

    private var connectingView: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.green)
                    .controlSize(.large)
                Text(session.profile.hostDisplay)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func failedView(message: String) -> some View {
        ZStack {
            Color.clear.ignoresSafeArea()
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
                    Task { await session.reconnect(modelContext: modelContext) }
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
}
