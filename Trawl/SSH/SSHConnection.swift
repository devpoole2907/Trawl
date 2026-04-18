import Foundation
import Network
import CSSH

// MARK: - Errors

enum SSHConnectionError: LocalizedError, Sendable {
    case authFailed
    case channelSetupFailed
    case notConnected
    case disconnectedOrTeardown
    case hostKeyMismatch(expected: String, got: String)
    case hostKeyUnverified
    case keyParseFailure
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .authFailed:
            return "Authentication failed. Check your username and credentials."
        case .channelSetupFailed:
            return "Failed to open a shell channel on the server."
        case .notConnected:
            return "Not connected."
        case .disconnectedOrTeardown:
            return "SSH session disconnected while an operation was waiting for network readiness."
        case .hostKeyMismatch(let exp, let got):
            return """
            Host key mismatch — possible MITM attack!
            Expected : \(exp)
            Received : \(got)
            Remove the saved fingerprint in the profile settings to reconnect.
            """
        case .hostKeyUnverified:
            return "Host key was not trusted."
        case .keyParseFailure:
            return "Could not parse the private key."
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        }
    }
}

// MARK: - Auth value type

enum SSHAuth: Sendable {
    case password(String)
    case privateKey(pem: String, passphrase: String?)
}

// MARK: - Thread-safe receive buffer

/// NWConnection fills this; libssh2's recv callback drains it synchronously.
private final class SshReceiveBuffer: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
    }

    /// Copy up to `maxLength` bytes into `ptr`. Returns bytes copied, or -EAGAIN when empty.
    func read(into ptr: UnsafeMutableRawPointer, maxLength: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return -Int(EAGAIN) }
        let n = min(maxLength, buffer.count)
        buffer.withUnsafeBytes { src in
            ptr.copyMemory(from: src.baseAddress!, byteCount: n)
        }
        buffer.removeFirst(n)
        return n
    }
}

// MARK: - Session context (passed as libssh2 "abstract" pointer)

private final class SshSessionContext: @unchecked Sendable {
    let connection: NWConnection
    let receiveBuffer: SshReceiveBuffer

    nonisolated
    init(connection: NWConnection, receiveBuffer: SshReceiveBuffer) {
        self.connection = connection
        self.receiveBuffer = receiveBuffer
    }
}

private final class ContinuationResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didResume = false

    nonisolated
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

// MARK: - C callbacks  (signatures must match LIBSSH2_SEND_FUNC / LIBSSH2_RECV_FUNC)

