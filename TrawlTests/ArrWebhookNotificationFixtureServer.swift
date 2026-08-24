import Foundation
import Network
@testable import Trawl

/// Loopback HTTP server for the Arr webhook-notification manager tests.
///
/// These tests need the real `ArrServiceManager` connection and notification
/// paths, which construct their own `SonarrAPIClient` / `RadarrAPIClient` /
/// `HTTPTransport` chain. A socket server is consequently the narrowest seam:
/// it fakes only the Arr server while retaining request construction, API-key
/// authentication, Codable, and HTTP status mapping in production code.
nonisolated struct ArrWebhookNotificationFixtureRequest: Sendable, Equatable {
    let method: String
    let path: String
    let rawQuery: String
    /// Header names are normalized to lowercase.
    let headers: [String: String]
    let body: String

    var apiKey: String? { headers["x-api-key"] }

    /// JSON object bodies are deliberately compared as objects, not encoded
    /// bytes: `JSONEncoder` gives no key-order guarantee.
    func jsonObject() -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return value as? [String: Any]
    }
}

nonisolated struct ArrWebhookNotificationFixtureResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ string: String, status: Int = 200) -> Self {
        Self(status: status, body: Data(string.utf8))
    }

    static func error(status: Int, message: String) -> Self {
        .json(#"{"message":"\#(message)"}"#, status: status)
    }

    static let empty = Self(status: 200, body: Data())
}

nonisolated final class ArrWebhookNotificationFixtureServer: @unchecked Sendable {
    typealias Handler = @Sendable (ArrWebhookNotificationFixtureRequest) -> ArrWebhookNotificationFixtureResponse

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler
    private let lock = NSLock()
    private var recordedRequests: [ArrWebhookNotificationFixtureRequest] = []

    init(label: String, handler: @escaping Handler) async throws {
        queue = DispatchQueue(label: "ArrWebhookNotificationFixtureServer.\(label)")
        listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
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
            fatalError("Webhook fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [ArrWebhookNotificationFixtureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func requests(method: String, path: String) -> [ArrWebhookNotificationFixtureRequest] {
        requests.filter { $0.method == method && $0.path == path }
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let data { accumulated.append(data) }
            guard let request = Self.parseRequest(accumulated) else {
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

            connection.send(
                content: Self.encode(self.handler(request)),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func parseRequest(_ buffer: Data) -> ArrWebhookNotificationFixtureRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<separator.lowerBound], encoding: .utf8) else {
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
            let key = String(line[..<colon]).lowercased()
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyData = Data(buffer[separator.upperBound...])
        guard bodyData.count >= contentLength else { return nil }

        let target = String(requestParts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return ArrWebhookNotificationFixtureRequest(
            method: String(requestParts[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count == 2 ? String(targetParts[1]) : "",
            headers: headers,
            body: String(data: bodyData.prefix(contentLength), encoding: .utf8) ?? ""
        )
    }

    private static func encode(_ response: ArrWebhookNotificationFixtureResponse) -> Data {
        let statusText: String = switch response.status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 500: "Internal Server Error"
        default: "Fixture Failure"
        }
        let headers = "HTTP/1.1 \(response.status) \(statusText)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data(headers.utf8) + response.body
    }
}

extension ArrWebhookNotificationFixtureServer {
    /// Minimum response set needed by `ArrServiceManager.connectService` for a
    /// Sonarr or Radarr profile. Every other endpoint deliberately produces a
    /// 599 response so a newly introduced request cannot pass invisibly.
    static func connectedServiceResponse(
        for request: ArrWebhookNotificationFixtureRequest,
        otherwise response: ArrWebhookNotificationFixtureResponse
    ) -> ArrWebhookNotificationFixtureResponse {
        switch request.path {
        case "/api/v3/system/status":
            .json("{}")
        case "/api/v3/qualityprofile", "/api/v3/rootfolder", "/api/v3/tag":
            .json("[]")
        default:
            response
        }
    }

    static func unexpected(_ request: ArrWebhookNotificationFixtureRequest) -> ArrWebhookNotificationFixtureResponse {
        .error(status: 599, message: "Unexpected \(request.method) \(request.path)")
    }
}
