//
//  QBittorrentFixtureServer.swift
//  TrawlUITests
//
//  A real loopback HTTP server the UI test process hosts on `NWListener`, modeled on
//  `SonarrFixtureServer`/`SABnzbdFixtureServer`'s proven pattern (`Connection: close`
//  framing, a lock-protected request log) plus `ArrSearchAddFixtureServer`'s
//  Content-Length-aware buffering, which this fixture also needs because it has to
//  record the *bodies* of `POST /api/v2/torrents/stop|start|delete` so a test can
//  assert exactly which torrent hash a mutation named.
//
//  Every response shape here is taken from `TrawlTests/LiveCapturedShapeContractTests
//  .swift`, itself captured verbatim from a live **qBittorrent v5.2.3** on 23 August
//  2026 - not from reading `Trawl/Services/AuthService.swift` /
//  `QBittorrentAPIClient.swift` and guessing:
//
//  - `POST /api/v2/auth/login` answers **204 with an empty body** (not v4's `200` +
//    `"Ok."`), carrying `Set-Cookie: QBT_SID_<port>=<sid>; HttpOnly; SameSite=Lax;
//    path=/`. A 204 has **no `Content-Type`** - `AuthService.performLogin` doesn't
//    read the body either way, only the status code and the cookie header.
//  - `GET /api/v2/sync/maindata` returns `full_update: true` plus a `torrents` object
//    keyed by hash, matching the real 68-field torrent object's shape (trimmed here to
//    the fields the app's `SyncTorrentData`/`Torrent` models actually read - every
//    other field on the real model is optional and defaults sensibly, per
//    `Trawl/Models/Torrent.swift`'s `fromDelta`).
//
//  The pause/resume/delete paths come from `Trawl/Services/QBittorrentAPIClient.swift`
//  directly: `pauseTorrents`/`resumeTorrents` hit qBittorrent v5's `/api/v2/torrents
//  /stop` and `/api/v2/torrents/start` (v4's `/pause`/`/resume` are only a fallback on
//  404, which this fixture never returns for the v5 paths, so those legacy routes are
//  never exercised here), and `deleteTorrents` hits `/api/v2/torrents/delete` with a
//  `hashes`/`deleteFiles` form body.
//
//  This fixture is *stateful*, unlike the read-only Sonarr/SABnzbd fixtures: pausing,
//  resuming, and deleting the seeded torrent actually change what the next
//  `/api/v2/sync/maindata` poll reports, so `DownloadsJourneyUITests` can assert both
//  the recorded server-side mutation *and* the resulting on-screen state change (the
//  torrent moving between the Active/Queue segments, or disappearing once deleted) -
//  exactly the "server actually changed, not just local state" proof the audit's UI
//  journey #2 asks for.

import Foundation
import Network

