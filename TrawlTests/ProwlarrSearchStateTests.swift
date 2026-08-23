import Foundation
import Testing
@testable import Trawl

/// `ProwlarrViewModel.performSearch()` + `StreamingSearchTracker`.
///
/// Every test here drives the real `ProwlarrAPIClient`, resolved through a real
/// `ArrServiceManager.connectService`, against a loopback fixture server. No
/// protocol fake is substituted for the client: a test that conformed a stub to
/// `IndexerCapableClient` and asserted the stub was called would prove nothing
/// about the request that leaves the app or the payload it parses.
///
/// Ordering barriers are the fixture server's own `waitForRequests` /
/// `releaseParked`, never sleeps. The 40ms per-item pacing inside
/// `StreamingSearchTracker.stream` is production's own; tests simply `await`
/// `performSearch()` and keep payloads small.
@Suite("Prowlarr search state", .serialized)
@MainActor
struct ProwlarrSearchStateTests {
    private static let alphaOne = prowlarrSearchResultJSON(guid: "alpha-1", title: "Alpha Release 1", indexerId: 1, indexer: "Alpha")
    private static let betaOne = prowlarrSearchResultJSON(guid: "beta-1", title: "Beta Release 1", indexerId: 2, indexer: "Beta")
    private static let alphaTwo = prowlarrSearchResultJSON(guid: "alpha-2", title: "Alpha Release 2", indexerId: 1, indexer: "Alpha")

    @Test("A search streams every returned release into searchResults and sends the trimmed query")
    func searchAccumulatesResultsAcrossIndexers() async throws {
        let payload = prowlarrJSONArray([Self.alphaOne, Self.betaOne, Self.alphaTwo])
        let server = try await ProwlarrFixtureServer(label: "search-accumulate") { request in
            if request.path == "/api/v1/search" { return .json(payload) }
            return prowlarrDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            viewModel.searchQuery = "  ubuntu 24.04  "
            viewModel.searchType = .tvsearch
            viewModel.selectedIndexerIds = [1, 2]

            await viewModel.performSearch()

            #expect(viewModel.searchResults.map(\.title) == ["Alpha Release 1", "Beta Release 1", "Alpha Release 2"])
            #expect(viewModel.searchResults.compactMap(\.indexerId) == [1, 2, 1])
            #expect(viewModel.isSearching == false)
            #expect(viewModel.searchError == nil)

            let searchRequests = server.requests(path: "/api/v1/search")
            #expect(searchRequests.count == 1)
            let sent = try #require(searchRequests.first)
            #expect(sent.method == "GET")
            #expect(sent.queryValue("query") == "ubuntu 24.04")
            #expect(sent.queryValue("type") == "tvsearch")
            #expect(Set(sent.queryValues("indexerIds")) == ["1", "2"])
            #expect(sent.apiKey == "prowlarr-fixture-key")
        }
    }

    @Test("Releases from the indexers that answered survive an indexer that failed")
    func partialIndexerCoverageStillYieldsResults() async throws {
        // Prowlarr answers 200 with only the rows from the indexers that
        // succeeded when one of the queried indexers errors, so this is the
        // shape the view model actually has to survive: both indexers asked
        // for, only one represented in the payload, and no error raised.
        let payload = prowlarrJSONArray([Self.betaOne])
        let server = try await ProwlarrFixtureServer(label: "search-partial") { request in
            if request.path == "/api/v1/search" { return .json(payload) }
            return prowlarrDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            viewModel.searchQuery = "ubuntu"
            viewModel.selectedIndexerIds = [1, 2]

            await viewModel.performSearch()

            #expect(viewModel.searchResults.map(\.title) == ["Beta Release 1"])
            #expect(viewModel.searchError == nil)
            #expect(viewModel.isSearching == false)

            let sent = try #require(server.requests(path: "/api/v1/search").first)
            #expect(Set(sent.queryValues("indexerIds")) == ["1", "2"])
        }
    }

    @Test("A blank query issues no request and leaves the previous results in place")
    func blankQueryIsIgnored() async throws {
        let payload = prowlarrJSONArray([Self.alphaOne])
        let server = try await ProwlarrFixtureServer(label: "search-blank") { request in
            if request.path == "/api/v1/search" { return .json(payload) }
            return prowlarrDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            viewModel.searchQuery = "ubuntu"
            await viewModel.performSearch()
            #expect(viewModel.searchResults.count == 1)

            viewModel.searchQuery = "   \n "
            await viewModel.performSearch()

            #expect(viewModel.searchResults.map(\.title) == ["Alpha Release 1"])
            #expect(server.requestCount(path: "/api/v1/search") == 1)
            #expect(viewModel.searchError == nil)
        }
    }

