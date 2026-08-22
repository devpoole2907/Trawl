import Foundation
import Network
import Testing
@testable import Trawl

/// Network contract tests for `JellyfinAPIClient`.
///
/// Every test here drives the real production stack — `JellyfinAPIClient`'s
/// request builders, `JellyfinAuthHeader`, `HTTPTransport`'s URL/query
/// construction, its status validator, `JSONDecoder`, and the
/// `HTTPErrorMapper` that produces `JellyfinAPIError`. The only fake is the
/// remote server: a loopback `NWListener` that records the raw HTTP bytes and
/// replies with canned payloads.
///
/// A real socket (rather than a `URLProtocol` stub) is used deliberately: it
/// lets these tests assert the *wire* form of the request — the exact request
/// line, the exact percent-encoding of the query, the exact `Authorization`
/// header string, and the exact request body — none of which a `URLProtocol`
/// can observe faithfully (`URLRequest.httpBody` is not reliably visible
/// there). It also needs no production seam: `JellyfinAPIClient.init` already
/// takes a `baseURL`.
@Suite("Jellyfin API client network contracts", .serialized)
@MainActor
struct JellyfinContractTests {

    // MARK: - Request shape

    @Test("The unauthenticated public system-info probe omits the auth token and decodes the server identity")
    func publicSystemInfoProbeOmitsToken() async throws {
        let server = try await JellyfinContractServer(label: "public-info") { _ in
            JellyfinCannedResponse.json(
                #"{"Id":"9f3ab2","ServerName":"Basement","Version":"10.10.7","ProductName":"Jellyfin Server","StartupCompleted":true}"#
            )
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: nil)

        let info = try await client.getPublicSystemInfo()

        #expect(info.id == "9f3ab2")
        #expect(info.serverName == "Basement")
        #expect(info.version == "10.10.7")
        #expect(info.startupCompleted == true)

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/System/Info/Public")
        #expect(request.rawQuery == "")

        let header = try #require(request.authorization)
        #expect(header.hasPrefix("MediaBrowser "))
        let fields = JellyfinAuthHeaderProbe.fields(in: header)
        #expect(fields.map(\.name) == ["Client", "Device", "DeviceId", "Version"])
        #expect(fields.first?.value == "Trawl")
        let deviceIdField = fields.first(where: { $0.name == "DeviceId" })
        let deviceId = try #require(deviceIdField?.value)
        #expect(UUID(uuidString: deviceId) != nil)
        // Every field value is percent-encoded, so no value can smuggle a
        // quote, comma, or space into the header and break its grammar.
        let everyValueIsEncoded = fields.allSatisfy {
            !$0.value.contains(" ") && !$0.value.contains("\"") && !$0.value.contains(",")
        }
        #expect(everyValueIsEncoded)
    }

    @Test("Authenticating by name posts the documented JSON body and adopts the returned access token")
    func authenticateByNameAdoptsReturnedToken() async throws {
        let server = try await JellyfinContractServer(label: "authenticate") { request -> JellyfinCannedResponse? in
            if request.path == "/Users/AuthenticateByName" {
                return JellyfinCannedResponse.json(
                    #"{"User":{"Id":"u1","Name":"admin","Policy":{"IsAdministrator":true}},"AccessToken":"server-issued-token","ServerId":"srv-1"}"#
                )
            }
            return JellyfinCannedResponse.json("{}")
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: nil)

        let response = try await client.authenticateByName(username: "admin", password: "hunter2")

        #expect(response.accessToken == "server-issued-token")
        #expect(response.serverId == "srv-1")
        #expect(response.user.id == "u1")
        #expect(response.user.isAdministrator)
        let storedToken = await client.getAccessToken()
        #expect(storedToken == "server-issued-token")

        try await client.ping()

        #expect(server.requests.count == 2)

        let login = try #require(server.requests.first)
        #expect(login.method == "POST")
        #expect(login.path == "/Users/AuthenticateByName")
        #expect(login.rawQuery == "")
        #expect(login.contentType == "application/json")
        let loginBody = try #require(login.jsonDictionary())
        #expect(loginBody.count == 2)
        #expect(loginBody["Username"] as? String == "admin")
        #expect(loginBody["Pw"] as? String == "hunter2")
        let loginHeader = try #require(login.authorization)
        #expect(JellyfinAuthHeaderProbe.fields(in: loginHeader).map(\.name) == ["Client", "Device", "DeviceId", "Version"])

        let ping = server.requests[1]
        #expect(ping.method == "GET")
        #expect(ping.path == "/System/Ping")
        let pingHeader = try #require(ping.authorization)
        let pingFields = JellyfinAuthHeaderProbe.fields(in: pingHeader)
        #expect(pingFields.map(\.name) == ["Client", "Device", "DeviceId", "Version", "Token"])
        #expect(pingFields.last?.value == "server-issued-token")
    }

