//
//  ProwlarrUIFixtureServer.swift
//  TrawlUITests
//
//  A loopback Prowlarr server for the tier-1 UI journeys. It serves the real
//  `/api/v1` shapes consumed by ProwlarrAPIClient and records the app's requests;
//  no production client, view model, or navigation code is replaced in tests.

import Foundation
import Network

final class ProwlarrUIFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: String
    }

    static let indexerName = "Fixture Torrent Indexer"
    static let proxyName = "Fixture HTTP Proxy"
    static let tagName = "Fixture Routing Tag"
    static let applicationName = "Fixture Sonarr Link"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ProwlarrUIFixtureServer")
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    private var tags: [(id: Int, label: String)] = [(101, ProwlarrUIFixtureServer.tagName)]
    private var nextTagID = 102

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
            fatalError("ProwlarrUIFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedRequest(
        method: String,
        path: String,
        header name: String? = nil,
        equals expectedValue: String? = nil
    ) -> Bool {
        requests.contains { request in
            guard request.method == method, request.path == path else { return false }
            guard let name else { return true }
            let value = request.headers[name.lowercased()]
            if let expectedValue {
                return value == expectedValue
            }
            return value != nil
        }
    }

    func hasReceivedRequest(method: String, path: String, bodyContains text: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path && $0.body.contains(text) }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - HTTP handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// A `POST /api/v1/tag` body is not guaranteed to arrive with its headers, so
    /// accumulate until Content-Length bytes have been received before parsing it.
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
        case ("GET", "/api/v1/system/status"):
            return (200, #"{"appName":"Prowlarr","version":"1.0.0"}"#)
        case ("GET", "/api/v1/indexer"):
            return (200, Self.indexersJSON)
        case ("GET", "/api/v1/indexerstatus"):
            return (200, #"[{"id":1,"indexerId":11}]"#)
        case ("GET", "/api/v1/indexerstats"):
            return (200, #"{"indexers":[{"indexerId":11,"indexerName":"Fixture Torrent Indexer","averageResponseTime":75.0,"numberOfQueries":8,"numberOfGrabs":2,"numberOfFailedQueries":1}]}"#)
        case ("GET", "/api/v1/appprofile"):
            return (200, #"[{"id":1,"name":"Standard"}]"#)
        case ("GET", "/api/v1/tag"):
            return (200, tagsJSON())
        case ("POST", "/api/v1/tag"):
            return createTagResponse(for: request.body)
        case ("POST", "/api/v1/indexer/test"):
            return (200, "")
        case ("GET", "/api/v1/applications"):
            return (200, Self.applicationsJSON)
        case ("GET", "/api/v1/applications/schema"):
            return (200, Self.applicationSchemaJSON)
        case ("GET", "/api/v1/indexerProxy"):
            return (200, Self.proxiesJSON)
        case ("GET", "/api/v1/indexerProxy/schema"):
            return (200, Self.proxySchemaJSON)
        default:
            // Background health/calendar work is outside these journeys. An empty
            // array is valid for the remaining collection endpoints and keeps the
            // fixture hermetic without masking any asserted route.
            return (200, "[]")
        }
    }

    private func createTagResponse(for body: String) -> (status: Int, body: String) {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let label = object["label"] as? String,
              !label.isEmpty else {
            return (400, "Missing tag label")
        }

        lock.lock()
        let tag = (id: nextTagID, label: label)
        nextTagID += 1
        tags.append(tag)
        lock.unlock()
        return (201, #"{"id":\#(tag.id),"label":"\#(tag.label)"}"#)
    }

    private func tagsJSON() -> String {
        lock.lock()
        defer { lock.unlock() }
        let rows = tags.map { #"{"id":\#($0.id),"label":"\#($0.label)"}"# }.joined(separator: ",")
        return "[\(rows)]"
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

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count - bodyStart >= contentLength else { return nil }
        let bodyEnd = bodyStart + contentLength
        let body = String(data: data[bodyStart..<bodyEnd], encoding: .utf8) ?? ""
        let rawPath = String(requestParts[1])
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")

        return RecordedRequest(
            method: String(requestParts[0]),
            path: path,
            headers: headers,
            body: body
        )
    }

    private static func httpResponse(status: Int, body: String) -> Data {
        let bytes = Data(body.utf8)
        let reason = status == 201 ? "Created" : "OK"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }

    private static let indexersJSON = #"""
    [{
      "id":11,
      "name":"Fixture Torrent Indexer",
      "enable":true,
      "implementation":"Cardigann",
      "implementationName":"Cardigann",
      "configContract":"CardigannSettings",
      "tags":[101],
      "priority":25,
      "appProfileId":1,
      "shouldSearch":true,
      "supportsRss":true,
      "supportsSearch":true,
      "protocol":"torrent",
      "fields":[{"name":"baseUrl","label":"Base URL","value":"https://indexer.fixture","type":"textbox","advanced":false}]
    }]
    """#

    private static let applicationsJSON = #"""
    [{
      "id":21,
      "name":"Fixture Sonarr Link",
      "implementation":"Sonarr",
      "implementationName":"Sonarr",
      "configContract":"SonarrSettings",
      "syncLevel":"fullSync",
      "tags":[101],
      "fields":[{"name":"baseUrl","label":"Sonarr URL","value":"http://sonarr.fixture","type":"textbox","advanced":false}]
    }]
    """#

    private static let applicationSchemaJSON = #"""
    [{"implementation":"Sonarr","implementationName":"Sonarr","configContract":"SonarrSettings","fields":[]}]
    """#

    private static let proxiesJSON = #"""
    [{
      "id":31,
      "name":"Fixture HTTP Proxy",
      "implementation":"Http",
      "implementationName":"Http",
      "configContract":"HttpSettings",
      "tags":[101],
      "fields":[
        {"name":"host","label":"Host","value":"proxy.fixture","type":"textbox","advanced":false},
        {"name":"port","label":"Port","value":8080,"type":"number","advanced":false}
      ]
    }]
    """#

    private static let proxySchemaJSON = #"""
    [{"implementation":"Http","implementationName":"Http","configContract":"HttpSettings","fields":[]}]
    """#
}