// ssize_t send(socket, const void *buffer, size_t length, int flags, void **abstract)
nonisolated(unsafe) private let libssh2SendCallback: @convention(c) (
    libssh2_socket_t,
    UnsafeRawPointer,
    Int,
    Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int = { _, buffer, length, _, abstract in
    guard let abstract else { return -1 }
    let ctx = Unmanaged<SshSessionContext>
        .fromOpaque(abstract.pointee!)
        .takeUnretainedValue()
    let data = Data(bytes: buffer, count: length)
    ctx.connection.send(content: data, completion: .idempotent)
    return length  // NWConnection queues sends; report success optimistically
}

// ssize_t recv(socket, void *buffer, size_t length, int flags, void **abstract)
nonisolated(unsafe) private let libssh2RecvCallback: @convention(c) (
    libssh2_socket_t,
    UnsafeMutableRawPointer,
    Int,
    Int32,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int = { _, buffer, length, _, abstract in
    guard let abstract else { return -1 }
    let ctx = Unmanaged<SshSessionContext>
        .fromOpaque(abstract.pointee!)
        .takeUnretainedValue()
    return ctx.receiveBuffer.read(into: buffer, maxLength: length)
}

// MARK: - Session actor

/// Serialises all libssh2 C API calls onto a single actor.
private actor SshSessionActor {
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var contextRef: Unmanaged<SshSessionContext>?

    // Pending continuations waiting for new bytes to arrive (EAGAIN)
    private var pendingTasks: [CheckedContinuation<Void, Error>] = []

    // MARK: Setup / Teardown

    func setup(connection: NWConnection, receiveBuffer: SshReceiveBuffer) throws {
        let ctx = SshSessionContext(connection: connection, receiveBuffer: receiveBuffer)
        let ref = Unmanaged.passRetained(ctx)
        self.contextRef = ref

        // Pass the context as the abstract pointer so callbacks can recover it
        guard let sess = libssh2_session_init_ex(nil, nil, nil, ref.toOpaque()) else {
            throw SSHConnectionError.connectionFailed("libssh2_session_init failed")
        }
        self.session = sess
        libssh2_session_set_blocking(sess, 0)

        // Register transport callbacks
        _ = libssh2_session_callback_set(sess, LIBSSH2_CALLBACK_SEND,
            unsafeBitCast(libssh2SendCallback, to: UnsafeMutableRawPointer.self))
        _ = libssh2_session_callback_set(sess, LIBSSH2_CALLBACK_RECV,
            unsafeBitCast(libssh2RecvCallback, to: UnsafeMutableRawPointer.self))
    }

    func teardown() {
        let waiting = pendingTasks
        pendingTasks.removeAll()
        if let ch = channel {
            libssh2_channel_close(ch)
            libssh2_channel_free(ch)
        }
        if let sess = session {
            libssh2_session_disconnect_ex(sess, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(sess)
        }
        channel = nil
        session = nil
        contextRef?.release()
        contextRef = nil
        for continuation in waiting {
            continuation.resume(throwing: SSHConnectionError.disconnectedOrTeardown)
        }
    }

    // MARK: EAGAIN retry

    /// Called when new bytes arrive from NWConnection — wakes queued EAGAIN operations.
    func pingTasks() {
        guard !pendingTasks.isEmpty else { return }
        let waiting = pendingTasks
        pendingTasks.removeAll()
        for c in waiting { c.resume(returning: ()) }
    }

    private func waitForRetry() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingTasks.append(cont)
        }
    }

    /// Retries `block` until it stops returning LIBSSH2_ERROR_EAGAIN.
    private func callSsh(_ block: () -> Int32) async throws {
        while true {
            let rc = block()
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await waitForRetry()
            } else if rc < 0 {
                throw SSHConnectionError.connectionFailed("libssh2 error \(rc)")
            } else {
                return
            }
        }
    }

    // MARK: Handshake

    func handshake() async throws {
        guard let sess = session else { throw SSHConnectionError.notConnected }
        try await callSsh { libssh2_session_handshake(sess, 0) }
    }

    // MARK: Fingerprint (TOFU)

    func fingerprint() throws -> String {
        guard let sess = session else { throw SSHConnectionError.notConnected }
        guard let raw = libssh2_hostkey_hash(sess, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            throw SSHConnectionError.connectionFailed("Could not get host key hash")
        }
        let bytes = (0..<32).map { UInt8(bitPattern: raw.advanced(by: $0).pointee) }
        return "SHA256:" + Data(bytes).base64EncodedString()
    }

    // MARK: Auth

    func authPassword(username: String, password: String) async throws {
        guard let sess = session else { throw SSHConnectionError.notConnected }
        try await callSsh {
            libssh2_userauth_password_ex(sess,
                username, UInt32(username.utf8.count),
                password, UInt32(password.utf8.count), nil)
        }
        if libssh2_userauth_authenticated(sess) == 0 {
            throw SSHConnectionError.authFailed
        }
    }

    func authPublicKey(username: String, privateKeyPEM: String, passphrase: String?) async throws {
        guard let sess = session else { throw SSHConnectionError.notConnected }
        let pass = passphrase ?? ""
        try await callSsh {
            libssh2_userauth_publickey_frommemory(sess,
                username, username.utf8.count,
                nil, 0,
                privateKeyPEM, privateKeyPEM.utf8.count,
                pass.isEmpty ? nil : pass)
        }
        if libssh2_userauth_authenticated(sess) == 0 {
            throw SSHConnectionError.authFailed
        }
    }

    // MARK: Channel / PTY / Shell

    func openChannel() async throws {
        guard let sess = session else { throw SSHConnectionError.notConnected }
        var ch: OpaquePointer?
        try await callSsh {
            ch = libssh2_channel_open_ex(sess, "session", 7, 2 * 1024 * 1024, 32768, nil, 0)
            return ch != nil ? 0 : Int32(libssh2_session_last_errno(sess))
        }
        guard let ch else { throw SSHConnectionError.channelSetupFailed }
        self.channel = ch
    }

    func requestPTY(cols: Int, rows: Int) async throws {
        guard let ch = channel else { throw SSHConnectionError.channelSetupFailed }
        let term = "xterm-256color"
        try await callSsh {
            libssh2_channel_request_pty_ex(ch,
                term, UInt32(term.utf8.count),
                nil, 0,
                Int32(cols), Int32(rows), 0, 0)
        }
    }

    func requestShell() async throws {
        guard let ch = channel else { throw SSHConnectionError.channelSetupFailed }
        try await callSsh {
            libssh2_channel_process_startup(ch, "shell", 5, nil, 0)
        }
    }

    func resizePTY(cols: Int, rows: Int) {
        guard let ch = channel else { return }
        libssh2_channel_request_pty_size_ex(ch, Int32(cols), Int32(rows), 0, 0)
    }

    func sendToChannel(_ data: Data) async throws {
        guard let ch = channel else { return }
        let bytes = [UInt8](data)
        var remaining = bytes.count
        var offset = 0
        while remaining > 0 {
            let n = bytes.withUnsafeBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return libssh2_channel_write_ex(
                    ch,
                    0,
                    UnsafeRawPointer(base).advanced(by: offset).assumingMemoryBound(to: CChar.self),
                    remaining
                )
            }
            if n > 0 {
                offset += n
                remaining -= n
            } else if Int32(n) == LIBSSH2_ERROR_EAGAIN {
                try await waitForRetry()
            } else if n < 0 {
                throw lastErrorDetails()
            } else {
                throw SSHConnectionError.connectionFailed("SSH channel write returned 0 before all bytes were sent.")
            }
        }
    }

    /// Attempt to read available bytes. Returns nil when there's nothing ready.
    func readChannel() throws -> [UInt8]? {
        guard let ch = channel else { return nil }
        var buf = [UInt8](repeating: 0, count: 32768)
        let n = buf.withUnsafeMutableBytes { ptr in
            libssh2_channel_read_ex(ch, 0,
                ptr.baseAddress!.assumingMemoryBound(to: CChar.self), ptr.count)
        }
        if n > 0 { return Array(buf.prefix(n)) }
        if Int32(n) == LIBSSH2_ERROR_EAGAIN { return nil }
        if n < 0 { throw lastErrorDetails() }
        return nil
    }

    var isChannelClosed: Bool {
        guard let ch = channel else { return true }
        return libssh2_channel_eof(ch) != 0
    }

    private func lastErrorDetails() -> SSHConnectionError {
        if let session {
            var messagePointer: UnsafeMutablePointer<Int8>?
            var messageLength: Int32 = 0
            let sessionError = libssh2_session_last_error(session, &messagePointer, &messageLength, 0)
            if sessionError < 0, let messagePointer {
                let message = String(cString: messagePointer)
                if !message.isEmpty {
                    return .connectionFailed(message)
                }
            }
            let errno = libssh2_session_last_errno(session)
            return .connectionFailed("libssh2 error \(errno)")
        }

        return .notConnected
    }
}