    @Test("A superseded search does not overwrite the results of the search that replaced it")
    func supersededSearchDiscardsItsResults() async throws {
        let firstPayload = prowlarrJSONArray([Self.alphaOne, Self.alphaTwo])
        let secondPayload = prowlarrJSONArray([Self.betaOne])
        let calls = ProwlarrCallCounter()
        let server = try await ProwlarrFixtureServer(label: "search-superseded") { request in
            guard request.path == "/api/v1/search" else { return prowlarrDefaultResponse(for: request) }
            // Park the first search so it is still in flight when the second
            // one begins; answer the second immediately.
            return calls.next("search") == 1 ? nil : .json(secondPayload)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)

            viewModel.searchQuery = "first query"
            let firstSearch = Task { await viewModel.performSearch() }
            // Barrier: the first request has reached the socket, so the second
            // search is genuinely the later one. No sleeping involved.
            await server.waitForRequests(path: "/api/v1/search", count: 1)

            viewModel.searchQuery = "second query"
            await viewModel.performSearch()
            #expect(viewModel.searchResults.map(\.title) == ["Beta Release 1"])

            server.releaseParked(with: .json(firstPayload))
            await firstSearch.value

            #expect(viewModel.searchResults.map(\.title) == ["Beta Release 1"])
            #expect(viewModel.isSearching == false)
            #expect(viewModel.searchError == nil)

            let queries = server.requests(path: "/api/v1/search").compactMap { $0.queryValue("query") }
            #expect(queries == ["first query", "second query"])
        }
    }

    @Test("clearSearch abandons an in-flight search so its results never land")
    func clearSearchAbandonsInFlightSearch() async throws {
        let payload = prowlarrJSONArray([Self.alphaOne, Self.alphaTwo])
        let server = try await ProwlarrFixtureServer(label: "search-cleared") { request in
            // Park every search: the request is recorded but never answered
            // until the test releases it.
            if request.path == "/api/v1/search" { return nil }
            return prowlarrDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            viewModel.searchQuery = "ubuntu"
            let inFlight = Task { await viewModel.performSearch() }
            await server.waitForRequests(path: "/api/v1/search", count: 1)

            viewModel.clearSearch()
            #expect(viewModel.isSearching == false)
            #expect(viewModel.searchQuery.isEmpty)

            server.releaseParked(with: .json(payload))
            await inFlight.value

            #expect(viewModel.searchResults.isEmpty)
            #expect(viewModel.isSearching == false)
            #expect(viewModel.searchError == nil)
        }
    }

    @Test("A search failure populates only the search error, and other loads neither clear nor inherit it")
    func searchErrorIsPartitionedFromTheOtherOperations() async throws {
        let indexers = prowlarrJSONArray([prowlarrIndexerJSON(id: 1, name: "Alpha")])
        let server = try await ProwlarrFixtureServer(label: "search-error") { request in
            switch request.path {
            case "/api/v1/search":
                return .failure(status: 500, message: "indexer query failed")
            case "/api/v1/indexer":
                return .json(indexers)
            default:
                return prowlarrDefaultResponse(for: request)
            }
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrViewModel(serviceManager: manager)
            await viewModel.loadIndexers()
            #expect(viewModel.indexerError == nil)

            viewModel.searchQuery = "ubuntu"
            await viewModel.performSearch()

            let searchError = try #require(viewModel.searchError)
            #expect(searchError.contains("500"))
            #expect(viewModel.searchResults.isEmpty)
            #expect(viewModel.isSearching == false)
            // A search failure must not leak into the other three buckets.
            #expect(viewModel.indexerError == nil)
            #expect(viewModel.statsError == nil)
            #expect(viewModel.schemaError == nil)

            // Nor may a later successful load silently clear it.
            await viewModel.loadIndexers()
            #expect(viewModel.indexerError == nil)
            #expect(viewModel.searchError == searchError)

            // clearSearch is the only thing that clears it.
            viewModel.clearSearch()
            #expect(viewModel.searchError == nil)
        }
    }

    @Test("Search without a connected Prowlarr reports the disconnected state and issues nothing")
    func searchWithoutClientReportsDisconnected() async throws {
        let manager = ArrServiceManager()
        #expect(manager.prowlarrClient == nil)
        let viewModel = ProwlarrViewModel(serviceManager: manager)
        viewModel.searchQuery = "ubuntu"

        await viewModel.performSearch()

        #expect(viewModel.searchError == "Prowlarr not connected.")
        #expect(viewModel.searchResults.isEmpty)
        #expect(viewModel.isSearching == false)
        #expect(viewModel.indexerError == nil)
        #expect(viewModel.statsError == nil)
    }
}
