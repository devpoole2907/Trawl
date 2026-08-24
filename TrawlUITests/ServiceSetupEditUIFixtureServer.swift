//
//  ServiceSetupEditUIFixtureServer.swift
//  TrawlUITests
//
//  A deliberately small, stateful loopback fixture used by the setup/edit UI
//  journeys. It supports the exact qBittorrent and SABnzbd handshakes that the
//  production setup view models perform. The parser buffers a complete HTTP body
//  before responding, so form posts cannot pass merely because their body happened
//  to arrive in the first TCP packet.
//

import Foundation
import Network

final class ServiceSetupEditUIFixtureServer: @unchecked Sendable {
    enum Service {
        case qbittorrent(username: String, password: String)
        case sabnzbd(apiKey: String)
    }

    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let queryItems: [String: String]
        let body: String

        func formValue(named name: String) -> String? {
            Self.items(in: body)[name]
        }

        private static func items(in value: String) -> [String: String] {
            guard let components = URLComponents(string: "http://fixture.invalid/?\(value)") else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let service: Service
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []

    init(service: Service) async throws {
        self.service = service
        self.queue = DispatchQueue(label: "ServiceSetupEditUIFixtureServer")
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
            fatalError("ServiceSetupEditUIFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedQBittorrentLogin(username: String, password: String) -> Bool {
        requests.contains {
            $0.method == "POST" &&
                $0.path == "/api/v2/auth/login" &&
                $0.formValue(named: "username") == username &&
                $0.formValue(named: "password") == password
        }
    }

    func hasReceivedSABnzbdRequest(mode: String, apiKey: String, extraKey: String? = nil) -> Bool {
        requests.contains { request in
            guard request.method == "GET", request.path == "/api", request.queryItems["mode"] == mode,
                  request.queryItems["apikey"] == apiKey else {
                return false
            }
            guard let extraKey else { return true }
            return request.queryItems["key"] == extraKey
        }
    }

    func stop() {
        listener.cancel()
    }

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

            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }

            if let request = Self.parseRequest(from: next) {
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
            } else if error != nil || (isComplete && (data == nil || data?.isEmpty == true)) {
                connection.cancel()
            } else {
                receive(on: connection, buffer: next)
            }
        }
    }

    private func respond(to request: RecordedRequest) -> Data {
        switch service {
        case .qbittorrent(let username, let password):
            respondToQBittorrent(request, username: username, password: password)
        case .sabnzbd(let apiKey):
            respondToSABnzbd(request, apiKey: apiKey)
        }
    }

    private func respondToQBittorrent(_ request: RecordedRequest, username: String, password: String) -> Data {
        switch (request.method, request.path) {
        case ("POST", "/api/v2/auth/login"):
            guard request.formValue(named: "username") == username,
                  request.formValue(named: "password") == password else {
                return Self.response(status: 403, reason: "Forbidden", headers: [:], body: Data("Fails.".utf8))
            }
            return Self.response(
                status: 204,
                reason: "No Content",
                headers: ["Set-Cookie": cookieHeader],
                body: Data()
            )
        case ("GET", "/api/v2/app/version"):
            return Self.response(status: 200, reason: "OK", headers: ["Content-Type": "text/plain"], body: Data("v5.2.3".utf8))
        case ("GET", "/api/v2/app/preferences"):
            return Self.json("{}")
        case ("GET", "/api/v2/sync/maindata"):
            return Self.json(#"{"full_update":true,"rid":1,"torrents":{}}"#)
        default:
            return Self.json("{}")
        }
    }

    private func respondToSABnzbd(_ request: RecordedRequest, apiKey: String) -> Data {
        guard request.queryItems["apikey"] == apiKey else {
            return Self.response(status: 401, reason: "Unauthorized", headers: ["Content-Type": "application/json"], body: Data(#"{"status":false,"error":"API Key Incorrect"}"#.utf8))
        }

        switch request.queryItems["mode"] {
        case "auth":
            guard request.queryItems["key"] == apiKey else {
                return Self.response(status: 401, reason: "Unauthorized", headers: ["Content-Type": "application/json"], body: Data(#"{"status":false,"error":"API Key Incorrect"}"#.utf8))
            }
            return Self.json(#"{"auth":"apikey"}"#)
        case "version":
            return Self.json(#"{"version":"4.5.0"}"#)
        case "queue":
            return Self.json(#"{"queue":{"status":"Downloading","paused":false,"slots":[]}}"#)
        case "history":
            return Self.json(#"{"history":{"slots":[]}}"#)
        case "get_cats":
            return Self.json(#"{"categories":["*","movies"]}"#)
        case "get_scripts":
            return Self.json(#"{"scripts":["None"]}"#)
        default:
            return Self.json("{}")
        }
    }

    private var cookieHeader: String {
        guard let port = listener.port else {
            fatalError("ServiceSetupEditUIFixtureServer did not bind a port.")
        }
        return "QBT_SID_\(port.rawValue)=setup-edit-session; HttpOnly; SameSite=Lax; path=/"
    }

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        let query = target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let queryItems = queryItems(in: query)
        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame else {
                return nil
            }
            return Int(pieces[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0

        let bodyStart = separator.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = String(data: data[bodyStart..<bodyEnd], encoding: .utf8) ?? ""
        return RecordedRequest(method: String(parts[0]), path: path, queryItems: queryItems, body: body)
    }

    private static func queryItems(in value: String) -> [String: String] {
        guard let components = URLComponents(string: "http://fixture.invalid/?\(value)") else { return [:] }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static func json(_ body: String) -> Data {
        response(status: 200, reason: "OK", headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    private static func response(status: Int, reason: String, headers: [String: String], body: Data) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(text.utf8) + body
    }
}
