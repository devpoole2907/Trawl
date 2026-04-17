import Foundation
import Network
import CSSH

// MARK: - Errors

enum SSHConnectionError: LocalizedError, Sendable {
    case authFailed
    case channelSetupFailed
    case notConnected
    case hostKeyMismatch(expected: String, got: String)
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
        case .hostKeyMismatch(let exp, let got):
            return """
            Host key mismatch — possible MITM attack!
            Expected : \(exp)
            Received : \(got)
            Remove the saved fingerprint in the profile settings to reconnect.
            """
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

    init(connection: NWConnection, receiveBuffer: SshReceiveBuffer) {
        self.connection = connection
        self.receiveBuffer = receiveBuffer
    }
}

// MARK: - C callbacks  (signatures must match LIBSSH2_SEND_FUNC / LIBSSH2_RECV_FUNC)

// ssize_t send(socket, const void *buffer, size_t length, int flags, void **abstract)
private let libssh2SendCallback: @convention(c) (
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
private let libssh2RecvCallback: @convention(c) (
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
    }

    // MARK: EAGAIN retry

    /// Called when new bytes arrive from NWConnection — wakes queued EAGAIN operations.
    func pingTasks() {
        guard !pendingTasks.isEmpty else { return }
        let waiting = pendingTasks
        pendingTasks.removeAll()
        for c in waiting { c.resume(returning: ()) }
    }

    /// Retries `block` until it stops returning LIBSSH2_ERROR_EAGAIN.
    private func callSsh(_ block: () -> Int32) async throws {
        while true {
            let rc = block()
            if rc == LIBSSH2_ERROR_EAGAIN {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    pendingTasks.append(cont)
                }
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

    func sendToChannel(_ data: Data) {
        guard let ch = channel else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let n = libssh2_channel_write_ex(ch, 0,
                    base.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                    remaining)
                if n > 0 { offset += n; remaining -= n } else { break }
            }
        }
    }

    /// Attempt to read available bytes. Returns nil when there's nothing ready.
    func readChannel() -> [UInt8]? {
        guard let ch = channel else { return nil }
        var buf = [UInt8](repeating: 0, count: 32768)
        let n = buf.withUnsafeMutableBytes { ptr in
            libssh2_channel_read_ex(ch, 0,
                ptr.baseAddress!.assumingMemoryBound(to: CChar.self), ptr.count)
        }
        if n > 0 { return Array(buf.prefix(n)) }
        return nil
    }

    var isChannelClosed: Bool {
        guard let ch = channel else { return true }
        return libssh2_channel_eof(ch) != 0
    }
}

// MARK: - SSHConnection

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
    var onNewFingerprint: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let sshActor = SshSessionActor()
    private var nwConnection: NWConnection?
    private let receiveBuffer = SshReceiveBuffer()
    private var readLoopTask: Task<Void, Never>?

    // MARK: Connect

    func connect(
        host: String,
        port: Int,
        username: String,
        auth: SSHAuth,
        knownFingerprint: String?
    ) async throws {
        transition(to: .connecting)

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 22
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.nwConnection = conn

        // Wait for the TCP connection to be ready
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    cont.resume()
                case .failed(let err):
                    cont.resume(throwing: SSHConnectionError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    cont.resume(throwing: SSHConnectionError.connectionFailed("Cancelled"))
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

        do {
            try await sshActor.handshake()

            // TOFU: validate or record host fingerprint
            let fp = try await sshActor.fingerprint()
            if let expected = knownFingerprint {
                guard fp == expected else {
                    throw SSHConnectionError.hostKeyMismatch(expected: expected, got: fp)
                }
            } else {
                let captured = fp
                DispatchQueue.main.async { self.onNewFingerprint?(captured) }
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
        Task { await sshActor.sendToChannel(data) }
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

    // MARK: Private: NWConnection receive loop

    private func startReceiving(_ conn: NWConnection) {
        func scheduleReceive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    Task { await self.sshActor.pingTasks() }
                }
                if isComplete || error != nil {
                    self.handleConnectionClose()
                    return
                }
                scheduleReceive()
            }
        }
        scheduleReceive()
    }

    // MARK: Private: Channel read loop

    private func startReadLoop() {
        readLoopTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let bytes = await self.sshActor.readChannel(), !bytes.isEmpty {
                    DispatchQueue.main.async { self.onOutput?(bytes) }
                } else if await self.sshActor.isChannelClosed {
                    self.handleConnectionClose()
                    return
                } else {
                    // Brief pause to avoid busy-spinning when no data is ready
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }
    }

    private func handleConnectionClose() {
        guard state == .connected else { return }
        transition(to: .disconnected)
        DispatchQueue.main.async { self.onClose?() }
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        DispatchQueue.main.async { self.onStateChange?(newState) }
    }
}
