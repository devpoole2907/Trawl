//
//  QBittorrentFixtureServer.swift
//  TrawlUITests
//
//  A real loopback HTTP server the UI test process hosts on `NWListener`, modeled on
//  `SonarrFixtureServer`'s pattern (request-line parsing, routing, `Connection: close`
//  framing, recorded requests) but generalized to also buffer and parse a request
//  *body* — qBittorrent's login endpoint is a form-encoded POST, not a bodyless GET,
//  and the whole point of `QBittorrentOnboardingJourneyUITests` is that this server
//  answers a *real* login/version/sync round trip driven by the app's real onboarding
//  UI, so it has to actually read what the app sent rather than only the request line.
//
//  This exists to answer exactly the endpoints Trawl's onboarding path and first
//  Downloads-tab load call for qBittorrent — see `OnboardingViewModel.validateAndSave`,
//  `QBittorrentClientFactory.makeAndLogin`, `AuthService.performLogin`, and
//  `SyncService.refreshNow`/`startPolling` — so those run entirely unmodified against
//  a deterministic fixture instead of a real qBittorrent instance.

import Foundation
import Network

/// Loopback fixture standing in for a real qBittorrent Web UI. Answers
/// `POST /api/v2/auth/login`, `GET /api/v2/app/version` (onboarding's connection
/// check), `GET /api/v2/app/preferences` (best-effort default save path fetch in
/// `AppServices.build`), and `GET /api/v2/sync/maindata` (the torrent list).
final class QBittorrentFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        /// The raw request body, when one was sent (e.g. the login form). `nil` for
        /// bodyless requests.
        let body: String?
    }

    /// The exact session id vended in `Set-Cookie` on a successful login. Exposed so
    /// a test could assert on it if it ever needed to; not currently required.
    static let sessionID = "fixture-sid-0000000000"

    private let listener: NWListener
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    /// Starts `false` (rejecting) so the failure half of the journey needs no setup;
    /// flipped at runtime by the test once it wants the success half to work.
    private var acceptsLogins = false

    init() async throws {
        self.queue = DispatchQueue(label: "QBittorrentFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)

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

    /// The base URL the app should be pointed at, e.g. typed into
    /// `ServerURLField` during onboarding.
    var baseURL: String {
        guard let port = listener.port else {
            fatalError("QBittorrentFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    /// Every request received so far, in arrival order. Thread-safe: connections can
    /// land concurrently (the app polls `/api/v2/sync/maindata` on a timer, and
    /// onboarding + the post-save `AppServices.build` login can overlap in flight), so
    /// every read/append of this goes through `lock`.
    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedRequest(method: String, path: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path }
    }

    /// Switches the login endpoint from rejecting every credential (the failure half
    /// of the journey) to accepting them (the success half). Safe to call while
    /// connections are in flight — guarded by the same lock as everything else.
    func setAcceptsLogins(_ accepts: Bool) {
        lock.lock()
        acceptsLogins = accepts
        lock.unlock()
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    /// Each inbound connection is handled independently and closed after one
    /// response (`Connection: close`), matching how `URLSession` issues one
    /// connection per request. Unlike a bodyless GET, the login POST's form body may
    /// not arrive in the same TCP read as the header block, so this buffers across
    /// as many `receive` calls as it takes to see a complete request (full header
    /// block plus a `Content-Length`-sized body) before responding.
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        pump(connection, buffer: Data())
    }

    private func pump(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if let request = Self.tryParseRequest(from: buffer) {
                self.lock.lock()
                self.recordedRequests.append(request)
                let accepts = self.acceptsLogins
                self.lock.unlock()

                let response = self.response(for: request, acceptsLogins: accepts)
                connection.send(
                    content: response,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            }

            if error != nil || (isComplete && (data?.isEmpty ?? true)) {
                // Connection closed before a full request arrived — nothing to answer.
                connection.cancel()
                return
            }

            // Still waiting on more of the header block or body; keep reading.
            self.pump(connection, buffer: buffer)
        }
    }

    // MARK: - Routing

    private func response(for request: RecordedRequest, acceptsLogins: Bool) -> Data {
        switch (request.method, request.path) {
        case ("POST", "/api/v2/auth/login"):
            return acceptsLogins ? Self.loginSuccessResponse() : Self.loginFailureResponse()

        case ("GET", "/api/v2/app/version"):
            return Self.httpResponse(status: "200 OK", contentType: "text/plain", body: "v4.6.5")

        case ("GET", "/api/v2/app/preferences"):
            return Self.httpResponse(status: "200 OK", contentType: "application/json", body: "{}")

        case ("GET", "/api/v2/sync/maindata"):
            return Self.httpResponse(status: "200 OK", contentType: "application/json", body: Self.mainDataJSON)

        default:
            // Anything else the app may poll (logout on teardown, etc.) gets a
            // harmless empty-object 200 rather than a connection failure, since it
            // isn't relevant to what this journey asserts.
            return Self.httpResponse(status: "200 OK", contentType: "application/json", body: "{}")
        }
    }

    /// These are the shapes a **real qBittorrent v5.2.3** sends, captured from a live
    /// server and frozen in `TrawlTests/LiveCapturedShapeContractTests.swift`.
    ///
    /// A successful login is `204` with an empty body and a **port-suffixed**
    /// `QBT_SID_<port>` cookie. A rejected login is `401` with a plain-text
    /// `Unauthorized` body. The older `200` + `"Ok."` + plain `SID` shapes this
    /// fixture used to send are what qBittorrent **v4** did; `AuthService` still
    /// accepts those, so the fixture was passing while exercising a legacy path no
    /// current server takes.
    private static func loginSuccessResponse() -> Data {
        httpResponse(
            status: "204 No Content",
            contentType: nil,
            body: "",
            extraHeaders: ["Set-Cookie": "QBT_SID_8080=\(sessionID); HttpOnly; SameSite=Lax; path=/"]
        )
    }

    private static func loginFailureResponse() -> Data {
        httpResponse(status: "401 Unauthorized", contentType: "text/plain; charset=UTF-8", body: "Unauthorized")
    }

    /// One torrent, `"Fixture Torrent Alpha"`, in the `downloading` state — which
    /// `DownloadsViewModel.isActive(_:Torrent)` (`Trawl/DownloadsStack/DownloadsViewModel.swift`)
    /// treats as active, so it lands in the Downloads tab's default "Active" segment
    /// without the test having to navigate anywhere first. `rid`/`full_update: true`
    /// matches a first sync response per `SyncMainData`'s decoding.
    private static let mainDataJSON = #"""
    {
        "rid": 1,
        "full_update": true,
        "torrents": {
            "fixturetorrenthash0000000000000000000001": {
                "name": "Fixture Torrent Alpha",
                "size": 1000000000,
                "progress": 0.42,
                "dlspeed": 1048576,
                "upspeed": 0,
                "priority": 1,
                "num_seeds": 5,
                "num_leechs": 2,
                "ratio": 0.0,
                "eta": 600,
                "state": "downloading",
                "category": "",
                "tags": "",
                "added_on": 1700000000,
                "completion_on": 0,
                "save_path": "/downloads",
                "dl_session": 0,
                "up_session": 0,
                "amount_left": 500000000,
                "total_size": 1000000000,
                "comment": "",
                "seq_dl": false,
                "f_l_piece_prio": false
            }
        },
        "torrents_removed": [],
        "categories": {},
        "categories_removed": [],
        "tags": [],
        "tags_removed": [],
        "server_state": {
            "dl_info_speed": 1048576,
            "up_info_speed": 0,
            "connection_status": "connected"
        }
    }
    """#

    // MARK: - Parsing

    /// Parses a request out of `buffer` once the full header block *and* (if a
    /// `Content-Length` is present) the full body have arrived. Returns `nil` when
    /// the buffer doesn't yet hold a complete request, so the caller keeps reading.
    private static func tryParseRequest(from buffer: Data) -> RecordedRequest? {
        guard let headerTerminatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = buffer[..<headerTerminatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = requestLineParts.first.map(String.init) ?? ""
        let rawPath = requestLineParts.dropFirst().first.map(String.init) ?? ""
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")

        var contentLength = 0
        for line in lines.dropFirst() {
            let headerParts = line.split(separator: ":", maxSplits: 1)
            guard headerParts.count == 2 else { continue }
            let name = headerParts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = headerParts[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length", let parsed = Int(value) {
                contentLength = parsed
            }
        }

        let bodyStart = headerTerminatorRange.upperBound
        let availableBodyBytes = buffer.count - bodyStart
        guard availableBodyBytes >= contentLength else {
            // Body hasn't fully arrived yet.
            return nil
        }

        let body: String?
        if contentLength > 0 {
            let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
            body = String(data: buffer[bodyStart..<bodyEnd], encoding: .utf8)
        } else {
            body = nil
        }

        return RecordedRequest(method: method, path: path, body: body)
    }

    /// `contentType` is optional because a real `204 No Content` login response
    /// carries no `Content-Type` header at all.
    private static func httpResponse(
        status: String,
        contentType: String?,
        body: String,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        let bodyBytes = Data(body.utf8)
        var headerText = "HTTP/1.1 \(status)\r\n"
        if let contentType {
            headerText += "Content-Type: \(contentType)\r\n"
        }
        headerText += "Content-Length: \(bodyBytes.count)\r\nConnection: close\r\n"
        for (name, value) in extraHeaders {
            headerText += "\(name): \(value)\r\n"
        }
        headerText += "\r\n"
        return Data(headerText.utf8) + bodyBytes
    }
}
