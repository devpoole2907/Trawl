import Foundation
import Network
@testable import Trawl

/// A loopback HTTP/1.1 server shared by the Jellyfin stateful-logic suites
/// (`JellyfinAvailabilityResolverTests`, `JellyfinServiceManagerTests`,
/// `JellyfinSetupViewModelTests`).
///
/// `JellyfinAPIClient.init` builds its own `URLSessionConfiguration.ephemeral`
/// and exposes no session seam, so a `URLProtocol` stub cannot be injected. A
/// real socket is therefore the only way to drive the production request path —
/// `JellyfinAPIClient` → `JellyfinAuthHeader` → `HTTPTransport` → `JSONDecoder`
/// → `HTTPErrorMapper` — with controlled payloads.
///
/// This is a deliberate copy of `JellyfinContractTests`' private
/// `JellyfinContractServer` (that type is file-private and cannot be shared),
/// extended with three things those contract tests do not need:
///
/// * per-path/per-query routing plus a per-path request counter, so a test can
///   prove how many times each tier of the availability lookup was hit;
/// * `releaseParked(_:)`, which answers connections the handler parked, so a
///   test can let a request that was in flight during `invalidate` complete;
/// * `waitForClosedConnections(_:)`, which resumes when the *client* tears a
///   parked connection down — the observable proof that a `Task.cancel()`
///   really reached the socket, with no sleeping or polling involved.
///
/// Nothing here uses time-based synchronisation: every barrier is a
/// `CheckedContinuation` resumed from the server's own connection callbacks.
nonisolated struct JellyfinFixtureRequest: Sendable, Equatable {
    let method: String
    let path: String
    /// The query exactly as it arrived, still percent-encoded.
    let rawQuery: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: String

    var authorization: String? { headers["authorization"] }

    var queryItems: [URLQueryItem] {
        guard !rawQuery.isEmpty else { return [] }
        return URLComponents(string: "http://jellyfin.fixture.test\(path)?\(rawQuery)")?.queryItems ?? []
    }

    func queryValue(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    /// The still-encoded value for a query key, for asserting percent-encoding.
    func rawQueryValue(named name: String) -> String? {
        for pair in rawQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == name else { continue }
            return parts.count > 1 ? String(parts[1]) : ""
        }
        return nil
    }

    func jsonDictionary() -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return raw as? [String: Any]
    }
}

nonisolated struct JellyfinFixtureResponse: Sendable {
    let status: Int
    let body: Data
    let contentType: String

    static func json(_ string: String, status: Int = 200) -> JellyfinFixtureResponse {
        JellyfinFixtureResponse(status: status, body: Data(string.utf8), contentType: "application/json")
    }

    static let noContent = JellyfinFixtureResponse(status: 204, body: Data(), contentType: "application/json")
}

