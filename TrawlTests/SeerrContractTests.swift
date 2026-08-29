import Foundation
import Testing
@testable import Trawl

/// Network contract tests for `SeerrAPIClient`.
///
/// These run the production request builder, the cookie auth layer, the JSON
/// serializer, the status validator, the decoder, and the `SeerrAPIError`
/// mapper. The only thing faked is the remote Seerr server, which is stubbed
/// with a recording `URLProtocol` injected through `sessionConfiguration`.
///
/// The suite is serialized because the stub protocol holds process-wide state.
@Suite("Seerr API client HTTP contracts", .serialized)
@MainActor
struct SeerrContractTests {

    // MARK: - Request shape, auth, and query encoding

    @Test("Request list and request count send the documented method, path, query, and session cookie")
    func requestListSendsDocumentedRequest() async throws {
        SeerrContractURLProtocol.stub(sequence: [
            .init(body: Data(SeerrFixture.requestList.utf8)),
            .init(body: Data(SeerrFixture.requestCount.utf8))
        ])
        let client = makeClient()

        let list = try await client.getRequests(
            take: 40,
            skip: 20,
            filter: SeerrRequestFilter.pending.apiValue,
            sort: "added",
            sortDirection: "desc",
            mediaType: "all"
        )
        let count = try await client.getRequestCount()

        #expect(list.results.count == 3)
        #expect(count.pending == 4)
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/request",
                queryPairs: [
                    "filter=pending",
                    "mediaType=all",
                    "skip=20",
                    "sort=added",
                    "sortDirection=desc",
                    "take=40"
                ],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            ),
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/request/count",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])
    }

    @Test("A client with no usable session cookie omits the Cookie header entirely", arguments: [nil, ""] as [String?])
    func missingSessionCookieOmitsHeader(cookie: String?) async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.publicSettings.utf8))
        let client = makeClient(sessionCookie: cookie)

        let settings = try await client.getPublicSettings()

        #expect(settings.isJellyfin)
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/settings/public",
                queryPairs: [],
                cookie: nil,
                contentType: nil,
                body: nil
            )
        ])
    }

    @Test("A base URL with a trailing slash still produces single-slash endpoint paths")
    func trailingSlashBaseURLDoesNotDoubleUp() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.publicSettings.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeerrContractURLProtocol.self]
        let client = SeerrAPIClient(
            baseURL: "https://seerr.contract.test/",
            sessionCookie: "session-token-1",
            sessionConfiguration: configuration
        )

        _ = try await client.getPublicSettings()

        #expect(SeerrContractURLProtocol.recordedRequests.map(\.path) == ["/api/v1/settings/public"])
    }

    @Test("Issue list sends take, skip, sort, and every documented filter value")
    func issueListSendsDocumentedQuery() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.issueList.utf8))
        let client = makeClient()

        // These are the only two filter values the app can ask for.
        #expect(SeerrIssueFilter.allCases.map({ $0.apiValue }) == ["open", "resolved"])

        for filter in SeerrIssueFilter.allCases {
            let response = try await client.getIssues(take: 20, skip: 0, sort: "added", filter: filter.apiValue)
            #expect(response.results.map({ $0.id }) == [31, 32])
            #expect(response.results.first?.issueKind?.title == "Audio")
            #expect(response.results.first?.issueStatus?.title == "Open")
            #expect(response.results.first?.commentCount == 1)
            #expect(response.results.last?.issueStatus?.title == "Resolved")
            #expect(response.results.last?.commentCount == 0)
        }

        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/issue",
                queryPairs: ["filter=open", "skip=0", "sort=added", "take=20"],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            ),
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/issue",
                queryPairs: ["filter=resolved", "skip=0", "sort=added", "take=20"],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])
    }

    @Test("Trending discovery uses the single combined endpoint and decodes camelCase TMDb fields")
    func discoverTrendingUsesCombinedEndpoint() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.trending.utf8))
        let client = makeClient()

        let items = try await client.discoverTrending()

        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/discover/trending",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])
        #expect(items.map(\.id) == [603, 1396, 42])

        let movie = try #require(items.first)
        #expect(movie.mediaType == "movie")
        #expect(movie.title == "The Matrix")
        #expect(movie.posterPath == "/matrix.jpg")
        #expect(movie.backdropPath == "/matrix-wide.jpg")
        #expect(movie.voteAverage == 8.2)
        #expect(movie.releaseDate == "1999-03-30")
        #expect(movie.genreIds == [28, 878])

        let series = items[1]
        #expect(series.mediaType == "tv")
        #expect(series.name == "Breaking Bad")
        #expect(series.firstAirDate == "2008-01-20")
        #expect(series.title == nil)

        // Seerr re-serialises TMDb in camelCase. A snake_case payload must decode
        // to nil rather than silently populating the fields: if a future change
        // adds `.convertFromSnakeCase` to the shared decoder, the camelCase
        // assertions above break and this one starts passing for the wrong reason.
        let snakeCase = items[2]
        #expect(snakeCase.posterPath == nil)
        #expect(snakeCase.voteAverage == nil)
        #expect(snakeCase.releaseDate == nil)
        #expect(snakeCase.mediaType == nil)
    }

    @Test("Media lookups route tv to /tv and everything else to /movie, and decode camelCase detail")
    func mediaLookupsRouteByMediaType() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.movieDetail.utf8))
        let client = makeClient()

        let summary = try await client.getMediaSummary(tmdbId: 77, mediaType: "tv")
        _ = try await client.getMediaSummary(tmdbId: 77, mediaType: "movie")
        _ = try await client.getMediaSummary(tmdbId: 77, mediaType: "documentary")
        let detail = try await client.getMediaDetail(tmdbId: 77, mediaType: "movie")

        #expect(SeerrContractURLProtocol.recordedRequests.map(\.path) == [
            "/api/v1/tv/77",
            "/api/v1/movie/77",
            "/api/v1/movie/77",
            "/api/v1/movie/77"
        ])
        #expect(SeerrContractURLProtocol.recordedRequests.map(\.method) == ["GET", "GET", "GET", "GET"])
        #expect(SeerrContractURLProtocol.recordedRequests.allSatisfy({ $0.queryPairs.isEmpty }))

        #expect(summary.displayTitle == "Arrival")
        #expect(summary.yearText == "2016")
        #expect(summary.posterURL == URL(string: "https://image.tmdb.org/t/p/w500/arrival.jpg"))

        #expect(detail.genreNames == ["Drama", "Science Fiction"])
        #expect(detail.runtimeText == "1h 56m")
        #expect(detail.ratingText == "7.6")
        #expect(detail.credits?.cast?.map(\.name) == ["Amy Adams", "Jeremy Renner"])
        #expect(detail.credits?.cast?.first?.profileURL == URL(string: "https://image.tmdb.org/t/p/w185/amy.jpg"))
        #expect(detail.credits?.cast?.last?.profileURL == nil)
    }

    @Test("Log requests drop a blank search term and keep the level filter")
    func logRequestsDropBlankSearchTerm() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.logs.utf8))
        let client = makeClient()

        _ = try await client.getLogs(take: 100, skip: 0, filter: SeerrLogLevelFilter.debug.apiValue, search: "   ")

        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/settings/logs",
                queryPairs: ["filter=debug", "skip=0", "take=100"],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])
    }

    @Test("Log requests percent-encode the search term and decode mixed data payloads")
    func logRequestsEncodeSearchTermAndDecodeMixedData() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.logs.utf8))
        let client = makeClient()

        let entries = try await client.getLogs(
            take: 50,
            skip: 25,
            filter: SeerrLogLevelFilter.warn.apiValue,
            search: "disk space"
        )

        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/settings/logs",
                queryPairs: ["filter=warn", "search=disk%20space", "skip=25", "take=50"],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])

        #expect(entries.map(\.message) == ["Object data", "String data", "No data at all"])
        #expect(entries[0].level == "warn")

        // `data` is free-form: an object on one entry, a bare string on the next,
        // and absent on the third. None of those may fail the whole page.
        guard case .object(let payload) = try #require(entries[0].data) else {
            Issue.record("Expected the first log entry's data to decode as an object")
            return
        }
        #expect(payload.count == 2)
        guard case .string(let job) = try #require(payload["job"]) else {
            Issue.record("Expected data.job to decode as a string")
            return
        }
        #expect(job == "radarr-scan")
        guard case .integer(let attempts) = try #require(payload["attempts"]) else {
            Issue.record("Expected data.attempts to decode as an integer")
            return
        }
        #expect(attempts == 3)

        guard case .string(let plainText) = try #require(entries[1].data) else {
            Issue.record("Expected the second log entry's data to decode as a string")
            return
        }
        #expect(plainText == "plain text")

        #expect(entries[2].data == nil)
        #expect(entries[2].prettyPrintedData == nil)
    }

    @Test("Linked application endpoints build the settings, test, and service paths for each kind", arguments: SeerrDVRKind.allCases)
    func linkedApplicationEndpointPaths(kind: SeerrDVRKind) async throws {
        SeerrContractURLProtocol.stub(sequence: [
            .init(body: Data(SeerrFixture.dvrSettingsList.utf8)),
            .init(body: Data(SeerrFixture.dvrPickerData.utf8)),
            .init(body: Data(SeerrFixture.dvrPickerData.utf8))
        ])
        let client = makeClient()

        let settings = try await client.getDVRSettings(kind)
        let testResponse = try await client.testDVRConnection(
            kind,
            body: SeerrDVRTestBody(
                hostname: "dvr.local",
                port: 8989,
                apiKey: "dvr-key",
                useSsl: false,
                baseUrl: "dvr-base"
            )
        )
        let service = try await client.getDVRService(kind, id: 3)

        #expect(settings.map(\.name) == ["Primary"])
        #expect(settings.first?.displayURL == "http://dvr.local:7878")
        #expect(testResponse.profiles?.map(\.displayName) == ["HD-1080p", "Profile 9"])
        #expect(service.rootFolders?.map(\.displayPath) == ["/data/media"])
        #expect(service.tags?.count == 1)

        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/settings/\(kind.rawValue)",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            ),
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/settings/\(kind.rawValue)/test",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data(#"{"hostname":"dvr.local","port":8989,"apiKey":"dvr-key","useSsl":false,"baseUrl":"dvr-base"}"#.utf8)
            ),
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/service/\(kind.rawValue)/3",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])
    }

    // MARK: - Mixed and missing response fields

    @Test("Request list decodes missing, null, and mixed-shape fields without failing")
    func requestListDecodesMixedShapes() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.requestList.utf8))
        let client = makeClient()

        let response = try await client.getRequests()

        #expect(response.pageInfo.pages == 3)
        #expect(response.pageInfo.results == 41)
        #expect(response.results.map(\.id) == [12, 13, 14])

        let approvedMovie = try #require(response.results.first)
        #expect(approvedMovie.requestStatus?.title == "Approved")
        #expect(approvedMovie.media?.displayTitle == "The Matrix")
        #expect(approvedMovie.media?.typeLabel == "Movie")
        #expect(approvedMovie.media?.posterURL == URL(string: "https://image.tmdb.org/t/p/w500/matrix.jpg"))
        // status 2 (approved) plus media status 5 (available) resolves to Available.
        #expect(approvedMovie.badgeStatus?.title == "Available")
        #expect(approvedMovie.requestedBy?.displayName == "Ada")

        // Only `name` is present, no poster, and the media status is processing.
        let series = response.results[1]
        #expect(series.media?.displayTitle == "Breaking Bad")
        #expect(series.media?.typeLabel == "Series")
        #expect(series.media?.posterURL == nil)
        #expect(series.requestStatus?.title == "Pending")
        #expect(series.badgeStatus?.title == "Pending")
        #expect(series.is4k == nil)

        // Null media, null requester, absent status.
        let bare = response.results[2]
        #expect(bare.media == nil)
        #expect(bare.requestedBy == nil)
        #expect(bare.requestStatus == nil)
        #expect(bare.badgeStatus == nil)
        #expect(bare.createdAtRelativeText == nil)
    }

    @Test("An issue payload with no comments array yields no comments rather than a decode failure")
    func issueWithoutCommentsArrayYieldsEmptyComments() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.issueWithoutComments.utf8))
        let client = makeClient()

        let comments = try await client.getIssueComments(issueId: 5)

        #expect(comments.isEmpty)
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/issue/5",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])
    }

    // MARK: - Mutation bodies

    @Test("Approve, decline, resolve, and reopen post an empty JSON object to the documented path", arguments: SeerrEmptyBodyMutation.allCases)
    fileprivate func emptyBodyMutationsPostAnEmptyObject(mutation: SeerrEmptyBodyMutation) async throws {
        SeerrContractURLProtocol.stub(body: Data(#"{"id":9}"#.utf8))
        let client = makeClient()

        let identifier: Int
        switch mutation {
        case .approveRequest: identifier = try await client.approveRequest(id: 9).id
        case .declineRequest: identifier = try await client.declineRequest(id: 9).id
        case .resolveIssue: identifier = try await client.resolveIssue(issueId: 9).id
        case .reopenIssue: identifier = try await client.reopenIssue(issueId: 9).id
        }

        #expect(identifier == 9)
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "POST",
                path: mutation.path,
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data("{}".utf8)
            )
        ])
    }

    @Test("Replying to an issue serializes exactly the comment message")
    func replyToIssueSerializesTheMessage() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.issueWithComment.utf8))
        let client = makeClient()

        let issue = try await client.replyToIssue(issueId: 31, message: "Audio desyncs after 12 minutes")

        #expect(issue.comments?.map({ $0.message }) == ["Audio desyncs after 12 minutes"])
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/issue/31/comment",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data(#"{"message":"Audio desyncs after 12 minutes"}"#.utf8)
            )
        ])
    }

    @Test("User list and permission update send the documented query and PUT body")
    func userListAndUpdateSendDocumentedRequests() async throws {
        SeerrContractURLProtocol.stub(sequence: [
            .init(body: Data(SeerrFixture.userList.utf8)),
            .init(body: Data(SeerrFixture.singleUser.utf8))
        ])
        let client = makeClient()

        let list = try await client.getUsers(take: 40, skip: 20)
        let updated = try await client.updateUser(id: 7, permissions: 32)

        #expect(list.results.map({ $0.displayName }) == ["Ada", "Grace Hopper", "User"])
        #expect(updated.permissions == 32)
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/user",
                queryPairs: ["skip=20", "take=40"],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            ),
            SeerrRecordedRequest(
                method: "PUT",
                path: "/api/v1/user/7",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data(#"{"permissions":32}"#.utf8)
            )
        ])
    }

    @Test("Importing Jellyfin users serializes the selected identifiers exactly")
    func importJellyfinUsersSerializesIdentifiers() async throws {
        SeerrContractURLProtocol.stub(body: Data(SeerrFixture.importedUsers.utf8))
        let client = makeClient()

        let imported = try await client.importUsersFromJellyfin(jellyfinUserIds: ["abc", "def"])

        // The second user has only an email, so the display name falls back to it.
        #expect(imported.map({ $0.displayName }) == ["Ada", "Grace Hopper"])
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/user/import-from-jellyfin",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data(#"{"jellyfinUserIds":["abc","def"]}"#.utf8)
            )
        ])
    }

    @Test("Deleting a request and a user issues DELETE with no body and accepts an empty 204")
    func deleteEndpointsSendNoBody() async throws {
        SeerrContractURLProtocol.stub(statusCode: 204, body: Data(), headerFields: [:])
        let client = makeClient()

        try await client.deleteRequest(id: 4)
        try await client.deleteUser(id: 7)

        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "DELETE",
                path: "/api/v1/request/4",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            ),
            SeerrRecordedRequest(
                method: "DELETE",
                path: "/api/v1/user/7",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: nil,
                body: nil
            )
        ])
    }

    @Test("Job run and cancel post an empty JSON object and accept an empty 204 body")
    func jobEndpointsPostEmptyObject() async throws {
        SeerrContractURLProtocol.stub(statusCode: 204, body: Data(), headerFields: [:])
        let client = makeClient()

        try await client.runJob(id: "radarr-scan")
        try await client.cancelJob(id: "radarr-scan")

        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/settings/jobs/radarr-scan/run",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data("{}".utf8)
            ),
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/settings/jobs/radarr-scan/cancel",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data("{}".utf8)
            )
        ])
    }

    @Test("Webhook notification settings serialize enabled, types, and only the populated options")
    func webhookNotificationSettingsSerializeExactly() async throws {
        SeerrContractURLProtocol.stub(statusCode: 204, body: Data(), headerFields: [:])
        let client = makeClient()
        let settings = SeerrWebhookNotificationSettings(
            enabled: true,
            types: 132,
            options: SeerrWebhookNotificationOptions(
                webhookUrl: "https://hooks.example.test/trawl",
                authHeader: nil,
                jsonPayload: nil,
                supportVariables: true,
                customHeaders: nil
            )
        )

        try await client.updateWebhookNotificationSettings(settings)
        try await client.testWebhookNotificationSettings(settings)

        // JSONEncoder escapes forward slashes and omits nil optionals.
        let expectedBody = Data(
            #"{"enabled":true,"types":132,"options":{"webhookUrl":"https:\/\/hooks.example.test\/trawl","supportVariables":true}}"#.utf8
        )
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/settings/notifications/webhook",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: expectedBody
            ),
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/settings/notifications/webhook/test",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: expectedBody
            )
        ])
    }

    // MARK: - Status code mapping

    @Test("401 and 403 both map to an expired session", arguments: [401, 403])
    func unauthorizedStatusesMapToExpiredSession(statusCode: Int) async throws {
        SeerrContractURLProtocol.stub(
            statusCode: statusCode,
            body: Data(#"{"message":"You do not have permission"}"#.utf8)
        )
        let client = makeClient()

        do {
            _ = try await client.getRequests()
            Issue.record("Expected getRequests() to reject HTTP \(statusCode)")
            return
        } catch let error as SeerrAPIError {
            guard case .unauthorized = error else {
                Issue.record("Expected .unauthorized for HTTP \(statusCode), received \(error)")
                return
            }
        }
        #expect(SeerrContractURLProtocol.recordedRequests.count == 1)
    }

    @Test("Documented failure statuses surface the status and the raw body", arguments: [404, 429, 503])
    func failureStatusesSurfaceStatusAndBody(statusCode: Int) async throws {
        let responseBody = #"{"message":"upstream said no"}"#
        SeerrContractURLProtocol.stub(statusCode: statusCode, body: Data(responseBody.utf8))
        let client = makeClient()

        do {
            _ = try await client.getRequests()
            Issue.record("Expected getRequests() to reject HTTP \(statusCode)")
            return
        } catch let error as SeerrAPIError {
            guard case .http(let status, let body) = error else {
                Issue.record("Expected .http for HTTP \(statusCode), received \(error)")
                return
            }
            #expect(status == statusCode)
            #expect(body == responseBody)
        }
        #expect(SeerrContractURLProtocol.recordedRequests.count == 1)
    }

    @Test("A 409 conflict on approve carries the server's own message into the error description")
    func conflictOnApproveCarriesServerMessage() async throws {
        SeerrContractURLProtocol.stub(
            statusCode: 409,
            body: Data(#"{"message":"Request already approved"}"#.utf8)
        )
        let client = makeClient()

        do {
            _ = try await client.approveRequest(id: 9)
            Issue.record("Expected approveRequest(id:) to reject HTTP 409")
            return
        } catch let error as SeerrAPIError {
            guard case .http(let status, let body) = error else {
                Issue.record("Expected .http for HTTP 409, received \(error)")
                return
            }
            #expect(status == 409)
            #expect(body == #"{"message":"Request already approved"}"#)
            #expect(error.errorDescription == "Seerr returned 409: Request already approved")
        }
        #expect(SeerrContractURLProtocol.recordedRequests.map(\.path) == ["/api/v1/request/9/approve"])
    }

    // MARK: - Body shapes that must never decode as an empty success

    @Test("Malformed, empty, and HTML 200 bodies fail instead of yielding an empty result", arguments: SeerrUndecodableBody.allCases)
    fileprivate func undecodableSuccessBodiesFail(fixture: SeerrUndecodableBody) async throws {
        SeerrContractURLProtocol.stub(statusCode: 200, body: Data(fixture.body.utf8), headerFields: fixture.headerFields)
        let client = makeClient()

        do {
            _ = try await client.discoverTrending()
            Issue.record("Expected discoverTrending() to reject a \(fixture.rawValue) body")
            return
        } catch let error as SeerrAPIError {
            guard case .decode = error else {
                Issue.record("Expected .decode for \(fixture.rawValue), received \(error)")
                return
            }
        }
        #expect(SeerrContractURLProtocol.recordedRequests.count == 1)
    }

    @Test("An HTML error page on a failing status is reported as an HTTP error, not a decode error")
    func htmlErrorPageOnFailureStatusIsHTTPError() async throws {
        let page = "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>"
        SeerrContractURLProtocol.stub(
            statusCode: 502,
            body: Data(page.utf8),
            headerFields: ["Content-Type": "text/html"]
        )
        let client = makeClient()

        do {
            _ = try await client.discoverTrending()
            Issue.record("Expected discoverTrending() to reject an HTML 502")
            return
        } catch let error as SeerrAPIError {
            guard case .http(let status, let body) = error else {
                Issue.record("Expected .http for an HTML 502, received \(error)")
                return
            }
            #expect(status == 502)
            #expect(body == page)
            #expect(error.errorDescription == "Seerr returned status 502.")
        }
    }

    // MARK: - Session cookie lifecycle

    @Test("Jellyfin login posts the credentials, captures the issued cookie, and reuses it")
    func jellyfinLoginCapturesAndReusesTheIssuedCookie() async throws {
        SeerrContractURLProtocol.stub(sequence: [
            .init(
                body: Data(SeerrFixture.singleUser.utf8),
                headerFields: [
                    "Content-Type": "application/json",
                    "Set-Cookie": "connect.sid=s%3Arolled.session; Path=/; HttpOnly; SameSite=Lax"
                ]
            ),
            .init(body: Data(SeerrFixture.singleUser.utf8))
        ])
        let client = makeClient(sessionCookie: nil)

        let user = try await client.loginJellyfin(username: "ada", password: "hunter2")
        let stored = await client.getSessionCookie()
        _ = try await client.getCurrentUser()

        #expect(user.id == 7)
        #expect(stored == "s%3Arolled.session")

        let recorded = SeerrContractURLProtocol.recordedRequests
        #expect(recorded.count == 2)

        let login = try #require(recorded.first)
        #expect(login.method == "POST")
        #expect(login.path == "/api/v1/auth/jellyfin")
        #expect(login.queryPairs == [])
        #expect(login.contentType == "application/json")
        #expect(login.cookie == nil)
        // JSONSerialization does not promise dictionary key order, so the body is
        // compared as decoded key/value pairs rather than as raw bytes.
        let loginBody = try #require(login.body)
        let loginFields = try JSONSerialization.jsonObject(with: loginBody) as? [String: String]
        #expect(loginFields == ["username": "ada", "password": "hunter2"])

        let me = recorded[1]
        #expect(me.method == "GET")
        #expect(me.path == "/api/v1/auth/me")
        #expect(me.cookie == "connect.sid=s%3Arolled.session")
    }

    @Test("Jellyfin login maps its own status codes without going through the shared validator", arguments: [401, 403, 500])
    func jellyfinLoginMapsItsOwnStatusCodes(statusCode: Int) async throws {
        SeerrContractURLProtocol.stub(
            statusCode: statusCode,
            body: Data(#"{"message":"Unable to sign in"}"#.utf8)
        )
        let client = makeClient(sessionCookie: nil)

        do {
            _ = try await client.loginJellyfin(username: "ada", password: "wrong")
            Issue.record("Expected loginJellyfin(username:password:) to reject HTTP \(statusCode)")
            return
        } catch let error as SeerrAPIError {
            switch statusCode {
            case 401, 403:
                guard case .unauthorized = error else {
                    Issue.record("Expected .unauthorized for HTTP \(statusCode), received \(error)")
                    return
                }
            default:
                guard case .http(let status, let body) = error else {
                    Issue.record("Expected .http for HTTP \(statusCode), received \(error)")
                    return
                }
                #expect(status == 500)
                #expect(body == #"{"message":"Unable to sign in"}"#)
            }
        }
        #expect(SeerrContractURLProtocol.recordedRequests.map(\.path) == ["/api/v1/auth/jellyfin"])
    }

    @Test("A rolling connect.sid in a multi-cookie response replaces the stored cookie exactly once")
    func rollingCookieInMultiCookieResponseIsAdopted() async throws {
        SeerrContractURLProtocol.stub(
            body: Data(SeerrFixture.singleUser.utf8),
            headerFields: [
                "Content-Type": "application/json",
                // Foundation joins multiple Set-Cookie headers with a comma.
                "Set-Cookie": "locale=en-GB; Path=/, connect.sid=s%3Arolled.two; Path=/; HttpOnly"
            ]
        )
        let client = makeClient()
        let cookieUpdates = SeerrEventLog()
        await client.setCookieUpdateHandler { value in cookieUpdates.record(value) }

        _ = try await client.getCurrentUser()
        // The observer hands the cookie off to a task; wait on the handler rather
        // than on the clock.
        await cookieUpdates.wait(untilCount: 1)
        _ = try await client.getCurrentUser()
        let stored = await client.getSessionCookie()

        #expect(cookieUpdates.recorded == ["s%3Arolled.two"])
        #expect(stored == "s%3Arolled.two")
        #expect(SeerrContractURLProtocol.recordedRequests.map(\.cookie) == [
            "connect.sid=session-token-1",
            "connect.sid=s%3Arolled.two"
        ])
    }

    @Test("Logout posts an empty object and clears the cookie even when the server rejects it")
    func logoutClearsTheCookieEvenOnFailure() async throws {
        SeerrContractURLProtocol.stub(sequence: [
            .init(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8)),
            .init(body: Data(SeerrFixture.publicSettings.utf8))
        ])
        let client = makeClient()

        try await client.logout()
        let stored = await client.getSessionCookie()
        _ = try await client.getPublicSettings()

        #expect(stored == nil)
        #expect(SeerrContractURLProtocol.recordedRequests == [
            SeerrRecordedRequest(
                method: "POST",
                path: "/api/v1/auth/logout",
                queryPairs: [],
                cookie: "connect.sid=session-token-1",
                contentType: "application/json",
                body: Data("{}".utf8)
            ),
            SeerrRecordedRequest(
                method: "GET",
                path: "/api/v1/settings/public",
                queryPairs: [],
                cookie: nil,
                contentType: nil,
                body: nil
            )
        ])
    }

    // MARK: - Cancellation

    @Test("Cancelling an in-flight request surfaces CancellationError, not a transport error")
    func cancellingInFlightRequestThrowsCancellationError() async throws {
        SeerrContractURLProtocol.stub(hangs: true)
        let client = makeClient()

        let task = Task { try await client.getCurrentUser() }
        // The stub never answers; wait until it has recorded the request so the
        // cancellation lands on a genuinely in-flight task.
        await SeerrContractURLProtocol.requestLog.wait(untilCount: 1)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled request to throw")
        } catch is CancellationError {
            // Expected: the transport translates URLError.cancelled into CancellationError.
        } catch {
            Issue.record("Expected CancellationError, received \(error)")
        }
        #expect(SeerrContractURLProtocol.recordedRequests.map(\.path) == ["/api/v1/auth/me"])
    }

    // MARK: - Helpers

    private func makeClient(sessionCookie: String? = "session-token-1") -> SeerrAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeerrContractURLProtocol.self]
        return SeerrAPIClient(
            baseURL: "https://seerr.contract.test",
            sessionCookie: sessionCookie,
            sessionConfiguration: configuration
        )
    }
}