final class QBittorrentFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let body: String
    }

    private let listener: NWListener
    private let queue: DispatchQueue

    private let torrentHash: String
    private let torrentName: String
    private let torrentSize: Int64
    private let torrentCategory: String

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var isPaused = false
    private var isDeleted = false
    private var ridCounter = 0

    /// - Parameters:
    ///   - torrentHash: the seeded torrent's 40-character hex hash. Real qBittorrent
    ///     hashes are lowercase hex, so this defaults to one shaped the same way -
    ///     a test that only pattern-matches on a plausible hash won't be misled by an
    ///     obviously-fake value.
    ///   - torrentName: the seeded torrent's display name, distinctive enough for a
    ///     `label CONTAINS[c]` match against the merged accessibility label
    ///     `TorrentSummaryView` produces (`.accessibilityElement(children: .combine)`).
    ///   - torrentSize: total size in bytes; `amount_left` is derived from this and a
    ///     fixed 42% progress.
    init(
        torrentHash: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        torrentName: String = "Fixture Downloading Torrent",
        torrentSize: Int64 = 2_147_483_648,
        torrentCategory: String = "movies"
    ) async throws {
        self.queue = DispatchQueue(label: "QBittorrentFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.torrentHash = torrentHash.lowercased()
        self.torrentName = torrentName
        self.torrentSize = torrentSize
        self.torrentCategory = torrentCategory

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
    /// `TRAWL_UITEST_QBITTORRENT_BASE_URL`.
    var baseURL: String {
        guard let port = listener.port else {
            fatalError("QBittorrentFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    /// The seeded torrent's hash - exposed so a test can assert a mutation's body
    /// named it, without hardcoding the default a second time.
    var hash: String { torrentHash }

    var name: String { torrentName }

    /// Every request received so far, in arrival order. Thread-safe: connections can
    /// land concurrently (the app polls and re-connects), so every read/append of
    /// this goes through `lock`.
    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedRequest(method: String, path: String, bodyContains fragment: String? = nil) -> Bool {
        requests.contains { request in
            guard request.method == method, request.path == path else { return false }
            guard let fragment else { return true }
            return request.body.contains(fragment)
        }
    }

    func requestCount(method: String, path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Accumulates received bytes until a full HTTP request - headers plus a body
    /// exactly as long as its declared `Content-Length` - has arrived, since nothing
    /// guarantees a `POST /api/v2/torrents/stop|start|delete` body arrives in the same
    /// `receive` callback as its headers. Modeled on `ArrSearchAddFixtureServer`'s
    /// buffering, which this fixture needs for the same reason: it has to record
    /// request bodies correctly, unlike the bodyless-`GET`-only Sonarr/SABnzbd
    /// fixtures.
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

        let response = respond(to: request)
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Route table

    /// Every route the qBittorrent connect sequence, the Downloads sync poll, and the
    /// pause/resume/delete mutations need is listed explicitly. Anything else (e.g.
    /// `POST /api/v2/auth/logout`, which the app never calls in this journey) gets a
    /// harmless empty `200 OK`, matching the convention `SonarrFixtureServer` and
    /// `SABnzbdFixtureServer` already establish.
    private func respond(to request: RecordedRequest) -> Data {
        switch (request.method, request.path) {
        case ("POST", "/api/v2/auth/login"):
            // Verbatim from a real qBittorrent v5.2.3 login: 204, empty body, no
            // Content-Type, and a port-suffixed `QBT_SID_<port>` cookie - see
            // `LiveCapturedShapeContractTests.qBittorrentV5LoginIsAcceptedAndItsCookieReused`.
            // `AuthService.performLogin` only accepts 204 or a 200 containing "Ok.";
            // it then requires a parseable Set-Cookie or it throws `.authFailed`.
            return Self.httpResponse(
                status: 204,
                reason: "No Content",
                headers: ["Set-Cookie": cookieHeader],
                body: Data()
            )

        case ("GET", "/api/v2/app/version"):
            return Self.httpResponse(
                status: 200,
                reason: "OK",
                headers: ["Content-Type": "text/plain"],
                body: Data("v5.2.3".utf8)
            )

        case ("GET", "/api/v2/app/preferences"):
            // Called best-effort by `AppServices.build(from:username:password:)`
            // (`try? await apiClient.getPreferences()`) - an empty object is enough,
            // since a missing `save_path` just leaves `syncService.defaultSavePath`
            // unset.
            return Self.httpResponse(
                status: 200,
                reason: "OK",
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )

        case ("GET", "/api/v2/sync/maindata"):
            return Self.httpResponse(
                status: 200,
                reason: "OK",
                headers: ["Content-Type": "application/json"],
                body: Data(torrentsSnapshotJSON().utf8)
            )

        case ("POST", "/api/v2/torrents/stop"):
            lock.lock()
            isPaused = true
            lock.unlock()
            return Self.emptySuccess()

        case ("POST", "/api/v2/torrents/start"):
            lock.lock()
            isPaused = false
            lock.unlock()
            return Self.emptySuccess()

        case ("POST", "/api/v2/torrents/delete"):
            lock.lock()
            isDeleted = true
            lock.unlock()
            return Self.emptySuccess()

        default:
            return Self.httpResponse(
                status: 200,
                reason: "OK",
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        }
    }

    /// `QBT_SID_<port>=<sid>; HttpOnly; SameSite=Lax; path=/` - the exact shape
    /// captured live. The cookie **name** carries the server's own port (qBittorrent
    /// binds one session cookie name per instance), which is why this can't be a
    /// static string: `AuthService.extractSessionCookie` parses whatever prefix comes
    /// before `=`, so a fixture that hardcoded a different port's name would still
    /// happen to work, but this mirrors the real server's behavior instead of relying
    /// on that.
    private var cookieHeader: String {
        guard let port = listener.port else {
            fatalError("QBittorrentFixtureServer did not bind a port.")
        }
        return "QBT_SID_\(port.rawValue)=fixture-session-0123456789abcdef; HttpOnly; SameSite=Lax; path=/"
    }

    /// A snapshot of the seeded torrent's current sync state as qBittorrent's
    /// `/api/v2/sync/maindata` would report it. Always answers `full_update: true`
    /// with the complete state, never a delta - `SyncService.applyDelta` treats a full
    /// update as authoritative (it rebuilds `torrents` from scratch), so this sidesteps
    /// ever having to reason about partial-update merge semantics.
    private func torrentsSnapshotJSON() -> String {
        let rid = nextRid()

        lock.lock()
        let paused = isPaused
        let deleted = isDeleted
        lock.unlock()

        guard !deleted else {
            // Mirrors the real "nothing queued" shape
            // (`LiveCapturedShapeContractTests.emptyQueueSyncPayloadDecodes`): the
            // `torrents` key is omitted entirely, not sent as an empty object.
            return #"{"full_update":true,"rid":\#(rid)}"#
        }

        // v5 names the paused-while-downloading state `stoppedDL`, not v4's
        // `pausedDL` (`LiveCapturedShapeContractTests.realTorrentObjectDecodes`).
        let state = paused ? "stoppedDL" : "downloading"
        let dlspeed = paused ? 0 : 5_242_880
        let upspeed = paused ? 0 : 131_072
        // qBittorrent's own "no ETA" sentinel, matching `Torrent.fromDelta`'s default.
        let eta = paused ? 8_640_000 : 420
        let progress = 0.42
        let amountLeft = Int64(Double(torrentSize) * (1 - progress))

        let torrentJSON = """
        {"name":"\(Self.jsonEscaped(torrentName))","size":\(torrentSize),"progress":\(progress),"dlspeed":\(dlspeed),"upspeed":\(upspeed),"eta":\(eta),"state":"\(state)","num_seeds":4,"num_leechs":2,"ratio":0,"category":"\(Self.jsonEscaped(torrentCategory))","tags":"","added_on":1787441350,"amount_left":\(amountLeft),"total_size":\(torrentSize)}
        """

        return #"{"full_update":true,"rid":\#(rid),"torrents":{"\#(torrentHash)":\#(torrentJSON)}}"#
    }

    /// Monotonically increasing across every `/api/v2/sync/maindata` response.
    /// `SyncService`'s polling loop only applies a response whose `rid >= self.rid`
    /// (`SyncService.swift`'s `startPolling`/`refreshNow`), so a fixture that returned
    /// a constant `rid` would still pass that guard (equal satisfies `>=`) but this
    /// mirrors a real server, which always advances it.
    private func nextRid() -> Int {
        lock.lock()
        defer { lock.unlock() }
        ridCounter += 1
        return ridCounter
    }

    private static func emptySuccess() -> Data {
        // Real qBittorrent answers these mutations with `200` and an empty body.
        // `QBittorrentAPIClient.performSuccessfulMutation`/`performWithLegacyFallback`
        // only ever check the status code, never decode the body.
        httpResponse(status: 200, reason: "OK", headers: [:], body: Data())
    }

    private static func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
        let rawTarget = parts.dropFirst().first.map(String.init) ?? ""
        let path = String(rawTarget.split(separator: "?", maxSplits: 1).first ?? "")

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

        return RecordedRequest(method: method, path: path, body: body)
    }

    private static func httpResponse(status: Int, reason: String, headers: [String: String], body: Data) -> Data {
        var headerText = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers {
            headerText += "\(key): \(value)\r\n"
        }
        headerText += "Content-Length: \(body.count)\r\n"
        headerText += "Connection: close\r\n\r\n"
        return Data(headerText.utf8) + body
    }
}