nonisolated final class JellyfinFixtureServer: @unchecked Sendable {
    typealias Handler = @Sendable (JellyfinFixtureRequest) -> JellyfinFixtureResponse?

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler

    private let lock = NSLock()
    private var recorded: [JellyfinFixtureRequest] = []
    private var servedCount = 0
    private var closedCount = 0
    private var parkedConnections: [NWConnection] = []
    private var receivedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var servedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var closedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(label: String, handler: @escaping Handler) async throws {
        self.queue = DispatchQueue(label: "JellyfinFixtureServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else {
            fatalError("Jellyfin fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [JellyfinFixtureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// How many recorded requests targeted `path`.
    func requestCount(path: String) -> Int {
        requests.filter { $0.path == path }.count
    }

    func stop() {
        lock.lock()
        let parked = parkedConnections
        parkedConnections = []
        let pendingReceived = receivedWaiters
        let pendingServed = servedWaiters
        let pendingClosed = closedWaiters
        receivedWaiters = []
        servedWaiters = []
        closedWaiters = []
        lock.unlock()

        for connection in parked { connection.cancel() }
        for waiter in pendingReceived { waiter.continuation.resume() }
        for waiter in pendingServed { waiter.continuation.resume() }
        for waiter in pendingClosed { waiter.continuation.resume() }
        listener.cancel()
    }

    /// Answers every connection the handler parked with `response`.
    func releaseParked(with response: JellyfinFixtureResponse) {
        lock.lock()
        let parked = parkedConnections
        parkedConnections = []
        lock.unlock()

        for connection in parked {
            connection.send(
                content: Self.encode(response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.recordServed()
                    connection.cancel()
                }
            )
        }
    }

    /// Resumes once `count` requests have arrived, whether or not they were answered.
    func waitForReceivedRequests(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if recorded.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            receivedWaiters.append((threshold: count, continuation: continuation))
            lock.unlock()
        }
    }

    /// Resumes once `count` responses have been written back to their clients.
    func waitForServedResponses(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if servedCount >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            servedWaiters.append((threshold: count, continuation: continuation))
            lock.unlock()
        }
    }

    /// Resumes once `count` parked connections have been closed *by the client*
    /// (EOF or a read error on a connection this server never answered). That
    /// only happens when `URLSession` tears the request down, which in turn only
    /// happens when the owning `Task` is cancelled — so this is a real, non-timing
    /// barrier proving cancellation propagated all the way to the socket.
    func waitForClosedConnections(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if closedCount >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            closedWaiters.append((threshold: count, continuation: continuation))
            lock.unlock()
        }
    }

    // MARK: - Connection handling

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let request = Self.parse(accumulated) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
                return
            }

            self.recordReceived(request)

            guard let response = self.handler(request) else {
                self.park(connection)
                return
            }

            connection.send(
                content: Self.encode(response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.recordServed()
                    connection.cancel()
                }
            )
        }
    }

    /// Holds a connection open without answering it, and keeps a read pending so
    /// a client-side teardown is observable as a close event.
    private func park(_ connection: NWConnection) {
        lock.lock()
        parkedConnections.append(connection)
        lock.unlock()

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            guard isComplete || error != nil else { return }
            self.lock.lock()
            self.parkedConnections.removeAll { $0 === connection }
            self.lock.unlock()
            self.recordClosed()
        }
    }

    private func recordReceived(_ request: JellyfinFixtureRequest) {
        lock.lock()
        recorded.append(request)
        let count = recorded.count
        let ready = receivedWaiters.filter { $0.threshold <= count }
        receivedWaiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    private func recordServed() {
        lock.lock()
        servedCount += 1
        let count = servedCount
        let ready = servedWaiters.filter { $0.threshold <= count }
        servedWaiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    private func recordClosed() {
        lock.lock()
        closedCount += 1
        let count = closedCount
        let ready = closedWaiters.filter { $0.threshold <= count }
        closedWaiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    // MARK: - HTTP framing

    /// Returns nil until the buffer holds a complete request head plus its
    /// declared `Content-Length` body.
    private static func parse(_ buffer: Data) -> JellyfinFixtureRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyBytes = Data(buffer[separator.upperBound...])
        guard bodyBytes.count >= contentLength else { return nil }
        let body = String(data: bodyBytes.prefix(contentLength), encoding: .utf8) ?? ""

        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return JellyfinFixtureRequest(
            method: String(parts[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count > 1 ? String(targetParts[1]) : "",
            headers: headers,
            body: body
        )
    }

    private static func encode(_ response: JellyfinFixtureResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

// MARK: - Resolver settling helpers

nonisolated enum JellyfinFixtureFailure: Error {
    case lookupFailed(String)
    case neverSettled
}

/// Reads the resolver's settled availability state.
///
/// `ensureLoaded` fires an unstructured `Task` with no completion hook, so
/// ordering is owned by the server barrier the caller already awaited (e.g.
/// `waitForServedResponses`); this only lets the main actor drain the resolver's
/// final continuation. It yields rather than sleeping, has no timing dependency,
/// and exits the instant the state stops being `.loading`. Mirrors the helper
/// `JellyfinContractTests` already uses for the same reason.
@MainActor
func jellyfinSettledItems(
    _ resolver: JellyfinAvailabilityResolver,
    key: JellyfinAvailabilityResolver.Key
) async throws -> [JellyfinLibraryItem] {
    for _ in 0..<2_000_000 {
        switch resolver.state(for: key) {
        case .resolved(let items): return items
        case .failed(let message): throw JellyfinFixtureFailure.lookupFailed(message)
        case .idle, .loading: await Task.yield()
        }
    }
    throw JellyfinFixtureFailure.neverSettled
}

/// As `jellyfinSettledItems`, but resolves once the state is anything other than
/// `.loading` — used by tests that expect a failure.
@MainActor
func jellyfinSettledState(
    _ resolver: JellyfinAvailabilityResolver,
    key: JellyfinAvailabilityResolver.Key
) async throws -> JellyfinAvailabilityResolver.State {
    for _ in 0..<2_000_000 {
        let state = resolver.state(for: key)
        if case .loading = state {
            await Task.yield()
            continue
        }
        return state
    }
    throw JellyfinFixtureFailure.neverSettled
}

@MainActor
func jellyfinSettledEpisodeState(
    _ resolver: JellyfinAvailabilityResolver,
    key: JellyfinAvailabilityResolver.EpisodesKey
) async throws -> JellyfinAvailabilityResolver.State {
    for _ in 0..<2_000_000 {
        let state = resolver.episodesState(for: key)
        if case .loading = state {
            await Task.yield()
            continue
        }
        return state
    }
    throw JellyfinFixtureFailure.neverSettled
}
