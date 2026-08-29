import Foundation
import Network
@testable import Trawl

/// A loopback HTTP/1.1 server for the Prowlarr view-model suites.
///
/// `ProwlarrAPIClient.init(baseURL:apiKey:allowsUntrustedTLS:)` builds its own
/// `ArrAPIClient` → `HTTPTransport` → `URLSession(configuration: .ephemeral)`
/// chain and exposes no session seam, so a `URLProtocol` stub cannot be
/// injected. A real socket is therefore the only way to exercise the production
/// request path - `ProwlarrViewModel` → `ProwlarrAPIClient` → `ArrAPIClient` →
/// `HTTPTransport` → `JSONEncoder`/`JSONDecoder` → `HTTPErrorMapper` → `ArrError`
/// - end to end, and the only way to assert on the bytes a mutation actually put
/// on the wire.
///
/// This is a deliberate copy of the pattern in `JellyfinFixtureServer` (and of
/// `ArrClientLifecycleTests`' file-private `LifecycleArrTestServer`, which
/// cannot be shared), specialised for Prowlarr and extended with a per-path
/// request waiter so a test can block until a specific endpoint has been hit.
///
/// Nothing here uses time-based synchronisation: every barrier is a
/// `CheckedContinuation` resumed from the server's own connection callbacks.
nonisolated struct ProwlarrFixtureRequest: Sendable, Equatable {
    let method: String
    let path: String
    /// The query exactly as it arrived, still percent-encoded.
    let rawQuery: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: String

    var apiKey: String? { headers["x-api-key"] }

    var queryItems: [URLQueryItem] {
        guard !rawQuery.isEmpty else { return [] }
        return URLComponents(string: "http://prowlarr.fixture.test\(path)?\(rawQuery)")?.queryItems ?? []
    }

    func queryValue(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    /// Every value for a repeated query key, in arrival order. Prowlarr's search
    /// endpoint repeats `indexerIds` once per selected indexer.
    func queryValues(_ name: String) -> [String] {
        queryItems.filter { $0.name == name }.compactMap(\.value)
    }

    /// The request body parsed as a JSON object.
    ///
    /// Bodies are always compared as parsed JSON, never as `JSONEncoder` bytes:
    /// key order in encoder output is unstable, so a byte comparison passes once
    /// and then fails for no reason.
    func jsonObject() -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return raw as? [String: Any]
    }
}

nonisolated struct ProwlarrFixtureResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ string: String, status: Int = 200) -> ProwlarrFixtureResponse {
        ProwlarrFixtureResponse(status: status, body: Data(string.utf8))
    }

    /// A Prowlarr-shaped failure. `ArrError.serverError` renders the `message`
    /// field of the payload into the string the view models store.
    static func failure(status: Int, message: String) -> ProwlarrFixtureResponse {
        .json(#"{"message":"\#(message)"}"#, status: status)
    }

    static let empty = ProwlarrFixtureResponse(status: 200, body: Data())
}