// MARK: - Test-only value types

private nonisolated struct SeerrRecordedRequest: Sendable, Equatable {
    let method: String
    let path: String
    let queryPairs: [String]
    let cookie: String?
    let contentType: String?
    let body: Data?

    /// Everything but the body compares exactly. JSON bodies compare
    /// *semantically*, because `JSONEncoder` gives no ordering guarantee for a
    /// synthesized `CodingKeys` - asserting raw bytes would make these tests
    /// fail on an encoder implementation detail rather than on a contract
    /// change. This is still the strong assertion: the key set must match
    /// exactly, so an optional that should have been omitted still fails, and a
    /// non-JSON body falls back to byte equality.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.method == rhs.method,
              lhs.path == rhs.path,
              lhs.queryPairs == rhs.queryPairs,
              lhs.cookie == rhs.cookie,
              lhs.contentType == rhs.contentType else { return false }
        return bodiesMatch(lhs.body, rhs.body)
    }

    private static func bodiesMatch(_ lhs: Data?, _ rhs: Data?) -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs,
              let lhsJSON = try? JSONSerialization.jsonObject(with: lhs),
              let rhsJSON = try? JSONSerialization.jsonObject(with: rhs) else { return false }
        return NSDictionary(dictionary: ["body": lhsJSON])
            .isEqual(to: ["body": rhsJSON])
    }
}

