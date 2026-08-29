import Foundation
import Testing
@testable import Trawl

/// `ProwlarrViewModel`'s indexer state machine: load/partition, the three
/// mutations that PUT or DELETE, connectivity tests, and the four-way error
/// partitioning (`indexer` / `schema` / `search` / `stats`).
///
/// As in `ProwlarrSearchStateTests`, everything runs through the real
/// `ProwlarrAPIClient` resolved by a real `ArrServiceManager`, against a
/// loopback fixture server - so the mutation tests can assert on the JSON the
/// app actually put on the wire rather than on a mock's call log. Bodies are
/// always compared as parsed JSON, never as encoder bytes.
@Suite("Prowlarr indexer state", .serialized)
@MainActor
struct ProwlarrIndexerStateTests {
    // Alpha: enabled torrent, tagged. Beta: disabled usenet. Gamma: enabled,
    // protocol absent (Prowlarr omits it for some definitions) - the input for
    // `otherIndexers`. Returned unsorted so the sort is observable.
    private static var indexerListJSON: String {
        prowlarrJSONArray([
            prowlarrIndexerJSON(id: 3, name: "Gamma", protocolName: nil),
            prowlarrIndexerJSON(id: 1, name: "Alpha", enable: true, protocolName: "torrent", tags: [2, 1]),
            prowlarrIndexerJSON(id: 2, name: "Beta", enable: false, protocolName: "usenet")
        ])
    }

    private static var statusListJSON: String {
        let formatter = ISO8601DateFormatter()
        let future = formatter.string(from: Date().addingTimeInterval(3600))
        let past = formatter.string(from: Date().addingTimeInterval(-3600))
        return """
        [{"id":11,"indexerId":1,"disabledTill":"\(future)"},\
        {"id":12,"indexerId":3,"disabledTill":"\(past)"}]
        """
    }

    private static let statsJSON = """
    {"indexers":[{"indexerId":1,"indexerName":"Alpha","numberOfQueries":42,\
    "numberOfFailedQueries":2,"numberOfGrabs":7,"averageResponseTime":123.0}]}
    """

    private static let tagsJSON = #"[{"id":2,"label":"zeta"},{"id":1,"label":"Alpha"}]"#
    private static let appProfilesJSON = #"[{"id":3,"name":"Zulu"},{"id":2,"name":"Standard"}]"#

    /// Routes the full `loadIndexers()` fan-out. `override` answers first so a
    /// test can fail or rewrite one endpoint without restating the rest.
    private static func loadedHandler(
        override: @escaping @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? = { _ in nil }
    ) -> @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? {
        let indexers = indexerListJSON
        let statuses = statusListJSON
        let stats = statsJSON
        let tags = tagsJSON
        let profiles = appProfilesJSON
        return { request in
            if let response = override(request) { return response }
            switch (request.method, request.path) {
            case ("GET", "/api/v1/indexer"): return .json(indexers)
            case ("GET", "/api/v1/indexerstatus"): return .json(statuses)
            case ("GET", "/api/v1/indexerstats"): return .json(stats)
            case ("GET", "/api/v1/tag"): return .json(tags)
            case ("GET", "/api/v1/appprofile"): return .json(profiles)
            default: return prowlarrDefaultResponse(for: request)
            }
        }
    }

    private func indexer(_ id: Int, in viewModel: ProwlarrViewModel) throws -> ProwlarrIndexer {
        let matches = viewModel.indexers.filter { $0.id == id }
        guard let match = matches.first else { throw ProwlarrFixtureFailure.missingIndexer(id) }
        return match
    }

    // MARK: - Load, partition, availability

