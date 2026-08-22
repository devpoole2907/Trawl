import Foundation
import Testing
@testable import Trawl

@Suite("qBittorrent API client HTTP contracts", .serialized)
struct QBittorrentAPIClientContractTests {
    @Test("App version rejects a 500 response and sends the documented request")
    func appVersionRejectsServerError() async throws {
        QBittorrentContractURLProtocol.configure(
            statusCode: 500,
            body: Data("upstream proxy failure".utf8)
        )
        let client = makeClient()

        do {
            _ = try await client.getAppVersion()
            Issue.record("Expected getAppVersion() to reject HTTP 500")
        } catch let error as QBError {
            guard case .serverError(let statusCode, _) = error else {
                Issue.record("Expected a status-specific server error, received \(error)")
                return
            }
            #expect(statusCode == 500)
        }

        #expect(QBittorrentContractURLProtocol.recordedRequests == [
            .init(method: "GET", path: "/api/v2/app/version", query: nil)
        ])
    }

    @Test("Sync endpoint rejects unauthorized JSON before decoding")
    func syncMainDataRejectsUnauthorizedResponse() async throws {
        QBittorrentContractURLProtocol.configure(
            statusCode: 401,
            body: Data("{\"error\":\"invalid session\"}".utf8)
        )
        let client = makeClient()

        do {
            _ = try await client.syncMainData(rid: 42)
            Issue.record("Expected syncMainData(rid:) to reject HTTP 401")
        } catch let error as QBError {
            guard case .serverError(let statusCode, _) = error else {
                Issue.record("Expected a status-specific server error, received \(error)")
                return
            }
            #expect(statusCode == 401)
        }

        #expect(QBittorrentContractURLProtocol.recordedRequests == [
            .init(method: "GET", path: "/api/v2/sync/maindata", query: "rid=42")
        ])
    }

    @Test("App version rejects documented non-success statuses", arguments: [404, 429])
    func appVersionRejectsNotFoundAndRateLimitedResponses(statusCode: Int) async throws {
        QBittorrentContractURLProtocol.configure(
            statusCode: statusCode,
            body: Data("text failure from qBittorrent".utf8)
        )
        let client = makeClient()

        do {
            _ = try await client.getAppVersion()
            Issue.record("Expected getAppVersion() to reject HTTP \(statusCode)")
        } catch let error as QBError {
            guard case .serverError(let receivedStatus, _) = error else {
                Issue.record("Expected a status-specific server error, received \(error)")
                return
            }
            #expect(receivedStatus == statusCode)
        }

        #expect(QBittorrentContractURLProtocol.recordedRequests == [
            .init(method: "GET", path: "/api/v2/app/version", query: nil)
        ])
    }

    @Test("Sync endpoint rejects documented non-success statuses", arguments: [404, 429])
    func syncMainDataRejectsNotFoundAndRateLimitedResponses(statusCode: Int) async throws {
        QBittorrentContractURLProtocol.configure(
            statusCode: statusCode,
            body: Data("{\"error\":\"request rejected\"}".utf8)
        )
        let client = makeClient()

        do {
            _ = try await client.syncMainData(rid: 42)
            Issue.record("Expected syncMainData(rid:) to reject HTTP \(statusCode)")
        } catch let error as QBError {
            guard case .serverError(let receivedStatus, _) = error else {
                Issue.record("Expected a status-specific server error, received \(error)")
                return
            }
            #expect(receivedStatus == statusCode)
        }

        #expect(QBittorrentContractURLProtocol.recordedRequests == [
            .init(method: "GET", path: "/api/v2/sync/maindata", query: "rid=42")
        ])
    }

    // A complete 403 retry contract needs an injectable reAuthenticate seam (the
    // production path reads credentials from Keychain and performs a real login).
    // Keep that scenario separate from these deterministic response-status tests.

    private func makeClient() -> QBittorrentAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QBittorrentContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return QBittorrentAPIClient(
            baseURL: "https://qbittorrent.contract.test",
            authService: AuthService(serverProfileID: UUID()),
            session: session
        )
    }
}

private final class QBittorrentContractURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Fixture: Sendable {
        let statusCode: Int
        let body: Data
    }

    struct RecordedRequest: Equatable, Sendable {
        let method: String
        let path: String
        let query: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture = Fixture(statusCode: 500, body: Data())
    nonisolated(unsafe) private static var requests: [RecordedRequest] = []

    static var recordedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func configure(statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        fixture = Fixture(statusCode: statusCode, body: body)
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.requests.append(
            .init(
                method: request.httpMethod ?? "GET",
                path: url.path,
                query: url.query
            )
        )
        let fixture = Self.fixture
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
