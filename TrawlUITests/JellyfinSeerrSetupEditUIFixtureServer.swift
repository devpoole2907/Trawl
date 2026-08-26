//
//  JellyfinSeerrSetupEditUIFixtureServer.swift
//  TrawlUITests
//
//  A loopback fixture for the Jellyfin and Seerr setup/edit journeys. Only the remote
//  service is faked: the app still runs the real `JellyfinSetupViewModel` /
//  `SeerrSetupViewModel`, the real API clients, the real Keychain writes, and the real
//  service managers against this socket.
//
//  Two properties matter for the journeys that use it:
//
//  * Credentials are checked, not assumed. A Jellyfin request whose
//    `Authorization: MediaBrowser … Token="…"` field does not match the configured API
//    key gets a real 401, and a Seerr login whose JSON body does not carry the exact
//    configured username/password gets a real 401 — so the "rejected then corrected"
//    halves of each journey are produced by the server, not by the test.
//  * Anything outside the routes these journeys legitimately exercise is recorded in
//    `unexpectedRequests` and answered with 404 rather than a catch-all success, so a
//    production path that quietly starts calling something else fails loudly instead
//    of being absorbed.
//
//  The parser buffers a complete body before responding, so a POST cannot be matched
//  merely because its body happened to land in the first TCP segment.
//

import Foundation
import Network

final class JellyfinSeerrSetupEditUIFixtureServer: @unchecked Sendable {
    enum Role {
        /// Serves the exact route set `JellyfinSetupViewModel.authenticate` and
        /// `JellyfinServiceManager.connectService` use in API-key mode.
        case jellyfin(apiKey: String, serverName: String, version: String)
        /// Serves the route set `SeerrSetupViewModel.login`,
        /// `SeerrServiceManager.connectService` and `SeerrSettingsView` use.
        case seerr(username: String, password: String, sessionCookie: String, applicationTitle: String)
    }

    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let queryItems: [String: String]
        /// Header names are lowercased; values keep their original casing.
        let headers: [String: String]
        let body: String

        var authorization: String? { headers["authorization"] }
        var cookie: String? { headers["cookie"] }
        var contentType: String? { headers["content-type"] }

