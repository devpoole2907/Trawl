import Foundation
import Network
import Testing
@testable import Trawl

// MARK: - Sonarr

/// Network contract tests for the *arr clients. Every test drives the real
/// `SonarrAPIClient` / `RadarrAPIClient` / `ProwlarrAPIClient` / `BazarrAPIClient`
/// (and therefore the real `ArrAPIClient` + `HTTPTransport` request builder, auth
/// layer, serializer, status validator, decoder and `ArrError` mapper) against a
/// loopback HTTP server. The only thing faked is the remote server: nothing in
/// Trawl is stubbed, so a regression in request construction or error mapping
/// fails these tests.
///
/// Model-level decoding, `ArrError` presentation, queue/release computed
/// properties and filesystem query construction are covered by `ArrStackTests`
/// and are deliberately not repeated here.
@Suite("Sonarr API client HTTP contracts", .serialized)
@MainActor
struct SonarrAPIClientContractTests {
    /// The Add button on the quality-profiles screen depends entirely on this
    /// call: a profile's `items` have to mirror the server's own quality
    /// definitions, so a blank profile cannot be built client-side and has to come
    /// from the schema. Two things could break it silently - the path (a 404 here
    /// would surface as "could not start" with no hint why) and the shape, since
    /// unlike every neighbouring endpoint this one returns a single object rather
    /// than an array, and a nested `items` tree that the editor renders directly.
    @Test("Quality profile schema is fetched as a single object with its nested quality tree intact")
    func qualityProfileSchemaRequestAndDecoding() async throws {
        // Trimmed from a real Sonarr v4 response: an ungrouped quality, then a
        // group holding two of them, which is the structure the editor walks.
        let payload = """
        {
          "name": "",
          "upgradeAllowed": false,
          "cutoff": 0,
          "items": [
            {"quality":{"id":0,"name":"Unknown","source":"unknown","resolution":0},"items":[],"allowed":false},
            {"id":1000,"name":"WEB 1080p","allowed":false,"items":[
              {"quality":{"id":3,"name":"WEBDL-1080p","source":"web","resolution":1080},"items":[],"allowed":false},
              {"quality":{"id":15,"name":"WEBRip-1080p","source":"webRip","resolution":1080},"items":[],"allowed":false}
            ]}
          ],
          "minFormatScore": 0,
          "cutoffFormatScore": 0,
          "formatItems": [],
          "id": 0
        }
        """
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-qualityprofile-schema",
            routes: ["/api/v3/qualityprofile/schema": .json(payload)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let schema = try await client.getQualityProfileSchema()

        let requests = server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.method == "GET")
        // The sibling path `/api/v3/qualityprofile` lists existing profiles, so a
        // missing `/schema` suffix would quietly return real profiles instead.
        #expect(requests.first?.path == "/api/v3/qualityprofile/schema")
        #expect(requests.first?.header("X-Api-Key") == "sonarr-contract-key")

        // Unsaved: the editor keys "create vs update" off this being absent.
        #expect(schema.id == 0)
        #expect(schema.name.isEmpty)
        #expect(schema.items?.count == 2)
        // The nested group has to survive decoding - flattening it would strip
        // every grouped quality out of the new profile.
        #expect(schema.items?[1].name == "WEB 1080p")
        #expect(schema.items?[1].items?.count == 2)
        #expect(schema.items?[1].items?.map { $0.quality?.name } == ["WEBDL-1080p", "WEBRip-1080p"])
        #expect(schema.items?[0].quality?.name == "Unknown")
        // Nothing is preselected, so the user's first choice is theirs.
        #expect(schema.items?.allSatisfy { $0.allowed == false } == true)
    }

