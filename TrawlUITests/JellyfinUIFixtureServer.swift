//
//  JellyfinUIFixtureServer.swift
//  TrawlUITests
//
//  A stateful loopback Jellyfin server for the tier-1 UI journey. It serves the
//  exact production endpoints used by the seeded startup connection and the
//  Media Server → Sessions path; no application method is replaced or mocked.
//

import Foundation
import Network

final class JellyfinUIFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let headers: [String: String]

        var authorization: String? { headers["authorization"] }
    }

    private struct Response {
        let status: Int
        let body: Data

        static func json(_ body: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(body.utf8))
        }

        static let noContent = Response(status: 204, body: Data())
    }

    static let serverName = "Fixture Jellyfin Server"
    static let userName = "Fixture Admin"
    static let episodeName = "Fixture Episode: The Signal"
    static let sessionID = "fixture-session-1"

    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var hasActivePlayback = true

    init() async throws {
        queue = DispatchQueue(label: "JellyfinUIFixtureServer")
        listener = try NWListener(using: .tcp, on: .any)

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
            fatalError("Jellyfin UI fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

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

    func stop() {
        listener.cancel()
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
                self.handle(request, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: accumulated)
            }
        }
    }

    private func handle(_ request: RecordedRequest, on connection: NWConnection) {
        lock.lock()
        recordedRequests.append(request)
        if request.method == "POST", request.path == "/Sessions/\(Self.sessionID)/Playing/Stop" {
            hasActivePlayback = false
        }
        let response = response(for: request)
        lock.unlock()

        connection.send(
            content: Self.httpResponse(for: response),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// Each route mirrors the real `JellyfinAPIClient` calls made by this journey:
    /// manager startup (`/System/Info`, `/Users`), session rendering (`/Sessions`),
    /// and the destructive session control action (`POST .../Playing/Stop`).
    private func response(for request: RecordedRequest) -> Response {
        switch (request.method, request.path) {
        case ("GET", "/System/Info"):
            return .json(
                #"{"Id":"fixture-jellyfin-server","ServerName":"Fixture Jellyfin Server","Version":"10.11.11","OperatingSystem":"Linux","ProductName":"Jellyfin Server","WebSocketPortNumber":8096}"#
            )
        case ("GET", "/Users"):
            return .json(
                #"[{"Id":"fixture-admin","Name":"Fixture Admin","Policy":{"IsAdministrator":true,"IsDisabled":false}}]"#
            )
        case ("GET", "/Sessions"):
            return hasActivePlayback ? .json(activeSessionJSON) : .json("[]")
        case ("POST", "/Sessions/\(Self.sessionID)/Playing/Stop"):
            return .noContent
        default:
            return .json(#"{"Message":"Fixture route not implemented"}"#, status: 404)
        }
    }

    private var activeSessionJSON: String {
        #"[{"Id":"fixture-session-1","UserId":"fixture-admin","UserName":"Fixture Admin","DeviceName":"Apple TV","Client":"Swiftfin","ApplicationVersion":"1.2.3","LastActivityDate":"2026-08-24T10:00:00.0000000Z","SupportsRemoteControl":true,"NowPlayingItem":{"Id":"fixture-episode-3","Name":"Fixture Episode: The Signal","Type":"Episode","RunTimeTicks":27000000000,"SeriesName":"Fixture Series","SeasonName":"Season 1","IndexNumber":3},"PlayState":{"PositionTicks":9000000000,"IsPaused":false,"IsMuted":false,"CanSeek":true,"PlayMethod":"DirectPlay","RepeatMode":"RepeatNone","VolumeLevel":80}}]"#
    }

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else {
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
        let body = data[headEnd.upperBound...]
        guard body.count >= contentLength else { return nil }

        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        return RecordedRequest(method: String(parts[0]), path: path, headers: headers)
    }

    private static func httpResponse(for response: Response) -> Data {
        let reason = response.status == 204 ? "No Content" : response.status == 404 ? "Not Found" : "OK"
        let head = "HTTP/1.1 \(response.status) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
