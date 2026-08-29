import Foundation
import Testing
@testable import Trawl

/// Covers `QBittorrentAPIClient`'s HTTP 403 re-authentication contract end to end:
/// the real request builder, the real `AuthService` login, the real status validator
/// and the real decoder all run. Only two things are faked - the remote server (via a
/// scripting `URLProtocol`) and the credential source (via `QBittorrentCredentialProviding`).
@Suite("qBittorrent 403 re-authentication contract", .serialized)
struct QBittorrentReauthContractTests {
    private static let baseURL = "https://qbittorrent.reauth.test"

    // MARK: - Happy path

    @Test("A 403 triggers exactly one re-authentication and one retry, then returns the decoded body")
    @MainActor
    func singleReauthenticationAndSingleRetryOnForbidden() async throws {
        QBittorrentReauthURLProtocol.configure(
            apiResponses: [
                .status(403, body: Data("Forbidden".utf8)),
                .status(200, body: Data(#"{"rid":43,"full_update":true}"#.utf8))
            ],
            loginResponses: [
                .loginSuccess(sid: "stale-sid"),
                .loginSuccess(sid: "fresh-sid")
            ]
        )
        let stack = makeStack()
        try await seedExpiredSession(on: stack.authService)

        let syncData = try await stack.client.syncMainData(rid: 42)
        #expect(syncData.rid == 43)
        #expect(syncData.fullUpdate == true)

        let apiRequests = QBittorrentReauthURLProtocol.recordedAPIRequests
        let loginRequests = QBittorrentReauthURLProtocol.recordedLoginRequests

        #expect(apiRequests.count == 2)
        #expect(loginRequests.count == 1)

        let original = try #require(apiRequests.first)
        let retry = try #require(apiRequests.last)

        #expect(original.method == "GET")
        #expect(original.path == "/api/v2/sync/maindata")
        #expect(original.query == "rid=42")

        // The retry replays the original request unchanged...
        #expect(retry.method == original.method)
        #expect(retry.path == original.path)
        #expect(retry.query == original.query)
        #expect(retry.body == original.body)
        #expect(retry.headersExcludingCookie == original.headersExcludingCookie)

        // ...except for the one header re-authentication exists to refresh.
        #expect(original.cookie == "SID=stale-sid")
        #expect(retry.cookie == "SID=fresh-sid")

        let login = try #require(loginRequests.first)
        #expect(login.method == "POST")
        #expect(login.path == "/api/v2/auth/login")
        #expect(login.bodyText == "username=reauth-user&password=reauth-pass")
    }

    @Test("The retry of a form POST replays the original body byte for byte")
    func retriedFormPostReplaysOriginalBody() async throws {
        QBittorrentReauthURLProtocol.configure(
            apiResponses: [
                .status(403),
                .status(200)
            ],
            loginResponses: [
                .loginSuccess(sid: "stale-sid"),
                .loginSuccess(sid: "fresh-sid")
            ]
        )
        let stack = makeStack()
        try await seedExpiredSession(on: stack.authService)

        try await stack.client.setTorrentDownloadLimit(hashes: ["aaa", "bbb"], limit: 1024)

        let apiRequests = QBittorrentReauthURLProtocol.recordedAPIRequests
        #expect(apiRequests.count == 2)
        #expect(QBittorrentReauthURLProtocol.recordedLoginRequests.count == 1)

        let original = try #require(apiRequests.first)
        let retry = try #require(apiRequests.last)

        #expect(original.method == "POST")
        #expect(original.path == "/api/v2/torrents/setDownloadLimit")
        #expect(original.query == nil)
        #expect(original.formPairs == ["hashes=aaa%7Cbbb", "limit=1024"])

        #expect(retry.method == original.method)
        #expect(retry.path == original.path)
        #expect(retry.query == original.query)
        #expect(retry.body == original.body)
        #expect(retry.body?.isEmpty == false)
        #expect(retry.headersExcludingCookie == original.headersExcludingCookie)
        #expect(retry.headers["content-type"] == "application/x-www-form-urlencoded")
        #expect(retry.cookie == "SID=fresh-sid")
    }

    // MARK: - Failing retry

    @Test("A retry that is also rejected with 403 fails as an authentication error and is not retried again")
    func retryRejectedWithForbiddenFailsWithoutFurtherAttempts() async throws {
        QBittorrentReauthURLProtocol.configure(
            apiResponses: [
                .status(403),
                .status(403)
            ],
            loginResponses: [
                .loginSuccess(sid: "stale-sid"),
                .loginSuccess(sid: "fresh-sid")
            ]
        )
        let stack = makeStack()
        try await seedExpiredSession(on: stack.authService)

        do {
            _ = try await stack.client.syncMainData(rid: 42)
            Issue.record("Expected a repeated 403 to fail")
        } catch let error as QBError {
            guard case .authFailed = error else {
                Issue.record("Expected .authFailed for a retry that is also forbidden, received \(error)")
                return
            }
        }

        // The retry is not itself retried, and re-authentication happens only once.
        #expect(QBittorrentReauthURLProtocol.recordedAPIRequests.count == 2)
        #expect(QBittorrentReauthURLProtocol.recordedLoginRequests.count == 1)
    }

    @Test("A retry that returns a non-success status surfaces that status instead of decoding the body")
    func retryWithServerErrorSurfacesStatusWithoutDecoding() async throws {
        // The 500's body is perfectly decodable - status validation must still win.
        QBittorrentReauthURLProtocol.configure(
            apiResponses: [
                .status(403),
                .status(500, body: Data(#"{"rid":99,"full_update":true}"#.utf8))
            ],
            loginResponses: [
                .loginSuccess(sid: "stale-sid"),
                .loginSuccess(sid: "fresh-sid")
            ]
        )
        let stack = makeStack()
        try await seedExpiredSession(on: stack.authService)

        do {
            _ = try await stack.client.syncMainData(rid: 42)
            Issue.record("Expected a 500 on the retry to be rejected")
        } catch let error as QBError {
            guard case .serverError(let statusCode, _) = error else {
                Issue.record("Expected a status-specific server error, received \(error)")
                return
            }
            #expect(statusCode == 500)
        }

        #expect(QBittorrentReauthURLProtocol.recordedAPIRequests.count == 2)
        #expect(QBittorrentReauthURLProtocol.recordedLoginRequests.count == 1)
    }

    // MARK: - Failing re-authentication

    @Test("Missing credentials fail as an authentication error with no login and no retry")
    func missingCredentialsFailWithoutLoginOrRetry() async throws {
        QBittorrentReauthURLProtocol.configure(
            apiResponses: [.status(403)],
            loginResponses: [.loginSuccess(sid: "stale-sid")]
        )
        let stack = makeStack(credentialProvider: StubCredentialProvider(failure: QBError.authFailed))
        try await seedExpiredSession(on: stack.authService)

        do {
            _ = try await stack.client.syncMainData(rid: 42)
            Issue.record("Expected missing credentials to fail the request")
        } catch let error as QBError {
            guard case .authFailed = error else {
                Issue.record("Expected .authFailed when credentials are unavailable, received \(error)")
                return
            }
        }

        #expect(QBittorrentReauthURLProtocol.recordedAPIRequests.count == 1)
        #expect(QBittorrentReauthURLProtocol.recordedLoginRequests.isEmpty)
    }

    @Test("A credential lookup that fails with a non-QBError still surfaces as an authentication error")
    func credentialLookupFailureSurfacesAsAuthenticationError() async throws {
        QBittorrentReauthURLProtocol.configure(
            apiResponses: [.status(403)],
            loginResponses: [.loginSuccess(sid: "stale-sid")]
        )
        let stack = makeStack(credentialProvider: StubCredentialProvider(failure: CredentialLookupFailure()))
        try await seedExpiredSession(on: stack.authService)

        do {
            _ = try await stack.client.syncMainData(rid: 42)
            Issue.record("Expected a failed credential lookup to fail the request")
        } catch let error as QBError {
            guard case .authFailed = error else {
                Issue.record("Expected .authFailed for a failed credential lookup, received \(error)")
                return
            }
        }

        #expect(QBittorrentReauthURLProtocol.recordedAPIRequests.count == 1)
        #expect(QBittorrentReauthURLProtocol.recordedLoginRequests.isEmpty)
    }

    @Test("A rejected login fails as an authentication error and the request is never retried")
    func rejectedLoginFailsWithoutRetry() async throws {
        QBittorrentReauthURLProtocol.configure(
            apiResponses: [.status(403)],
            loginResponses: [
                .loginSuccess(sid: "stale-sid"),
                .status(403, body: Data("Fails.".utf8))
            ]
        )
        let stack = makeStack()
        try await seedExpiredSession(on: stack.authService)

        do {
            _ = try await stack.client.syncMainData(rid: 42)
            Issue.record("Expected a rejected re-authentication to fail the request")
        } catch let error as QBError {
            guard case .authFailed = error else {
                Issue.record("Expected .authFailed when re-authentication is rejected, received \(error)")
                return
            }
        }

        // One attempt, one login attempt, and crucially no retry of the original request.
        #expect(QBittorrentReauthURLProtocol.recordedAPIRequests.count == 1)
        #expect(QBittorrentReauthURLProtocol.recordedLoginRequests.count == 1)
    }

    // MARK: - Helpers

    private struct Stack {
        let client: QBittorrentAPIClient
        let authService: AuthService
    }

    private func makeStack(
        credentialProvider: any QBittorrentCredentialProviding = StubCredentialProvider()
    ) -> Stack {
        // Separate sessions for auth and API traffic, mirroring production, so neither
        // owner's teardown can disturb the other. Both are driven by the same script.
        let authService = AuthService(serverProfileID: UUID(), session: Self.makeSession())
        let client = QBittorrentAPIClient(
            baseURL: Self.baseURL,
            authService: authService,
            session: Self.makeSession(),
            credentialProvider: credentialProvider
        )
        return Stack(client: client, authService: authService)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.protocolClasses = [QBittorrentReauthURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Gives the client a session cookie that the scripted server will then reject with
    /// 403, so the retry starts from a realistic "stale SID" state. The seeding login is
    /// dropped from the recording so request counts describe only the behaviour under test.
    private func seedExpiredSession(on authService: AuthService) async throws {
        try await authService.login(
            hostURL: Self.baseURL,
            username: "seed-user",
            password: "seed-pass"
        )
        #expect(QBittorrentReauthURLProtocol.recordedLoginRequests.count == 1)
        QBittorrentReauthURLProtocol.clearRecordedRequests()
    }
}

// MARK: - Credential source stub

/// Stands in for whatever stores credentials, so re-authentication can be driven
/// deterministically. Trawl's own login/request logic is never stubbed.
private nonisolated struct StubCredentialProvider: QBittorrentCredentialProviding {
    private let storedCredentials: QBittorrentCredentials
    private let failure: (any Error & Sendable)?

    init(
        storedCredentials: QBittorrentCredentials = QBittorrentCredentials(
            username: "reauth-user",
            password: "reauth-pass"
        )
    ) {
        self.storedCredentials = storedCredentials
        self.failure = nil
    }

    init(failure: any Error & Sendable) {
        self.storedCredentials = QBittorrentCredentials(username: "unused", password: "unused")
        self.failure = failure
    }

    func credentials(forServerProfileID serverProfileID: UUID) async throws -> QBittorrentCredentials {
        if let failure {
            throw failure
        }
        return storedCredentials
    }
}

/// A credential-store failure that is deliberately *not* a `QBError`, standing in for
/// something like a keychain read error.
private nonisolated struct CredentialLookupFailure: Error {}

// MARK: - Scripted server

private final class QBittorrentReauthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let loginPath = "/api/v2/auth/login"

    struct ScriptedResponse: Sendable {
        let statusCode: Int
        let body: Data
        let headerFields: [String: String]

        static func status(
            _ statusCode: Int,
            body: Data = Data(),
            headerFields: [String: String] = [:]
        ) -> ScriptedResponse {
            ScriptedResponse(statusCode: statusCode, body: body, headerFields: headerFields)
        }

        /// A qBittorrent login success: HTTP 200, `Ok.` body, and a session cookie.
        static func loginSuccess(sid: String) -> ScriptedResponse {
            ScriptedResponse(
                statusCode: 200,
                body: Data("Ok.".utf8),
                headerFields: ["Set-Cookie": "SID=\(sid); HttpOnly; path=/"]
            )
        }
    }

    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let query: String?
        let body: Data?
        /// Header names lowercased so comparisons don't depend on URLSession's casing.
        let headers: [String: String]

        var cookie: String? { headers["cookie"] }
        var headersExcludingCookie: [String: String] { headers.filter { $0.key != "cookie" } }
        var bodyText: String? { body.flatMap { String(data: $0, encoding: .utf8) } }
        var formPairs: Set<String> {
            Set(bodyText?.components(separatedBy: "&").filter { !$0.isEmpty } ?? [])
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var apiResponses: [ScriptedResponse] = []
    nonisolated(unsafe) private static var loginResponses: [ScriptedResponse] = []
    nonisolated(unsafe) private static var requests: [RecordedRequest] = []

    static func configure(apiResponses: [ScriptedResponse], loginResponses: [ScriptedResponse]) {
        lock.lock()
        defer { lock.unlock() }
        Self.apiResponses = apiResponses
        Self.loginResponses = loginResponses
        requests = []
    }

    static func clearRecordedRequests() {
        lock.lock()
        defer { lock.unlock() }
        requests = []
    }

    static var recordedRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static var recordedLoginRequests: [RecordedRequest] {
        recordedRequests.filter { $0.path == loginPath }
    }

    static var recordedAPIRequests: [RecordedRequest] {
        recordedRequests.filter { $0.path != loginPath }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: url.query,
            body: Self.bodyData(from: request),
            headers: Self.normalizedHeaders(from: request)
        )

        Self.lock.lock()
        Self.requests.append(recorded)
        let scripted: ScriptedResponse?
        if recorded.path == Self.loginPath {
            scripted = Self.loginResponses.isEmpty ? nil : Self.loginResponses.removeFirst()
        } else {
            scripted = Self.apiResponses.isEmpty ? nil : Self.apiResponses.removeFirst()
        }
        Self.lock.unlock()

        // An unscripted request means the client made more calls than the contract
        // allows. Answer with an unmistakable status so the count assertions report it.
        let fixture = scripted ?? ScriptedResponse.status(599, body: Data("unscripted request".utf8))

        var headerFields = fixture.headerFields
        headerFields["Content-Type"] = headerFields["Content-Type"] ?? "application/json"
        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: nil,
            headerFields: headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func normalizedHeaders(from request: URLRequest) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value
        }
        return headers
    }

    /// URLSession converts `httpBody` into `httpBodyStream` before a `URLProtocol` sees
    /// the request, so both forms have to be handled to record the real bytes sent.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data.isEmpty ? nil : data
    }
}