    @Test("Series list sends GET with the default X-Api-Key header and tolerates missing and unknown fields")
    func seriesListRequestAndDecoding() async throws {
        let payload = """
        [
          {"id":11,"title":"The Expanse","status":"ended","year":2015,"monitored":true,"seasons":[],"anUnknownFutureField":{"nested":1}},
          {"id":12,"title":"Severance"}
        ]
        """
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-series",
            routes: ["/api/v3/series": .json(payload)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let series = try await client.getSeries()

        #expect(series.map(\.id) == [11, 12])
        #expect(series.map(\.title) == ["The Expanse", "Severance"])
        #expect(series[0].status == "ended")
        #expect(series[0].year == 2015)
        #expect(series[1].status == nil)
        #expect(series[1].year == nil)
        #expect(series[1].seasons == nil)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v3/series")
        #expect(request.rawQuery == nil)
        #expect(request.queryItems == [])
        #expect(request.headerName(matching: "X-Api-Key") == "X-Api-Key")
        #expect(request.header("X-Api-Key") == "sonarr-contract-key")
        #expect(request.header("Content-Type") == nil)
        #expect(request.body.isEmpty)
    }

    @Test("Series lookup percent-encodes the search term into a single term query item")
    func seriesLookupEncodesTerm() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-lookup",
            routes: ["/api/v3/series/lookup": .json(#"[{"id":0,"title":"The Expanse","tvdbId":280619}]"#)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let results = try await client.lookupSeries(term: "The Expanse")

        #expect(results.map(\.tvdbId) == [280619])

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v3/series/lookup")
        #expect(request.rawQuery == "term=The%20Expanse")
        #expect(request.queryItems == [URLQueryItem(name: "term", value: "The Expanse")])
    }

    @Test("Queue request sends the documented default page size and both unknown-item flags")
    func queueRequestSendsDefaultPagination() async throws {
        let payload = """
        {"page":1,"pageSize":20,"sortKey":"timeleft","sortDirection":"ascending","totalRecords":1,
         "records":[{"id":5,"title":"The.Expanse.S01E01","status":"downloading","trackedDownloadState":"downloading"}]}
        """
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-queue",
            routes: ["/api/v3/queue": .json(payload)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let page = try await client.getQueue()

        #expect(page.totalRecords == 1)
        #expect(page.records?.map(\.id) == [5])

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v3/queue")
        #expect(request.queryItems == [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pageSize", value: "20"),
            URLQueryItem(name: "includeUnknownMovieItems", value: "true"),
            URLQueryItem(name: "includeUnknownSeriesItems", value: "true")
        ])
    }

    @Test("Calendar request serializes its date range as ISO 8601 alongside the monitoring flags")
    func calendarRequestSerializesDateRange() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-calendar",
            routes: ["/api/v3/calendar": .json("[]")]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let episodes = try await client.getCalendar(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_086_400)
        )

