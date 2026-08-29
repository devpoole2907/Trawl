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

    // MARK: - Torrent deletion
    //
    // The most destructive call in a download manager: `deleteFiles` is the difference
    // between removing a torrent from the list and erasing the downloaded media from
    // disk. Both the flag and the hash list ride in the form body, and the hashes are
    // joined with `|` - qBittorrent's own separator. Joining with a comma instead would
    // not error; it would send one unmatched hash string, so the wrong thing (or
    // nothing) gets deleted while the app reports success.

    @Test("Deleting torrents without their files sends deleteFiles=false and the pipe-joined hashes")
    func deleteTorrentsKeepsFilesByDefault() async throws {
        QBittorrentContractURLProtocol.configure(statusCode: 200, body: Data("Ok.".utf8))
        let client = makeClient()

        try await client.deleteTorrents(hashes: ["aaa111", "bbb222"], deleteFiles: false)

        let request = try #require(QBittorrentContractURLProtocol.recordedRequests.last)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v2/torrents/delete")
        let fields = request.formFields
        #expect(
            fields["deleteFiles"] == "false",
            "The flag that decides whether the user's files are erased must be sent explicitly."
        )
        #expect(
            fields["hashes"] == "aaa111|bbb222",
            "qBittorrent separates hashes with a pipe. Any other separator sends one unrecognised hash, so nothing is deleted and the app still reports success."
        )
    }

    @Test("Deleting torrents with their files sends deleteFiles=true")
    func deleteTorrentsCanEraseFiles() async throws {
        QBittorrentContractURLProtocol.configure(statusCode: 200, body: Data("Ok.".utf8))
        let client = makeClient()

        try await client.deleteTorrents(hashes: ["aaa111"], deleteFiles: true)

        let request = try #require(QBittorrentContractURLProtocol.recordedRequests.last)
        #expect(request.formFields["deleteFiles"] == "true")
        #expect(request.formFields["hashes"] == "aaa111")
    }

    @Test("A rejected deletion surfaces as an error rather than reporting success")
    func deleteTorrentsPropagatesRejection() async throws {
        QBittorrentContractURLProtocol.configure(statusCode: 500, body: Data("failed".utf8))
        let client = makeClient()

        await #expect(throws: (any Error).self) {
            try await client.deleteTorrents(hashes: ["aaa111"], deleteFiles: true)
        }
        #expect(QBittorrentContractURLProtocol.recordedRequests.contains { $0.path == "/api/v2/torrents/delete" })
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
        /// The form body exactly as it was sent. qBittorrent takes its mutation
        /// parameters as a form body rather than a query, so assertions about *what
        /// was acted on* need this.
        ///
        /// Defaulted so the existing GET expectations, which compare whole recorded
        /// requests and have no body, keep reading as they did.
        var body: String = ""

        /// The form body decoded into its pairs. qBittorrent joins multi-value
        /// parameters with `|` inside a single value rather than repeating the field,
        /// so a dictionary is the right shape here - unlike Bazarr's settings form.
        var formFields: [String: String] {
            guard !body.isEmpty else { return [:] }
            var fields: [String: String] = [:]
            for pair in body.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts.first ?? "")
                let value = parts.count > 1 ? String(parts[1]) : ""
                fields[name.removingPercentEncoding ?? name] = value.removingPercentEncoding ?? value
            }
            return fields
        }
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
                query: url.query,
                body: Self.bodyString(of: request)
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

    /// `URLSession` converts a request body into `httpBodyStream` before a `URLProtocol`
    /// sees it, leaving `httpBody` nil - reading only `httpBody` here silently records
    /// every request as having sent nothing, and every body assertion would then pass
    /// against an empty string. The stream is drained as the fallback.
    private static func bodyString(of request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(data: data, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