    @Test("loadIndexers sorts by name, partitions by protocol, and folds in statuses, tags, profiles and stats")
    func loadIndexersPopulatesEveryDerivedView() async throws {
        let server = try await ProwlarrFixtureServer(label: "indexer-load", handler: Self.loadedHandler())
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            #expect(viewModel.indexers.map { $0.name ?? "" } == ["Alpha", "Beta", "Gamma"])
            #expect(viewModel.items.map(\.id) == [1, 2, 3])
            #expect(viewModel.isLoadingIndexers == false)
            #expect(viewModel.isLoadingStats == false)
            #expect(viewModel.indexerError == nil)
            #expect(viewModel.statsError == nil)

            #expect(viewModel.torrentIndexers.map { $0.name ?? "" } == ["Alpha"])
            #expect(viewModel.usenetIndexers.map { $0.name ?? "" } == ["Beta"])
            #expect(viewModel.otherIndexers.map { $0.name ?? "" } == ["Gamma"])

            // Alpha is enabled but temporarily disabled by Prowlarr, so it is
            // not available; Beta is disabled outright; Gamma's disabledTill
            // has already passed.
            #expect(viewModel.isIndexerTemporarilyDisabled(id: 1) == true)
            #expect(viewModel.isIndexerTemporarilyDisabled(id: 2) == false)
            #expect(viewModel.isIndexerTemporarilyDisabled(id: 3) == false)
            let alpha = try indexer(1, in: viewModel)
            let beta = try indexer(2, in: viewModel)
            let gamma = try indexer(3, in: viewModel)
            #expect(viewModel.isIndexerAvailable(alpha) == false)
            #expect(viewModel.isIndexerAvailable(beta) == false)
            #expect(viewModel.isIndexerAvailable(gamma) == true)
            #expect(viewModel.statusForIndexer(id: 1)?.id == 11)
            #expect(viewModel.statusForIndexer(id: 2) == nil)

            #expect(viewModel.statsForIndexer(id: 1)?.numberOfQueries == 42)
            #expect(viewModel.statsForIndexer(id: 99) == nil)

            #expect(viewModel.availableTags.map(\.label) == ["Alpha", "zeta"])
            #expect(viewModel.appProfiles.map { $0.name ?? "" } == ["Standard", "Zulu"])
            #expect(viewModel.defaultAppProfileID == 2)
            #expect(viewModel.containsIndexer(id: 2) == true)
            #expect(viewModel.containsIndexer(id: 42) == false)
        }
    }

    @Test("A failing indexer list still lets tags and stats load")
    func indexerListFailureDoesNotBlockTagsOrStats() async throws {
        let handler = Self.loadedHandler { request in
            request.path == "/api/v1/indexer" ? .failure(status: 500, message: "indexer list exploded") : nil
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-list-fails", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            let error = try #require(viewModel.indexerError)
            #expect(error.contains("500"))
            #expect(viewModel.indexers.isEmpty)
            #expect(viewModel.isLoadingIndexers == false)
            // Production loads tags and stats after the list precisely so a list
            // failure does not take them down with it.
            #expect(viewModel.statsError == nil)
            #expect(viewModel.statsForIndexer(id: 1)?.numberOfQueries == 42)
            #expect(viewModel.availableTags.map(\.label) == ["Alpha", "zeta"])
        }
    }

    // MARK: - toggleIndexer

    @Test("toggleIndexer PUTs the flipped indexer and then adopts the server's copy")
    func toggleIndexerSendsFlipAndAdoptsServerCopy() async throws {
        let serverCopy = prowlarrIndexerJSON(id: 1, name: "Alpha (server canonical)", enable: false, tags: [2, 1])
        let handler = Self.loadedHandler { request in
            request.method == "PUT" && request.path == "/api/v1/indexer/1" ? .json(serverCopy) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-toggle", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()
            let alpha = try indexer(1, in: viewModel)
            #expect(alpha.enable == true)

            await viewModel.toggleIndexer(alpha)

            let puts = server.requests(path: "/api/v1/indexer/1").filter { $0.method == "PUT" }
            #expect(puts.count == 1)
            let sent = try #require(puts.first)
            let body = try #require(sent.jsonObject())
            #expect(body["id"] as? Int == 1)
            #expect(body["enable"] as? Bool == false)
            #expect(body["name"] as? String == "Alpha")

            // The server's returned record - not the optimistic local copy - is
            // what the list must end up holding.
            let updated = try indexer(1, in: viewModel)
            #expect(updated.enable == false)
            #expect(updated.name == "Alpha (server canonical)")
            #expect(viewModel.indexerError == nil)
            #expect(viewModel.indexers.map(\.id) == [1, 2, 3])
        }
    }

    @Test("A failed toggle reverts the optimistic flip and records an indexer error")
    func failedToggleRevertsLocalState() async throws {
        let handler = Self.loadedHandler { request in
            request.method == "PUT" && request.path == "/api/v1/indexer/1"
                ? .failure(status: 500, message: "could not save indexer")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-toggle-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            let alpha = try indexer(1, in: viewModel)
            await viewModel.toggleIndexer(alpha)

            let putRequests = server.requests(path: "/api/v1/indexer/1")
            let sent = try #require(putRequests.first)
            #expect(sent.jsonObject()?["enable"] as? Bool == false)

            let reverted = try indexer(1, in: viewModel)
            #expect(reverted.enable == true)
            #expect(reverted.name == "Alpha")
            let error = try #require(viewModel.indexerError)
            #expect(error.contains("500"))
            #expect(viewModel.statsError == nil)
            #expect(viewModel.searchError == nil)
        }
    }

    // MARK: - deleteIndexer

    @Test("deleteIndexer removes the row only after the server confirms")
    func deleteIndexerRemovesOnSuccess() async throws {
        let handler = Self.loadedHandler { request in
            request.method == "DELETE" && request.path == "/api/v1/indexer/2" ? .empty : nil
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-delete", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            let beta = try indexer(2, in: viewModel)
            let removed = await viewModel.deleteIndexer(beta)

            #expect(removed == true)
            #expect(viewModel.indexers.map(\.id) == [1, 3])
            #expect(viewModel.containsIndexer(id: 2) == false)
            #expect(viewModel.indexerError == nil)
            #expect(server.requestCount(method: "DELETE", path: "/api/v1/indexer/2") == 1)
        }
    }

    @Test("A failed delete keeps the indexer and records an indexer error")
    func failedDeleteKeepsIndexer() async throws {
        let handler = Self.loadedHandler { request in
            request.method == "DELETE" && request.path == "/api/v1/indexer/2"
                ? .failure(status: 500, message: "delete rejected")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-delete-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            let beta = try indexer(2, in: viewModel)
            let removed = await viewModel.deleteIndexer(beta)

            #expect(removed == false)
            #expect(viewModel.indexers.map(\.id) == [1, 2, 3])
            let error = try #require(viewModel.indexerError)
            #expect(error.contains("500"))
        }
    }

    // MARK: - updateIndexerTags

    @Test("updateIndexerTags PUTs sorted tag ids and adopts the server's copy")
    func updateIndexerTagsSendsSortedTags() async throws {
        let serverCopy = prowlarrIndexerJSON(id: 1, name: "Alpha", enable: true, tags: [3, 7, 9])
        let handler = Self.loadedHandler { request in
            request.method == "PUT" && request.path == "/api/v1/indexer/1" ? .json(serverCopy) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-tags", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            let alpha = try indexer(1, in: viewModel)
            let saved = await viewModel.updateIndexerTags(alpha, tagIDs: [9, 3, 7])

            #expect(saved == true)
            let putRequests = server.requests(path: "/api/v1/indexer/1")
            let sent = try #require(putRequests.first)
            let body = try #require(sent.jsonObject())
            #expect(body["tags"] as? [Int] == [3, 7, 9])
            #expect(body["id"] as? Int == 1)
            let stored = try indexer(1, in: viewModel)
            #expect(stored.tags == [3, 7, 9])
            #expect(viewModel.indexerError == nil)
        }
    }

    @Test("A failed tag update restores the whole indexer list unchanged")
    func failedTagUpdateRestoresList() async throws {
        let handler = Self.loadedHandler { request in
            request.method == "PUT" && request.path == "/api/v1/indexer/1"
                ? .failure(status: 500, message: "tags rejected")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-tags-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            let alpha = try indexer(1, in: viewModel)
            let saved = await viewModel.updateIndexerTags(alpha, tagIDs: [9, 3, 7])

            #expect(saved == false)
            #expect(viewModel.indexers.map(\.id) == [1, 2, 3])
            let restored = try indexer(1, in: viewModel)
            #expect(restored.tags == [2, 1])
            let error = try #require(viewModel.indexerError)
            #expect(error.contains("500"))
        }
    }

    // MARK: - Connectivity tests

    @Test("testIndexer tracks a pass and a fail across two indexers, last outcome winning")
    func testIndexerTracksPerIndexerOutcomes() async throws {
        let handler = Self.loadedHandler { request in
            guard request.method == "POST", request.path == "/api/v1/indexer/test" else { return nil }
            let name = request.jsonObject()?["name"] as? String
            return name == "Beta" ? .failure(status: 500, message: "no results returned") : .empty
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-test", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            let alpha = try indexer(1, in: viewModel)
            await viewModel.testIndexer(alpha)
            #expect(viewModel.testResult == "Alpha passed.")
            #expect(viewModel.testSucceeded == true)
            #expect(viewModel.isTesting == false)

            let beta = try indexer(2, in: viewModel)
            await viewModel.testIndexer(beta)
            let failure = try #require(viewModel.testResult)
            #expect(failure.hasPrefix("Beta failed:"))
            #expect(failure.contains("500"))
            #expect(viewModel.testSucceeded == false)
            #expect(viewModel.isTesting == false)
            // A connectivity test must not write into the indexer error bucket.
            #expect(viewModel.indexerError == nil)

            let testedNames = server.requests(path: "/api/v1/indexer/test").compactMap { $0.jsonObject()?["name"] as? String }
            #expect(testedNames == ["Alpha", "Beta"])

            viewModel.clearTestResult()
            #expect(viewModel.testResult == nil)
            #expect(viewModel.testSucceeded == nil)
        }
    }

    @Test("testAllIndexers reports the loaded indexer count, and resets between a pass and a fail")
    func testAllIndexersReportsCountThenFailure() async throws {
        let calls = ProwlarrCallCounter()
        let handler = Self.loadedHandler { request in
            guard request.path == "/api/v1/indexer/testall" else { return nil }
            return calls.next("testall") == 1 ? .empty : .failure(status: 500, message: "two indexers failed")
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-testall", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            await viewModel.testAllIndexers()
            #expect(viewModel.testResult == "All 3 indexers passed their connectivity tests.")
            #expect(viewModel.testSucceeded == true)

            await viewModel.testAllIndexers()
            let failure = try #require(viewModel.testResult)
            #expect(failure.hasPrefix("One or more indexers failed their test."))
            #expect(failure.contains("500"))
            #expect(viewModel.testSucceeded == false)
            #expect(viewModel.isTesting == false)
            #expect(server.requestCount(method: "POST", path: "/api/v1/indexer/testall") == 2)
        }
    }

    @Test("testAllIndexers uses the singular label for a single indexer")
    func testAllIndexersSingularLabel() async throws {
        let single = prowlarrJSONArray([prowlarrIndexerJSON(id: 1, name: "Alpha")])
        let server = try await ProwlarrFixtureServer(label: "indexer-testall-one") { request in
            switch request.path {
            case "/api/v1/indexer": return .json(single)
            case "/api/v1/indexer/testall": return .empty
            default: return prowlarrDefaultResponse(for: request)
            }
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()
            await viewModel.testAllIndexers()

            #expect(viewModel.testResult == "All 1 indexer passed their connectivity tests.")
            #expect(viewModel.testSucceeded == true)
        }
    }

    // MARK: - Error partitioning

    @Test("An indexer failure and a stats failure are tracked and cleared independently")
    func indexerAndStatsErrorsArePartitioned() async throws {
        let handler = Self.loadedHandler { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v1/indexerstats"): return .failure(status: 503, message: "stats unavailable")
            case ("PUT", "/api/v1/indexer/1"): return .failure(status: 500, message: "could not save indexer")
            default: return nil
            }
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-partition", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()

            // The list loaded; only stats failed.
            #expect(viewModel.indexers.count == 3)
            #expect(viewModel.indexerError == nil)
            let statsError = try #require(viewModel.statsError)
            #expect(statsError.contains("503"))

            let alpha = try indexer(1, in: viewModel)
            await viewModel.toggleIndexer(alpha)
            let indexerError = try #require(viewModel.indexerError)
            #expect(indexerError.contains("500"))
            #expect(viewModel.statsError == statsError)

            viewModel.clearIndexerError()
            #expect(viewModel.indexerError == nil)
            #expect(viewModel.statsError == statsError)
            #expect(viewModel.searchError == nil)
            #expect(viewModel.schemaError == nil)
        }
    }

    @Test("clearTestOutcome clears the test result and the indexer error, leaving stats alone")
    func clearTestOutcomeClearsBothTestAndIndexerErrors() async throws {
        let handler = Self.loadedHandler { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v1/indexerstats"): return .failure(status: 503, message: "stats unavailable")
            case ("PUT", "/api/v1/indexer/1"): return .failure(status: 500, message: "could not save indexer")
            case ("POST", "/api/v1/indexer/test"): return .failure(status: 500, message: "test failed")
            default: return nil
            }
        }
        let server = try await ProwlarrFixtureServer(label: "indexer-clear-outcome", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()
            let alpha = try indexer(1, in: viewModel)
            await viewModel.toggleIndexer(alpha)
            let reverted = try indexer(1, in: viewModel)
            await viewModel.testIndexer(reverted)

            #expect(viewModel.testResult != nil)
            #expect(viewModel.testSucceeded == false)
            #expect(viewModel.indexerError != nil)
            let statsError = try #require(viewModel.statsError)

            viewModel.clearTestOutcome()

            #expect(viewModel.testResult == nil)
            #expect(viewModel.testSucceeded == nil)
            #expect(viewModel.indexerError == nil)
            #expect(viewModel.statsError == statsError)
        }
    }

    // MARK: - Stats

    @Test("loadStats replaces the stats error on a later success")
    func loadStatsRecoversAfterFailure() async throws {
        let calls = ProwlarrCallCounter()
        let stats = Self.statsJSON
        let server = try await ProwlarrFixtureServer(label: "stats-recover") { request in
            guard request.path == "/api/v1/indexerstats" else { return prowlarrDefaultResponse(for: request) }
            return calls.next("stats") == 1 ? .failure(status: 503, message: "stats unavailable") : .json(stats)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)

            await viewModel.loadStats()
            #expect(viewModel.statsError != nil)
            #expect(viewModel.indexerStats == nil)
            #expect(viewModel.isLoadingStats == false)

            await viewModel.loadStats()
            #expect(viewModel.statsError == nil)
            #expect(viewModel.statsForIndexer(id: 1)?.numberOfGrabs == 7)
            #expect(viewModel.isLoadingStats == false)
        }
    }

    // MARK: - Schema

    @Test("loadSchema fetches once; reloadSchema forces a refetch")
    func schemaLoadIsIdempotentUntilReloaded() async throws {
        let schema = prowlarrJSONArray([
            #"{"name":"Zeta Definition","implementation":"Cardigann","configContract":"CardigannSettings"}"#,
            #"{"name":"Alpha Definition","implementation":"Cardigann","configContract":"CardigannSettings"}"#
        ])
        let server = try await ProwlarrFixtureServer(label: "schema-idempotent") { request in
            request.path == "/api/v1/indexer/schema" ? .json(schema) : prowlarrDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)

            await viewModel.loadSchema()
            #expect(viewModel.schemaIndexers.map { $0.name ?? "" } == ["Alpha Definition", "Zeta Definition"])
            #expect(viewModel.isLoadingSchema == false)
            #expect(viewModel.schemaError == nil)

            await viewModel.loadSchema()
            #expect(server.requestCount(path: "/api/v1/indexer/schema") == 1)

            await viewModel.reloadSchema()
            #expect(server.requestCount(path: "/api/v1/indexer/schema") == 2)
            #expect(viewModel.schemaIndexers.count == 2)
        }
    }

    @Test("A schema failure populates only the schema error and leaves the cache empty for a retry")
    func schemaFailureIsPartitionedAndRetryable() async throws {
        let calls = ProwlarrCallCounter()
        let schema = prowlarrJSONArray([#"{"name":"Alpha Definition","implementation":"Cardigann"}"#])
        let server = try await ProwlarrFixtureServer(label: "schema-failure") { request in
            guard request.path == "/api/v1/indexer/schema" else { return prowlarrDefaultResponse(for: request) }
            return calls.next("schema") == 1 ? .failure(status: 500, message: "schema unavailable") : .json(schema)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)

            await viewModel.loadSchema()
            let error = try #require(viewModel.schemaError)
            #expect(error.contains("500"))
            #expect(viewModel.schemaIndexers.isEmpty)
            #expect(viewModel.indexerError == nil)
            #expect(viewModel.statsError == nil)

            // The empty cache means a plain retry is enough to refetch.
            await viewModel.loadSchema()
            #expect(viewModel.schemaError == nil)
            #expect(viewModel.schemaIndexers.map { $0.name ?? "" } == ["Alpha Definition"])
        }
    }

    // MARK: - Disconnected

    @Test("Every indexer entry point is inert without a connected Prowlarr")
    func mutationsAreInertWhenDisconnected() async throws {
        let manager = ArrServiceManager()
        let viewModel = ProwlarrViewModel(serviceManager: manager)
        let orphan = ProwlarrIndexer(
            id: 1,
            name: "Alpha",
            enable: true,
            implementation: nil,
            implementationName: nil,
            configContract: nil,
            infoLink: nil,
            tags: [],
            priority: nil,
            appProfileId: nil,
            shouldSearch: nil,
            supportsRss: nil,
            supportsSearch: nil,
            protocol: .torrent,
            fields: nil
        )

        await viewModel.loadIndexers()
        #expect(viewModel.indexerError == "Prowlarr not connected.")

        viewModel.clearIndexerError()
        await viewModel.toggleIndexer(orphan)
        #expect(viewModel.indexerError == nil)
        #expect(viewModel.indexers.isEmpty)

        let deleted = await viewModel.deleteIndexer(orphan)
        let tagged = await viewModel.updateIndexerTags(orphan, tagIDs: [1])
        let added = await viewModel.addIndexer(orphan)
        #expect(deleted == false)
        #expect(tagged == false)
        #expect(added == false)

        await viewModel.testIndexer(orphan)
        #expect(viewModel.testResult == nil)
        #expect(viewModel.testSucceeded == nil)

        await viewModel.loadSchema()
        #expect(viewModel.schemaError == nil)
        #expect(viewModel.schemaIndexers.isEmpty)

        await viewModel.loadStats()
        #expect(viewModel.statsError == "Prowlarr not connected.")
    }
}