        /// The `Token="…"` field of Jellyfin's `Authorization` header, or nil when the
        /// request was made without one (the unauthenticated `/System/Info/Public`
        /// probe `JellyfinSetupViewModel` performs before authenticating).
        var jellyfinToken: String? {
            guard let authorization else { return nil }
            guard let range = authorization.range(of: #"Token=""#) else { return nil }
            let remainder = authorization[range.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { return nil }
            return String(remainder[..<end]).removingPercentEncoding ?? String(remainder[..<end])
        }

        /// The request body parsed as a JSON object, so assertions compare decoded
        /// values instead of encoder-dependent key ordering.
        var jsonBody: [String: String]? {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object.compactMapValues { $0 as? String }
        }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let role: Role
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var recordedUnexpectedRequests: [RecordedRequest] = []

    init(role: Role) async throws {
        self.role = role
        self.queue = DispatchQueue(label: "JellyfinSeerrSetupEditUIFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else {
            fatalError("JellyfinSeerrSetupEditUIFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    /// Requests this fixture had no legitimate route for. Non-empty means production
    /// called something these journeys never traced, which the tests assert on rather
    /// than swallow.
    var unexpectedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedUnexpectedRequests
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Jellyfin matchers

    func hasReceivedJellyfinRequest(method: String, path: String, token: String?) -> Bool {
        jellyfinRequestCount(method: method, path: path, token: token) > 0
    }

    func jellyfinRequestCount(method: String, path: String, token: String?) -> Int {
        requests.filter { $0.method == method && $0.path == path && $0.jellyfinToken == token }.count
    }

    /// Every Jellyfin request must carry the client identity fields
    /// `JellyfinAuthHeader.value(token:)` builds, whether or not a token is present.
    func hasReceivedJellyfinRequestWithClientIdentity(method: String, path: String) -> Bool {
        requests.contains { request in
            request.method == method &&
                request.path == path &&
                request.authorization?.hasPrefix("MediaBrowser ") == true &&
                request.authorization?.contains(#"Client="Trawl""#) == true &&
                request.authorization?.contains("DeviceId=\"") == true
        }
    }

    // MARK: - Seerr matchers

    /// Matches Seerr's real sign-in request: `POST /api/v1/auth/jellyfin`, a JSON
    /// content type, no query string, and a JSON body carrying exactly these
    /// credentials.
    func hasReceivedSeerrLogin(username: String, password: String) -> Bool {
        requests.contains { request in
            request.method == "POST" &&
                request.path == "/api/v1/auth/jellyfin" &&
                request.queryItems.isEmpty &&
                request.contentType == "application/json" &&
                request.jsonBody == ["username": username, "password": password]
        }
    }

    func hasReceivedSeerrRequest(method: String, path: String, cookie: String) -> Bool {
        seerrRequestCount(method: method, path: path, cookie: cookie) > 0
    }

    func seerrRequestCount(method: String, path: String, cookie: String) -> Int {
        requests.filter {
            $0.method == method && $0.path == path && $0.cookie == "connect.sid=\(cookie)"
        }.count
    }

    func hasReceivedSeerrRequest(
        method: String,
        path: String,
        queryItems: [String: String],
        cookie: String
    ) -> Bool {
        requests.contains {
            $0.method == method &&
                $0.path == path &&
                $0.queryItems == queryItems &&
                $0.cookie == "connect.sid=\(cookie)"
        }
    }

    /// Any request bearing a credential this server was never meant to see. The
    /// journeys assert the *old* fixture never receives one: after a successful
    /// repoint, the replacement credential is the only one production holds, so a
    /// manager or client still aimed at the old host would show up here regardless of
    /// when a background refresh happens to fire.
    func hasReceivedRequestCarrying(jellyfinToken token: String) -> Bool {
        requests.contains { $0.jellyfinToken == token }
    }

    func hasReceivedRequestCarrying(seerrCookie cookie: String) -> Bool {
        requests.contains { $0.cookie == "connect.sid=\(cookie)" }
    }

    // MARK: - HTTP handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if let request = Self.parseRequest(from: accumulated) {
                let response = self.record(request)
                connection.send(
                    content: response,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            } else if error != nil || (isComplete && (data == nil || data?.isEmpty == true)) {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: accumulated)
            }
        }
    }

    private func record(_ request: RecordedRequest) -> Data {
        let response = self.response(for: request)
        lock.lock()
        recordedRequests.append(request)
        if response.isUnexpectedRoute {
            recordedUnexpectedRequests.append(request)
        }
        lock.unlock()
        return Self.httpResponse(status: response.status, headers: response.headers, body: response.body)
    }

    private struct Response {
        let status: Int
        let headers: [String: String]
        let body: String
        let isUnexpectedRoute: Bool

        static func json(_ body: String, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: body, isUnexpectedRoute: false)
        }

        static let unexpectedRoute = Response(
            status: 404,
            headers: [:],
            body: #"{"message":"No fixture route: this journey never traced this call."}"#,
            isUnexpectedRoute: true
        )
    }

    private func response(for request: RecordedRequest) -> Response {
        switch role {
        case let .jellyfin(apiKey, serverName, version):
            return jellyfinResponse(for: request, apiKey: apiKey, serverName: serverName, version: version)
        case let .seerr(username, password, sessionCookie, applicationTitle):
            return seerrResponse(
                for: request,
                username: username,
                password: password,
                sessionCookie: sessionCookie,
                applicationTitle: applicationTitle
            )
        }
    }

    // MARK: - Jellyfin routes

    /// `GET /System/Info/Public` is the unauthenticated probe
    /// `JellyfinSetupViewModel.authenticate` runs first; `GET /System/Info` and
    /// `GET /Users` are the authenticated calls it and `JellyfinServiceManager
    /// .connectService` make. Nothing else is served.
    private func jellyfinResponse(
        for request: RecordedRequest,
        apiKey: String,
        serverName: String,
        version: String
    ) -> Response {
        switch (request.method, request.path) {
        case ("GET", "/System/Info/Public"):
            return .json(
                #"{"Id":"\#(serverName)-id","ServerName":"\#(serverName)","Version":"\#(version)","ProductName":"Jellyfin Server","StartupCompleted":true}"#
            )
        case ("GET", "/System/Info"):
            guard request.jellyfinToken == apiKey else { return Self.jellyfinUnauthorized }
            return .json(
                #"{"Id":"\#(serverName)-id","ServerName":"\#(serverName)","Version":"\#(version)","OperatingSystem":"Linux","ProductName":"Jellyfin Server","WebSocketPortNumber":8096}"#
            )
        case ("GET", "/Users"):
            guard request.jellyfinToken == apiKey else { return Self.jellyfinUnauthorized }
            return .json(
                #"[{"Id":"fixture-admin","Name":"Fixture Admin","Policy":{"IsAdministrator":true,"IsDisabled":false}}]"#
            )
        default:
            return .unexpectedRoute
        }
    }

    private static let jellyfinUnauthorized = Response.json(
        #"{"Message":"Invalid API key."}"#,
        status: 401
    )

    // MARK: - Seerr routes

    /// `POST /api/v1/auth/jellyfin` is the real sign-in `SeerrSetupViewModel.login`
    /// performs; `GET /api/v1/auth/me` is what `SeerrServiceManager.connectService`
    /// calls and the setup flow never does, which is what lets a journey tell a real
    /// manager reconnect apart from the sign-in that preceded it. `/api/v1/user` is the
    /// manager's user-count prefetch, `/api/v1/settings/public` backs
    /// `SeerrSettingsView`'s System Status section, and `/api/v1/request` is the
    /// notification accessory's slow pending-approvals poll.
    private func seerrResponse(
        for request: RecordedRequest,
        username: String,
        password: String,
        sessionCookie: String,
        applicationTitle: String
    ) -> Response {
        if request.method == "POST", request.path == "/api/v1/auth/jellyfin" {
            guard request.jsonBody == ["username": username, "password": password] else {
                return .json(#"{"message":"Unable to sign in."}"#, status: 401)
            }
            return .json(
                Self.seerrAdminUserJSON,
                headers: ["Set-Cookie": "connect.sid=\(sessionCookie); Path=/; HttpOnly; SameSite=Lax"]
            )
        }

        guard request.cookie == "connect.sid=\(sessionCookie)" else {
            return .json(#"{"message":"Unauthorized"}"#, status: 401)
        }

        switch (request.method, request.path) {
        case ("GET", "/api/v1/auth/me"):
            return .json(Self.seerrAdminUserJSON)
        case ("GET", "/api/v1/user"):
            return .json(
                #"{"pageInfo":{"pages":1,"pageSize":1,"results":1,"page":1},"results":[\#(Self.seerrAdminUserJSON)]}"#
            )
        case ("GET", "/api/v1/settings/public"):
            return .json(
                #"{"initialized":true,"applicationTitle":"\#(applicationTitle)","localLogin":true,"mediaServerType":2,"hideAvailable":false,"partialRequestsEnabled":true}"#
            )
        case ("GET", "/api/v1/request"):
            return .json(#"{"pageInfo":{"pages":0,"pageSize":20,"results":0,"page":1},"results":[]}"#)
        default:
            return .unexpectedRoute
        }
    }

    private static let seerrAdminUserJSON =
        #"{"id":1,"displayName":"Fixture Admin","jellyfinUsername":"fixture-admin","permissions":2,"requestCount":0}"#

    // MARK: - Wire format

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
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
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = String(data: data[bodyStart..<bodyEnd], encoding: .utf8) ?? ""

        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        let query = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""

        return RecordedRequest(
            method: String(parts[0]),
            path: path,
            queryItems: queryItems(in: query),
            headers: headers,
            body: body
        )
    }

    private static func queryItems(in value: String) -> [String: String] {
        guard !value.isEmpty,
              let components = URLComponents(string: "http://fixture.invalid/?\(value)") else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func httpResponse(status: Int, headers: [String: String], body: String) -> Data {
        let bytes = Data(body.utf8)
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + bytes
    }
}