        #expect(episodes.isEmpty)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v3/calendar")
        #expect(request.queryItems == [
            URLQueryItem(name: "start", value: "2023-11-14T22:13:20Z"),
            URLQueryItem(name: "end", value: "2023-11-15T22:13:20Z"),
            URLQueryItem(name: "unmonitored", value: "false"),
            URLQueryItem(name: "includeSeries", value: "true")
        ])
    }

    @Test("Interactive release search sends every identifier and decodes a mixed-shape release payload")
    func releaseSearchDecodesMixedShapePayload() async throws {
        let payload = """
        [
          {"guid":"indexer-1-abc","indexerId":3,"title":"The.Expanse.S01E01.1080p","protocol":"torrent",
           "size":4294967296,"seeders":42,"leechers":3,"approved":true,"rejected":false,
           "ageHours":12,"quality":{"quality":{"name":"WEBDL-1080p"}}},
          {}
        ]
        """
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-release",
            routes: ["/api/v3/release": .json(payload)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let releases = try await client.getReleases(episodeId: 42, seriesId: 7, seasonNumber: 2)

        #expect(releases.count == 2)
        #expect(releases[0].guid == "indexer-1-abc")
        #expect(releases[0].indexerId == 3)
        #expect(releases[0].protocol_ == "torrent")
        #expect(releases[0].size == 4_294_967_296)
        #expect(releases[0].ageHours == 12)
        #expect(releases[1].guid == nil)
        #expect(releases[1].indexerId == nil)
        #expect(releases[1].protocol_ == nil)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v3/release")
        #expect(request.queryItems == [
            URLQueryItem(name: "episodeId", value: "42"),
            URLQueryItem(name: "seriesId", value: "7"),
            URLQueryItem(name: "seasonNumber", value: "2")
        ])
    }

    @Test("Grabbing a release POSTs exactly the trimmed guid and indexer id as JSON")
    func grabReleaseSerializesExactJSONBody() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-grab",
            routes: ["/api/v3/release": .empty(status: 201)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")
        let release = try JSONDecoder().decode(
            ArrRelease.self,
            from: Data(#"{"guid":"  sonarr-guid-1  ","indexerId":7}"#.utf8)
        )

        try await client.grabRelease(release)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v3/release")
        #expect(request.rawQuery == nil)
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("X-Api-Key") == "sonarr-contract-key")
        // Compared as parsed JSON, not raw bytes: `JSONEncoder` gives no key-order
        // guarantee, so a byte assertion here fails intermittently on an encoder
        // detail rather than on a contract change. The key set is still exact, so
        // a stray or missing field still fails - and the trimmed guid is the point.
        let body = try #require(request.jsonObjectBody)
        let expected: NSDictionary = ["guid": "sonarr-guid-1", "indexerId": 7]
        #expect(body == expected)
    }

    @Test("Series search POSTs the documented command payload and decodes the queued command")
    func seriesSearchCommandBody() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-command",
            routes: ["/api/v3/command": .json(#"{"id":901,"name":"SeriesSearch","status":"queued"}"#, status: 201)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let command = try await client.searchSeries(seriesId: 2)

        #expect(command.id == 901)
        #expect(command.name == "SeriesSearch")
        #expect(command.isTerminal == false)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v3/command")
        #expect(request.header("Content-Type") == "application/json")
        let body = try #require(request.jsonObjectBody)
        let expected: NSDictionary = ["name": "SeriesSearch", "seriesId": 2]
        #expect(body == expected)
    }

    // MARK: - Series deletion
    //
    // The only call in the app that can delete a user's media files. `deleteFiles`
    // decides whether the library entry alone goes or the episodes on disk go with it,
    // and `addImportListExclusion` decides whether the series can ever come back
    // automatically. Both are carried as query flags, and the two are expressed
    // differently: `deleteFiles` is always sent, while `addImportListExclusion` says
    // "false" by being absent. That asymmetry is exactly the kind of thing a tidying
    // refactor unifies without noticing.

    @Test("Deleting a series keeps the files by default and omits the exclusion flag")
    func deleteSeriesDefaultsToKeepingFiles() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-series-delete",
            routes: ["/api/v3/series/11": .empty(status: 200)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        try await client.deleteSeries(id: 11)

        let request = try #require(server.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/api/v3/series/11")
        let pairs = queryPairs(request.rawQuery)
        #expect(
            pairs["deleteFiles"] == "false",
            "The destructive flag must be sent explicitly as false rather than left to the server's default."
        )
        #expect(
            pairs["addImportListExclusion"] == nil,
            "Not excluding is expressed by omitting the parameter - sending it as \"false\" is a different request."
        )
    }

    @Test("Deleting a series with its files sends deleteFiles=true")
    func deleteSeriesCanDeleteFiles() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-series-delete-files",
            routes: ["/api/v3/series/11": .empty(status: 200)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        try await client.deleteSeries(id: 11, deleteFiles: true)

        let request = try #require(server.requests.first)
        #expect(request.path == "/api/v3/series/11")
        #expect(queryPairs(request.rawQuery)["deleteFiles"] == "true")
    }

    @Test("Excluding a series from import lists adds that flag alongside deleteFiles")
    func deleteSeriesCanAddImportListExclusion() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-series-delete-exclude",
            routes: ["/api/v3/series/11": .empty(status: 200)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        try await client.deleteSeries(id: 11, deleteFiles: false, addImportListExclusion: true)

        let pairs = queryPairs(try #require(server.requests.first).rawQuery)
        #expect(pairs["deleteFiles"] == "false")
        #expect(pairs["addImportListExclusion"] == "true")
    }

    @Test("A rejected series deletion surfaces as an ArrError rather than reporting success")
    func deleteSeriesPropagatesRejection() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-series-delete-reject",
            routes: ["/api/v3/series/11": .json(#"{"message":"nope"}"#, status: 500)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        await #expect(throws: ArrError.self) {
            try await client.deleteSeries(id: 11)
        }
    }

    // MARK: - Queue deletion
    //
    // The most destructive call the app makes: it removes the download from the
    // client's disk and can blocklist the release so it is never grabbed again.
    // Both effects are carried entirely by query flags, so a wrong default or a
    // dropped parameter silently changes what a tap destroys. Nothing covered this
    // at any level before.

    @Test("Removing a queue item DELETEs that item, removing it from the download client and not blocklisting")
    func deleteQueueItemDefaultsToRemoveFromClientWithoutBlocklisting() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-queue-delete",
            routes: ["/api/v3/queue/42": .empty(status: 200)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        try await client.deleteQueueItem(id: 42)

        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "DELETE")
        #expect(request.path == "/api/v3/queue/42")
        #expect(request.header("X-Api-Key") == "sonarr-contract-key")
        // Parsed rather than string-compared: query item order is an implementation
        // detail, and pinning it would fail on a reorder that changes nothing.
        #expect(queryPairs(request.rawQuery) == ["removeFromClient": "true", "blocklist": "false"])
    }

    @Test("Blocklisting a queue item sends blocklist=true and still removes it from the client")
    func deleteQueueItemBlocklistsWhenAsked() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-queue-blocklist",
            routes: ["/api/v3/queue/42": .empty(status: 200)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        try await client.deleteQueueItem(id: 42, blocklist: true)

        let request = try #require(server.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/api/v3/queue/42")
        #expect(queryPairs(request.rawQuery) == ["removeFromClient": "true", "blocklist": "true"])
    }

    @Test("Keeping the download sends removeFromClient=false rather than omitting it")
    func deleteQueueItemCanKeepTheDownload() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-queue-keep",
            routes: ["/api/v3/queue/7": .empty(status: 200)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        try await client.deleteQueueItem(id: 7, removeFromClient: false, blocklist: false)

        let request = try #require(server.requests.first)
        #expect(queryPairs(request.rawQuery) == ["removeFromClient": "false", "blocklist": "false"])
    }

    @Test("A rejected queue deletion surfaces as an ArrError rather than reporting success")
    func deleteQueueItemPropagatesServerRejection() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-queue-reject",
            routes: ["/api/v3/queue/42": .json(#"{"message":"nope"}"#, status: 500)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        await #expect(throws: ArrError.self) {
            try await client.deleteQueueItem(id: 42)
        }
        // The request still went out - this is a server rejection, not a client-side
        // refusal to send.
        #expect(server.requests.contains { $0.method == "DELETE" && $0.path == "/api/v3/queue/42" })
    }

    @Test("Sonarr keeps import list exclusions on the shared paged endpoint")
    func importListExclusionsUseSharedPath() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "sonarr-exclusions",
            routes: ["/api/v3/importlistexclusion/paged": .json(#"{"page":1,"pageSize":20,"totalRecords":0,"records":[]}"#)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let page = try await client.getImportListExclusions()

        #expect(page.totalRecords == 0)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v3/importlistexclusion/paged")
        #expect(request.queryItems == [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pageSize", value: "20")
        ])
    }
}