    @Test("A library page sends Jellyfin's documented Items query")
    func libraryPageSendsDocumentedQuery() async throws {
        let server = try await JellyfinContractServer(label: "library-page") { _ in
            JellyfinCannedResponse.json(#"{"Items":[],"TotalRecordCount":0,"StartIndex":500}"#)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        _ = try await client.getLibraryItems(
            includeItemTypes: ["Movie", "Series"],
            startIndex: 500,
            limit: 250
        )

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/Items")
        #expect(request.sortedQueryItems == [
            URLQueryItem(name: "Fields", value: "ProviderIds,Path,DateCreated,MediaSources"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Limit", value: "250"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "StartIndex", value: "500")
        ])
    }

    @Test("A provider-ID lookup joins every provider and id into one AnyProviderIdEquals value")
    func providerLookupJoinsProviderIdPairs() async throws {
        let server = try await JellyfinContractServer(label: "provider-lookup") { _ in
            JellyfinCannedResponse.json(#"{"Items":[],"TotalRecordCount":0}"#)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        _ = try await client.findItems(
            includeItemTypes: ["Movie"],
            anyProviderIdEquals: [(provider: "Tmdb", id: "335984"), (provider: "Imdb", id: "tt1856101")],
            limit: 5
        )

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/Items")
        #expect(request.sortedQueryItems == [
            URLQueryItem(name: "AnyProviderIdEquals", value: "Tmdb.335984,Imdb.tt1856101"),
            URLQueryItem(name: "Fields", value: "ProviderIds,Path,DateCreated,MediaSources"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
            URLQueryItem(name: "Limit", value: "5"),
            URLQueryItem(name: "Recursive", value: "true")
        ])
    }

