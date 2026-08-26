//
//  ArrSearchAddFixtureServer.swift
//  TrawlUITests
//
//  A second loopback Sonarr fixture, alongside `SonarrFixtureServer`, purpose-built
//  for UI journey #5 (search for and add a series — TRAWL_RELIABILITY_TEST_AUDIT.md).
//  Modeled on `SonarrFixtureServer`'s NWListener/lock/`Connection: close` pattern
//  (itself modeled on `TrawlTests/ArrClientLifecycleTests.swift`'s
//  `LifecycleArrTestServer`), but a distinct type because this journey needs routes
//  neither of those serve — `GET /api/v3/series/lookup` and a `POST /api/v3/series`
//  whose outcome a single test can flip at runtime — plus request *bodies*, which
//  neither prior fixture records, so the add journey's tests can assert exactly what
//  the app sent.
//
//  Production routes this answers (read from source, not guessed):
//  - Sonarr connect sequence, shared with `SonarrFixtureServer`: `GET
//    /api/v3/system/status`, `GET /api/v3/qualityprofile`, `GET /api/v3/rootfolder`,
//    `GET /api/v3/tag` (`ArrServiceManager.connectService`/`refreshConfiguration`).
//  - `GET /api/v3/series` — the series library
//    (`ArrServiceManager.loadSeriesLibrary`, `SonarrAPIClient.getSeries`), reloaded
//    with `maxAge: 0` (always refetches) after every successful add
//    (`SonarrViewModel.addSeries` -> `loadSeries()`).
//  - `GET /api/v3/series/lookup` — the add-new search
//    (`SonarrAPIClient.lookupSeries(term:)`, called from
//    `ArrLibraryViewModel.performLookup(term:)` via `SearchViewModel.startArrLookup`).
//  - `POST /api/v3/series` — the add itself (`SonarrAPIClient.addSeries(_:)`, called
//    from `SonarrAddToLibrarySheet.addSeries()` via `SonarrViewModel.addSeries`).
//
//  Both `GET /api/v3/series` and `POST /api/v3/series` are runtime-configurable
//  because one test (the duplicate path) needs the library to already contain what's
//  being searched for, and another (the failure path) needs the add itself to fail
//  with a real 500 — the audit's explicit ask ("configurable at runtime so one test
//  can switch a route between success and failure").

import Foundation
import Network

