import Foundation
import Testing
@testable import Trawl

/// Network contract tests for `SABnzbdAPIClient`.
///
/// Everything here runs the real client: the real query builder, the real
/// `HTTPTransport`, the real multipart serializer, the real status validator,
/// the real decoder and the real `HTTPErrorMapper`. The only fake is the remote
/// SABnzbd server, which answers through an injected `URLProtocol` and records
/// exactly what Trawl put on the wire.
///
/// Model decoding of realistic mixed-shape queue/history payloads, normalized
/// statuses and `SABnzbdAPIError` message formatting belong to
/// `SABnzbdTests.swift` and are deliberately not repeated here. What this file
/// owns is the request/auth/status/upload boundary that file cannot reach.
@Suite("SABnzbd API client HTTP contracts", .serialized)
struct SABnzbdAPIClientContractTests {
    private let apiKey = "contract-api-key"
    private let hostileFilename = "episode\".nzb\r\nContent-Type: text/html\r\n\r\n<script>alert(1)</script>"
    private let sanitizedFilename = "episode'.nzbContent-Type: text/html<script>alert(1)</script>"

    // MARK: - Request shape: reads

    @Test("The queue request sends mode, paging, search and status filters in the documented order")
    func queueRequestSendsDocumentedQuery() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(
            .json(#"{"queue":{"slots":[{"nzo_id":"SABnzbd_nzo_q1","filename":"Contract Job","status":"Downloading","mb":100,"mbleft":25,"percentage":75,"size":"100 MB","sizeleft":"25 MB"}]}}"#),
            forKey: "queue"
        )
        let client = makeClient()

        let queue = try await client.getQueue(
            start: 5,
            limit: 25,
            search: "  the expanse  ",
            statuses: ["Downloading", "Paused"]
        )

        #expect(queue.jobs.map(\.id) == ["SABnzbd_nzo_q1"])
        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "queue"),
                item("start", "5"),
                item("limit", "25"),
                item("search", "the expanse"),
                item("status", "Downloading,Paused")
            ])
        ])
    }

    @Test("Out-of-range queue paging is clamped before it reaches the server")
    func queuePagingIsClampedInTheRequest() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json(#"{"queue":{"slots":[]}}"#), forKey: "queue")
        let client = makeClient()

        _ = try await client.getQueue(start: -7, limit: 0)

        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "queue"),
                item("start", "0"),
                item("limit", "1")
            ])
        ])
    }

    @Test("History sends paging, status and last_history_update, and reads both documented shapes")
    func historyRequestSendsPagingAndPollingToken() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(
            .json(#"{"history":{"last_history_update":42,"slots":[{"nzo_id":"SABnzbd_nzo_h1","name":"Contract Finished","status":"Completed","bytes":100000,"downloaded":100000,"size":"100 KB","completed":1700000000}]}}"#),
            forKey: "history"
        )
        let client = makeClient()

        let history = try await client.getHistory(start: 10, limit: 50, statuses: ["Completed"])
        #expect(history?.jobs.map(\.id) == ["SABnzbd_nzo_h1"])

        // SABnzbd's polling shape: `history` comes back as `false` when nothing
        // changed since `last_history_update`.
        server.setResponse(.json(#"{"history":false}"#), forKey: "history")
        let unchanged = try await client.getHistory(lastHistoryUpdate: 42)
        #expect(unchanged == nil)

        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "history"),
                item("start", "10"),
                item("limit", "50"),
                item("status", "Completed")
            ]),
            signature(query: common() + [
                item("mode", "history"),
                item("start", "0"),
                item("limit", "200"),
                item("last_history_update", "42")
            ])
        ])
    }

    @Test("Category and script lists are fetched by their own modes and stripped of SABnzbd's sentinels")
    func categoryAndScriptListsAreRequestedAndFiltered() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json(#"{"categories":["*","Default","none","","movies","tv"]}"#), forKey: "get_cats")
        server.setResponse(.json(#"{"scripts":["None","notify.py"]}"#), forKey: "get_scripts")
        let client = makeClient()

        let categories = try await client.getCategories()
        let scripts = try await client.getScripts()

        #expect(categories == ["movies", "tv"])
        #expect(scripts == ["notify.py"])
        #expect(server.signatures() == [
            signature(query: common() + [item("mode", "get_cats")]),
            signature(query: common() + [item("mode", "get_scripts")])
        ])
    }

    @Test("Config sections are read by mode=get_config plus an explicit section")
    func configSectionsAreRequestedBySection() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(
            .json(#"{"config":{"servers":[{"name":"primary","host":"news.example","port":"563","connections":8,"ssl":1,"enable":true,"optional":0}]}}"#),
            forKey: "get_config/servers"
        )
        // A section SABnzbd answers without the key at all must read as empty,
        // not as a decode failure.
        server.setResponse(.json(#"{"config":{}}"#), forKey: "get_config/categories")
        let client = makeClient()

        let servers = try await client.getNewsServers()
        let categories = try await client.getCategoryConfigs()

        #expect(servers.map(\.name) == ["primary"])
        #expect(categories.isEmpty)
        #expect(server.signatures() == [
            signature(query: common() + [item("mode", "get_config"), item("section", "servers")]),
            signature(query: common() + [item("mode", "get_config"), item("section", "categories")])
        ])
    }

    // MARK: - Base URL and API key encoding

    @Test(
        "Every accepted base URL form resolves to exactly one /api path",
        arguments: [
            ("https://sabnzbd.contract.test", "/api"),
            ("https://sabnzbd.contract.test/", "/api"),
            ("https://sabnzbd.contract.test/api", "/api"),
            ("https://sabnzbd.contract.test/api/", "/api"),
            ("  https://sabnzbd.contract.test/sab  ", "/sab/api")
        ]
    )
    func baseURLVariantsResolveToOneAPIPath(baseURL: String, expectedPath: String) async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json(#"{"version":"4.5.1"}"#), forKey: "version")
        let client = makeClient(baseURL: baseURL)

        let version = try await client.getVersion()

        #expect(version == "4.5.1")
        #expect(server.signatures() == [
            SABnzbdRequestSignature(
                method: "GET",
                path: expectedPath,
                queryItems: common() + [item("mode", "version")]
            )
        ])
    }

    @Test("The API key is percent-encoded into every query rather than sent raw")
    func apiKeyIsPercentEncodedInTheQuery() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json(#"{"version":"4.5.1"}"#), forKey: "version")
        let client = makeClient(apiKey: "trawl contract key")

        _ = try await client.getVersion()

        let recorded = try #require(server.requests().first)
        let url = try #require(recorded.request.url)
        #expect(url.query(percentEncoded: true) == "output=json&apikey=trawl%20contract%20key&mode=version")
        #expect(server.requests().count == 1)
    }

    // MARK: - Authentication and key rejection

    /// SABnzbd's *only* signal that the caller holds the add-only NZB key rather
    /// than the full API key is `mode=auth` answering `{"auth":"nzbkey"}` - it is
    /// a plain HTTP 200 success. The client decodes it and returns it; it does
    /// not translate it into `SABnzbdAPIError.insufficientAPIKey`. That
    /// translation currently happens nowhere: `SABnzbdSetupViewModel` raises its
    /// own `SABnzbdSetupError.fullAPIKeyRequired`, and the
    /// `catch SABnzbdAPIError.insufficientAPIKey` arm in `SABnzbdServiceManager`
    /// is therefore unreachable. This test pins the real contract.
    @Test("mode=auth reports the add-only NZB key as a successful 200, not as an error")
    func authenticationModeReportsTheAddOnlyKeyWithoutThrowing() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json(#"{"auth":"nzbkey"}"#), forKey: "auth")
        let client = makeClient()

        let authentication = try await client.getAuthentication()

        #expect(authentication == .nzbKey)
        #expect(server.signatures() == [
            signature(query: common() + [item("mode", "auth"), item("key", apiKey)])
        ])
    }

    @Test("mode=auth reports a full API key and a bad key through the same 200 shape", arguments: [
        ("apikey", SABnzbdAuthentication.apiKey),
        ("badkey", SABnzbdAuthentication.badKey)
    ])
    func authenticationModeReportsRemainingKeyKinds(raw: String, expected: SABnzbdAuthentication) async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json("{\"auth\":\"\(raw)\"}"), forKey: "auth")
        let client = makeClient()

        let authentication = try await client.getAuthentication()

        #expect(authentication == expected)
        #expect(server.requests().count == 1)
    }

    @Test("A 401 or 403 from SABnzbd maps to unauthorized", arguments: [401, 403])
    func unauthorizedStatusesMapToUnauthorized(statusCode: Int) async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"status":false,"error":"API Key Incorrect"}"#, status: statusCode))
        let client = makeClient()

        let error = await capturedError { _ = try await client.getQueue() }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .unauthorized = apiError else {
            Issue.record("Expected .unauthorized for HTTP \(statusCode), received \(apiError)")
            return
        }
        #expect(server.requests().count == 1)
    }

    /// The other way SABnzbd rejects a key: HTTP 200 with `status:false`. The
    /// client maps that to `.api(message:)`, **not** `.unauthorized` - so the
    /// H-05/H-06 lifecycle in `SABnzbdServiceManager`, which keys off
    /// `SABnzbdAPIError.unauthorized`, never fires for a server that answers this
    /// way. This test pins the current mapping so that gap is visible rather than
    /// silent.
    @Test("A key rejection delivered as a 200 error body maps to .api, not .unauthorized", arguments: [
        "API Key Incorrect",
        "API Key Required"
    ])
    func keyRejectionInA200BodyMapsToAPIError(serverMessage: String) async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json("{\"status\":false,\"error\":\"\(serverMessage)\"}"))
        let client = makeClient()

        let error = await capturedError { _ = try await client.getQueue() }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .api(let message) = apiError else {
            Issue.record("Expected .api, received \(apiError)")
            return
        }
        #expect(message == serverMessage)
        #expect(server.requests().count == 1)
    }

    // MARK: - HTTP failure statuses

    @Test("Documented non-success statuses map to .http with the server's body", arguments: [404, 429, 503])
    func failureStatusesMapToHTTPError(statusCode: Int) async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.text("SABnzbd is unavailable", status: statusCode))
        let client = makeClient()

        let error = await capturedError { _ = try await client.getQueue() }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .http(let status, let body) = apiError else {
            Issue.record("Expected .http for HTTP \(statusCode), received \(apiError)")
            return
        }
        #expect(status == statusCode)
        #expect(body == "SABnzbd is unavailable")
        #expect(server.requests().count == 1)
    }

    @Test("A reverse-proxy HTML error page keeps its status and body instead of decoding")
    func htmlErrorPageMapsToHTTPError() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        let page = "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>"
        server.setFallbackResponse(.html(page, status: 502))
        let client = makeClient()

        let error = await capturedError { _ = try await client.getQueue() }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .http(let status, let body) = apiError else {
            Issue.record("Expected .http, received \(apiError)")
            return
        }
        #expect(status == 502)
        #expect(body == page)
        #expect(server.requests().count == 1)
    }

    // MARK: - Bodies that must never read as an empty success

    @Test("Malformed, empty and HTML 200 bodies fail to decode instead of yielding an empty queue", arguments: [
        "{ \"queue\": ",
        "",
        "<html><body>SABnzbd is starting up</body></html>",
        "[]"
    ])
    func undecodableSuccessBodiesFailLoudly(body: String) async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(body))
        let client = makeClient()

        let error = await capturedError { _ = try await client.getQueue() }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .decode = apiError else {
            Issue.record("Expected .decode for body \"\(body)\", received \(apiError)")
            return
        }
        #expect(server.requests().count == 1)
    }

    // MARK: - Queue mutations

    @Test("Queue mutations send the documented mode, name and value pairs")
    func queueMutationsSendDocumentedQueries() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"status":true}"#))
        let client = makeClient()

        try await client.pauseQueue()
        try await client.resumeQueue()
        try await client.pauseJobs(ids: ["  nzo_a  ", "", "nzo_b"])
        try await client.resumeJobs(ids: ["nzo_a"])
        try await client.deleteQueueJobs(ids: ["nzo_a", "nzo_b"], deleteFiles: true)
        try await client.deleteQueueJobs(ids: ["nzo_c"])
        try await client.setPriority(id: "nzo_a", priority: -1)
        try await client.setCategory(id: "nzo_a", category: "tv")
        try await client.reorderJob(id: "nzo_a", toPosition: 3)

        #expect(server.signatures() == [
            signature(query: common() + [item("mode", "pause")]),
            signature(query: common() + [item("mode", "resume")]),
            signature(query: common() + [item("mode", "queue"), item("name", "pause"), item("value", "nzo_a,nzo_b")]),
            signature(query: common() + [item("mode", "queue"), item("name", "resume"), item("value", "nzo_a")]),
            signature(query: common() + [
                item("mode", "queue"),
                item("name", "delete"),
                item("value", "nzo_a,nzo_b"),
                item("del_files", "1")
            ]),
            signature(query: common() + [item("mode", "queue"), item("name", "delete"), item("value", "nzo_c")]),
            signature(query: common() + [
                item("mode", "queue"),
                item("name", "priority"),
                item("value", "nzo_a"),
                item("value2", "-1")
            ]),
            signature(query: common() + [
                item("mode", "queue"),
                item("name", "change_cat"),
                item("value", "nzo_a"),
                item("value2", "tv")
            ]),
            signature(query: common() + [item("mode", "switch"), item("value", "nzo_a"), item("value2", "3")])
        ])
    }

    @Test("History mutations send the documented mode, name and value pairs")
    func historyMutationsSendDocumentedQueries() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"status":true}"#))
        server.setResponse(.json(#"{"status":true,"nzo_id":"SABnzbd_nzo_retry"}"#), forKey: "retry")
        let client = makeClient()

        try await client.deleteHistoryJobs(ids: ["nzo_h1", "nzo_h2"], permanently: true, deleteFiles: true)
        try await client.clearHistory()
        let retriedID = try await client.retryHistoryJob(id: "nzo_h1", password: "s3cret")

        #expect(retriedID == "SABnzbd_nzo_retry")
        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "history"),
                item("name", "delete"),
                item("value", "nzo_h1,nzo_h2"),
                item("archive", "0"),
                item("del_files", "1")
            ]),
            signature(query: common() + [item("mode", "history"), item("name", "delete"), item("value", "all")]),
            signature(query: common() + [item("mode", "retry"), item("value", "nzo_h1"), item("password", "s3cret")])
        ])
    }

    @Test("Blank job identifiers fail before anything is put on the wire")
    func blankJobIdentifiersNeverReachTheServer() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        let client = makeClient()

        var errors: [(any Error)?] = []
        errors.append(await capturedError { try await client.pauseJobs(ids: ["   ", ""]) })
        errors.append(await capturedError { try await client.resumeJobs(ids: []) })
        errors.append(await capturedError { try await client.deleteQueueJobs(ids: []) })
        errors.append(await capturedError { try await client.reorderJob(id: " ", toPosition: 1) })
        errors.append(await capturedError { _ = try await client.retryHistoryJob(id: "") })

        for error in errors {
            let apiError = try #require(error as? SABnzbdAPIError)
            guard case .invalidResponse = apiError else {
                Issue.record("Expected .invalidResponse, received \(apiError)")
                return
            }
        }

        #expect(server.requests().isEmpty)
    }

    @Test("A mutation SABnzbd refuses in a 200 body surfaces its message")
    func refusedMutationSurfacesServerMessage() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"status":false,"error":"nzo_id not found"}"#))
        let client = makeClient()

        let error = await capturedError { try await client.deleteQueueJobs(ids: ["nzo_missing"]) }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .api(let message) = apiError else {
            Issue.record("Expected .api, received \(apiError)")
            return
        }
        #expect(message == "nzo_id not found")
        #expect(server.requests().count == 1)
    }

    // MARK: - Config writes

    @Test("Speed limit, pause duration and del_config send exact section and keyword queries")
    func configurationMutationsSendDocumentedQueries() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"status":true}"#))
        let client = makeClient()

        try await client.setSpeedLimit("1500K")
        try await client.setPauseDuration(minutes: 30)
        try await client.deleteCategory(name: "tv")
        try await client.deleteNewsServer(name: "news.example")

        #expect(server.signatures() == [
            signature(query: common() + [item("mode", "config"), item("name", "speedlimit"), item("value", "1500K")]),
            signature(query: common() + [item("mode", "config"), item("name", "set_pause"), item("value", "30")]),
            signature(query: common() + [
                item("mode", "del_config"),
                item("section", "categories"),
                item("keyword", "tv")
            ]),
            signature(query: common() + [
                item("mode", "del_config"),
                item("section", "servers"),
                item("keyword", "news.example")
            ])
        ])
    }

    /// `set_config` echoes the saved section instead of a status envelope, which
    /// is why the client reads it as raw data. A successful save must therefore
    /// not be reported as a decode failure.
    @Test("Renaming a news server sends keyword plus name and tolerates the echoed config body")
    func savingANewsServerSendsRenameKeysAndAcceptsTheEcho() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(
            .json(#"{"config":{"servers":[{"name":"primary","host":"news.example","port":563}]}}"#)
        )
        let client = makeClient()

        let newsServer = SABnzbdNewsServer(
            name: "primary",
            displayName: "Primary",
            host: "news.example",
            port: 563,
            username: "reader",
            password: "hunter2",
            connections: 8,
            ssl: true,
            sslVerify: 1,
            enabled: true,
            optional: false,
            retention: 1200,
            timeout: 60,
            priority: 0,
            notes: "primary feed"
        )

        try await client.saveNewsServer(newsServer, originalName: "legacy-name")

        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "set_config"),
                item("section", "servers"),
                item("keyword", "legacy-name"),
                item("name", "primary"),
                item("host", "news.example"),
                item("port", "563"),
                item("connections", "8"),
                item("ssl", "1"),
                item("enable", "1"),
                item("optional", "0"),
                item("displayname", "Primary"),
                item("username", "reader"),
                item("password", "hunter2"),
                item("retention", "1200"),
                item("timeout", "60"),
                item("priority", "0"),
                item("ssl_verify", "1"),
                item("notes", "primary feed")
            ])
        ])
    }

    @Test("Saving a renamed category always sends explicit empty script and directory values")
    func savingACategorySendsExplicitClearingValues() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"config":{"categories":[{"name":"tv"}]}}"#))
        let client = makeClient()

        let category = SABnzbdCategory(name: "tv", postProcessing: 3, script: nil, directory: nil, priority: -1)
        try await client.saveCategory(category, originalName: "television")

        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "set_config"),
                item("section", "categories"),
                item("keyword", "television"),
                item("name", "tv"),
                item("pp", "3"),
                item("script", ""),
                item("dir", ""),
                item("priority", "-1")
            ])
        ])
    }

    @Test("A failed news-server test is a successful request that returns SABnzbd's message")
    func testNewsServerReturnsFailureMessageWithoutThrowing() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"value":{"result":false,"message":"Server could not be reached"}}"#))
        let client = makeClient()

        let newsServer = SABnzbdNewsServer(
            name: "primary",
            host: "news.example",
            port: 119,
            username: "reader",
            password: "hunter2",
            connections: 4,
            ssl: false
        )
        let outcome = try await client.testNewsServer(newsServer)

        #expect(outcome.succeeded == false)
        #expect(outcome.message == "Server could not be reached")
        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "config"),
                item("name", "test_server"),
                item("host", "news.example"),
                item("port", "119"),
                item("username", "reader"),
                item("password", "hunter2"),
                item("connections", "4"),
                item("ssl", "0")
            ])
        ])
    }

    // MARK: - Add by URL

    @Test("addurl sends the NZB URL and every add option as query items")
    func addURLSendsDocumentedQuery() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json(#"{"status":true,"nzo_ids":["SABnzbd_nzo_added"]}"#), forKey: "addurl")
        let client = makeClient()

        // The NZB URL carries its own query string; it has to survive as one
        // opaque value rather than leaking extra query items into SABnzbd's call.
        let nzbURL = try #require(URL(string: "https://indexer.contract.test/fetch?id=abc&r=xyz"))
        let identifiers = try await client.addURL(
            nzbURL,
            options: SABnzbdAddOptions(
                name: "  My Show  ",
                password: "nzbpass",
                category: "tv",
                script: "notify.py",
                priority: -1,
                postProcessing: 3
            )
        )

        #expect(identifiers == ["SABnzbd_nzo_added"])
        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "addurl"),
                item("name", "https://indexer.contract.test/fetch?id=abc&r=xyz"),
                item("nzbname", "My Show"),
                item("password", "nzbpass"),
                item("cat", "tv"),
                item("script", "notify.py"),
                item("priority", "-1"),
                item("pp", "3")
            ])
        ])
    }

    @Test("Blank add options are omitted from the addurl query entirely")
    func addURLOmitsBlankOptions() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setResponse(.json(#"{"status":true,"nzo_ids":[]}"#), forKey: "addurl")
        let client = makeClient()

        let nzbURL = try #require(URL(string: "https://indexer.contract.test/one.nzb"))
        let identifiers = try await client.addURL(
            nzbURL,
            options: SABnzbdAddOptions(name: "   ", password: "", category: "  ", script: nil)
        )

        #expect(identifiers.isEmpty)
        #expect(server.signatures() == [
            signature(query: common() + [
                item("mode", "addurl"),
                item("name", "https://indexer.contract.test/one.nzb")
            ])
        ])
    }

    // MARK: - NZB upload (multipart)

    @Test("The NZB upload posts one multipart file part and cannot be tricked into a second header")
    func addNZBPostsOneSanitizedFilePart() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"status":true,"nzo_ids":["SABnzbd_nzo_upload"]}"#))
        let client = makeClient()

        let fileData = Data("<nzb><file subject=\"part\"/></nzb>".utf8)
        let identifiers = try await client.addNZB(
            data: fileData,
            filename: hostileFilename,
            options: SABnzbdAddOptions(category: "tv", priority: -100)
        )

        #expect(identifiers == ["SABnzbd_nzo_upload"])

        let recorded = try #require(server.requests().first)
        #expect(server.requests().count == 1)
        #expect(recorded.request.httpMethod == "POST")
        #expect(recorded.request.url?.path == "/api")

        // Credentials travel in the query; the add options travel in the form body.
        let components = URLComponents(url: try #require(recorded.request.url), resolvingAgainstBaseURL: false)
        #expect(components?.queryItems == common())

        let contentType = try #require(recorded.request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        #expect(contentType == "multipart/form-data; boundary=\(boundary)")
        #expect(boundary.hasPrefix("TrawlBoundary"))
        #expect(boundary.count == "TrawlBoundary".count + 32)

        let expectedBody = Data(([
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"mode\"\r\n\r\n",
            "addfile\r\n",
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"cat\"\r\n\r\n",
            "tv\r\n",
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"priority\"\r\n\r\n",
            "-100\r\n",
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"nzbfile\"; filename=\"\(sanitizedFilename)\"\r\n",
            "Content-Type: application/x-nzb\r\n\r\n",
            "<nzb><file subject=\"part\"/></nzb>\r\n",
            "--\(boundary)--\r\n"
        ] as [String]).joined().utf8)
        #expect(recorded.body == expectedBody)

        // The hostile filename asked for a second `Content-Disposition` header and
        // a `Content-Type: text/html` header. Neither exists: the CR/LF pair was
        // stripped and the quotes were downgraded, so the whole payload stayed
        // inside one quoted filename token.
        let bodyText = try #require(String(data: recorded.body, encoding: .utf8))
        // Three form fields plus exactly one file part: four headers, no more.
        #expect(occurrences(of: "\r\nContent-Disposition:", in: "\r\n" + bodyText) == 4)
        #expect(occurrences(of: "filename=\"", in: bodyText) == 1)
        #expect(occurrences(of: "Content-Type: application/x-nzb", in: bodyText) == 1)
        #expect(occurrences(of: "Content-Type: text/html\r\n", in: bodyText) == 0)
        #expect(occurrences(of: "--\(boundary)", in: bodyText) == 5)
        #expect(recorded.request.value(forHTTPHeaderField: "X-Injected") == nil)
    }

    @Test("An empty NZB payload is rejected before any upload is attempted")
    func addNZBRejectsEmptyPayloadWithoutARequest() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        let client = makeClient()

        let error = await capturedError { _ = try await client.addNZB(data: Data(), filename: "empty.nzb") }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .invalidResponse = apiError else {
            Issue.record("Expected .invalidResponse, received \(apiError)")
            return
        }
        #expect(server.requests().isEmpty)
    }

    @Test("An upload refused in a 200 body surfaces SABnzbd's message")
    func addNZBSurfacesRefusalMessage() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.json(#"{"status":false,"error":"Empty NZB file"}"#))
        let client = makeClient()

        let error = await capturedError {
            _ = try await client.addNZB(data: Data("<nzb/>".utf8), filename: "broken.nzb")
        }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .api(let message) = apiError else {
            Issue.record("Expected .api, received \(apiError)")
            return
        }
        #expect(message == "Empty NZB file")
        #expect(server.requests().count == 1)
    }

    @Test("An upload rejected with 401 maps to unauthorized on the multipart path too")
    func addNZBMapsUnauthorizedStatus() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.text("API Key Incorrect", status: 401))
        let client = makeClient()

        let error = await capturedError {
            _ = try await client.addNZB(data: Data("<nzb/>".utf8), filename: "rejected.nzb")
        }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .unauthorized = apiError else {
            Issue.record("Expected .unauthorized, received \(apiError)")
            return
        }
        #expect(server.requests().count == 1)
    }

    @Test("An HTML page returned to an upload fails to decode rather than reporting no identifiers")
    func addNZBRejectsHTMLSuccessBody() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        server.setFallbackResponse(.html("<html><body>Login</body></html>", status: 200))
        let client = makeClient()

        let error = await capturedError {
            _ = try await client.addNZB(data: Data("<nzb/>".utf8), filename: "login.nzb")
        }

        let apiError = try #require(error as? SABnzbdAPIError)
        guard case .decode = apiError else {
            Issue.record("Expected .decode, received \(apiError)")
            return
        }
        #expect(server.requests().count == 1)
    }

    // MARK: - Cancellation

    @Test("Cancelling an in-flight queue request surfaces CancellationError, not a transport error")
    func cancellingAnInFlightRequestThrowsCancellationError() async throws {
        let server = SABnzbdContractServer.shared
        server.reset()
        // The fake server accepts the request and never answers, so the only way
        // this call can finish is cancellation. No sleeping is involved: the test
        // waits on the server's own arrival barrier before cancelling.
        server.stallEveryRequest()
        let client = makeClient()

        let request = Task { try await client.getQueue() }
        await server.waitForFirstRequest()
        request.cancel()

        let error = await capturedError { _ = try await request.value }

        #expect(error is CancellationError, "Expected CancellationError, received \(String(describing: error))")
        #expect(server.requests().count == 1)
        server.reset()
    }

    // MARK: - Helpers

    private func makeClient(
        baseURL: String = "https://sabnzbd.contract.test",
        apiKey: String? = nil
    ) -> SABnzbdAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SABnzbdContractURLProtocol.self]
        return SABnzbdAPIClient(
            baseURL: baseURL,
            apiKey: apiKey ?? self.apiKey,
            sessionConfiguration: configuration
        )
    }

    private func common(apiKey: String? = nil) -> [URLQueryItem] {
        [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "apikey", value: apiKey ?? self.apiKey)
        ]
    }

    private func item(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }

    private func signature(
        method: String = "GET",
        path: String = "/api",
        query: [URLQueryItem]
    ) -> SABnzbdRequestSignature {
        SABnzbdRequestSignature(method: method, path: path, queryItems: query)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func capturedError(_ operation: () async throws -> Void) async -> (any Error)? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }
}

