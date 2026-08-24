//
//  JellyfinLibrariesUIFixtureServer.swift
//  TrawlUITests
//
//  Stateful loopback Jellyfin server for the Libraries UI journey. The app keeps
//  using JellyfinServiceManager and JellyfinAPIClient; this fixture is only the
//  remote HTTP endpoint and changes its next library-list response after the
//  production DELETE request succeeds.
//

import Foundation
import Network

final class JellyfinLibrariesUIFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let query: [String: String]
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

    static let libraryName = "Fixture Films Library"
    static let libraryPath = "/media/fixture-films"
    static let libraryID = "fixture-films-library"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "JellyfinLibrariesUIFixtureServer")
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var hasLibrary = true

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
            fatalError("Jellyfin Libraries UI fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func requestCount(method: String, path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    func hasReceivedAuthenticatedLibraryList() -> Bool {
        requests.contains {
            $0.method == "GET" &&
            $0.path == "/Library/VirtualFolders" &&
            $0.authorization?.contains("Token=\"uitest-api-key\"") == true
        }
    }

    func hasReceivedAuthenticatedRemovalOfFixtureLibrary() -> Bool {
        requests.contains {
            $0.method == "DELETE" &&
            $0.path == "/Library/VirtualFolders" &&
            $0.query["name"] == Self.libraryName &&
            $0.query["refreshLibrary"] == "true" &&
            $0.authorization?.contains("Token=\"uitest-api-key\"") == true
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
            guard let self else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            guard let request = Self.parseRequest(from: accumulated) else {
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
                return
            }

            lock.lock()
            recordedRequests.append(request)
            if request.method == "DELETE",
               request.path == "/Library/VirtualFolders",
               request.query["name"] == Self.libraryName,
               request.query["refreshLibrary"] == "true" {
                hasLibrary = false
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
    }

    /// Routes mirror the seeded profile's normal service-manager startup and the
    /// libraries list/removal calls used by JellyfinLibrariesView.
    private func response(for request: RecordedRequest) -> Response {
        switch (request.method, request.path) {
        case ("GET", "/System/Info"):
            return .json(
                #"{"Id":"fixture-jellyfin-libraries","ServerName":"Fixture Jellyfin Libraries","Version":"10.11.11","OperatingSystem":"Linux","ProductName":"Jellyfin Server","WebSocketPortNumber":8096}"#
            )
        case ("GET", "/Users"):
            return .json(
                #"[{"Id":"fixture-admin","Name":"Fixture Admin","Policy":{"IsAdministrator":true,"IsDisabled":false}}]"#
            )
        case ("GET", "/Library/VirtualFolders"):
            return hasLibrary ? .json(Self.fixtureLibraryJSON) : .json("[]")
        case ("DELETE", "/Library/VirtualFolders"):
            guard request.query["name"] == Self.libraryName,
                  request.query["refreshLibrary"] == "true" else {
                return .json(#"{"Message":"Unexpected library removal query"}"#, status: 400)
            }
            return .noContent
        default:
            return .json(#"{"Message":"Fixture route not implemented"}"#, status: 404)
        }
    }

    private static let fixtureLibraryJSON = #"""
    [
      {
        "Name": "Fixture Films Library",
        "Locations": ["/media/fixture-films"],
        "CollectionType": "movies",
        "ItemId": "fixture-films-library",
        "RefreshStatus": "Idle"
      }
    ]
    """#

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
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = targetParts.count == 2 ? Self.queryItems(from: String(targetParts[1])) : [:]
        return RecordedRequest(
            method: String(parts[0]),
            path: String(targetParts[0]),
            query: query,
            headers: headers
        )
    }

    private static func queryItems(from query: String) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = query
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { item in
            (item.name, item.value ?? "")
        })
    }

    private static func httpResponse(for response: Response) -> Data {
        let reason: String
        switch response.status {
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "OK"
        }

        let head = "HTTP/1.1 \(response.status) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