// MARK: - SSHConnection

@MainActor
@Observable
final class SSHConnection: @unchecked Sendable {

    enum State: Equatable {
        case disconnected, connecting, connected
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected), (.connecting, .connecting), (.connected, .connected):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private(set) var state: State = .disconnected

    var onOutput: (([UInt8]) -> Void)?
    var onClose: (() -> Void)?
    var onNewFingerprint: ((String) async -> Bool)?
    var onStateChange: ((State) -> Void)?

    private let sshActor = SshSessionActor()
    private var nwConnection: NWConnection?
    private let receiveBuffer = SshReceiveBuffer()
    private var readLoopTask: Task<Void, Never>?
    private let transportCloseLock = NSLock()
    private var isHandlingTransportClose = false

    // MARK: Connect

    func connect(
        host: String,
        port: Int,
        username: String,
        auth: SSHAuth,
        knownFingerprint: String?
    ) async throws {
        resetTransportCloseGuard()
        transition(to: .connecting)

        // Validate port is within valid range before casting to UInt16
        let validatedPort: UInt16
        if port >= 1 && port <= 65535 {
            validatedPort = UInt16(port)
        } else {
            validatedPort = 22  // Use default port if invalid
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: validatedPort) ?? 22
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.nwConnection = conn

        do {
            // Wait for the TCP connection to be ready
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumeGate = ContinuationResumeGate()

                @Sendable func resumeOnce(with result: Result<Void, Error>) {
                    guard resumeGate.tryResume() else {
                        return
                    }
                    conn.stateUpdateHandler = nil

                    switch result {
                    case .success:
                        cont.resume()
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }

                conn.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        resumeOnce(with: .success(()))
                    case .failed(let err):
                        resumeOnce(with: .failure(SSHConnectionError.connectionFailed(err.localizedDescription)))
                    case .cancelled:
                        resumeOnce(with: .failure(SSHConnectionError.connectionFailed("Cancelled")))
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
            }
            conn.stateUpdateHandler = nil

            // Start filling the receive buffer from the network
            startReceiving(conn)

            // Initialise libssh2 session
            try await sshActor.setup(connection: conn, receiveBuffer: receiveBuffer)
        } catch {
            conn.stateUpdateHandler = nil
            transition(to: .failed(error.localizedDescription))
            conn.cancel()
            nwConnection = nil
            throw error
        }

        do {
            try await sshActor.handshake()

            // TOFU: validate or record host fingerprint
            let fp = try await sshActor.fingerprint()
            if let expected = knownFingerprint {
                guard fp == expected else {
                    throw SSHConnectionError.hostKeyMismatch(expected: expected, got: fp)
                }
            } else {
                let accepted = await onNewFingerprint?(fp) ?? false
                if !accepted {
                    throw SSHConnectionError.hostKeyUnverified
                }
            }

            // Authenticate
            switch auth {
            case .password(let pw):
                try await sshActor.authPassword(username: username, password: pw)
            case .privateKey(let pem, let passphrase):
                try await sshActor.authPublicKey(username: username, privateKeyPEM: pem, passphrase: passphrase)
            }

            // Open interactive shell
            try await sshActor.openChannel()
            try await sshActor.requestPTY(cols: 80, rows: 24)
            try await sshActor.requestShell()

            transition(to: .connected)
            startReadLoop()
        } catch {
            transition(to: .failed(error.localizedDescription))
            await sshActor.teardown()
            conn.cancel()
            throw error
        }
    }

