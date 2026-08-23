import Foundation
import Testing
@testable import Trawl

/// `ProwlarrProxiesViewModel` — the indexer-proxy (Http/Socks4/Socks5/
/// FlareSolverr) half of `ProwlarrViewModel.swift`. Same rules as the other
/// Prowlarr suites: real `ProwlarrAPIClient`, real `ArrServiceManager`,
/// loopback fixture server, request bodies compared as parsed JSON.
@Suite("Prowlarr indexer proxies", .serialized)
@MainActor
struct ProwlarrProxiesStateTests {
    private static let httpProxyJSON = #"{"id":2,"name":"Zeta HTTP","implementation":"Http","implementationName":"Http","configContract":"HttpProxySettings","tags":[],"fields":[]}"#
    private static let socksProxyJSON = #"{"id":1,"name":"Alpha Socks","implementation":"Socks5","implementationName":"Socks5","configContract":"Socks5Settings","tags":[3],"fields":[]}"#

    private static let schemaJSON = prowlarrJSONArray([
        #"{"implementation":"Socks5","implementationName":"Socks5","configContract":"Socks5Settings","fields":[]}"#,
        #"{"implementation":"Http","implementationName":"Http","configContract":"HttpProxySettings","fields":[]}"#,
        #"{"implementation":"FlareSolverr","implementationName":"FlareSolverr","configContract":"FlareSolverrSettings","fields":[]}"#
    ])

    private static let tagsJSON = #"[{"id":2,"label":"zeta"},{"id":1,"label":"Alpha"}]"#

    private static func newProxy() -> ProwlarrIndexerProxy {
        ProwlarrIndexerProxy(
            id: 0,
            name: "New Proxy",
            fields: nil,
            implementationName: "Socks5",
            implementation: "Socks5",
            configContract: "Socks5Settings",
            infoLink: nil,
            message: nil,
            tags: [3],
            presets: nil
        )
    }

    private static func standardHandler(
        override: @escaping @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? = { _ in nil }
    ) -> @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? {
        let proxies = prowlarrJSONArray([httpProxyJSON, socksProxyJSON])
        let schema = schemaJSON
        let tags = tagsJSON
        return { request in
            if let response = override(request) { return response }
            switch (request.method, request.path) {
            case ("GET", "/api/v1/indexerProxy"): return .json(proxies)
            case ("GET", "/api/v1/indexerProxy/schema"): return .json(schema)
            case ("GET", "/api/v1/tag"): return .json(tags)
            default: return prowlarrDefaultResponse(for: request)
            }
        }
    }

    @Test("loadProxies loads unsorted server order, sortedProxies sorts by name, and tags load alongside")
    func loadProxiesAndSortedView() async throws {
        let server = try await ProwlarrFixtureServer(label: "proxies-load", handler: Self.standardHandler())
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)
            await viewModel.loadProxies()