nonisolated final class ProwlarrFixtureServer: @unchecked Sendable {
    /// Returning `nil` parks the connection: the request is recorded but not
    /// answered until `releaseParked(with:)` or `stop()`.
    typealias Handler = @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse?

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler

    private let lock = NSLock()
    private var recorded: [ProwlarrFixtureRequest] = []
    private var parkedConnections: [NWConnection] = []
    private var receivedWaiters: [(matches: @Sendable (ProwlarrFixtureRequest) -> Bool, threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(label: String, handler: @escaping Handler) async throws {
        self.queue = DispatchQueue(label: "ProwlarrFixtureServer.\(label)")
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
            fatalError("Prowlarr fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [ProwlarrFixtureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(path: String) -> [ProwlarrFixtureRequest] {
        requests.filter { $0.path == path }
    }

    func requestCount(path: String) -> Int {
        requests(path: path).count
    }

    func requestCount(method: String, path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    func stop() {
        lock.lock()
        let parked = parkedConnections
        parkedConnections = []
        let pending = receivedWaiters
        receivedWaiters = []
        lock.unlock()

        for connection in parked { connection.cancel() }
        for waiter in pending { waiter.continuation.resume() }
        listener.cancel()
    }

    /// Answers every connection the handler parked with `response`.
    func releaseParked(with response: ProwlarrFixtureResponse) {
        lock.lock()
        let parked = parkedConnections
        parkedConnections = []
        lock.unlock()

        for connection in parked {
            connection.send(
                content: Self.encode(response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    /// Resumes once `count` requests for `path` have arrived, whether or not
    /// they were answered. This is the barrier used to know an in-flight request
    /// really reached the socket before the test does something else to the view
    /// model - no sleeping, no polling.
    func waitForRequests(path: String, count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let matches: @Sendable (ProwlarrFixtureRequest) -> Bool = { $0.path == path }
            lock.lock()
            if recorded.filter(matches).count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            receivedWaiters.append((matches: matches, threshold: count, continuation: continuation))
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
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private func park(_ connection: NWConnection) {
        lock.lock()
        parkedConnections.append(connection)
        lock.unlock()
    }

    private func recordReceived(_ request: ProwlarrFixtureRequest) {
        lock.lock()
        recorded.append(request)
        let snapshot = recorded
        let ready = receivedWaiters.filter { snapshot.filter($0.matches).count >= $0.threshold }
        receivedWaiters.removeAll { snapshot.filter($0.matches).count >= $0.threshold }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    // MARK: - HTTP framing

    /// Returns nil until the buffer holds a complete request head plus its
    /// declared `Content-Length` body.
    private static func parse(_ buffer: Data) -> ProwlarrFixtureRequest? {
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
        return ProwlarrFixtureRequest(
            method: String(parts[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count > 1 ? String(targetParts[1]) : "",
            headers: headers,
            body: body
        )
    }

    private static func encode(_ response: ProwlarrFixtureResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

// MARK: - Routing helpers

/// Answers the endpoints every Prowlarr test needs but no test is asserting on:
/// the `/system/status` + `/tag` pair `ArrServiceManager.connectService` requires
/// to mark Prowlarr connected, plus empty defaults for the rest of the surface.
/// Handlers pass anything they do not route themselves to this.
nonisolated func prowlarrDefaultResponse(for request: ProwlarrFixtureRequest) -> ProwlarrFixtureResponse {
    switch request.path {
    case "/api/v1/system/status": return .json(#"{"version":"1.30.2.4939","appName":"Prowlarr"}"#)
    case "/api/v1/indexerstats": return .json(#"{"indexers":[]}"#)
    case "/api/v1/search": return .json("[]")
    default: return .json("[]")
    }
}

// MARK: - JSON fixtures

/// Builds one Prowlarr indexer payload. Field set matches a live Prowlarr
/// v1 `/api/v1/indexer` record (see `LiveCapturedShapeContractTests` for the
/// shape this stack is modelled on).
nonisolated func prowlarrIndexerJSON(
    id: Int,
    name: String,
    enable: Bool = true,
    protocolName: String? = "torrent",
    tags: [Int] = [],
    priority: Int = 25
) -> String {
    let tagList = tags.map(String.init).joined(separator: ",")
    let protocolField = protocolName.map { #""protocol":"\#($0)","# } ?? ""
    return """
    {"id":\(id),"name":"\(name)","enable":\(enable),\(protocolField)\
    "implementation":"Cardigann","implementationName":"Cardigann",\
    "configContract":"CardigannSettings","infoLink":"https://wiki.servarr.com",\
    "tags":[\(tagList)],"priority":\(priority),"appProfileId":1,\
    "supportsRss":true,"supportsSearch":true,"fields":[]}
    """
}

nonisolated func prowlarrSearchResultJSON(
    guid: String,
    title: String,
    indexerId: Int,
    indexer: String,
    protocolName: String = "torrent"
) -> String {
    """
    {"guid":"\(guid)","title":"\(title)","indexerId":\(indexerId),"indexer":"\(indexer)",\
    "size":1073741824,"seeders":12,"leechers":3,"protocol":"\(protocolName)",\
    "downloadUrl":"http://indexer.invalid/\(guid)","publishDate":"2026-01-02T03:04:05Z",\
    "downloadVolumeFactor":1.0,"uploadVolumeFactor":1.0}
    """
}

nonisolated func prowlarrApplicationJSON(
    id: Int,
    name: String,
    implementation: String,
    configContract: String,
    syncLevel: String = "fullSync"
) -> String {
    """
    {"id":\(id),"name":"\(name)","implementation":"\(implementation)",\
    "implementationName":"\(implementation)","configContract":"\(configContract)",\
    "syncLevel":"\(syncLevel)","tags":[],"fields":[]}
    """
}

nonisolated func prowlarrJSONArray(_ elements: [String]) -> String {
    "[\(elements.joined(separator: ","))]"
}

// MARK: - Connection helper

nonisolated enum ProwlarrFixtureFailure: Error {
    case notConnected(String)
    case missingIndexer(Int)
}

/// A lock-guarded call counter for handlers that must answer the same path
/// differently on successive hits (park the first, answer the second; fail then
/// succeed). Handlers are `@Sendable` and run on the listener queue, so the
/// counter cannot live in the test body.
nonisolated final class ProwlarrCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// Returns the 1-based ordinal of this call for `key`.
    func next(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = (counts[key] ?? 0) + 1
        counts[key] = value
        return value
    }
}

/// Stands up a real `ArrServiceManager`, connects it to `server` as a Prowlarr
/// instance through the production `connectService` path (Keychain read, real
/// `ProwlarrAPIClient`, real `/api/v1/system/status` round trip), and hands the
/// manager to `body`. The API key is removed afterwards.
@MainActor
func withConnectedProwlarr(
    server: ProwlarrFixtureServer,
    _ body: (ArrServiceManager) async throws -> Void
) async throws {
    let profile = ArrServiceProfile(displayName: "Prowlarr", hostURL: server.baseURL, serviceType: .prowlarr)
    let manager = ArrServiceManager()
    try await withProwlarrAPIKey(for: profile) {
        await manager.connectService(profile)
        guard manager.prowlarrConnected, manager.prowlarrClient != nil else {
            throw ProwlarrFixtureFailure.notConnected(manager.prowlarrConnectionError ?? "no error recorded")
        }
        try await body(manager)
    }
}

/// Saves an API key for `profile` for the duration of `operation`, then removes
/// it. `ArrServiceManager.connectService` reads the key from the real Keychain,
/// so this is what makes a real connection possible. Copied (rather than shared)
/// from `ArrClientLifecycleTests`, where the equivalent helper is file-private.
@MainActor
func withProwlarrAPIKey(
    for profile: ArrServiceProfile,
    operation: () async throws -> Void
) async throws {
    try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "prowlarr-fixture-key")
    do {
        try await operation()
        try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
    } catch {
        try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        throw error
    }
}