// MARK: - Recorded request

private nonisolated struct SABnzbdRequestSignature: Equatable, Sendable {
    let method: String
    let path: String
    let queryItems: [URLQueryItem]
}

private nonisolated struct SABnzbdRecordedRequest: Sendable {
    let request: URLRequest
    let body: Data

    var signature: SABnzbdRequestSignature {
        let url = request.url
        let queryItems = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
        } ?? []
        return SABnzbdRequestSignature(
            method: request.httpMethod ?? "GET",
            path: url?.path ?? "",
            queryItems: queryItems
        )
    }
}

// MARK: - Fake SABnzbd server

/// One fake SABnzbd behind a `URLProtocol`. Responses are keyed by the `mode`
/// query item (plus `section` where SABnzbd overloads a mode), so a single test
/// can drive several endpoints and still assert an exact request list.
private nonisolated final class SABnzbdContractServer: @unchecked Sendable {
    static let host = "sabnzbd.contract.test"
    static let shared = SABnzbdContractServer()

    struct Response: Sendable {
        let statusCode: Int
        let body: Data
        let contentType: String

        static func json(_ json: String, status: Int = 200) -> Response {
            Response(statusCode: status, body: Data(json.utf8), contentType: "application/json")
        }

        static func html(_ html: String, status: Int) -> Response {
            Response(statusCode: status, body: Data(html.utf8), contentType: "text/html; charset=utf-8")
        }

        static func text(_ text: String, status: Int) -> Response {
            Response(statusCode: status, body: Data(text.utf8), contentType: "text/plain; charset=utf-8")
        }
    }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var fallback = Response.json("{}")
    private var isStalling = false
    private var recorded: [SABnzbdRecordedRequest] = []
    private var arrivalWaiter: CheckedContinuation<Void, Never>?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        responses = [:]
        fallback = Response.json("{}")
        isStalling = false
        recorded = []
        arrivalWaiter = nil
    }

    func setResponse(_ response: Response, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        responses[key] = response
    }

    func setFallbackResponse(_ response: Response) {
        lock.lock()
        defer { lock.unlock() }
        fallback = response
    }

    func stallEveryRequest() {
        lock.lock()
        defer { lock.unlock() }
        isStalling = true
    }

    func requests() -> [SABnzbdRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func signatures() -> [SABnzbdRequestSignature] {
        requests().map(\.signature)
    }

    /// Records the request and returns the response to send, or `nil` when the
    /// server is deliberately stalling and should never answer.
    func record(_ request: URLRequest, body: Data) -> Response? {
        lock.lock()
        recorded.append(SABnzbdRecordedRequest(request: request, body: body))
        let waiter = arrivalWaiter
        arrivalWaiter = nil
        let stalling = isStalling
        let key = request.url.map(Self.responseKey(for:)) ?? ""
        let response = responses[key] ?? fallback
        lock.unlock()

        waiter?.resume()
        return stalling ? nil : response
    }

    /// Barrier used instead of sleeping: resumes as soon as the fake server has
    /// actually received a request.
    func waitForFirstRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !recorded.isEmpty {
                lock.unlock()
                continuation.resume()
                return
            }
            arrivalWaiter = continuation
            lock.unlock()
        }
    }

    private static func responseKey(for url: URL) -> String {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let mode = queryItems.first(where: { $0.name == "mode" })?.value ?? ""
        guard let section = queryItems.first(where: { $0.name == "section" })?.value else { return mode }
        return "\(mode)/\(section)"
    }
}

private nonisolated final class SABnzbdContractURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == SABnzbdContractServer.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = Self.readBody(from: request)
        guard let fixture = SABnzbdContractServer.shared.record(request, body: body) else {
            // Stalled on purpose; only cancellation can end this request.
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": fixture.contentType]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !fixture.body.isEmpty {
            client?.urlProtocol(self, didLoad: fixture.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            buffer.withUnsafeBufferPointer { bytes in
                if let baseAddress = bytes.baseAddress {
                    body.append(baseAddress, count: count)
                }
            }
        }
        return body
    }
}