// MARK: - Radarr

@Suite("Radarr API client HTTP contracts", .serialized)
@MainActor
struct RadarrAPIClientContractTests {
    @Test("TMDb lookup targets the dedicated path with a single tmdbId query item")
    func tmdbLookupRequest() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "radarr-tmdb",
            routes: ["/api/v3/movie/lookup/tmdb": .json(#"{"id":0,"title":"Dune","tmdbId":438631,"year":2021}"#)]
        )
        defer { server.stop() }
        let client = RadarrAPIClient(baseURL: server.baseURL, apiKey: "radarr-contract-key")

        let movie = try await client.lookupMovieByTmdb(tmdbId: 438631)

        #expect(movie.title == "Dune")
        #expect(movie.tmdbId == 438631)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v3/movie/lookup/tmdb")
        #expect(request.queryItems == [URLQueryItem(name: "tmdbId", value: "438631")])
        #expect(request.header("X-Api-Key") == "radarr-contract-key")
    }

    @Test("Editing a movie PUTs the full record and only sends moveFiles when it is requested")
    func updateMovieSendsMoveFilesOnlyWhenRequested() async throws {
        let stored = #"{"id":12,"title":"Dune","year":2021,"monitored":true,"qualityProfileId":4}"#
        let server = try await ArrContractTestServer.routed(
            label: "radarr-update",
            routes: ["/api/v3/movie/12": .json(stored)]
        )
        defer { server.stop() }
        let client = RadarrAPIClient(baseURL: server.baseURL, apiKey: "radarr-contract-key")
        let movie = try JSONDecoder().decode(RadarrMovie.self, from: Data(stored.utf8))

        let moved = try await client.updateMovie(movie, moveFiles: true)
        let inPlace = try await client.updateMovie(movie)

        #expect(moved.id == 12)
        #expect(inPlace.id == 12)

        let requests = server.requests
        #expect(requests.count == 2)
        let movedRequest = try #require(requests.first)
        #expect(movedRequest.method == "PUT")
        #expect(movedRequest.path == "/api/v3/movie/12")
        #expect(movedRequest.queryItems == [URLQueryItem(name: "moveFiles", value: "true")])
        #expect(movedRequest.header("Content-Type") == "application/json")
        let sentBody = try #require(movedRequest.jsonObjectBody)
        #expect(sentBody["id"] as? Int == 12)
        #expect(sentBody["title"] as? String == "Dune")
        #expect(sentBody["qualityProfileId"] as? Int == 4)
        #expect(sentBody["year"] as? Int == 2021)

        let inPlaceRequest = try #require(requests.last)
        #expect(inPlaceRequest.method == "PUT")
        #expect(inPlaceRequest.path == "/api/v3/movie/12")
        #expect(inPlaceRequest.rawQuery == nil)
        #expect(inPlaceRequest.queryItems == [])
    }