    @Test("The episode lookup interpolates the series id into the Shows path")
    func episodeLookupInterpolatesSeriesId() async throws {
        let server = try await JellyfinContractServer(label: "series-episodes") { _ in
            JellyfinCannedResponse.json(
                #"{"Items":[{"Id":"ep-1","Name":"Dulcinea","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1,"SeriesId":"3f2a9b"}],"TotalRecordCount":1}"#
            )
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        let episodes = try await client.getSeriesEpisodes(seriesId: "3f2a9b")

        #expect(episodes.map(\.id) == ["ep-1"])
        #expect(episodes.first?.indexNumber == 1)
        #expect(episodes.first?.parentIndexNumber == 1)

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/Shows/3f2a9b/Episodes")
        #expect(request.sortedQueryItems == [
            URLQueryItem(name: "Fields", value: "ProviderIds,Path,DateCreated,MediaSources,Overview")
        ])
    }

    @Test("A title search percent-encodes the search term on the wire")
    func titleSearchPercentEncodesTheTerm() async throws {
        let server = try await JellyfinContractServer(label: "search-term") { _ in
            JellyfinCannedResponse.json(#"{"Items":[],"TotalRecordCount":0}"#)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        _ = try await client.searchItems(term: "The Expanse", includeItemTypes: ["Series"])

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/Items")
        #expect(request.sortedQueryItems == [
            URLQueryItem(name: "Fields", value: "ProviderIds,Path,DateCreated,MediaSources"),
            URLQueryItem(name: "IncludeItemTypes", value: "Series"),
            URLQueryItem(name: "Limit", value: "20"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SearchTerm", value: "The Expanse")
        ])
        #expect(request.rawQueryValue(named: "SearchTerm") == "The%20Expanse")
    }

    @Test("A body-less refresh POST carries its refresh modes in the query and sends no body")
    func refreshItemPostsAnEmptyBody() async throws {
        let server = try await JellyfinContractServer(label: "refresh-item") { _ in
            JellyfinCannedResponse(status: 204, body: Data(), contentType: "application/json")
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        try await client.refreshItem(id: "lib-1")

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/Items/lib-1/Refresh")
        #expect(request.body == "")
        #expect(request.sortedQueryItems == [
            URLQueryItem(name: "ImageRefreshMode", value: "Default"),
            URLQueryItem(name: "MetadataRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "ReplaceAllImages", value: "false"),
            URLQueryItem(name: "ReplaceAllMetadata", value: "false")
        ])
    }

    @Test("Adding a media path posts the nested path body alongside its refresh query")
    func addMediaPathPostsNestedBodyWithQuery() async throws {
        let server = try await JellyfinContractServer(label: "add-media-path") { _ in
            JellyfinCannedResponse(status: 204, body: Data(), contentType: "application/json")
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        try await client.addMediaPath(libraryName: "Movies", path: "/mnt/media/movies")

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/Library/VirtualFolders/Paths")
        #expect(request.contentType == "application/json")
        #expect(request.sortedQueryItems == [URLQueryItem(name: "refreshLibrary", value: "true")])

        let body = try #require(request.jsonDictionary())
        #expect(body.count == 2)
        #expect(body["Name"] as? String == "Movies")
        let pathInfo = try #require(body["PathInfo"] as? [String: Any])
        #expect(pathInfo.count == 1)
        #expect(pathInfo["Path"] as? String == "/mnt/media/movies")
    }

    @Test("Removing a virtual folder sends a DELETE with the library name percent-encoded in the query")
    func removeVirtualFolderSendsDelete() async throws {
        let server = try await JellyfinContractServer(label: "remove-folder") { _ in
            JellyfinCannedResponse(status: 204, body: Data(), contentType: "application/json")
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        try await client.removeVirtualFolder(name: "4K Movies")

        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/Library/VirtualFolders")
        #expect(request.sortedQueryItems == [
            URLQueryItem(name: "name", value: "4K Movies"),
            URLQueryItem(name: "refreshLibrary", value: "true")
        ])
        #expect(request.rawQueryValue(named: "name") == "4K%20Movies")
    }

    @Test("Paging stops as soon as the server's total record count is satisfied")
    func pagingStopsAtTotalRecordCount() async throws {
        let server = try await JellyfinContractServer(label: "paging") { request -> JellyfinCannedResponse? in
            if request.queryValue("StartIndex") == "0" {
                return JellyfinCannedResponse.json(
                    #"{"Items":[{"Id":"a","Name":"A"},{"Id":"b","Name":"B"}],"TotalRecordCount":3,"StartIndex":0}"#
                )
            }
            return JellyfinCannedResponse.json(
                #"{"Items":[{"Id":"c","Name":"C"}],"TotalRecordCount":3,"StartIndex":2}"#
            )
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        let items = try await client.getAllLibraryItems(includeItemTypes: ["Movie"], pageSize: 2)

        #expect(items.map(\.id) == ["a", "b", "c"])
        #expect(server.requests.count == 2)
        let startIndexes = server.requests.map { $0.queryValue("StartIndex") }
        let limits = server.requests.map { $0.queryValue("Limit") }
        #expect(startIndexes == ["0", "2"])
        #expect(limits == ["2", "2"])
    }

    // MARK: - Response decoding

    @Test("Users decode when optional, null, and unknown fields are mixed across the payload")
    func usersDecodeWithMixedShapes() async throws {
        let payload = """
        [
          {"Id":"u1","Name":"admin","ServerId":"srv","HasPassword":true,"HasConfiguredPassword":true,
           "LastLoginDate":"2026-08-01T10:00:00.0000000Z","LastActivityDate":"2026-08-02T11:00:00.0000000Z",
           "Policy":{"IsAdministrator":true,"IsDisabled":false,"EnabledFolders":[]},"Configuration":{}},
          {"Id":"u2","Name":"kid"},
          {"Id":"u3","Name":"guest","ServerId":null,"HasPassword":false,"Policy":null,
           "UnknownFutureField":{"nested":[1,2,3]}}
        ]
        """
        let server = try await JellyfinContractServer(label: "users-mixed") { _ in
            JellyfinCannedResponse.json(payload)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        let users = try await client.getUsers()

        #expect(users.map(\.id) == ["u1", "u2", "u3"])
        #expect(users[0].isAdministrator)
        #expect(users[0].isDisabled == false)
        #expect(users[0].policy?.enabledFolders == [String]())
        #expect(users[0].configuration != nil)
        #expect(users[1].configuration == nil)
        #expect(users[1].policy == nil)
        #expect(users[1].hasPassword == nil)
        #expect(users[1].isAdministrator == false)
        #expect(users[2].serverId == nil)
        #expect(users[2].hasPassword == false)
        #expect(users[2].policy == nil)

        #expect(server.requests.count == 1)
        #expect(server.requests.first?.path == "/Users")
    }

    @Test("Library items decode when provider ids, media sources, and episode numbers are absent or partial")
    func libraryItemsDecodeWithMixedShapes() async throws {
        let payload = """
        {"Items":[
          {"Id":"i1","Name":"Blade Runner 2049","Type":"Movie","ProductionYear":2017,
           "RunTimeTicks":98520000000,"ProviderIds":{"Tmdb":"335984","Imdb":"tt1856101"},
           "MediaSources":[{"Id":"m1","Size":12345678,"Container":"mkv"}]},
          {"Id":"i2","Name":"No Providers","Type":"Movie"},
          {"Id":"i3","Name":"Empty Sources","Type":"Movie","ProductionYear":null,"ProviderIds":{},"MediaSources":[]},
          {"Id":"i4","Name":"S01E02","Type":"Episode","IndexNumber":2,"ParentIndexNumber":1,
           "SeriesId":"s1","SeasonId":"se1","MediaSources":[{"Id":"m4","Path":"/media/x.mkv"}]}
        ]}
        """
        let server = try await JellyfinContractServer(label: "items-mixed") { _ in
            JellyfinCannedResponse.json(payload)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        let response = try await client.getLibraryItems(includeItemTypes: ["Movie", "Episode"])

        // TotalRecordCount is genuinely absent from some Jellyfin responses.
        #expect(response.totalRecordCount == nil)
        #expect(response.startIndex == nil)
        #expect(response.items.map(\.id) == ["i1", "i2", "i3", "i4"])

        // Provider-id lookup is case-insensitive by design; Jellyfin's casing varies.
        #expect(response.items[0].providerID(for: ["TMDb"]) == "335984")
        #expect(response.items[0].providerID(for: ["IMDB"]) == "tt1856101")
        #expect(response.items[0].fileSize == 12345678)
        #expect(response.items[0].runtimeMinutes == 164)

        #expect(response.items[1].providerIds == nil)
        #expect(response.items[1].providerID(for: ["Tmdb"]) == nil)
        #expect(response.items[1].fileSize == nil)
        #expect(response.items[1].runtimeMinutes == nil)

        #expect(response.items[2].productionYear == nil)
        #expect(response.items[2].providerIds == [String: String]())
        #expect(response.items[2].providerID(for: ["Tmdb"]) == nil)
        #expect(response.items[2].fileSize == nil)
        #expect(response.items[2].providerIDSummary == "No provider IDs")

        #expect(response.items[3].indexNumber == 2)
        #expect(response.items[3].parentIndexNumber == 1)
        #expect(response.items[3].seriesId == "s1")
        #expect(response.items[3].seasonId == "se1")
        // MediaSources present but sizeless — must not fabricate a size.
        #expect(response.items[3].fileSize == nil)
    }

    // MARK: - Status mapping

    @Test("401 and 403 both map to unauthorized", arguments: [401, 403])
    func unauthorizedStatusesMapToUnauthorized(status: Int) async throws {
        let server = try await JellyfinContractServer(label: "unauthorized-\(status)") { _ in
            JellyfinCannedResponse.json(#"{"Message":"Access token is invalid or expired."}"#, status: status)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "stale-token")

        do {
            _ = try await client.getUsers()
            Issue.record("Expected getUsers() to reject HTTP \(status).")
        } catch let error as JellyfinAPIError {
            guard case .unauthorized = error else {
                Issue.record("Expected .unauthorized for HTTP \(status), received \(error).")
                return
            }
        }

        #expect(server.requests.count == 1)
        #expect(server.requests.first?.path == "/Users")
    }

    @Test("Documented failure statuses surface as HTTP errors carrying the server body", arguments: [404, 429, 503])
    func failureStatusesSurfaceStatusAndBody(status: Int) async throws {
        let payload = #"{"Message":"upstream refused"}"#
        let server = try await JellyfinContractServer(label: "failure-\(status)") { _ in
            JellyfinCannedResponse.json(payload, status: status)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        do {
            _ = try await client.getSessions()
            Issue.record("Expected getSessions() to reject HTTP \(status).")
        } catch let error as JellyfinAPIError {
            guard case .http(let receivedStatus, let receivedBody) = error else {
                Issue.record("Expected .http for HTTP \(status), received \(error).")
                return
            }
            #expect(receivedStatus == status)
            #expect(receivedBody == payload)
        }

        #expect(server.requests.count == 1)
        #expect(server.requests.first?.path == "/Sessions")
    }

    @Test("A Jellyfin error payload's message reaches the presented error description")
    func errorPayloadMessageReachesDescription() async throws {
        let server = try await JellyfinContractServer(label: "error-message") { _ in
            JellyfinCannedResponse.json(#"{"Message":"User not found."}"#, status: 404)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        do {
            _ = try await client.getUser(id: "missing")
            Issue.record("Expected getUser(id:) to reject HTTP 404.")
        } catch let error as JellyfinAPIError {
            #expect(error.errorDescription == "Jellyfin returned 404: User not found.")
        }

        #expect(server.requests.count == 1)
        #expect(server.requests.first?.path == "/Users/missing")
    }

    // MARK: - Malformed bodies

    @Test("Truncated JSON fails as a decode error instead of an empty result")
    func truncatedJSONFailsAsDecodeError() async throws {
        let server = try await JellyfinContractServer(label: "truncated-json") { _ in
            JellyfinCannedResponse.json(#"{"Items":[{"Id":"a","Name":"A"}"#)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        do {
            let response = try await client.getLibraryItems(includeItemTypes: ["Movie"])
            Issue.record("Expected malformed JSON to throw, decoded \(response.items.count) items instead.")
        } catch let error as JellyfinAPIError {
            guard case .decode = error else {
                Issue.record("Expected .decode for malformed JSON, received \(error).")
                return
            }
        }

        #expect(server.requests.count == 1)
    }

    @Test("An empty 200 body fails as a decode error instead of an empty user list")
    func emptyBodyFailsAsDecodeError() async throws {
        let server = try await JellyfinContractServer(label: "empty-body") { _ in
            JellyfinCannedResponse(status: 200, body: Data(), contentType: "application/json")
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        do {
            let users = try await client.getUsers()
            Issue.record("Expected an empty body to throw, decoded \(users.count) users instead.")
        } catch let error as JellyfinAPIError {
            guard case .decode = error else {
                Issue.record("Expected .decode for an empty body, received \(error).")
                return
            }
        }

        #expect(server.requests.count == 1)
    }

    @Test("An HTML page returned with a 200 status fails as a decode error")
    func htmlBodyWithSuccessStatusFailsAsDecodeError() async throws {
        let page = "<!DOCTYPE html><html><head><title>Jellyfin</title></head><body><div id=\"app\"></div></body></html>"
        let server = try await JellyfinContractServer(label: "html-200") { _ in
            JellyfinCannedResponse.html(page, status: 200)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        do {
            let sessions = try await client.getSessions()
            Issue.record("Expected an HTML body to throw, decoded \(sessions.count) sessions instead.")
        } catch let error as JellyfinAPIError {
            guard case .decode = error else {
                Issue.record("Expected .decode for an HTML body, received \(error).")
                return
            }
        }

        #expect(server.requests.count == 1)
    }

    @Test("An HTML gateway error surfaces its status and the HTML body verbatim")
    func htmlGatewayErrorSurfacesStatusAndBody() async throws {
        let page = "<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center></body></html>"
        let server = try await JellyfinContractServer(label: "html-502") { _ in
            JellyfinCannedResponse.html(page, status: 502)
        }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        do {
            _ = try await client.getScheduledTasks()
            Issue.record("Expected an HTML 502 to throw.")
        } catch let error as JellyfinAPIError {
            guard case .http(let status, let body) = error else {
                Issue.record("Expected .http for an HTML 502, received \(error).")
                return
            }
            #expect(status == 502)
            #expect(body == page)
        }

        #expect(server.requests.count == 1)
        #expect(server.requests.first?.path == "/ScheduledTasks")
    }

    // MARK: - Cancellation

    @Test("A cancelled request throws CancellationError after exactly one request reaches the server")
    func cancellationThrowsCancellationError() async throws {
        // Returning nil parks the connection: the server never answers, so the
        // only thing that can end the request is the cancellation under test.
        let server = try await JellyfinContractServer(label: "cancellation") { _ in nil }
        defer { server.stop() }
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        let task = Task { try await client.getScheduledTasks() }
        await server.waitForReceivedRequests(1)
        task.cancel()

        do {
            let tasks = try await task.value
            Issue.record("Expected the cancelled request to throw, received \(tasks.count) tasks instead.")
        } catch is CancellationError {
            // Expected: HTTPTransport normalises URLError.cancelled to CancellationError.
        } catch {
            Issue.record("Expected CancellationError, received \(error).")
        }

        #expect(server.requests.count == 1)
        #expect(server.requests.first?.path == "/ScheduledTasks")
    }

    // MARK: - Availability resolver fallback

    // This server ignores AnyProviderIdEquals, which is exactly what the user's
    // Jellyfin instance does. The resolver must notice the mismatch locally and
    // retry the lookup as a SearchTerm query.
    @Test("The availability resolver falls back to a SearchTerm lookup when the server ignores AnyProviderIdEquals")
    func availabilityResolverFallsBackToSearchTerm() async throws {
        let ignoredFilterPage = #"{"Items":[{"Id":"unrelated","Name":"Some Unrelated Film","Type":"Movie","ProductionYear":1999,"ProviderIds":{"Tmdb":"11"}}],"TotalRecordCount":1}"#
        let searchPage = #"{"Items":[{"Id":"blade-2049","Name":"Blade Runner 2049","Type":"Movie","ProductionYear":2017,"ProviderIds":{"Tmdb":"335984","Imdb":"tt1856101"}}],"TotalRecordCount":1}"#

        let server = try await JellyfinContractServer(label: "resolver-search") { request -> JellyfinCannedResponse? in
            if request.queryValue("AnyProviderIdEquals") != nil {
                return JellyfinCannedResponse.json(ignoredFilterPage)
            }
            return JellyfinCannedResponse.json(searchPage)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(
            title: "Blade Runner 2049",
            year: 2017,
            tmdbId: 335984,
            imdbId: "tt1856101"
        )
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(2)
        let items = try await settledItems(resolver, key: key)

        #expect(items.map(\.id) == ["blade-2049"])
        #expect(server.requests.count == 2)

        let providerLookup = server.requests[0]
        #expect(providerLookup.method == "GET")
        #expect(providerLookup.path == "/Items")
        #expect(providerLookup.queryValue("AnyProviderIdEquals") == "Tmdb.335984,Imdb.tt1856101")
        #expect(providerLookup.queryValue("IncludeItemTypes") == "Movie")
        #expect(providerLookup.queryValue("SearchTerm") == nil)

        let fallback = server.requests[1]
        #expect(fallback.method == "GET")
        #expect(fallback.path == "/Items")
        #expect(fallback.queryValue("SearchTerm") == "Blade Runner 2049")
        #expect(fallback.queryValue("IncludeItemTypes") == "Movie")
        #expect(fallback.queryValue("Recursive") == "true")
        #expect(fallback.queryValue("Limit") == "20")
        #expect(fallback.queryValue("AnyProviderIdEquals") == nil)
    }

    @Test("The availability resolver dash-normalises the title, then narrows to its most distinctive word")
    func availabilityResolverNarrowsToDistinctiveWord() async throws {
        let ignoredFilterPage = #"{"Items":[{"Id":"unrelated","Name":"Something Else","Type":"Series","ProductionYear":2001,"ProviderIds":{"Tvdb":"999"}}],"TotalRecordCount":1}"#
        let emptyPage = #"{"Items":[],"TotalRecordCount":0}"#
        let matchPage = #"{"Items":[{"Id":"dune-prophecy","Name":"Dune: Prophecy","Type":"Series","ProductionYear":2024,"ProviderIds":{"Tvdb":"434153"}}],"TotalRecordCount":1}"#

        let server = try await JellyfinContractServer(label: "resolver-word") { request -> JellyfinCannedResponse? in
            if request.queryValue("AnyProviderIdEquals") != nil {
                return JellyfinCannedResponse.json(ignoredFilterPage)
            }
            if request.queryValue("SearchTerm") == "Prophecy" {
                return JellyfinCannedResponse.json(matchPage)
            }
            return JellyfinCannedResponse.json(emptyPage)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        // An en-dash in the Sonarr title: Jellyfin's SearchTerm is a literal
        // substring match, so the dash must be normalised before it is sent.
        let media = JellyfinMediaAvailabilityCard.Media.series(
            title: "Dune\u{2013}Prophecy",
            year: 2024,
            tvdbId: 434153,
            tmdbId: nil,
            imdbId: nil,
            totalEpisodes: 6
        )
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(3)
        let items = try await settledItems(resolver, key: key)

        #expect(items.map(\.id) == ["dune-prophecy"])
        #expect(server.requests.count == 3)
        #expect(server.requests.map(\.path) == ["/Items", "/Items", "/Items"])
        let itemTypes = server.requests.map { $0.queryValue("IncludeItemTypes") }
        #expect(itemTypes == ["Series", "Series", "Series"])

        #expect(server.requests[0].queryValue("AnyProviderIdEquals") == "Tvdb.434153")
        #expect(server.requests[1].queryValue("SearchTerm") == "Dune-Prophecy")
        // The en-dash was replaced, not percent-encoded as UTF-8 (%E2%80%93).
        #expect(server.requests[1].rawQueryValue(named: "SearchTerm") == "Dune-Prophecy")
        #expect(server.requests[2].queryValue("SearchTerm") == "Prophecy")
    }

    // MARK: - Helpers

    /// Reads the resolver's settled state. `ensureLoaded` fires a detached Task
    /// with no completion hook, so ordering is owned by the server barrier the
    /// caller already awaited; this only lets the main actor drain the
    /// resolver's final continuation. It yields rather than sleeping and exits
    /// the instant the state stops being `.loading`.
    private func settledItems(
        _ resolver: JellyfinAvailabilityResolver,
        key: JellyfinAvailabilityResolver.Key
    ) async throws -> [JellyfinLibraryItem] {
        for _ in 0..<100_000 {
            switch resolver.state(for: key) {
            case .resolved(let items):
                return items
            case .failed(let message):
                throw JellyfinResolverTestFailure.lookupFailed(message)
            case .idle, .loading:
                await Task.yield()
            }
        }
        throw JellyfinResolverTestFailure.neverSettled
    }
}

// MARK: - Test failures

private nonisolated enum JellyfinResolverTestFailure: Error {
    case lookupFailed(String)
    case neverSettled
}

// MARK: - Authorization header probe

private nonisolated struct JellyfinAuthField: Sendable, Equatable {
    let name: String
    let value: String
}

/// Parses `MediaBrowser Client="…", Device="…", …` back into ordered fields so
/// tests can assert the header's real grammar rather than restate the code that
/// produced it.
private nonisolated enum JellyfinAuthHeaderProbe {
    static func fields(in header: String) -> [JellyfinAuthField] {
        let prefix = "MediaBrowser "
        guard header.hasPrefix(prefix) else { return [] }
        return String(header.dropFirst(prefix.count))
            .components(separatedBy: ", ")
            .compactMap { component -> JellyfinAuthField? in
                guard let equals = component.firstIndex(of: "=") else { return nil }
                let name = String(component[component.startIndex..<equals])
                let quoted = String(component[component.index(after: equals)...])
                guard quoted.count >= 2, quoted.hasPrefix("\""), quoted.hasSuffix("\"") else { return nil }
                return JellyfinAuthField(name: name, value: String(quoted.dropFirst().dropLast()))
            }
    }
}

// MARK: - Recorded request

private nonisolated struct JellyfinRecordedRequest: Sendable, Equatable {
    let method: String
    let path: String
    /// The query exactly as it arrived, still percent-encoded.
    let rawQuery: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: String

    var authorization: String? { headers["authorization"] }
    var contentType: String? { headers["content-type"] }

    var queryItems: [URLQueryItem] {
        guard !rawQuery.isEmpty else { return [] }
        return URLComponents(string: "http://jellyfin.contract.test\(path)?\(rawQuery)")?.queryItems ?? []
    }

    /// `JellyfinAPIClient` builds its query items from a dictionary, so the
    /// wire order is not stable. Sorting by name keeps the assertion exact
    /// without depending on dictionary iteration order.
    var sortedQueryItems: [URLQueryItem] {
        queryItems.sorted { $0.name < $1.name }
    }

    func queryValue(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    /// The still-encoded value for a query key, for asserting percent-encoding.
    func rawQueryValue(named name: String) -> String? {
        for pair in rawQuery.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.first.map(String.init) == name else { continue }
            return parts.count > 1 ? String(parts[1]) : ""
        }
        return nil
    }

    func jsonDictionary() -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return raw as? [String: Any]
    }
}

// MARK: - Canned response

private nonisolated struct JellyfinCannedResponse: Sendable {
    let status: Int
    let body: Data
    let contentType: String

    static func json(_ string: String, status: Int = 200) -> JellyfinCannedResponse {
        JellyfinCannedResponse(status: status, body: Data(string.utf8), contentType: "application/json")
    }

    static func html(_ string: String, status: Int) -> JellyfinCannedResponse {
        JellyfinCannedResponse(status: status, body: Data(string.utf8), contentType: "text/html; charset=utf-8")
    }
}

// MARK: - Loopback server

/// A loopback HTTP/1.1 server that records the raw request and replies with a
/// caller-supplied response. Returning `nil` from the handler parks the
/// connection without answering, which is how the cancellation test keeps a
/// request in flight.
private final class JellyfinContractServer: @unchecked Sendable {
    typealias Handler = @Sendable (JellyfinRecordedRequest) -> JellyfinCannedResponse?

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler

    private let lock = NSLock()
    private var recorded: [JellyfinRecordedRequest] = []
    private var servedCount = 0
    private var parkedConnections: [NWConnection] = []
    private var receivedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var servedWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(label: String, handler: @escaping Handler) async throws {
        self.queue = DispatchQueue(label: "JellyfinContractServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
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
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else {
            fatalError("Jellyfin contract server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [JellyfinRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stop() {
        lock.lock()
        let parked = parkedConnections
        parkedConnections = []
        let pendingReceived = receivedWaiters
        let pendingServed = servedWaiters
        receivedWaiters = []
        servedWaiters = []
        lock.unlock()

        for connection in parked { connection.cancel() }
        for waiter in pendingReceived { waiter.continuation.resume() }
        for waiter in pendingServed { waiter.continuation.resume() }
        listener.cancel()
    }

    /// Resumes once `count` requests have arrived, whether or not they were answered.
    func waitForReceivedRequests(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if recorded.count >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            receivedWaiters.append((threshold: count, continuation: continuation))
            lock.unlock()
        }
    }

    /// Resumes once `count` responses have been written back to their clients.
    func waitForServedResponses(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if servedCount >= count {
                lock.unlock()
                continuation.resume()
                return
            }
            servedWaiters.append((threshold: count, continuation: continuation))
            lock.unlock()
        }
    }

    // MARK: - Connection handling

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let request = Self.parse(accumulated) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
                return
            }

            self.recordReceived(request)

            guard let response = self.handler(request) else {
                self.lock.lock()
                self.parkedConnections.append(connection)
                self.lock.unlock()
                return
            }

            connection.send(
                content: Self.encode(response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    self?.recordServed()
                    connection.cancel()
                }
            )
        }
    }

    private func recordReceived(_ request: JellyfinRecordedRequest) {
        lock.lock()
        recorded.append(request)
        let count = recorded.count
        let ready = receivedWaiters.filter { $0.threshold <= count }
        receivedWaiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    private func recordServed() {
        lock.lock()
        servedCount += 1
        let count = servedCount
        let ready = servedWaiters.filter { $0.threshold <= count }
        servedWaiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    // MARK: - HTTP framing

    /// Returns nil until the buffer holds a complete request head plus its
    /// declared `Content-Length` body.
    private static func parse(_ buffer: Data) -> JellyfinRecordedRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyBytes = Data(buffer[separator.upperBound...])
        guard bodyBytes.count >= contentLength else { return nil }
        let body = String(data: bodyBytes.prefix(contentLength), encoding: .utf8) ?? ""

        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return JellyfinRecordedRequest(
            method: String(parts[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count > 1 ? String(targetParts[1]) : "",
            headers: headers,
            body: body
        )
    }

    private static func encode(_ response: JellyfinCannedResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
