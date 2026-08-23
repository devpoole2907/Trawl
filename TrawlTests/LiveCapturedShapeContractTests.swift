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

    // MARK: - qBittorrent torrent object

    /// Verbatim `GET /api/v2/sync/maindata?rid=0` from qBittorrent **v5.2.3**,
    /// carrying one torrent. The real torrent object has **68 fields**; the
    /// hand-written fixtures used three.
    ///
    /// The state is `stoppedDL`, which is the v5 name — v4 called this `pausedDL`.
    /// A client that only knew the v4 spelling would mis-categorise every paused
    /// torrent on a modern server.
    private static let capturedQBittorrentMainData = """
        {
            "full_update": true,
            "rid": 1,
            "torrents": {
                "0123456789abcdef0123456789abcdef01234567": {
                    "added_on": 1787441350,
                    "amount_left": 0,
                    "auto_tmm": false,
                    "availability": 0,
                    "category": "",
                    "comment": "",
                    "completed": 0,
                    "completion_on": -1,
                    "connections_count": 0,
                    "connections_limit": 100,
                    "content_path": "",
                    "created_by": "",
                    "creation_date": -1,
                    "dl_limit": 0,
                    "dlspeed": 0,
                    "download_path": "",
                    "downloaded": 0,
                    "downloaded_session": 0,
                    "eta": 8640000,
                    "f_l_piece_prio": false,
                    "force_start": false,
                    "has_metadata": false,
                    "has_other_announce_error": false,
                    "has_tracker_error": false,
                    "has_tracker_warning": false,
                    "inactive_seeding_time_limit": -2,
                    "infohash_v1": "0123456789abcdef0123456789abcdef01234567",
                    "infohash_v2": "",
                    "last_activity": 1787441350,
                    "magnet_uri": "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=trawl-shape-probe",
                    "max_inactive_seeding_time": -1,
                    "max_ratio": -1,
                    "max_seeding_time": -1,
                    "name": "trawl-shape-probe",
                    "num_complete": 0,
                    "num_incomplete": 0,
                    "num_leechs": 0,
                    "num_seeds": 0,
                    "piece_size": -1,
                    "pieces_have": 0,
                    "pieces_num": -1,
                    "popularity": 0,
                    "priority": 1,
                    "private": null,
                    "progress": 0,
                    "ratio": 0,
                    "ratio_limit": -2,
                    "reannounce": 0,
                    "root_path": "",
                    "save_path": "/downloads",
                    "seeding_time": 0,
                    "seeding_time_limit": -2,
                    "seen_complete": -1,
                    "seq_dl": false,
                    "share_limit_action": "Default",
                    "size": 0,
                    "state": "stoppedDL",
                    "super_seeding": false,
                    "tags": "",
                    "time_active": 0,
                    "total_size": -1,
                    "total_wasted": 0,
                    "tracker": "",
                    "trackers_count": 0,
                    "up_limit": 0,
                    "uploaded": 0,
                    "uploaded_session": 0,
                    "upspeed": 0
                }
            }
        }
    """

    @Test("A real qBittorrent v5 torrent object decodes, including the v5-only stopped state")
    @MainActor
    func realTorrentObjectDecodes() throws {
        let decoded = try JSONDecoder().decode(
            SyncMainData.self,
            from: Data(Self.capturedQBittorrentMainData.utf8)
        )

        let torrents = try #require(decoded.torrents)
        #expect(torrents.count == 1)
        let entry = try #require(torrents.values.first)

        #expect(entry.name == "trawl-shape-probe")
        // `state` decodes straight into `TorrentState`, so an unrecognised spelling
        // would land as `.unknown` and strand every paused torrent on a v5 server in
        // the wrong section of the Downloads list.
        #expect(entry.state == .stoppedDL)
        #expect(TorrentState.stoppedDL.displayName == "Stopped")
        #expect(TorrentState.stoppedDL != .unknown)
    }

    // MARK: - Sonarr lookup payload

    /// Verbatim from `GET /api/v3/series/lookup?term=Severance` against Sonarr
    /// **4.0.19.2979**, trimmed only by dropping all but one image and two seasons.
    ///
    /// The load-bearing detail is what is **missing**: a lookup result carries no
    /// `id`, because the series is not in the library yet. Every hand-written
    /// fixture in this repo included one, so the real shape of the add-a-new-series
    /// path was never actually decoded in a test.
    private static let capturedSonarrLookupSeries = """
        {
            "added": "0001-01-01T00:00:00Z",
            "airTime": "21:00",
            "certification": "TV-MA",
            "cleanTitle": "severance",
            "ended": false,
            "firstAired": "2022-02-18T00:00:00Z",
            "folder": "Severance",
            "genres": [
                "Drama",
                "Mystery",
                "Science Fiction",
                "Thriller"
            ],
            "images": [
                {
                    "coverType": "banner",
                    "remoteUrl": "https://artworks.thetvdb.com/banners/v4/series/371980/banners/67d3854a3f3f2.jpg",
                    "url": "/MediaCoverProxy/982218b500aadfe659d4accaf3dc72f3aa865ab4cdaddcc277c5d5fc6225995a/67d3854a3f3f2.jpg"
                }
            ],
            "imdbId": "tt11280740",
            "languageProfileId": 1,
            "lastAired": "2025-03-20T00:00:00Z",
            "monitorNewItems": "all",
            "monitored": true,
            "network": "Apple TV",
            "originalLanguage": {
                "id": 1,
                "name": "English"
            },
            "overview": "Mark leads a team of office workers whose memories have been surgically divided between their work and personal lives. When a mysterious colleague appears outside of work, it begins a journey to discover the truth about their jobs.",
            "qualityProfileId": 0,
            "ratings": {
                "value": 8.6,
                "votes": 402221
            },
            "remotePoster": "https://artworks.thetvdb.com/banners/v4/series/371980/posters/621096b26f0e2.jpg",
            "runtime": 49,
            "seasonFolder": false,
            "seasons": [
                {
                    "monitored": false,
                    "seasonNumber": 0
                },
                {
                    "monitored": true,
                    "seasonNumber": 1
                }
            ],
            "seriesType": "standard",
            "sortTitle": "severance",
            "statistics": {
                "episodeCount": 0,
                "episodeFileCount": 0,
                "percentOfEpisodes": 0,
                "seasonCount": 2,
                "sizeOnDisk": 0,
                "totalEpisodeCount": 0
            },
            "status": "continuing",
            "tags": [],
            "title": "Severance",
            "titleSlug": "severance",
            "tmdbId": 95396,
            "tvMazeId": 44933,
            "tvRageId": 0,
            "tvdbId": 371980,
            "useSceneNumbering": false,
            "year": 2022
        }
    """

    @Test("A real Sonarr lookup result carries no id, and decodes with a synthesised one")
    @MainActor
    func sonarrLookupResultDecodesWithoutAnID() throws {
        let series = try JSONDecoder().decode(
            SonarrSeries.self,
            from: Data(Self.capturedSonarrLookupSeries.utf8)
        )

        #expect(series.title == "Severance")
        #expect(series.tvdbId == 371980)
        #expect(series.year == 2022)

        // No `id` in the payload, so SonarrSeries derives a stable negative one from
        // the tvdb id. A non-optional `id` would simply have failed to decode here,
        // taking the whole "add a series you don't own yet" flow with it.
        #expect(series.id == -371980)

        // Rich sub-objects a two-field stub never exercised.
        #expect(series.statistics?.seasonCount == 2)
        #expect(series.ratings?.value == 8.6)
        #expect(series.seasons?.count == 2)
        #expect(series.network == "Apple TV")
        #expect(series.status == "continuing")
    }

    // MARK: - SABnzbd key tiers

    /// SABnzbd issues two API keys: a full one and an add-only "NZB key". Measured
    /// against a real SABnzbd 5.1.1 with the NZB-only key:
    ///
    /// | mode      | status |
    /// |-----------|--------|
    /// | `version` | 200    |
    /// | `queue`   | 403    |
    /// | `history` | 403    |
    ///
    /// So the add-only key is not simply "rejected" — it is accepted for some modes
    /// and refused for others, and that asymmetry is the only way to tell it apart
    /// from a plain wrong key. Before this was handled, pasting the NZB key produced
    /// "SABnzbd rejected the API key. Update it in Settings.", which sends the user
    /// off to re-copy a key that was never wrong.
    @Test("An add-only SABnzbd NZB key is reported as the wrong key tier, not as a rejected key")
    @MainActor
    func addOnlyNZBKeyIsReportedAsWrongTier() async throws {
        CapturedShapeURLProtocol.reset()
        CapturedShapeURLProtocol.sabnzbdModeResponses = [
            "version": CapturedResponse(
                statusCode: 200,
                body: Data(#"{"version":"5.1.1"}"#.utf8),
                headerFields: ["Content-Type": "application/json"]
            ),
            "queue": CapturedResponse(
                statusCode: 403,
                body: Data("API Key Incorrect".utf8),
                headerFields: ["Content-Type": "text/html;charset=utf-8"]
            )
        ]

        let manager = SABnzbdServiceManager(
            sessionConfiguration: CapturedShapeURLProtocol.makeConfiguration()
        )
        let profile = SABnzbdServiceProfile(displayName: "Fixture SAB", hostURL: "http://captured.sabnzbd.test")
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "add-only-nzb-key")
        defer { Task { try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey) } }

        await manager.connectService(profile)

        #expect(manager.isConnected == false)
        #expect(manager.connectionError == "Trawl needs the full SABnzbd API key, not the add-only NZB key.")
    }

    /// The contrast case: a key that is wrong outright is refused for *every* mode,
    /// including `version`, and must still read as a rejected key.
    @Test("A wholly wrong SABnzbd key is still reported as a rejected key")
    @MainActor
    func whollyWrongSABnzbdKeyIsReportedAsRejected() async throws {
        CapturedShapeURLProtocol.reset()
        let refused = CapturedResponse(
            statusCode: 403,
            body: Data("API Key Incorrect".utf8),
            headerFields: ["Content-Type": "text/html;charset=utf-8"]
        )
        CapturedShapeURLProtocol.sabnzbdModeResponses = ["version": refused, "queue": refused]

        let manager = SABnzbdServiceManager(
            sessionConfiguration: CapturedShapeURLProtocol.makeConfiguration()
        )
        let profile = SABnzbdServiceProfile(displayName: "Fixture SAB", hostURL: "http://captured.sabnzbd.test")
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "totally-wrong-key")
        defer { Task { try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey) } }

        await manager.connectService(profile)

        #expect(manager.isConnected == false)
        #expect(manager.connectionError == "SABnzbd rejected the API key. Update it in Settings.")
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
    /// Keyed by SABnzbd's `mode` query parameter, because SABnzbd has one path and
    /// distinguishes calls by `mode` rather than by endpoint.
    nonisolated(unsafe) static var sabnzbdModeResponses: [String: CapturedResponse] = [:]

    static func reset() {
        loginResponse = nil
        apiResponse = nil
        sabnzbdModeResponses = [:]
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

        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "mode" })?
            .value

        let canned: CapturedResponse?
        if url.path.contains("/auth/login") {
            canned = Self.loginResponse
        } else if let mode, let modeResponse = Self.sabnzbdModeResponses[mode] {
            canned = modeResponse
        } else {
            canned = Self.apiResponse
        }

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
