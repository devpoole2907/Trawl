//
//  CleanuparrUIFixtureServer.swift
//  TrawlUITests
//
//  A loopback Cleanuparr server for the dashboard journey. It stands in only for
//  Cleanuparr's remote Stats and Health APIs; the app still performs its real
//  profile seeding, Keychain lookup, manager connection, HTTP request building,
//  decoding, state updates, and SwiftUI navigation.
//

import Foundation
import Network

final class CleanuparrUIFixtureServer: @unchecked Sendable {
    enum StatsAvailability: Sendable, Equatable {
        case available
        case unavailable
    }

    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    static let apiKey = "uitest-api-key"

    private let listener: NWListener
    private let queue: DispatchQueue
    private let statsAvailability: StatsAvailability

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []

    init(statsAvailability: StatsAvailability = .available) async throws {
        self.queue = DispatchQueue(label: "CleanuparrUIFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.statsAvailability = statsAvailability

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
            fatalError("CleanuparrUIFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedStatsRequest(hours: Int, includeDryRun: Bool) -> Bool {
        requests.contains {
            $0.method == "GET" &&
            $0.path == "/api/v2/stats" &&
            $0.query["hours"] == String(hours) &&
            $0.query["includeDryRun"] == (includeDryRun ? "true" : "false") &&
            $0.headers["x-api-key"] == Self.apiKey
        }
    }

    func hasReceivedRequest(method: String, path: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - HTTP handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// `NWConnection.receive` is stream-based, so accumulate bytes until the full
    /// request header arrives instead of assuming one callback contains the complete
    /// GET request. Cleanuparr's dashboard path is read-only and bodyless.
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
                self.record(request)
                self.respond(to: request, on: connection)
            } else if error != nil || (isComplete && (data == nil || data!.isEmpty)) {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func record(_ request: RecordedRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    private func respond(to request: RecordedRequest, on connection: NWConnection) {
        let response = response(for: request)
        connection.send(
            content: Self.httpResponse(status: response.status, reason: response.reason, body: response.body),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// Routes are taken from `CleanuparrAPIClient`: connection validates
    /// `GET /api/v2/stats?hours=168&includeDryRun=false`, then checks
    /// `GET /health/ready`; the dashboard's toggle refreshes that same Stats route
    /// with `includeDryRun=true`.
    private func response(for request: RecordedRequest) -> (status: Int, reason: String, body: String) {
        switch (request.method, request.path) {
        case ("GET", "/api/v2/stats"):
            guard statsAvailability == .available else {
                return (503, "Service Unavailable", #"{"message":"Fixture stats service unavailable"}"#)
            }
            let isIncludingDryRuns = request.query["includeDryRun"] == "true"
            return (200, "OK", isIncludingDryRuns ? Self.dryRunStatsJSON : Self.normalStatsJSON)

        case ("GET", "/health/ready"), ("GET", "/health"):
            return (200, "OK", "")

        default:
            return (404, "Not Found", #"{"message":"Fixture route not found"}"#)
        }
    }

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        let headerDelimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: headerDelimiter),
              let headerText = String(data: Data(data[..<headerRange.lowerBound]), encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLineParts.count >= 2 else { return nil }

        let method = String(requestLineParts[0])
        let target = String(requestLineParts[1])
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        let query = (components?.queryItems ?? []).reduce(into: [String: String]()) { values, item in
            values[item.name] = item.value ?? ""
        }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { values, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            values[name] = value
        }

        return RecordedRequest(
            method: method,
            path: components?.path ?? "",
            query: query,
            headers: headers
        )
    }

    private static func httpResponse(status: Int, reason: String, body: String) -> Data {
        let bytes = Data(body.utf8)
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }

    /// Complete documented v2 shapes are intentional: `CleanuparrStats` has no
    /// lossy defaults, so a partial stub would test the fixture rather than the
    /// production decoder used by the dashboard.
    private static let normalStatsJSON = #"""
    {
      "events": {
        "total": 7,
        "byType": { "StalledStrike": 4, "QueueItemDeleted": 3 },
        "bySeverity": { "Warning": 5, "Information": 2 }
      },
      "strikes": {
        "total": 4,
        "byType": { "Stalled": 4 },
        "recovered": 2
      },
      "removals": {
        "total": 3,
        "byReason": { "Stalled": 2, "Orphaned": 1 }
      },
      "cleaned": {
        "total": 2,
        "byReason": { "Seeding": 2 }
      },
      "searches": {
        "total": 9,
        "completed": 7,
        "failed": 2,
        "grabbed": 5,
        "byReason": { "Replacement": 5, "Upgrade": 4 }
      },
      "jobs": {
        "total": 6,
        "completed": 5,
        "failed": 1,
        "byType": {
          "QueueCleaner": {
            "total": 6,
            "completed": 5,
            "failed": 1,
            "lastRunAt": "2026-08-24T00:00:00Z",
            "nextRunAt": "2026-08-24T00:05:00Z"
          }
        }
      },
      "health": {
        "downloadClients": [{
          "id": "fixture-download-client",
          "name": "Fixture qBittorrent",
          "type": "qBittorrent",
          "isHealthy": true,
          "lastChecked": "2026-08-24T00:00:00Z",
          "responseTimeMs": 12.5,
          "errorMessage": null
        }],
        "arrInstances": [{
          "id": "fixture-arr-instance",
          "name": "Fixture Radarr",
          "type": "Radarr",
          "isHealthy": false,
          "lastChecked": "2026-08-24T00:00:00Z",
          "responseTimeMs": null,
          "errorMessage": "Fixture Radarr is unavailable"
        }]
      },
      "timeframeHours": 168,
      "generatedAt": "2026-08-24T00:00:00Z"
    }
    """#

    private static let dryRunStatsJSON = #"""
    {
      "events": {
        "total": 11,
        "byType": { "DryRun": 11 },
        "bySeverity": { "Information": 11 }
      },
      "strikes": {
        "total": 0,
        "byType": {},
        "recovered": 0
      },
      "removals": {
        "total": 0,
        "byReason": {}
      },
      "cleaned": {
        "total": 0,
        "byReason": {}
      },
      "searches": {
        "total": 2,
        "completed": 2,
        "failed": 0,
        "grabbed": 0,
        "byReason": { "DryRun": 2 }
      },
      "jobs": {
        "total": 2,
        "completed": 2,
        "failed": 0,
        "byType": {
          "DryRunCleaner": {
            "total": 2,
            "completed": 2,
            "failed": 0,
            "lastRunAt": "2026-08-24T00:00:00Z",
            "nextRunAt": "2026-08-24T00:05:00Z"
          }
        }
      },
      "health": {
        "downloadClients": [{
          "id": "fixture-download-client",
          "name": "Fixture Dry Run qBittorrent",
          "type": "qBittorrent",
          "isHealthy": true,
          "lastChecked": "2026-08-24T00:00:00Z",
          "responseTimeMs": 9.5,
          "errorMessage": null
        }],
        "arrInstances": []
      },
      "timeframeHours": 168,
      "generatedAt": "2026-08-24T00:00:00Z"
    }
    """#
}
