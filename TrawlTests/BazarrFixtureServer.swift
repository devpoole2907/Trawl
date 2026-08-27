import Foundation
import Network
@testable import Trawl

/// A loopback HTTP/1.1 server for `BazarrViewModelTests`.
///
/// `BazarrAPIClient.init` builds its own `ArrAPIClient` (and that its own ephemeral
/// `URLSession`) with no session-injection seam, so a `URLProtocol` stub cannot be
/// used. A real socket is therefore the only way to drive the production request
/// path — `BazarrViewModel` → `BazarrAPIClient` → `ArrAPIClient`/`HTTPTransport` →
/// `JSONDecoder` — with controlled payloads, mirroring `ArrClientLifecycleTests`'
/// file-private `LifecycleArrTestServer` and `JellyfinFixtureServer`. Those two
/// types are either file-private or not the right shape for Bazarr's multi-path
/// connect flow (`/api/system/status`, `/api/system/languages/profiles`,
/// `/api/system/languages`, `/api/series`, `/api/movies`, `/api/episodes`), so
/// this is a deliberate, separately named copy rather than a shared import.
///
/// Nothing here sleeps on the clock: `waitForReceivedRequests` and the park /
/// `releaseParked` pair are `CheckedContinuation` barriers resumed from the
/// server's own connection callbacks, used by the isConnecting mid-flight test to
/// observe a real in-flight request without guessing at timing.
nonisolated struct BazarrFixtureRequest: Sendable, Equatable {
    let method: String
    let path: String
    let rawQuery: String
    /// The request body exactly as it arrived. Bazarr posts settings as a form body
    /// rather than a query, so assertions about *what was saved* need this.
    let body: String

    /// The form body decoded into its pairs, in order and with repeats preserved —
    /// `settings-general-enabled_providers` is sent once per enabled provider, so a
    /// dictionary would silently collapse the very thing worth asserting.
    var formPairs: [(name: String, value: String)] {
        guard !body.isEmpty else { return [] }
        return body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts.first ?? "")
            let value = parts.count > 1 ? String(parts[1]) : ""
            return (
                name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? name,
                value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
            )
        }
    }

    func formValues(named name: String) -> [String] {
        formPairs.filter { $0.name == name }.map(\.value)
    }
}

nonisolated struct BazarrFixtureResponse: Sendable {
    let status: Int
    let body: String

    static func json(_ body: String, status: Int = 200) -> BazarrFixtureResponse {
        BazarrFixtureResponse(status: status, body: body)
    }

    /// A body BazarrAPIClient's flexible decoders accept for practically any
    /// endpoint used here: `BazarrPage` reads `data`/`total`; `BazarrArrayResponse`
    /// falls back to `data` when the root isn't a bare array; `BazarrStatusResponse`
    /// falls back to decoding `BazarrSystemStatus` directly (all-optional fields)
    /// when neither wrapped shape matches.
    static let genericOK = BazarrFixtureResponse.json(#"{"data":[],"total":0}"#)
}

nonisolated final class BazarrFixtureServer: @unchecked Sendable {
    /// Return `nil` to park the connection (hold it open, unanswered) instead of
    /// responding immediately. Used only by the isConnecting mid-flight test.
    typealias Handler = @Sendable (BazarrFixtureRequest) -> BazarrFixtureResponse?

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler

    private let lock = NSLock()
    private var recorded: [BazarrFixtureRequest] = []
    private var parkedConnections: [NWConnection] = []
    private var receivedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(label: String, handler: @escaping Handler) async throws {
        self.queue = DispatchQueue(label: "BazarrFixtureServer.\(label)")
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
            fatalError("Bazarr fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [BazarrFixtureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requestCount(path: String) -> Int {
        requests.filter { $0.path == path }.count
    }

    func stop() {
        lock.lock()
        let parked = parkedConnections
        parkedConnections = []
        let waiters = receivedWaiters
        receivedWaiters = []
        lock.unlock()

        for connection in parked { connection.cancel() }
        for waiter in waiters { waiter.continuation.resume() }
        listener.cancel()
    }

    /// Answers every connection the handler parked with `response`.
    func releaseParked(with response: BazarrFixtureResponse) {
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

    /// Resumes once `count` requests have arrived, whether or not they were answered yet.
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

    private func recordReceived(_ request: BazarrFixtureRequest) {
        lock.lock()
        recorded.append(request)
        let count = recorded.count
        let ready = receivedWaiters.filter { $0.threshold <= count }
        receivedWaiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    // MARK: - HTTP framing

    private static func parse(_ buffer: Data) -> BazarrFixtureRequest? {
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

        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let body = String(data: bodyBytes.prefix(contentLength), encoding: .utf8) ?? ""
        return BazarrFixtureRequest(
            method: String(parts[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count > 1 ? String(targetParts[1]) : "",
            body: body
        )
    }

    private static func encode(_ response: BazarrFixtureResponse) -> Data {
        let bytes = Data(response.body.utf8)
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bytes.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 401: return "Unauthorized"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