    // MARK: Send / Resize / Disconnect

    func send(_ data: Data) {
        Task { try? await sshActor.sendToChannel(data) }
    }

    func resize(cols: Int, rows: Int) {
        Task { await sshActor.resizePTY(cols: cols, rows: rows) }
    }

    func disconnect() {
        readLoopTask?.cancel()
        readLoopTask = nil
        nwConnection?.cancel()
        nwConnection = nil
        Task { await sshActor.teardown() }
        transition(to: .disconnected)
    }

    func markFailed(_ message: String) {
        transition(to: .failed(message))
    }

    // MARK: Private: NWConnection receive loop

    private nonisolated func startReceiving(_ conn: NWConnection) {
        func scheduleReceive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    Task { await self.sshActor.pingTasks() }
                }
                if isComplete || error != nil {
                    let message = error?.localizedDescription ?? (isComplete ? "Connection closed" : nil)
                    Task { await self.handleTransportClosed(for: conn, error: message) }
                    return
                }
                scheduleReceive()
            }
        }
        scheduleReceive()
    }

    // MARK: Private: Channel read loop

    private func startReadLoop() {
        guard let conn = nwConnection else { return }
        readLoopTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let bytes = try await self.sshActor.readChannel(), !bytes.isEmpty {
                        await MainActor.run { self.onOutput?(bytes) }
                    } else if await self.sshActor.isChannelClosed {
                        await self.handleTransportClosed(for: conn, error: nil)
                        return
                    } else {
                        // Brief pause to avoid busy-spinning when no data is ready
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                } catch {
                    await self.handleTransportClosed(for: conn, error: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handleConnectionClose() {
        guard let conn = nwConnection else { return }
        Task { await handleTransportClosed(for: conn, error: nil) }
    }

    private func shouldHandleTransportClose() -> Bool {
        transportCloseLock.lock()
        defer { transportCloseLock.unlock() }
        guard !isHandlingTransportClose else { return false }
        isHandlingTransportClose = true
        return true
    }

    private func resetTransportCloseGuard() {
        transportCloseLock.lock()
        isHandlingTransportClose = false
        transportCloseLock.unlock()
    }

    private func handleTransportClosed(for conn: NWConnection, error: String?) async {
        // Guard against stale/old connections
        guard nwConnection === conn else { return }
        guard shouldHandleTransportClose() else { return }

        readLoopTask?.cancel()
        readLoopTask = nil

        let wasConnected = state == .connected
        let failureMessage = error ?? (wasConnected ? nil : "Connection closed")

        nwConnection?.cancel()
        nwConnection = nil
        await sshActor.teardown()

        if let failureMessage {
            transition(to: .failed(failureMessage))
        } else {
            transition(to: .disconnected)
        }

        onClose?()
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}