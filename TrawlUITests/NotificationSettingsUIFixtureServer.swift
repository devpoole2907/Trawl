//
//  NotificationSettingsUIFixtureServer.swift
//  TrawlUITests
//
//  Stateful loopback Sonarr fixture for Notification Settings journeys. The app
//  still performs its normal ArrServiceManager -> SonarrAPIClient requests; this
//  type only represents the external server and records the complete HTTP shape.
//

import Foundation
import Network

final class NotificationSettingsUIFixtureServer: @unchecked Sendable {
    enum NotificationListBehavior: Sendable, Equatable {
        case configured
        case failing
    }

    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        var bodyString: String { String(decoding: body, as: UTF8.self) }
    }

    static let deviceToken = "trawl-ui-test-apns-token-v1"
    static let notificationID = 91
    static let tagID = 27
    static let tagLabel = "Release Alerts"
    static let failureMessage = "Fixture notification configuration failed."

    private struct Response {
        let status: Int
        let body: Data

        static func json(_ string: String, status: Int = 200) -> Response {
            Response(status: status, body: Data(string.utf8))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "NotificationSettingsUIFixtureServer")
    private let lock = NSLock()
    private let notificationListBehavior: NotificationListBehavior
    private var recordedRequests: [RecordedRequest] = []
    private var unexpectedRequests: [RecordedRequest] = []
    private var currentNotificationJSON = NotificationSettingsUIFixtureServer.configuredNotificationJSON

    init(notificationListBehavior: NotificationListBehavior = .configured) async throws {
        self.notificationListBehavior = notificationListBehavior
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
            fatalError("Notification Settings fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var unexpectedRequestDescriptions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return unexpectedRequests.map { "\($0.method) \($0.path)?\($0.query) \($0.bodyString)" }
    }

    func requestCount(method: String, path: String) -> Int {
        requests.count { $0.method == method && $0.path == path }
    }

    func receivedAuthenticatedNotificationRead() -> Bool {
        requests.contains {
            $0.method == "GET" &&
            $0.path == "/api/v3/notification" &&
            $0.headers["x-api-key"] == "uitest-api-key"
        }
    }

    func receivedExactSave() -> Bool {
        requests.contains { request in
            guard request.method == "PUT",
                  request.path == "/api/v3/notification/\(Self.notificationID)",
                  request.query.isEmpty,
                  request.headers["x-api-key"] == "uitest-api-key",
                  request.headers["content-type"]?.lowercased().contains("application/json") == true,
                  let payload = Self.jsonObject(from: request.body) else {
                return false
            }

            return Self.matchesExactSavePayload(payload)
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
                    receive(on: connection, buffer: accumulated)
                }
                return
            }

            let response = recordAndRespond(to: request)
            connection.send(
                content: Self.httpResponse(for: response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private func recordAndRespond(to request: RecordedRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)

        switch (request.method, request.path) {
        // `ArrServiceManager.connectService(_:)` for the seeded Sonarr profile.
        case ("GET", "/api/v3/system/status"):
            return .json("{}")
        case ("GET", "/api/v3/qualityprofile"):
            return .json(#"[{"id":1,"name":"HD"}]"#)
        case ("GET", "/api/v3/rootfolder"):
            return .json(#"[{"id":1,"path":"/tv"}]"#)
        case ("GET", "/api/v3/tag"):
            return .json(#"[{"id":27,"label":"Release Alerts"}]"#)

        // Normal app startup and the Notifications sheet prefetch these Sonarr
        // surfaces. They are intentionally empty but correctly shaped so this
        // journey remains hermetic without treating unrelated background reads
        // as notification failures.
        case ("GET", "/api/v3/queue"),
             ("GET", "/api/v3/history"),
             ("GET", "/api/v3/blocklist"):
            return .json("{}")
        case ("GET", "/api/v3/series"),
             ("GET", "/api/v3/calendar"),
             ("GET", "/api/v3/health"),
             ("GET", "/api/v3/command"):
            return .json("[]")

        // `ArrWebhookNotificationHubRow` and the detail configuration view both
        // read this real endpoint. A deliberate 500 is the second journey's
        // failure surface; it must never look like an empty notification list.
        case ("GET", "/api/v3/notification"):
            switch notificationListBehavior {
            case .configured:
                return .json("[\(currentNotificationJSON)]")
            case .failing:
                return .json(#"{"message":"Fixture notification configuration failed."}"#, status: 500)
            }

        // The save journey edits this existing notification, so it must use the
        // exact ID-bearing PUT endpoint rather than creating a duplicate webhook.
        case ("PUT", "/api/v3/notification/91"):
            guard notificationListBehavior == .configured,
                  request.headers["x-api-key"] == "uitest-api-key",
                  let payload = Self.jsonObject(from: request.body),
                  Self.matchesExactSavePayload(payload) else {
                return .json(#"{"message":"Unexpected notification save payload."}"#, status: 400)
            }
            currentNotificationJSON = request.bodyString
            return .json(currentNotificationJSON)

        default:
            // A fixture route must never quietly make a newly-added production
            // request pass. Preserve the evidence and force production down its
            // normal HTTP-error path so the parent can see the unexpected call.
            unexpectedRequests.append(request)
            return .json(#"{"message":"Unexpected Notification Settings fixture route."}"#, status: 404)
        }
    }

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let headRange = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headRange.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])

        let target = String(requestParts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let query = targetParts.count == 2 ? queryItems(from: String(targetParts[1])) : [:]
        return RecordedRequest(
            method: String(requestParts[0]),
            path: String(targetParts[0]),
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func queryItems(from query: String) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = query
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { item in
            (item.name, item.value ?? "")
        })
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func matchesExactSavePayload(_ payload: [String: Any]) -> Bool {
        guard payload.count == 17,
              (payload["id"] as? NSNumber)?.intValue == notificationID,
              payload["name"] as? String == "Trawl (Fixture Sonarr)",
              payload["onGrab"] as? Bool == true,
              payload["onDownload"] as? Bool == true,
              payload["onUpgrade"] as? Bool == true,
              payload["onRename"] as? Bool == true,
              payload["onHealthIssue"] as? Bool == true,
              payload["onApplicationUpdate"] as? Bool == true,
              payload["onSeriesAdd"] as? Bool == true,
              payload["onSeriesDelete"] as? Bool == false,
              payload["onEpisodeFileDelete"] as? Bool == false,
              payload["onEpisodeFileDeleteForUpgrade"] as? Bool == false,
              payload["includeHealthWarnings"] as? Bool == true,
              payload["implementation"] as? String == "Webhook",
              payload["configContract"] as? String == "WebhookSettings",
              let tags = payload["tags"] as? [Any], tags.isEmpty,
              let fields = payload["fields"] as? [[String: Any]],
              fields.count == 3 else {
            return false
        }

        let fieldValues = Dictionary(uniqueKeysWithValues: fields.compactMap { field -> (String, Any)? in
            guard let name = field["name"] as? String, let value = field["value"] else { return nil }
            return (name, value)
        })
        guard fieldValues.count == 3,
              fieldValues["url"] as? String == "https://trawl-apns-worker.james-5d8.workers.dev/push",
              (fieldValues["method"] as? NSNumber)?.intValue == 1,
              let headers = fieldValues["headers"] as? [[String: Any]],
              headers.count == 1,
              headers[0]["Key"] as? String == "X-Trawl-Token",
              headers[0]["Value"] as? String == deviceToken else {
            return false
        }

        return true
    }

    private static let configuredNotificationJSON = #"""
    {"id":91,"name":"Trawl (Fixture Sonarr)","onGrab":true,"onDownload":true,"onUpgrade":true,"onRename":true,"onHealthIssue":true,"onApplicationUpdate":true,"onSeriesAdd":false,"onSeriesDelete":false,"onEpisodeFileDelete":false,"onEpisodeFileDeleteForUpgrade":false,"includeHealthWarnings":true,"implementation":"Webhook","configContract":"WebhookSettings","fields":[{"name":"url","value":"https://trawl-apns-worker.james-5d8.workers.dev/push"},{"name":"method","value":1},{"name":"headers","value":[{"Key":"X-Trawl-Token","Value":"trawl-ui-test-apns-token-v1"}]}],"tags":[27]}
    """#

    private static func httpResponse(for response: Response) -> Data {
        let reason: String
        switch response.status {
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        default: reason = "OK"
        }
        let head = "HTTP/1.1 \(response.status) \(reason)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
