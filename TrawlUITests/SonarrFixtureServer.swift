//
//  SonarrFixtureServer.swift
//  TrawlUITests
//
//  A real loopback HTTP server the UI test process hosts on `NWListener`, modeled on
//  the pattern already proven in `TrawlTests/ArrClientLifecycleTests.swift`
//  (`LifecycleArrTestServer`). The app under test and this test process share the
//  same simulator, so the app can reach `http://127.0.0.1:<port>` directly.
//
//  This exists to seed only *external* state for the end-to-end journey in
//  `SonarrConnectedJourneyUITests`: it answers exactly the HTTP endpoints Sonarr's
//  real API exposes, so `ArrServiceManager.connectService(_:)` and `SonarrAPIClient`
//  run entirely unmodified against it.

import Foundation
import Network

/// Loopback fixture standing in for a real Sonarr server. Answers the endpoints
/// `ArrServiceManager.connectService(_:)` calls for `.sonarr` (system status, quality
/// profiles, root folders, tags - see `SharedArrClient` and `ArrServiceManager.swift`),
/// plus the series library endpoint the Series tab loads afterward.
final class SonarrFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        /// The `X-Api-Key` header this request carried, so a journey can assert *which*
        /// key reached the socket rather than only that some request arrived.
        let apiKey: String?
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let seriesResponseBody: String
    private let acceptedAPIKey: String?
    private let statusResponseBody: String
    /// Body for `GET /api/v3/episode`. Defaults to an empty array, so every suite
    /// that predates episode coverage keeps exactly the behaviour it had.
    private let episodesResponseBody: String
    private let episodeFilesResponseBody: String
    private let downloadClientsJSON: String
    private let logJSON: String

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []

    /// - Parameters:
    ///   - seriesJSON: raw JSON array body returned for `GET /api/v3/series`.
    ///   - acceptedAPIKey: when non-nil, any request whose `X-Api-Key` header does not
    ///     match is answered `401`, exactly as a real Sonarr rejects a bad key. The
    ///     production client maps 401 to `ArrError.invalidAPIKey`
    ///     (`ArrAPIClient.swift`'s `unauthorizedStatusCodes: [401]`), which is what the
    ///     setup sheet surfaces. Defaults to nil - accept every key - so the journeys
    ///     that only need a reachable server are unaffected.
    ///   - statusJSON: body for `GET /api/v3/system/status`. Defaults to `{}`; give it
    ///     an `instanceName` when a journey needs to tell two instances apart in the UI,
    ///     since that is what `ArrSetupViewModel` uses as the profile's display name.
    init(
        seriesJSON: String,
        acceptedAPIKey: String? = nil,
        statusJSON: String = "{}",
        episodesJSON: String = "[]",
        episodeFilesJSON: String = "[]",
        /// Defaults to none, which is a real answer rather than a failure: a server
        /// with no download client is a state the app has to render.
        downloadClientsJSON: String = "[]",
        /// Defaults to an empty page, which is a real answer: a server with nothing
        /// logged is a state the Events screen has to render.
        logJSON: String = #"{"page":1,"pageSize":50,"totalRecords":0,"records":[]}"#
    ) async throws {
        self.downloadClientsJSON = downloadClientsJSON
        self.logJSON = logJSON
        self.queue = DispatchQueue(label: "SonarrFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.seriesResponseBody = seriesJSON
        self.acceptedAPIKey = acceptedAPIKey
        self.statusResponseBody = statusJSON
        self.episodesResponseBody = episodesJSON
        self.episodeFilesResponseBody = episodeFilesJSON

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

    /// The base URL the app should be launched with, e.g. via
    /// `TRAWL_UITEST_SONARR_BASE_URL`.
    var baseURL: String {
        guard let port = listener.port else {
            fatalError("SonarrFixtureServer did not bind a port.")
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

    func hasReceivedRequest(method: String, path: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path }
    }

    /// Whether a request arrived at this endpoint carrying exactly `apiKey`. Used to
    /// prove the key the user typed is the key the production client actually sent.
    func hasReceivedRequest(method: String, path: String, apiKey: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path && $0.apiKey == apiKey }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Request handling

    /// Each inbound connection is handled independently and closed after one
    /// response (`Connection: close`), matching how `URLSession` issues one
    /// connection per request. The app polls and reconnects services repeatedly, so
    /// this can and does get invoked many times concurrently - `newConnectionHandler`
    /// spins up a fresh handler per connection, and every mutation of
    /// `recordedRequests` is serialized by `lock`, so nothing here assumes a single
    /// request per endpoint.
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
            self.lock.unlock()

            let isAuthorized = self.acceptedAPIKey.map { $0 == request.apiKey } ?? true
            let status = isAuthorized ? 200 : 401
            let body = isAuthorized ? self.responseBody(for: request) : "{}"
            connection.send(
                content: Self.httpResponse(body: body, status: status),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    /// Route table: method + path. Every route Sonarr's connect path and the series
    /// library need is listed explicitly; anything else (health checks, blocklist,
    /// queue, calendar prefetches, etc. that the app may also issue) gets a
    /// harmless empty-array `200 OK` rather than a connection failure, since those
    /// aren't relevant to what this journey asserts.
    private func responseBody(for request: RecordedRequest) -> String {
        switch (request.method, request.path) {
        case ("GET", "/api/v3/system/status"):
            return statusResponseBody
        case ("GET", "/api/v3/qualityprofile"):
            return "[]"
        case ("GET", "/api/v3/log"):
            return logJSON
        case ("GET", "/api/v3/downloadclient"):
            return downloadClientsJSON
        case ("GET", "/api/v3/rootfolder"):
            return "[]"
        case ("GET", "/api/v3/tag"):
            return "[]"
        case ("GET", "/api/v3/series"):
            return seriesResponseBody
        case ("GET", "/api/v3/episode"):
            return episodesResponseBody
        case ("GET", "/api/v3/episodefile"):
            return episodeFilesResponseBody
        default:
            return "[]"
        }
    }

    private static func parseRequest(from data: Data) -> RecordedRequest {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return RecordedRequest(method: "", path: "", apiKey: nil)
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")
        return RecordedRequest(method: method, path: path, apiKey: apiKeyHeader(in: text))
    }

    /// Header names are case-insensitive per RFC 9110, and the value is everything
    /// after the first colon with surrounding whitespace removed.
    private static func apiKeyHeader(in text: String) -> String? {
        for line in text.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("X-Api-Key") == .orderedSame else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func httpResponse(body: String, status: Int = 200) -> Data {
        let bytes = Data(body.utf8)
        let reason = status == 200 ? "OK" : "Unauthorized"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }
}
