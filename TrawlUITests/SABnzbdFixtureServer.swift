//
//  SABnzbdFixtureServer.swift
//  TrawlUITests
//
//  A real loopback HTTP server the UI test process hosts on `NWListener`, modeled on
//  `SonarrFixtureServer` (same pattern already proven there and in
//  `TrawlTests/ArrClientLifecycleTests.swift`'s `LifecycleArrTestServer`). The app
//  under test and this test process share the same simulator, so the app can reach
//  `http://127.0.0.1:<port>` directly.
//
//  Unlike Sonarr's REST-shaped API, SABnzbd's is query-driven: every call is a GET
//  (or POST for `addfile`) to the same path with a `mode=` query parameter selecting
//  the operation (see `Trawl/SABnzbdStack/SABnzbdAPIClient.swift`). This fixture
//  therefore routes on `mode`, not on path, and records the full query string of every
//  request so a test can prove exactly which calls landed and how many times.
//
//  This exists to seed only *external* state for
//  `SABnzbdUnauthorizedJourneyUITests`: it answers exactly the calls
//  `SABnzbdServiceManager.connectService(_:)` and `refresh()` make against `.sabnzbd`
//  (version, queue, history — see `SABnzbdServiceManager.swift`), and can flip to
//  rejecting every request with an HTTP 401 at runtime, which is exactly how SABnzbd
//  itself signals an invalid API key: `HTTPTransport.validate(_:data:path:urlString:)`
//  maps any status in `errorMapper.unauthorizedStatusCodes` — `[401, 403]` for SABnzbd,
//  set in `SABnzbdAPIClient.init` — to `SABnzbdAPIError.unauthorized` *before* the
//  response body is ever decoded. A `200` with a `{"status":false,...}` error body, by
//  contrast, is real SABnzbd behavior too but maps to `.api(message:)`, not
//  `.unauthorized` (see `SABnzbdAPIClientContractTests`'s "delivered as a 200 error
//  body" test) — so this fixture uses the status-code path deliberately, because that
//  is the one `SABnzbdServiceManager.refresh()` actually treats as an authorization
//  failure.

import Foundation
import Network

/// Loopback fixture standing in for a real SABnzbd server. Answers `mode=version`,
/// `mode=queue`, `mode=history`, `mode=get_cats`, `mode=get_scripts`, `mode=pause`,
/// and `mode=resume` — the calls the connect path, the polling refresh, the manager
/// view's on-appear category fetch, and its queue-level mutation actions make. Any
/// other `mode` gets a harmless empty-object `200 OK`, since it isn't relevant to what
/// this journey asserts.
final class SABnzbdFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        /// The raw query string, e.g. `"mode=queue&output=json&apikey=uitest-api-key"`.
        let query: String

        /// The `mode=` query parameter, which is how SABnzbd's API distinguishes
        /// operations — there is no per-operation path to key off of.
        var mode: String? {
            query
                .split(separator: "&")
                .compactMap { pair -> (String, String)? in
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    guard let key = parts.first else { return nil }
                    let value = parts.count > 1 ? String(parts[1]) : ""
                    return (String(key), value)
                }
                .first(where: { $0.0 == "mode" })?
                .1
        }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    /// The queue slot's `filename` (SABnzbd's field for what Trawl renders as the
    /// job's title) served for `mode=queue` while the fixture is authorized.
    private let queueJobName: String

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    /// Flipped at runtime by the test to simulate a revoked API key. Every request
    /// while this is `true` answers `401` instead of its normal `200` body,
    /// regardless of `mode` — matching a real SABnzbd server rejecting every call
    /// once its API key no longer matches, not just the next poll.
    private var isUnauthorized = false

    /// - Parameter queueJobName: the `filename` of the single queue slot this fixture
    ///   serves for `mode=queue` while authorized — the job the journey's first
    ///   assertion looks for on screen.
    init(queueJobName: String) async throws {
        self.queue = DispatchQueue(label: "SABnzbdFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.queueJobName = queueJobName

        listener.newConnectionHandler = { [weak self] connection in
            self?.respond(to: connection)
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

    /// The base URL the app should be launched with, via
    /// `TRAWL_UITEST_SABNZBD_BASE_URL`.
    var baseURL: String {
        guard let port = listener.port else {
            fatalError("SABnzbdFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    /// Every request received so far, in arrival order. Thread-safe: connections can
    /// land concurrently (the app polls and re-connects), so every read/append of
    /// this goes through `lock`.
    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    func requestCount(forMode mode: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.filter { $0.mode == mode }.count
    }

    /// Flips the fixture into rejecting every subsequent request with a real HTTP
    /// 401 — the same status `HTTPTransport` maps to `SABnzbdAPIError.unauthorized`
    /// in production, which is what makes this an *authentic* regression test for
    /// H-05 rather than a stubbed error path.
    func setUnauthorized() {
        lock.lock()
        isUnauthorized = true
        lock.unlock()
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Request handling

    /// Each inbound connection is handled independently and closed after one
    /// response (`Connection: close`), matching how `URLSession` issues one
    /// connection per request. The app polls repeatedly, so this can and does get
    /// invoked many times concurrently — every mutation of `recordedRequests` and
    /// `isUnauthorized` is serialized by `lock`.
    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            let request = Self.parseRequest(from: data)
            self.lock.lock()
            self.recordedRequests.append(request)
            let rejecting = self.isUnauthorized
            self.lock.unlock()

            let response = rejecting
                ? Self.httpResponse(status: 401, statusText: "Unauthorized", body: #"{"status":false,"error":"API Key Incorrect"}"#)
                : Self.httpResponse(status: 200, statusText: "OK", body: self.responseBody(for: request))

            connection.send(
                content: response,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    /// Route table, keyed by `mode` — SABnzbd's API has one path and dispatches
    /// entirely on this query parameter. Bodies are the minimal shape each envelope
    /// needs; every other field on `SABnzbdQueue`/`SABnzbdHistory`/etc. has a lossy
    /// default (see `SABnzbdModels.swift`), so this only needs to supply what the
    /// journey actually reads or what a real server always includes.
    private func responseBody(for request: RecordedRequest) -> String {
        switch request.mode {
        case "version":
            return #"{"version":"4.5.0"}"#
        case "queue":
            return #"""
            {"queue":{"status":"Downloading","paused":false,"slots":[{"nzo_id":"SABnzbd_nzo_fixture1","filename":"\#(queueJobName)","status":"Downloading","index":0,"priority":"Normal","cat":"movies","time_added":0,"timeleft":"0:10:00","percentage":42,"mb":1000,"mbleft":580,"mbmissing":0,"size":"1000 MB","sizeleft":"580 MB","labels":[]}]}}
            """#
        case "history":
            return #"{"history":{"slots":[]}}"#
        case "get_cats":
            return #"{"categories":["*","movies"]}"#
        case "get_scripts":
            return #"{"scripts":["None"]}"#
        case "pause", "resume":
            return #"{"status":true}"#
        default:
            return "{}"
        }
    }

    private static func parseRequest(from data: Data) -> RecordedRequest {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return RecordedRequest(method: "", path: "", query: "")
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawTarget = parts.dropFirst().first.map(String.init) ?? ""
        let targetParts = rawTarget.split(separator: "?", maxSplits: 1)
        let path = String(targetParts.first ?? "")
        let query = targetParts.count > 1 ? String(targetParts[1]) : ""
        return RecordedRequest(method: method, path: path, query: query)
    }

    private static func httpResponse(status: Int, statusText: String, body: String) -> Data {
        let bytes = Data(body.utf8)
        let headers = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }
}