    @Test("Deleting a movie sends DELETE with the exclusion flag only when asked and never sends a body")
    func deleteMovieQueryEncoding() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "radarr-delete",
            routes: [
                "/api/v3/movie/12": .empty(),
                "/api/v3/movie/13": .empty()
            ]
        )
        defer { server.stop() }
        let client = RadarrAPIClient(baseURL: server.baseURL, apiKey: "radarr-contract-key")

        try await client.deleteMovie(id: 12, deleteFiles: true, addImportExclusion: true)
        try await client.deleteMovie(id: 13)

        let requests = server.requests
        #expect(requests.count == 2)
        let excluded = try #require(requests.first)
        #expect(excluded.method == "DELETE")
        #expect(excluded.path == "/api/v3/movie/12")
        #expect(excluded.queryItems == [
            URLQueryItem(name: "deleteFiles", value: "true"),
            URLQueryItem(name: "addImportExclusion", value: "true")
        ])
        #expect(excluded.body.isEmpty)

        let plain = try #require(requests.last)
        #expect(plain.method == "DELETE")
        #expect(plain.path == "/api/v3/movie/13")
        #expect(plain.queryItems == [URLQueryItem(name: "deleteFiles", value: "false")])
    }

    @Test("Radarr routes import list exclusions to its own exclusions path")
    func importListExclusionsUseRadarrPath() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "radarr-exclusions",
            routes: ["/api/v3/exclusions/paged": .json(#"{"page":2,"pageSize":50,"totalRecords":1,"records":[{"id":3,"movieTitle":"Dune"}]}"#)]
        )
        defer { server.stop() }
        let client = RadarrAPIClient(baseURL: server.baseURL, apiKey: "radarr-contract-key")

        let page = try await client.getImportListExclusions(page: 2, pageSize: 50)

        #expect(page.totalRecords == 1)
        #expect(page.records?.map(\.id) == [3])

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.path == "/api/v3/exclusions/paged")
        #expect(request.queryItems == [
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "pageSize", value: "50")
        ])
    }

    @Test("Movie search POSTs the documented command payload")
    func movieSearchCommandBody() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "radarr-command",
            routes: ["/api/v3/command": .json(#"{"id":77,"name":"MoviesSearch","status":"started"}"#, status: 201)]
        )
        defer { server.stop() }
        let client = RadarrAPIClient(baseURL: server.baseURL, apiKey: "radarr-contract-key")

        let command = try await client.searchMovie(movieIds: [12, 13])

        #expect(command.id == 77)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v3/command")
        #expect(request.header("Content-Type") == "application/json")
        let body = try #require(request.jsonObjectBody)
        let expected: NSDictionary = ["name": "MoviesSearch", "movieIds": [12, 13]]
        #expect(body == expected)
    }
}

// MARK: - Failure, body and cancellation contracts