final class ArrSearchAddFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let rawQuery: String?
        let body: String
    }

    /// What the *next* (and every subsequent, until changed again) `POST
    /// /api/v3/series` should do.
    enum AddOutcome: Sendable {
        /// Responds 201 with `addedSeriesJSON` — which must decode as a
        /// `SonarrSeries` (real Sonarr's add response shape), since
        /// `SonarrAPIClient.addSeries` decodes its response — and folds that same
        /// object into what `GET /api/v3/series` returns afterward, mirroring real
        /// Sonarr so the app's post-add `loadSeries()` refetch sees the new series.
        case success
        /// Responds with `status` and a plain-text `body`. Plain text (not JSON) is
        /// deliberate: `ArrError.serverErrorDisplayMessage` passes a non-JSON body
        /// straight through as its first line, so the resulting
        /// `errorDescription` is exactly "Server error (\(status)): \(body)" —
        /// deterministic and assertable, per `ArrSharedModels.swift`'s
        /// `ArrError.errorDescription` / `serverErrorDisplayMessage`.
        case failure(status: Int, body: String)
    }

    private let listener: NWListener
    private let queue: DispatchQueue

    private let qualityProfilesJSON: String
    private let rootFoldersJSON: String
    private let lookupResponseJSON: String
    private let addedSeriesJSON: String
    private let releaseResponseJSON: String
    private let commandResponseJSON: String

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var currentLibraryJSON: String
    private var addOutcome: AddOutcome

    /// - Parameters:
    ///   - librarySeriesJSON: raw JSON array body initially returned for `GET
    ///     /api/v3/series`.
    ///   - lookupResponseJSON: raw JSON array body returned for `GET
    ///     /api/v3/series/lookup`, regardless of the `term` query value — every
    ///     journey here performs exactly one search, so no per-term routing is
    ///     needed.
    ///   - addedSeriesJSON: raw JSON *object* (not array) both returned as the
    ///     successful add's response body and merged into the library array
    ///     afterward. Irrelevant when a test only ever forces `.failure`.
    ///   - addOutcome: what `POST /api/v3/series` does until a test calls
    ///     `setAddOutcome(_:)`.
    init(
        librarySeriesJSON: String,
        lookupResponseJSON: String,
        addedSeriesJSON: String,
        qualityProfilesJSON: String = #"[{"id":1,"name":"HD-1080p"}]"#,
        rootFoldersJSON: String = #"[{"id":1,"path":"/tv"}]"#,
        releaseResponseJSON: String = "[]",
        commandResponseJSON: String = #"{"id":901,"name":"SeriesSearch","status":"queued"}"#,
        addOutcome: AddOutcome = .success
    ) async throws {
        self.queue = DispatchQueue(label: "ArrSearchAddFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.currentLibraryJSON = librarySeriesJSON
        self.lookupResponseJSON = lookupResponseJSON
        self.addedSeriesJSON = addedSeriesJSON
        self.qualityProfilesJSON = qualityProfilesJSON
        self.rootFoldersJSON = rootFoldersJSON
        self.releaseResponseJSON = releaseResponseJSON
        self.commandResponseJSON = commandResponseJSON
        self.addOutcome = addOutcome

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
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
    /// `TRAWL_UITEST_SONARR_BASE_URL`.
    var baseURL: String {
        guard let port = listener.port else {
            fatalError("ArrSearchAddFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    /// Every request received so far, in arrival order. Thread-safe: connections
    /// can land concurrently (the connect sequence, polling, and the debounced
    /// as-you-type lookup can all overlap), so every read/append goes through `lock`.
    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedRequest(method: String, path: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path }
    }

    func requestCount(method: String, path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    /// Switches what the *next* `POST /api/v3/series` does. Must be called before
    /// the app is driven to actually send that request (i.e. before the test taps
    /// the add sheet's confirm button) — this fixture has no other synchronization
    /// with the app under test.
    func setAddOutcome(_ outcome: AddOutcome) {
        lock.lock()
        addOutcome = outcome
        lock.unlock()
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Accumulates received bytes until a full HTTP request — headers plus a body
    /// exactly as long as its declared `Content-Length` — has arrived, rather than
    /// assuming (as the simpler fixture servers in this suite do) that one `receive`
    /// callback always contains the whole request. That assumption holds for a
    /// bodyless `GET`, but this fixture also has to record `POST /api/v3/series`'s
    /// body correctly, and nothing about `NWConnection.receive` guarantees a small
    /// body arrives in the same callback as its headers.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }

            if let request = Self.parseRequest(from: next) {
                self.handle(request, on: connection)
            } else if error != nil || (isComplete && (data == nil || data!.isEmpty)) {
                // Connection closed (or errored) before a complete request ever
                // arrived — nothing sensible to respond with.
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func handle(_ request: RecordedRequest, on connection: NWConnection) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()

        let (status, body) = responseBody(for: request)
        connection.send(
            content: Self.httpResponse(statusCode: status, body: body),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// Route table. Every route the Sonarr connect path, the add-search lookup, the
    /// series library, and the add itself need is listed explicitly; anything else
    /// (health checks, blocklist, calendar prefetches, etc. the app may also issue)
    /// gets a harmless empty-array `200 OK`, matching `SonarrFixtureServer`'s
    /// convention — those aren't relevant to what this journey asserts.
    private func responseBody(for request: RecordedRequest) -> (status: Int, body: String) {
        switch (request.method, request.path) {
        case ("GET", "/api/v3/system/status"):
            return (200, "{}")
        case ("GET", "/api/v3/qualityprofile"):
            return (200, qualityProfilesJSON)
        case ("GET", "/api/v3/rootfolder"):
            return (200, rootFoldersJSON)
        case ("GET", "/api/v3/tag"):
            return (200, "[]")
        case ("GET", "/api/v3/series"):
            lock.lock()
            let body = currentLibraryJSON
            lock.unlock()
            return (200, body)
        case ("GET", "/api/v3/series/lookup"):
            return (200, lookupResponseJSON)
        case ("POST", "/api/v3/series"):
            lock.lock()
            let outcome = addOutcome
            lock.unlock()
            switch outcome {
            case .success:
                lock.lock()
                currentLibraryJSON = Self.mergedArray(currentLibraryJSON, appending: addedSeriesJSON)
                lock.unlock()
                return (201, addedSeriesJSON)
            case .failure(let status, let body):
                return (status, body)
            }
        case ("POST", "/api/v3/command"):
            return (201, commandResponseJSON)
        case ("GET", "/api/v3/release"):
            return (200, releaseResponseJSON)
        case ("POST", "/api/v3/release"):
            return (201, "{}")
        case ("GET", "/api/v3/queue"),
             ("GET", "/api/v3/history"),
             ("GET", "/api/v3/blocklist"):
            return (200, "{}")
        case ("GET", "/api/v3/episode"),
             ("GET", "/api/v3/episodefile"):
            return (200, "[]")
        default:
            return (200, "[]")
        }
    }

    /// Appends one JSON object's raw text into a JSON array's raw text — e.g.
    /// `[{"a":1}]` plus `{"b":2}` becomes `[{"a":1},{"b":2}]`. String-level rather
    /// than decode/re-encode so this fixture never has to know the full
    /// `SonarrSeries` shape, only what it's given.
    private static func mergedArray(_ arrayJSON: String, appending objectJSON: String) -> String {
        let trimmed = arrayJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]") else { return arrayJSON }
        let withoutClosingBracket = String(trimmed.dropLast())
        let isEmpty = withoutClosingBracket.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("[")
        return isEmpty ? "\(withoutClosingBracket)\(objectJSON)]" : "\(withoutClosingBracket),\(objectJSON)]"
    }

    // MARK: - Request parsing

    /// Parses one HTTP/1.1 request out of `data`, returning `nil` when the buffer
    /// doesn't yet contain a full request (no header/body separator, or a
    /// `Content-Length` body that hasn't fully arrived) so the caller keeps reading.
    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        guard let headerText = String(data: data[data.startIndex..<separatorRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        let pathAndQuery = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pathAndQuery.first.map(String.init) ?? ""
        let rawQuery = pathAndQuery.count == 2 ? String(pathAndQuery[1]) : nil

        var contentLength = 0
        for line in lines.dropFirst() {
            let headerParts = line.split(separator: ":", maxSplits: 1)
            guard headerParts.count == 2 else { continue }
            let name = headerParts[0].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLength = Int(headerParts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = separatorRange.upperBound
        let bodyBytesAvailable = data.count - bodyStart
        guard bodyBytesAvailable >= contentLength else {
            return nil
        }

        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let bodyData = data[bodyStart..<bodyEnd]
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        return RecordedRequest(method: method, path: path, rawQuery: rawQuery, body: body)
    }

    /// Reason phrase is cosmetic — `URLSession`/`HTTPURLResponse` parse only the
    /// numeric status code — but a real one avoids relying on the perennially odd
    /// `HTTPURLResponse.localizedString(forStatusCode:)` (e.g. it returns "no error"
    /// for 200 on Apple platforms).
    private static func httpResponse(statusCode: Int, body: String) -> Data {
        let bytes = Data(body.utf8)
        let reasonPhrase: String
        switch statusCode {
        case 200: reasonPhrase = "OK"
        case 201: reasonPhrase = "Created"
        case 500: reasonPhrase = "Internal Server Error"
        default: reasonPhrase = "Status"
        }
        let headers = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }
}