            // Server order preserved in `proxies` itself...
            #expect(viewModel.proxies.map { $0.name ?? "" } == ["Zeta HTTP", "Alpha Socks"])
            // ...but the computed sorted view is alphabetical.
            #expect(viewModel.sortedProxies.map { $0.name ?? "" } == ["Alpha Socks", "Zeta HTTP"])
            #expect(viewModel.availableTags.map(\.label) == ["Alpha", "zeta"])
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.isLoadingProxies == false)
        }
    }

    @Test("A proxies load failure is reported and leaves the list empty")
    func loadProxiesFailureReportsError() async throws {
        let handler = Self.standardHandler { request in
            request.method == "GET" && request.path == "/api/v1/indexerProxy"
                ? .failure(status: 500, message: "proxy list exploded")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "proxies-load-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)
            await viewModel.loadProxies()

            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("500"))
            #expect(viewModel.proxies.isEmpty)
            #expect(viewModel.sortedProxies.isEmpty)
            #expect(viewModel.isLoadingProxies == false)
        }
    }

    @Test("loadSchemaIfNeeded fetches once; reloadSchema forces a refetch, sorted by type name")
    func schemaLoadIsIdempotentUntilReloaded() async throws {
        let schema = Self.schemaJSON
        let server = try await ProwlarrFixtureServer(label: "proxies-schema") { request in
            request.path == "/api/v1/indexerProxy/schema" ? .json(schema) : prowlarrDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)

            await viewModel.loadSchemaIfNeeded()
            #expect(viewModel.sortedSchemas.map(\.typeName) == ["FlareSolverr", "Http", "Socks5"])
            #expect(viewModel.isLoadingSchema == false)
            #expect(viewModel.errorMessage == nil)

            await viewModel.loadSchemaIfNeeded()
            #expect(server.requestCount(path: "/api/v1/indexerProxy/schema") == 1)

            await viewModel.reloadSchema()
            #expect(server.requestCount(path: "/api/v1/indexerProxy/schema") == 2)
            #expect(viewModel.sortedSchemas.count == 3)

            let socksSchema = try #require(viewModel.schemaProxies.first { $0.implementation == "Socks5" })
            let matched = viewModel.schema(matching: socksSchema)
            #expect(matched?.implementation == "Socks5")
        }
    }

    @Test("Saving a new proxy POSTs it and refreshes the list from the server")
    func saveNewProxyPosts() async throws {
        let created = #"{"id":9,"name":"New Proxy","implementation":"Socks5","implementationName":"Socks5","configContract":"Socks5Settings","tags":[3],"fields":[]}"#
        let handler = Self.standardHandler { request in
            request.method == "POST" && request.path == "/api/v1/indexerProxy" ? .json(created) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "proxies-create", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)

            let saved = await viewModel.saveProxy(Self.newProxy())

            #expect(saved == true)
            #expect(viewModel.errorMessage == nil)
            let posts = server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/indexerProxy" }
            #expect(posts.count == 1)
            let sent = try #require(posts.first)
            let body = try #require(sent.jsonObject())
            #expect(body["id"] as? Int == 0)
            #expect(body["name"] as? String == "New Proxy")
            #expect(body["implementation"] as? String == "Socks5")
            #expect(body["tags"] as? [Int] == [3])
            #expect(server.requests.filter { $0.method == "PUT" }.isEmpty)
            // The save refreshed the list from the server.
            #expect(server.requestCount(method: "GET", path: "/api/v1/indexerProxy") == 1)
        }
    }

    @Test("Saving an existing proxy PUTs to its id")
    func saveExistingProxyPuts() async throws {
        let updatedProxy = #"{"id":1,"name":"Alpha Renamed","implementation":"Socks5","implementationName":"Socks5","configContract":"Socks5Settings","tags":[3],"fields":[]}"#
        let handler = Self.standardHandler { request in
            request.method == "PUT" && request.path == "/api/v1/indexerProxy/1" ? .json(updatedProxy) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "proxies-update", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)
            await viewModel.loadProxies()
            let matches = viewModel.proxies.filter { $0.id == 1 }
            var existing = try #require(matches.first)
            existing.name = "Alpha Renamed"

            let saved = await viewModel.saveProxy(existing)

            #expect(saved == true)
            let puts = server.requests.filter { $0.method == "PUT" }
            #expect(puts.count == 1)
            let sent = try #require(puts.first)
            #expect(sent.path == "/api/v1/indexerProxy/1")
            let body = try #require(sent.jsonObject())
            #expect(body["id"] as? Int == 1)
            #expect(body["name"] as? String == "Alpha Renamed")
            #expect(server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/indexerProxy" }.isEmpty)
        }
    }

    @Test("A failed save reports the error and does not refresh the list")
    func failedSaveSkipsRefresh() async throws {
        let handler = Self.standardHandler { request in
            request.method == "POST" && request.path == "/api/v1/indexerProxy"
                ? .failure(status: 400, message: "proxy rejected")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "proxies-create-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)
            await viewModel.loadProxies()
            let getsBeforeSave = server.requestCount(method: "GET", path: "/api/v1/indexerProxy")

            let saved = await viewModel.saveProxy(Self.newProxy())

            #expect(saved == false)
            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("400"))
            #expect(server.requestCount(method: "GET", path: "/api/v1/indexerProxy") == getsBeforeSave)

            viewModel.clearError()
            #expect(viewModel.errorMessage == nil)
        }
    }

    @Test("deleteProxy drops the row only when the server confirms")
    func deleteProxyRemovesOnlyOnSuccess() async throws {
        let calls = ProwlarrCallCounter()
        let handler = Self.standardHandler { request in
            guard request.method == "DELETE", request.path == "/api/v1/indexerProxy/1" else { return nil }
            return calls.next("delete") == 1 ? .failure(status: 500, message: "delete rejected") : .empty
        }
        let server = try await ProwlarrFixtureServer(label: "proxies-delete", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)
            await viewModel.loadProxies()
            let matches = viewModel.proxies.filter { $0.id == 1 }
            let target = try #require(matches.first)

            let firstAttempt = await viewModel.deleteProxy(target)
            #expect(firstAttempt == false)
            #expect(viewModel.proxies.map(\.id).sorted() == [1, 2])
            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("500"))

            let secondAttempt = await viewModel.deleteProxy(target)
            #expect(secondAttempt == true)
            #expect(viewModel.proxies.map(\.id) == [2])
            #expect(viewModel.errorMessage == nil)
            #expect(server.requestCount(method: "DELETE", path: "/api/v1/indexerProxy/1") == 2)
        }
    }

    @Test("testProxy tracks isTesting and reports a failure's message")
    func testProxyTracksOutcome() async throws {
        let calls = ProwlarrCallCounter()
        let handler = Self.standardHandler { request in
            guard request.method == "POST", request.path == "/api/v1/indexerProxy/test" else { return nil }
            return calls.next("test") == 1 ? .empty : .failure(status: 500, message: "proxy unreachable")
        }
        let server = try await ProwlarrFixtureServer(label: "proxies-test", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)
            await viewModel.loadProxies()
            let matches = viewModel.proxies.filter { $0.id == 1 }
            let target = try #require(matches.first)

            let firstResult = await viewModel.testProxy(target)
            #expect(firstResult == true)
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.isTesting == false)

            let secondResult = await viewModel.testProxy(target)
            #expect(secondResult == false)
            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("500"))
            #expect(viewModel.isTesting == false)
            #expect(server.requestCount(method: "POST", path: "/api/v1/indexerProxy/test") == 2)
        }
    }

    @Test("Every proxies entry point reports the disconnected state")
    func entryPointsReportDisconnected() async throws {
        let manager = ArrServiceManager()
        let viewModel = ProwlarrProxiesViewModel(serviceManager: manager)

        await viewModel.loadProxies()
        #expect(viewModel.errorMessage == "Prowlarr not connected.")
        #expect(viewModel.proxies.isEmpty)

        viewModel.clearError()
        await viewModel.reloadSchema()
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        viewModel.clearError()
        let saved = await viewModel.saveProxy(Self.newProxy())
        #expect(saved == false)
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        viewModel.clearError()
        let deleted = await viewModel.deleteProxy(Self.newProxy())
        #expect(deleted == false)
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        viewModel.clearError()
        let tested = await viewModel.testProxy(Self.newProxy())
        #expect(tested == false)
        #expect(viewModel.errorMessage == "Prowlarr not connected.")
    }
}