fileprivate nonisolated enum SeerrEmptyBodyMutation: String, CaseIterable, Sendable {
    case approveRequest
    case declineRequest
    case resolveIssue
    case reopenIssue

    var path: String {
        switch self {
        case .approveRequest: "/api/v1/request/9/approve"
        case .declineRequest: "/api/v1/request/9/decline"
        case .resolveIssue: "/api/v1/issue/9/resolved"
        case .reopenIssue: "/api/v1/issue/9/open"
        }
    }
}

fileprivate nonisolated enum SeerrUndecodableBody: String, CaseIterable, Sendable {
    case malformedJSON
    case emptyBody
    case htmlPage

    var body: String {
        switch self {
        case .malformedJSON: #"{"pageInfo":{"pages":1},"results":[{"id":603,"#
        case .emptyBody: ""
        case .htmlPage: "<html><body><h1>502 Bad Gateway</h1></body></html>"
        }
    }

    var headerFields: [String: String] {
        switch self {
        case .htmlPage: ["Content-Type": "text/html"]
        default: ["Content-Type": "application/json"]
        }
    }
}

// MARK: - Fixtures

private nonisolated enum SeerrFixture {
    static let requestList = #"""
    {
      "pageInfo": { "pages": 3, "pageSize": 20, "results": 41, "page": 1 },
      "results": [
        {
          "id": 12,
          "status": 2,
          "is4k": false,
          "createdAt": "2026-08-01T10:15:00.000Z",
          "updatedAt": "2026-08-01T10:16:00.000Z",
          "media": {
            "id": 501,
            "tmdbId": 603,
            "status": 5,
            "mediaType": "movie",
            "title": "The Matrix",
            "posterPath": "/matrix.jpg"
          },
          "requestedBy": { "id": 3, "displayName": "Ada", "permissions": 32 }
        },
        {
          "id": 13,
          "status": 1,
          "media": {
            "id": 502,
            "tvdbId": 81189,
            "status": 3,
            "mediaType": "tv",
            "name": "Breaking Bad"
          }
        },
        {
          "id": 14,
          "media": null,
          "requestedBy": null,
          "createdAt": null
        }
      ]
    }
    """#

    static let requestCount = #"""
    { "total": 41, "movie": 20, "tv": 21, "pending": 4, "approved": 30, "processing": 2, "available": 5 }
    """#

    static let issueList = #"""
    {
      "pageInfo": { "pages": 1, "pageSize": 20, "results": 2, "page": 1 },
      "results": [
        {
          "id": 31,
          "issueType": 2,
          "status": 1,
          "createdAt": "2026-08-02T09:00:00.000Z",
          "media": { "id": 501, "tmdbId": 603, "mediaType": "movie", "title": "The Matrix" },
          "createdBy": { "id": 3, "displayName": "Ada" },
          "comments": [
            { "id": 90, "message": "No sound after the first act", "createdAt": "2026-08-02T09:00:00.000Z" }
          ]
        },
        {
          "id": 32,
          "issueType": 4,
          "status": 2,
          "media": null,
          "comments": []
        }
      ]
    }
    """#

    static let issueWithoutComments = #"""
    { "id": 5, "issueType": 1, "status": 1, "media": { "id": 77, "name": "Arrival" } }
    """#

    static let issueWithComment = #"""
    {
      "id": 31,
      "issueType": 2,
      "status": 1,
      "comments": [
        { "id": 91, "message": "Audio desyncs after 12 minutes", "createdAt": "2026-08-02T10:00:00.000Z" }
      ]
    }
    """#

    static let trending = #"""
    {
      "pageInfo": { "pages": 1, "pageSize": 20, "results": 3, "page": 1 },
      "results": [
        {
          "id": 603,
          "mediaType": "movie",
          "title": "The Matrix",
          "overview": "A hacker learns the truth.",
          "posterPath": "/matrix.jpg",
          "backdropPath": "/matrix-wide.jpg",
          "voteAverage": 8.2,
          "releaseDate": "1999-03-30",
          "genreIds": [28, 878]
        },
        {
          "id": 1396,
          "mediaType": "tv",
          "name": "Breaking Bad",
          "posterPath": "/breaking-bad.jpg",
          "voteAverage": 8.9,
          "firstAirDate": "2008-01-20",
          "genreIds": [18]
        },
        {
          "id": 42,
          "media_type": "movie",
          "poster_path": "/snake.jpg",
          "vote_average": 5.5,
          "release_date": "2020-01-01"
        }
      ]
    }
    """#

    static let movieDetail = #"""
    {
      "id": 77,
      "title": "Arrival",
      "posterPath": "/arrival.jpg",
      "backdropPath": "/arrival-wide.jpg",
      "releaseDate": "2016-11-11",
      "runtime": 116,
      "voteAverage": 7.6,
      "genres": [ { "id": 18, "name": "Drama" }, { "id": 878, "name": "Science Fiction" } ],
      "credits": {
        "cast": [
          { "id": 1, "name": "Amy Adams", "character": "Louise Banks", "profilePath": "/amy.jpg" },
          { "id": 2, "name": "Jeremy Renner", "character": "Ian Donnelly" }
        ]
      }
    }
    """#

    static let logs = #"""
    {
      "pageInfo": { "pages": 1, "pageSize": 50, "results": 3, "page": 1 },
      "results": [
        {
          "label": "Jobs",
          "level": "warn",
          "message": "Object data",
          "timestamp": "2026-08-03T12:00:00.000Z",
          "data": { "job": "radarr-scan", "attempts": 3 }
        },
        {
          "label": "Jobs",
          "level": "warn",
          "message": "String data",
          "timestamp": "2026-08-03T12:00:01.000Z",
          "data": "plain text"
        },
        {
          "label": "Jobs",
          "level": "warn",
          "message": "No data at all",
          "timestamp": "2026-08-03T12:00:02.000Z"
        }
      ]
    }
    """#

    static let dvrSettingsList = #"""
    [
      {
        "id": 3,
        "name": "Primary",
        "hostname": "dvr.local",
        "port": 7878,
        "apiKey": "dvr-key",
        "activeProfileId": 9,
        "activeDirectory": "/data/media",
        "isDefault": true
      }
    ]
    """#

    static let dvrPickerData = #"""
    {
      "profiles": [ { "id": 6, "name": "HD-1080p" }, { "id": 9 } ],
      "rootFolders": [ { "id": 1, "path": "/data/media", "freeSpace": 91234567890 } ],
      "tags": [ { "id": 4, "label": "trawl" } ]
    }
    """#

    static let userList = #"""
    {
      "pageInfo": { "pages": 1, "pageSize": 40, "results": 3, "page": 1 },
      "results": [
        { "id": 3, "displayName": "Ada", "permissions": 32, "email": "ada@example.test" },
        { "id": 4, "email": "grace.hopper@example.test", "permissions": 2 },
        { "id": 5 }
      ]
    }
    """#

    static let singleUser = #"""
    { "id": 7, "displayName": "Ada", "jellyfinUsername": "ada", "permissions": 32, "requestCount": 12 }
    """#

    static let importedUsers = #"""
    [
      { "id": 3, "displayName": "Ada", "permissions": 32 },
      { "id": 4, "email": "grace.hopper@example.test", "permissions": 2 }
    ]
    """#

    static let publicSettings = #"""
    { "initialized": true, "applicationTitle": "Seerr", "localLogin": false, "mediaServerType": 2 }
    """#
}

// MARK: - Ordering primitive

/// A lock-guarded event log with continuation-based waiters. Tests use it to wait
/// for a specific number of events instead of sleeping.
private nonisolated final class SeerrEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        let count = events.count
        let ready = waiters.filter { $0.threshold <= count }
        waiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(untilCount threshold: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if events.count >= threshold {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((threshold, continuation))
                lock.unlock()
            }
        }
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func reset() {
        lock.lock()
        events = []
        waiters = []
        lock.unlock()
    }
}

// MARK: - Stub server

private final class SeerrContractURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        var headerFields: [String: String] = ["Content-Type": "application/json"]
        var hangs: Bool = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [Stub] = [Stub()]
    nonisolated(unsafe) private static var responseIndex = 0
    nonisolated(unsafe) private static var requests: [SeerrRecordedRequest] = []
    static let requestLog = SeerrEventLog()

    static func stub(
        statusCode: Int = 200,
        body: Data = Data(),
        headerFields: [String: String] = ["Content-Type": "application/json"],
        hangs: Bool = false
    ) {
        stub(sequence: [Stub(statusCode: statusCode, body: body, headerFields: headerFields, hangs: hangs)])
    }

    /// Responses are consumed in order; the last one repeats for any extra request.
    static func stub(sequence: [Stub]) {
        lock.lock()
        responses = sequence.isEmpty ? [Stub()] : sequence
        responseIndex = 0
        requests = []
        lock.unlock()
        requestLog.reset()
    }

    static var recordedRequests: [SeerrRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "seerr.contract.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let recorded = SeerrRecordedRequest(
            method: request.httpMethod ?? "",
            path: url.path,
            queryPairs: Self.queryPairs(from: components),
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: Self.bodyData(from: request)
        )

        Self.lock.lock()
        Self.requests.append(recorded)
        let stub = Self.responses[min(Self.responseIndex, Self.responses.count - 1)]
        Self.responseIndex += 1
        Self.lock.unlock()

        Self.requestLog.record(recorded.path)

        guard !stub.hangs else { return }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Sorted `k=v` pairs, still percent-encoded, so both the values and their
    /// encoding are asserted. `SeerrAPIClient` builds query items from a
    /// dictionary, so the wire order is not stable and must not be asserted.
    private static func queryPairs(from components: URLComponents) -> [String] {
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return [] }
        return query.split(separator: "&").map(String.init).sorted()
    }

    /// URLSession hands `URLProtocol` the body as a stream, so `httpBody` is nil
    /// by the time the request arrives here.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body.isEmpty ? nil : body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
