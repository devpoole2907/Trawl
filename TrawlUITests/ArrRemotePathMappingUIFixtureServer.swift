//
//  ArrRemotePathMappingUIFixtureServer.swift
//  TrawlUITests
//
//  A stateful loopback Sonarr server for the remote-path-mapping journey. The app
//  reaches this server through the normal ArrServiceManager → SonarrAPIClient path;
//  the fixture only supplies Sonarr's documented /api/v3 payloads and records the
//  HTTP traffic that production code emits.
//

import Foundation
import Network

final class ArrRemotePathMappingUIFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let body: String
    }

    static let originalRemotePath = "/remote/complete"
    static let originalLocalPath = "/media/complete"
    static let addedRemotePath = "/remote/added"
    static let addedLocalPath = "/media/added"
    static let editedRemotePath = "/remote/edited"
    static let editedLocalPath = "/media/edited"

    private struct Mapping: Codable, Equatable {
        var id: Int
        var host: String
        var remotePath: String
        var localPath: String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ArrRemotePathMappingUIFixtureServer")
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var mappings: [Mapping] = [
        Mapping(
            id: 41,
            host: "*",
            remotePath: ArrRemotePathMappingUIFixtureServer.originalRemotePath,
            localPath: ArrRemotePathMappingUIFixtureServer.originalLocalPath
        )
    ]
    private var nextMappingID = 42

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
            fatalError("ArrRemotePathMappingUIFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedRequest(method: String, path: String, bodyMatching expected: [String: AnyHashable]? = nil) -> Bool {
        requests.contains { request in
            guard request.method == method, request.path == path else { return false }
            guard let expected else { return true }
            return Self.jsonObject(from: request.body).map { object in
                guard object.count == expected.count else { return false }
                return expected.allSatisfy { key, value in
                    guard let received = object[key] as? AnyHashable else { return false }
                    return received == value
                }
            } ?? false
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

    /// Bodies are needed for POST and PUT assertions. Accumulating according to
    /// Content-Length avoids assuming that headers and JSON arrive in the same TCP
    /// receive callback.
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
                handle(request, on: connection)
            } else if error != nil || (isComplete && (data == nil || data!.isEmpty)) {
                connection.cancel()
            } else {
                receive(on: connection, buffer: next)
            }
        }
    }

    private func handle(_ request: RecordedRequest, on connection: NWConnection) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()

        let response = response(for: request)
        connection.send(
            content: Self.httpResponse(status: response.status, body: response.body),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func response(for request: RecordedRequest) -> (status: Int, body: String) {
        switch (request.method, request.path) {
        // The real ArrServiceManager connection sequence for a Sonarr profile.
        case ("GET", "/api/v3/system/status"):
            return (200, "{}")
        case ("GET", "/api/v3/qualityprofile"):
            return (200, #"[{"id":1,"name":"HD"}]"#)
        case ("GET", "/api/v3/rootfolder"):
            return (200, #"[{"id":1,"path":"/tv"}]"#)
        case ("GET", "/api/v3/tag"):
            return (200, "[]")

        case ("GET", "/api/v3/remotepathmapping"):
            return (200, mappingsJSON())
        case ("POST", "/api/v3/remotepathmapping"):
            return createMapping(from: request.body)
        case ("PUT", "/api/v3/remotepathmapping/41"):
            return updateMapping(id: 41, from: request.body)
        case ("PUT", "/api/v3/remotepathmapping/42"):
            return updateMapping(id: 42, from: request.body)
        case ("DELETE", "/api/v3/remotepathmapping/41"):
            return deleteMapping(id: 41)
        case ("DELETE", "/api/v3/remotepathmapping/42"):
            return deleteMapping(id: 42)
        default:
            // These journeys only use the routes above. Returning a valid empty
            // collection keeps unrelated background Arr requests hermetic without
            // making an asserted route look successful by accident.
            return (200, "[]")
        }
    }

    private func createMapping(from body: String) -> (status: Int, body: String) {
        guard var mapping = decodeMapping(from: body) else {
            return (400, "Invalid remote path mapping")
        }

        lock.lock()
        mapping.id = nextMappingID
        nextMappingID += 1
        mappings.append(mapping)
        lock.unlock()
        return (201, encode(mapping))
    }

    private func updateMapping(id: Int, from body: String) -> (status: Int, body: String) {
        guard var mapping = decodeMapping(from: body) else {
            return (400, "Invalid remote path mapping")
        }

        lock.lock()
        defer { lock.unlock() }
        guard let index = mappings.firstIndex(where: { $0.id == id }) else {
            return (404, "No mapping with id \(id)")
        }
        mapping.id = id
        mappings[index] = mapping
        return (200, encode(mapping))
    }

    private func deleteMapping(id: Int) -> (status: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        guard mappings.contains(where: { $0.id == id }) else {
            return (404, "No mapping with id \(id)")
        }
        mappings.removeAll { $0.id == id }
        return (200, "")
    }

    private func mappingsJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = try! JSONEncoder().encode(mappings)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeMapping(from body: String) -> Mapping? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Mapping.self, from: data)
    }

    private func encode(_ mapping: Mapping) -> String {
        let data = try! JSONEncoder().encode(mapping)
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonObject(from body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        let contentLength = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0

        let bodyStart = headerRange.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let bodyEnd = bodyStart + contentLength
        let body = String(data: data[bodyStart..<bodyEnd], encoding: .utf8) ?? ""
        let rawPath = String(requestParts[1])
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")

        return RecordedRequest(method: String(requestParts[0]), path: path, body: body)
    }

    private static func httpResponse(status: Int, body: String) -> Data {
        let bytes = Data(body.utf8)
        let reason: String
        switch status {
        case 201: reason = "Created"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "OK"
        }
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }
}
