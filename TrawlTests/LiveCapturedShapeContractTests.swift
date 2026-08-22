import Foundation
import Testing
@testable import Trawl

/// Response shapes captured from real services, then frozen here.
///
/// Every other contract suite in this project fakes a server from a reading of
/// Trawl's own code, which cannot catch "we modelled the API wrong in the first
/// place". These fixtures were instead taken verbatim from live instances on
/// 23 August 2026 — **qBittorrent v5.2.3**, **SABnzbd** (CherryPy 18.10.0) and
/// **Sonarr 4.0.19.2979** — so they pin what those servers actually send rather
/// than what we assumed.
///
/// Two of these differ from what the hand-written fixtures had been asserting:
/// qBittorrent v5 answers a successful login with `204` and a port-suffixed
/// `QBT_SID_<port>` cookie rather than `200` + `"Ok."` + `SID`, and SABnzbd
/// rejects a bad key with `403` and a plain-text body rather than `401`.
@Suite("Captured live response shapes", .serialized)
struct LiveCapturedShapeContractTests {

    // MARK: - qBittorrent v5 login

    /// Verbatim from qBittorrent v5.2.3. Note the cookie **name** carries the
    /// server's port, and the **value** contains `/` and `+` — a parser that
    /// splits on the wrong character, or that assumes an alphanumeric token,
    /// breaks on a real session.
    private static let capturedSetCookie =
        "QBT_SID_8080=mRdEjKBWOJEloRFqri/nG9lif+qkfnrs; HttpOnly; SameSite=Lax; expires=Sun, 23-Aug-2026 00:00:47 GMT; path=/"
    private static let capturedCookieValue = "mRdEjKBWOJEloRFqri/nG9lif+qkfnrs"

    @Test("A real qBittorrent v5 login answers 204 with a port-suffixed cookie, and that cookie is what later requests send")
    func qBittorrentV5LoginIsAcceptedAndItsCookieReused() async throws {
        CapturedShapeURLProtocol.reset()
        CapturedShapeURLProtocol.loginResponse = CapturedResponse(
            statusCode: 204,
            body: Data(),
            headerFields: ["Set-Cookie": Self.capturedSetCookie]
        )
        // Any 2xx JSON will do here; the point is which Cookie header it carries.
        CapturedShapeURLProtocol.apiResponse = CapturedResponse(
            statusCode: 200,
            body: Data(#"{"rid":1,"full_update":true,"server_state":{}}"#.utf8),
            headerFields: ["Content-Type": "application/json"]
        )

        let authService = AuthService(
            serverProfileID: UUID(),
            session: CapturedShapeURLProtocol.makeSession()
        )
        try await authService.login(
            hostURL: "http://captured.qbittorrent.test",
            username: "admin",
            password: "trawl-test-qbt"
        )

        var request = URLRequest(url: URL(string: "http://captured.qbittorrent.test/api/v2/sync/maindata")!)
        await authService.authorize(&request)

        #expect(request.value(forHTTPHeaderField: "Cookie") == "QBT_SID_8080=\(Self.capturedCookieValue)")
    }

    @Test("A real qBittorrent v5 rejected login answers 401 with a plain-text body and fails as an authentication error")
    func qBittorrentV5RejectedLoginFailsAsAuthentication() async throws {
        CapturedShapeURLProtocol.reset()
        // Verbatim from qBittorrent v5.2.3 for a wrong password: not a 200 with
        // a "Fails." body, which is what older versions sent.
        CapturedShapeURLProtocol.loginResponse = CapturedResponse(
            statusCode: 401,
            body: Data("Unauthorized".utf8),
            headerFields: ["Content-Type": "text/plain; charset=UTF-8"]
        )

        let authService = AuthService(
            serverProfileID: UUID(),
            session: CapturedShapeURLProtocol.makeSession()
        )

        do {
            try await authService.login(
                hostURL: "http://captured.qbittorrent.test",
                username: "admin",
                password: "wrong"
            )
            Issue.record("A 401 login must not be treated as a successful session.")
        } catch let error as QBError {
            guard case .authFailed = error else {
                Issue.record("Expected .authFailed for a rejected login, received \(error)")
                return
            }
        }
    }

    // MARK: - qBittorrent sync payload

    @Test("A real empty qBittorrent queue omits the torrents key entirely and still decodes")
    @MainActor
    func emptyQueueSyncPayloadDecodes() throws {
        // Verbatim top-level shape from `GET /api/v2/sync/maindata?rid=0` against a
        // pristine v5.2.3 instance: with nothing queued there is no `torrents` key
        // at all, rather than an empty object. A non-optional property here would
        // fail to decode against a real idle server.
        let captured = Data(#"{"rid":1,"full_update":true,"server_state":{"connection_status":"connected","dl_info_speed":0,"up_info_speed":0}}"#.utf8)

        let decoded = try JSONDecoder().decode(SyncMainData.self, from: captured)

        #expect(decoded.rid == 1)
        #expect(decoded.fullUpdate == true)
        #expect(decoded.torrents == nil)
        #expect(decoded.torrentsRemoved == nil)
    }

    // MARK: - SABnzbd rejected key

    @Test("A real SABnzbd rejects a bad API key with 403 and a plain-text body, which maps to unauthorized")
    func sabnzbdRejectedKeyMapsToUnauthorized() async throws {
        CapturedShapeURLProtocol.reset()
        // Verbatim from SABnzbd (CherryPy/18.10.0): status 403, body
        // "API Key Incorrect". Not a 401, and not a 200 carrying a JSON error
        // envelope — the two shapes the hand-written fixtures had assumed.
        CapturedShapeURLProtocol.apiResponse = CapturedResponse(
            statusCode: 403,
            body: Data("API Key Incorrect".utf8),
            headerFields: ["Content-Type": "text/html;charset=utf-8"]
        )

        let client = SABnzbdAPIClient(
            baseURL: "http://captured.sabnzbd.test",
            apiKey: "wrong-key",
            sessionConfiguration: CapturedShapeURLProtocol.makeConfiguration()
        )

        do {
            _ = try await client.getQueue(start: 0, limit: 200)
            Issue.record("A 403 from SABnzbd must not be decoded as a successful queue.")
        } catch let error as SABnzbdAPIError {
            guard case .unauthorized = error else {
                Issue.record("Expected .unauthorized for SABnzbd's 403, received \(error)")
                return
            }
        }
    }
}

private nonisolated struct CapturedResponse: Sendable {
    let statusCode: Int
    let body: Data
    let headerFields: [String: String]
}

/// Serves one canned response for the login path and another for everything else.
private final class CapturedShapeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var loginResponse: CapturedResponse?
    nonisolated(unsafe) static var apiResponse: CapturedResponse?

    static func reset() {
        loginResponse = nil
        apiResponse = nil
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturedShapeURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return configuration
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let canned = url.path.contains("/auth/login")
            ? Self.loginResponse
            : Self.apiResponse

        guard let canned else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: canned.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: canned.headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