@Suite("Arr API client failure and cancellation contracts", .serialized)
@MainActor
struct ArrAPIClientFailureContractTests {
    @Test("Documented failure statuses map to the matching ArrError without a second attempt",
          arguments: [401, 404, 409, 429, 503])
    func failureStatusesMapToArrError(statusCode: Int) async throws {
        let body = #"{"message":"the server rejected this request"}"#
        let server = try await ArrContractTestServer.routed(
            label: "arr-status-\(statusCode)",
            routes: ["/api/v3/series": .json(body, status: statusCode)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        do {
            let series = try await client.getSeries()
            Issue.record("Expected HTTP \(statusCode) to throw; decoded \(series.count) series instead.")
        } catch let error as ArrError {
            switch error {
            case .invalidAPIKey:
                #expect(statusCode == 401)
            case .serverError(let code, let message):
                #expect(statusCode != 401)
                #expect(code == statusCode)
                #expect(message == body)
            default:
                Issue.record("Expected an API-key or server error for HTTP \(statusCode), received \(error).")
            }
        } catch {
            Issue.record("Expected ArrError for HTTP \(statusCode), received \(error).")
        }

        let requests = server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.path == "/api/v3/series")
    }

    @Test("A successful status with an undecodable body fails instead of returning an empty library",
          arguments: ["truncated-json", "empty-body", "html-page"])
    func undecodableSuccessBodiesThrow(kind: String) async throws {
        let stub: ArrContractStubResponse = switch kind {
        case "truncated-json": .json(#"[{"id":11,"title":"The Expa"#)
        case "empty-body": .empty()
        default: .html("<!DOCTYPE html><html><body>Sign in to continue</body></html>")
        }
        let server = try await ArrContractTestServer.routed(
            label: "arr-undecodable-\(kind)",
            routes: ["/api/v3/series": stub]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        do {
            let series = try await client.getSeries()
            Issue.record("Expected \(kind) to throw; received \(series.count) series instead.")
        } catch let error as ArrError {
            guard case .decodingError = error else {
                Issue.record("Expected ArrError.decodingError for \(kind), received \(error).")
                return
            }
        } catch {
            Issue.record("Expected ArrError.decodingError for \(kind), received \(error).")
        }

        let requests = server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.path == "/api/v3/series")
    }

    @Test("A reverse-proxy HTML error page surfaces as a server error carrying the page body")
    func htmlErrorPageSurfacesAsServerError() async throws {
        let page = "<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>"
        let server = try await ArrContractTestServer.routed(
            label: "arr-html-502",
            routes: ["/api/v3/series": .html(page, status: 502)]
        )
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        do {
            let series = try await client.getSeries()
            Issue.record("Expected the HTML 502 page to throw; received \(series.count) series instead.")
        } catch let error as ArrError {
            guard case .serverError(let code, let message) = error else {
                Issue.record("Expected ArrError.serverError, received \(error).")
                return
            }
            #expect(code == 502)
            #expect(message == page)
        } catch {
            Issue.record("Expected ArrError.serverError, received \(error).")
        }

        let requests = server.requests
        #expect(requests.count == 1)
    }

    @Test("Cancelling an in-flight request throws CancellationError after the request reached the server")
    func inFlightRequestCancels() async throws {
        let server = try await ArrContractTestServer(label: "arr-cancel") { _ in nil }
        defer { server.stop() }
        let client = SonarrAPIClient(baseURL: server.baseURL, apiKey: "sonarr-contract-key")

        let task = Task { try await client.getSeries() }
        await server.requestReceived.wait()
        task.cancel()

        do {
            let series = try await task.value
            Issue.record("Expected the cancelled request to throw; received \(series.count) series instead.")
        } catch is CancellationError {
            // Expected: HTTPTransport normalises URLError.cancelled to CancellationError.
        } catch {
            Issue.record("Expected CancellationError, received \(error).")
        }

        let requests = server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.path == "/api/v3/series")
    }
}

// MARK: - Prowlarr and Bazarr

@Suite("Prowlarr and Bazarr API client HTTP contracts", .serialized)
@MainActor
struct ProwlarrBazarrAPIClientContractTests {
    @Test("Prowlarr resolves the shared system status endpoint against its own v1 API path")
    func prowlarrSharedEndpointUsesV1() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "prowlarr-status",
            routes: ["/api/v1/system/status": .json(#"{"version":"1.21.2.4649","appName":"Prowlarr"}"#)]
        )
        defer { server.stop() }
        let client = ProwlarrAPIClient(baseURL: server.baseURL, apiKey: "prowlarr-contract-key")

        let status = try await client.getSystemStatus()

        #expect(status.version == "1.21.2.4649")

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/system/status")
        #expect(request.headerName(matching: "X-Api-Key") == "X-Api-Key")
        #expect(request.header("X-Api-Key") == "prowlarr-contract-key")
    }

