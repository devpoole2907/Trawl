//
//  SeerrUIFixtureServer.swift
//  TrawlUITests
//
//  A loopback Seerr fixture for the end-to-end issue journey. The app still uses its
//  production SeerrServiceManager and SeerrAPIClient; this is only the remote service.
//

import Foundation
import Network

final class SeerrUIFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let body: String

        /// The `jellyfinUserIds` array of an import request, decoded from JSON rather
        /// than string-matched, so the assertion is about the values sent and not
        /// about encoder key order or spacing.
        var jellyfinUserIDs: [String]? {
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object["jellyfinUserIds"] as? [String]
        }
    }

    static let sessionCookie = "uitest-session"
    static let issueID = 701
    static let issueTitle = "Fixture Issue: Audio Dropout"
    static let detailComment = "Fixture comment loaded from the Seerr issue detail response."

    /// The Jellyfin accounts Seerr offers for import. The middle one carries no
    /// username on purpose: `SeerrJellyfinUser.displayName` falls back to the email,
    /// and the import sheet renders that fallback.
    static let importableUsers: [(id: String, displayName: String)] = [
        (id: "jf-ada", displayName: "Fixture Ada"),
        (id: "jf-grace", displayName: "grace@fixture.test"),
        (id: "jf-linus", displayName: "Fixture Linus")
    ]

    /// The Seerr display name each imported Jellyfin ID comes back as.
    static let importedDisplayNames: [String: String] = [
        "jf-ada": "Fixture Ada",
        "jf-grace": "Fixture Grace",
        "jf-linus": "Fixture Linus"
    ]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "SeerrUIFixtureServer")
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var issueIsResolved = false

    init() async throws {
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
            fatalError("Seerr UI fixture server did not bind a port.")
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

    /// The import requests this fixture received, newest last. The journey asserts on
    /// the decoded ID list: the sheet's whole job is turning ticked rows into exactly
    /// this payload.
    var jellyfinImportRequests: [RecordedRequest] {
        requests.filter { $0.method == "POST" && $0.path == "/api/v1/user/import-from-jellyfin" }
    }

    func hasReceivedAuthenticatedRequest(method: String, path: String) -> Bool {
        requests.contains {
            $0.method == method &&
            $0.path == path &&
            $0.headers["cookie"] == "connect.sid=\(Self.sessionCookie)"
        }
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
            guard let self, error == nil else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            guard let request = Self.parseRequest(from: accumulated) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
                return
            }

            self.lock.lock()
            self.recordedRequests.append(request)
            self.lock.unlock()

            let response = self.response(for: request)
            connection.send(
                content: Self.httpResponse(status: response.status, body: response.body),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private func response(for request: RecordedRequest) -> (status: Int, body: String) {
        guard request.headers["cookie"] == "connect.sid=\(Self.sessionCookie)" else {
            return (401, #"{"message":"Unauthorized"}"#)
        }

        switch (request.method, request.path) {
        case ("GET", "/api/v1/auth/me"):
            return (200, Self.authenticatedUserJSON)
        case ("GET", "/api/v1/user"):
            return (200, Self.userListJSON)
        case ("GET", "/api/v1/issue"):
            return (200, issueListJSON())
        case ("GET", "/api/v1/issue/\(Self.issueID)"):
            return (200, issueDetailJSON())
        case ("GET", "/api/v1/settings/jellyfin/users"):
            return (200, Self.jellyfinUsersJSON)
        case ("POST", "/api/v1/user/import-from-jellyfin"):
            return (200, Self.importedUsersJSON(for: request.jellyfinUserIDs ?? []))
        case ("POST", "/api/v1/issue/\(Self.issueID)/resolved"):
            lock.lock()
            issueIsResolved = true
            lock.unlock()
            return (200, issueDetailJSON())
        default:
            return (404, #"{"message":"Fixture route not found"}"#)
        }
    }

    private func issueListJSON() -> String {
        let status = issueStatus
        return #"""
        {
          "pageInfo": { "pages": 1, "pageSize": 20, "results": 1, "page": 1 },
          "results": [
            {
              "id": 701,
              "issueType": 2,
              "status": \#(status),
              "createdAt": "2026-08-24T09:00:00.000Z",
              "updatedAt": "2026-08-24T09:05:00.000Z",
              "media": { "id": 5001, "tmdbId": 424242, "mediaType": "movie", "title": "Fixture Issue: Audio Dropout" },
              "createdBy": { "id": 42, "displayName": "Fixture Reporter", "permissions": 32 },
              "comments": []
            }
          ]
        }
        """#
    }

    private func issueDetailJSON() -> String {
        let status = issueStatus
        return #"""
        {
          "id": 701,
          "issueType": 2,
          "status": \#(status),
          "createdAt": "2026-08-24T09:00:00.000Z",
          "updatedAt": "2026-08-24T09:05:00.000Z",
          "media": { "id": 5001, "tmdbId": 424242, "mediaType": "movie", "title": "Fixture Issue: Audio Dropout" },
          "createdBy": { "id": 42, "displayName": "Fixture Reporter", "permissions": 32 },
          "comments": [
            {
              "id": 9001,
              "user": { "id": 9, "displayName": "Fixture Maintainer", "permissions": 32 },
              "message": "Fixture comment loaded from the Seerr issue detail response.",
              "createdAt": "2026-08-24T09:03:00.000Z",
              "updatedAt": "2026-08-24T09:03:00.000Z"
            }
          ]
        }
        """#
    }

    private var issueStatus: Int {
        lock.lock()
        defer { lock.unlock() }
        return issueIsResolved ? 2 : 1
    }

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n")
        else {
            return nil
        }

        let headerLines = String(text[..<headerEnd.lowerBound]).components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        let target = String(requestParts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            headers[String(pair[0]).lowercased()] = String(pair[1]).trimmingCharacters(in: .whitespaces)
        }

        // Wait for a complete body before answering. Returning a response off the
        // headers alone would record a POST whose payload happened to land in a later
        // TCP segment as an empty body, which is indistinguishable from the app
        // sending nothing.
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let body = String(text[headerEnd.upperBound...])
        guard body.utf8.count >= contentLength else { return nil }

        return RecordedRequest(
            method: String(requestParts[0]),
            path: String(targetParts[0]),
            query: targetParts.count == 2 ? String(targetParts[1]) : "",
            headers: headers,
            body: body
        )
    }

    private static func httpResponse(status: Int, body: String) -> Data {
        let bytes = Data(body.utf8)
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : "Not Found"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }

    private static let jellyfinUsersJSON = #"""
    [
      { "id": "jf-ada", "username": "Fixture Ada", "email": "ada@fixture.test", "thumb": null },
      { "id": "jf-grace", "username": null, "email": "grace@fixture.test", "thumb": null },
      { "id": "jf-linus", "username": "Fixture Linus", "email": null, "thumb": null }
    ]
    """#

    /// Echoes back a Seerr user per requested ID, the way the real endpoint does, so
    /// the list the journey sees afterwards is produced by the response rather than
    /// assumed by the app.
    private static func importedUsersJSON(for ids: [String]) -> String {
        let users = ids.enumerated().map { index, id in
            let name = importedDisplayNames[id] ?? id
            return #"{"id":\#(900 + index),"displayName":"\#(name)","permissions":32,"requestCount":0}"#
        }
        return "[\(users.joined(separator: ","))]"
    }

    private static let authenticatedUserJSON = #"{"id":1,"displayName":"Fixture Admin","permissions":32,"requestCount":1}"#
    private static let userListJSON = #"{"pageInfo":{"pages":1,"pageSize":1,"results":1,"page":1},"results":[{"id":1,"displayName":"Fixture Admin","permissions":32}]}"#
}