    @Test("Prowlarr search repeats indexer and category identifiers as separate query items in order")
    func prowlarrSearchRepeatsQueryItems() async throws {
        let payload = #"[{"guid":"prowlarr-1","title":"Dune 2021","indexerId":4,"protocol":"usenet","size":123}]"#
        let server = try await ArrContractTestServer.routed(
            label: "prowlarr-search",
            routes: ["/api/v1/search": .json(payload)]
        )
        defer { server.stop() }
        let client = ProwlarrAPIClient(baseURL: server.baseURL, apiKey: "prowlarr-contract-key")

        let results = try await client.search(
            query: "dune",
            indexerIds: [1, 2],
            type: .moviesearch,
            categories: [2000, 5000],
            limit: 50,
            offset: 10
        )

        #expect(results.map(\.guid) == ["prowlarr-1"])

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/search")
        #expect(request.queryItems == [
            URLQueryItem(name: "query", value: "dune"),
            URLQueryItem(name: "type", value: "moviesearch"),
            URLQueryItem(name: "indexerIds", value: "1"),
            URLQueryItem(name: "indexerIds", value: "2"),
            URLQueryItem(name: "categories", value: "2000"),
            URLQueryItem(name: "categories", value: "5000"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "offset", value: "10")
        ])
    }

    @Test("Bazarr sends its own uppercase API key header and accepts both wrapped and bare status payloads",
          arguments: [
            #"{"data":{"bazarr_version":"1.4.3","sonarr_version":"4.0.0"}}"#,
            #"{"bazarr_version":"1.4.3","sonarr_version":"4.0.0"}"#
          ])
    func bazarrStatusHeaderAndPayloadShapes(payload: String) async throws {
        let server = try await ArrContractTestServer.routed(
            label: "bazarr-status",
            routes: ["/api/system/status": .json(payload)]
        )
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-contract-key")

        let status = try await client.getSystemStatus()

        #expect(status.bazarrVersion == "1.4.3")
        #expect(status.sonarrVersion == "4.0.0")

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/system/status")
        #expect(request.headerName(matching: "X-API-KEY") == "X-API-KEY")
        #expect(request.header("X-API-KEY") == "bazarr-contract-key")
    }

    @Test("Bazarr movie listing percent-encodes its bracketed repeated id parameter")
    func bazarrMovieListEncodesBracketedIDs() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "bazarr-movies",
            routes: ["/api/movies": .json(#"{"data":[],"total":0}"#)]
        )
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-contract-key")

        let page = try await client.getMovies(ids: [7, 9])

        #expect(page.total == 0)
        #expect(page.data.isEmpty)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/movies")
        #expect(request.rawQuery == "start=0&length=-1&radarrid%5B%5D=7&radarrid%5B%5D=9")
        #expect(request.queryItems == [
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "length", value: "-1"),
            URLQueryItem(name: "radarrid[]", value: "7"),
            URLQueryItem(name: "radarrid[]", value: "9")
        ])
    }

    @Test("Bazarr profile assignment posts a form body that repeats keys and keeps the null sentinel")
    func bazarrProfileAssignmentFormBody() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "bazarr-profiles",
            routes: ["/api/series": .empty()]
        )
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-contract-key")

        try await client.updateSeriesProfile(seriesIds: [3, 8], profileIds: ["2", nil])

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/series")
        #expect(request.rawQuery == nil)
        #expect(request.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.bodyText == "seriesid=3&profileid=2&seriesid=8&profileid=null")
    }

    @Test("Bazarr series actions are sent as a PATCH with the action in the query string")
    func bazarrSeriesActionUsesPatch() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "bazarr-action",
            routes: ["/api/series": .empty()]
        )
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-contract-key")

        try await client.runSeriesAction(seriesId: 3, action: .searchMissing)

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/series")
        #expect(request.queryItems == [
            URLQueryItem(name: "seriesid", value: "3"),
            URLQueryItem(name: "action", value: "search-missing")
        ])
        #expect(request.body.isEmpty)
    }

    @Test("Bazarr maps an unauthorized response to the invalid API key error")
    func bazarrUnauthorizedMapsToInvalidAPIKey() async throws {
        let server = try await ArrContractTestServer.routed(
            label: "bazarr-401",
            routes: ["/api/system/status": .json(#"{"error":"Unauthorized"}"#, status: 401)]
        )
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-contract-key")

        do {
            let status = try await client.getSystemStatus()
            Issue.record("Expected HTTP 401 to throw; decoded version \(status.bazarrVersion) instead.")
        } catch let error as ArrError {
            guard case .invalidAPIKey = error else {
                Issue.record("Expected ArrError.invalidAPIKey, received \(error).")
                return
            }
        } catch {
            Issue.record("Expected ArrError.invalidAPIKey, received \(error).")
        }

        let requests = server.requests
        #expect(requests.count == 1)
    }
}

// MARK: - Loopback contract server

private nonisolated struct ArrContractRequest: Sendable, Equatable {
    let method: String
    let path: String
    let rawQuery: String?
    let queryItems: [URLQueryItem]
    /// Header names exactly as they appeared on the wire.
    let headers: [String: String]
    let body: Data

    /// Case-insensitive header lookup, matching HTTP semantics.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The header name exactly as the client wrote it, found case-insensitively.
    func headerName(matching name: String) -> String? {
        headers.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    var bodyText: String { String(decoding: body, as: UTF8.self) }

    var jsonObjectBody: NSDictionary? {
        (try? JSONSerialization.jsonObject(with: body)) as? NSDictionary
    }
}

private nonisolated struct ArrContractStubResponse: Sendable {
    let statusCode: Int
    let reason: String
    let contentType: String
    let body: Data

    static func json(_ body: String, status: Int = 200) -> ArrContractStubResponse {
        ArrContractStubResponse(
            statusCode: status,
            reason: reasonPhrase(for: status),
            contentType: "application/json",
            body: Data(body.utf8)
        )
    }

    static func html(_ body: String, status: Int = 200) -> ArrContractStubResponse {
        ArrContractStubResponse(
            statusCode: status,
            reason: reasonPhrase(for: status),
            contentType: "text/html; charset=utf-8",
            body: Data(body.utf8)
        )
    }

    static func empty(status: Int = 200) -> ArrContractStubResponse {
        ArrContractStubResponse(
            statusCode: status,
            reason: reasonPhrase(for: status),
            contentType: "application/json",
            body: Data()
        )
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

/// One-shot barrier used instead of sleeping: the server signals it as soon as a
/// full request has been parsed, so cancellation happens at a known point.
private final class ArrContractSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        if isSignalled {
            lock.unlock()
            return
        }
        isSignalled = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isSignalled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A loopback HTTP/1.1 server that records the exact bytes each *arr client puts
/// on the wire and replays a scripted response. Returning `nil` from the router
/// holds the connection open without answering, which is how the cancellation
/// contract is exercised.
/// Parses a raw query string into its pairs, so a test can assert the parameters a
/// request carried without pinning the order they were built in.
private func queryPairs(_ rawQuery: String?) -> [String: String] {
    guard let rawQuery, !rawQuery.isEmpty else { return [:] }
    var pairs: [String: String] = [:]
    for component in rawQuery.split(separator: "&") {
        let parts = component.split(separator: "=", maxSplits: 1)
        guard let name = parts.first else { continue }
        let value = parts.count > 1 ? String(parts[1]) : ""
        pairs[String(name).removingPercentEncoding ?? String(name)] = value.removingPercentEncoding ?? value
    }
    return pairs
}

private final class ArrContractTestServer: @unchecked Sendable {
    typealias Router = @Sendable (ArrContractRequest) -> ArrContractStubResponse?

    let requestReceived = ArrContractSignal()

    private let listener: NWListener
    private let queue: DispatchQueue
    private let router: Router
    private let lock = NSLock()
    private var recordedRequests: [ArrContractRequest] = []
    private var connections: [NWConnection] = []

    init(label: String, router: @escaping Router) async throws {
        self.queue = DispatchQueue(label: "ArrContractTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.router = router
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
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

    static func routed(
        label: String,
        routes: [String: ArrContractStubResponse],
        fallback: ArrContractStubResponse = .json(#"{"message":"unrouted path"}"#, status: 404)
    ) async throws -> ArrContractTestServer {
        try await ArrContractTestServer(label: label) { request in
            routes[request.path] ?? fallback
        }
    }

    var baseURL: String {
        guard let port = listener.port else { fatalError("Arr contract test server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [ArrContractRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func stop() {
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            guard let request = Self.parse(accumulated) else {
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
            self.requestReceived.signal()

            guard let stub = self.router(request) else {
                // Deliberately unanswered: the client must observe cancellation.
                return
            }
            connection.send(
                content: Self.encode(stub),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    /// Returns nil until the buffer holds a complete request line, headers and
    /// the full `Content-Length` body.
    private static func parse(_ buffer: Data) -> ArrContractRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: buffer[buffer.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = headers
            .first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value) } ?? 0
        let bodyStart = separator.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])

        let components = URLComponents(string: target)
        return ArrContractRequest(
            method: method,
            path: components?.path ?? target,
            rawQuery: components?.percentEncodedQuery,
            queryItems: components?.queryItems ?? [],
            headers: headers,
            body: body
        )
    }

    private static func encode(_ stub: ArrContractStubResponse) -> Data {
        var head = "HTTP/1.1 \(stub.statusCode) \(stub.reason)\r\n"
        head += "Content-Type: \(stub.contentType)\r\n"
        head += "Content-Length: \(stub.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + stub.body
    }
}
