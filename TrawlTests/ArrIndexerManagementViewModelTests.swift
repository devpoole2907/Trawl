import Foundation
import Testing
@testable import Trawl

/// `ArrIndexerManagementViewModel` - the Sonarr/Radarr indexer manager at the
/// bottom of `ProwlarrViewModel.swift`. Every mutation is keyed by
/// `(profileID, serviceType)` and resolved to a real `SonarrAPIClient` /
/// `RadarrAPIClient` through a real `ArrServiceManager.connectService`
/// against loopback fixture servers - never a protocol fake standing in for
/// the client. The highest-value behaviour under test is instance routing:
/// with two connected instances of the *same* service type, an operation
/// addressed to one profile must never reach the other profile's socket,
/// since misrouting there would silently edit the wrong server's indexers.
@Suite("Arr indexer management routing", .serialized)
@MainActor
struct ArrIndexerManagementViewModelTests {
    // MARK: - Load, per profile

    @Test("loadIndexers sorts by name and stores each profile's result under its own key only")
    func loadIndexersStoresPerProfile() async throws {
        let listA = arrJSONArray([
            arrManagedIndexerJSON(id: 2, name: "Zeta"),
            arrManagedIndexerJSON(id: 1, name: "Alpha")
        ])
        let listB = arrJSONArray([arrManagedIndexerJSON(id: 3, name: "Beta")])
        let serverA = try await ArrIndexerFixtureServer(label: "load-a") { request in
            request.path == "/api/v3/indexer" ? .json(listA) : arrIndexerDefaultResponse(for: request)
        }
        let serverB = try await ArrIndexerFixtureServer(label: "load-b") { request in
            request.path == "/api/v3/indexer" ? .json(listB) : arrIndexerDefaultResponse(for: request)
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)

            await viewModel.loadIndexers(for: profileA.id, serviceType: .sonarr)
            await viewModel.loadIndexers(for: profileB.id, serviceType: .sonarr)

            #expect(viewModel.indexers(for: profileA.id, serviceType: .sonarr).map { $0.name ?? "" } == ["Alpha", "Zeta"])
            #expect(viewModel.indexers(for: profileB.id, serviceType: .sonarr).map { $0.name ?? "" } == ["Beta"])
            #expect(viewModel.error(for: profileA.id) == nil)
            #expect(viewModel.error(for: profileB.id) == nil)
            #expect(viewModel.isLoadingIndexers(for: profileA.id) == false)
            #expect(serverA.requestCount(method: "GET", path: "/api/v3/indexer") == 1)
            #expect(serverB.requestCount(method: "GET", path: "/api/v3/indexer") == 1)
        }
    }

    @Test("loadAllIndexers fans out to every connected Sonarr and Radarr instance without cross-contamination")
    func loadAllIndexersFansOutByServiceTypeAndProfile() async throws {
        let sonarrList = arrJSONArray([arrManagedIndexerJSON(id: 1, name: "SonarrOne")])
        let radarrList = arrJSONArray([arrManagedIndexerJSON(id: 1, name: "RadarrOne")])
        let sonarrServer = try await ArrIndexerFixtureServer(label: "fanout-sonarr") { request in
            request.path == "/api/v3/indexer" ? .json(sonarrList) : arrIndexerDefaultResponse(for: request)
        }
        let radarrServer = try await ArrIndexerFixtureServer(label: "fanout-radarr") { request in
            request.path == "/api/v3/indexer" ? .json(radarrList) : arrIndexerDefaultResponse(for: request)
        }
        defer { sonarrServer.stop(); radarrServer.stop() }

        try await withConnectedArrInstances([
            .init(sonarrServer, .sonarr, "Sonarr"),
            .init(radarrServer, .radarr, "Radarr")
        ]) { manager, profiles in
            let sonarrProfile = profiles[0]
            let radarrProfile = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)

            await viewModel.loadAllIndexers()

            #expect(viewModel.indexers(for: sonarrProfile.id, serviceType: .sonarr).map { $0.name ?? "" } == ["SonarrOne"])
            #expect(viewModel.indexers(for: radarrProfile.id, serviceType: .radarr).map { $0.name ?? "" } == ["RadarrOne"])
            // Same numeric id (1) on both servers - a keying bug (e.g. keyed by
            // indexer id instead of profile id) would smear one service's list
            // into the other's slot. It must not.
            #expect(viewModel.sonarrIndexersByProfileID[radarrProfile.id] == nil)
            #expect(viewModel.radarrIndexersByProfileID[sonarrProfile.id] == nil)
            #expect(sonarrServer.requestCount(method: "GET", path: "/api/v3/indexer") == 1)
            #expect(radarrServer.requestCount(method: "GET", path: "/api/v3/indexer") == 1)
        }
    }

    // MARK: - Instance routing: add / update / delete / test

    @Test("addIndexer POSTs to the addressed instance only, with the other connected instance untouched")
    func addIndexerRoutesToAddressedInstanceOnly() async throws {
        let created = arrManagedIndexerJSON(id: 9, name: "New Indexer")
        let serverA = try await ArrIndexerFixtureServer(label: "add-a") { request in
            request.method == "POST" && request.path == "/api/v3/indexer" ? .json(created) : arrIndexerDefaultResponse(for: request)
        }
        let serverB = try await ArrIndexerFixtureServer(label: "add-b") { request in
            arrIndexerDefaultResponse(for: request)
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
            let newIndexer = makeTestArrManagedIndexer(id: 0, name: "New Indexer")

            let added = await viewModel.addIndexer(newIndexer, for: profileA.id, serviceType: .sonarr)

            #expect(added == true)
            #expect(viewModel.error(for: profileA.id) == nil)
            #expect(serverA.requestCount(method: "POST", path: "/api/v3/indexer") == 1)
            // The routing assertion: profile B's socket must never see this POST.
            #expect(serverB.requestCount(method: "POST", path: "/api/v3/indexer") == 0)

            let sent = try #require(serverA.requests(path: "/api/v3/indexer").first { $0.method == "POST" })
            #expect(sent.jsonObject()?["name"] as? String == "New Indexer")

            #expect(viewModel.indexers(for: profileA.id, serviceType: .sonarr).map(\.id) == [9])
            #expect(viewModel.indexers(for: profileB.id, serviceType: .sonarr).isEmpty)
        }
    }

    @Test("updateIndexer PUTs to the addressed instance only, with the other connected instance untouched")
    func updateIndexerRoutesToAddressedInstanceOnly() async throws {
        let initialList = arrJSONArray([arrManagedIndexerJSON(id: 1, name: "Alpha")])
        let updated = arrManagedIndexerJSON(id: 1, name: "Alpha Renamed")
        let serverA = try await ArrIndexerFixtureServer(label: "update-a") { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v3/indexer"): return .json(initialList)
            case ("PUT", "/api/v3/indexer/1"): return .json(updated)
            default: return arrIndexerDefaultResponse(for: request)
            }
        }
        let serverB = try await ArrIndexerFixtureServer(label: "update-b") { request in
            arrIndexerDefaultResponse(for: request)
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
            await viewModel.loadIndexers(for: profileA.id, serviceType: .sonarr)
            let alpha = makeTestArrManagedIndexer(id: 1, name: "Alpha Renamed")

            let saved = await viewModel.updateIndexer(alpha, for: profileA.id, serviceType: .sonarr)

            #expect(saved == true)
            #expect(serverA.requestCount(method: "PUT", path: "/api/v3/indexer/1") == 1)
            #expect(serverB.requestCount(method: "PUT", path: "/api/v3/indexer/1") == 0)
            #expect(viewModel.indexers(for: profileA.id, serviceType: .sonarr).map { $0.name ?? "" } == ["Alpha Renamed"])
            #expect(viewModel.indexers(for: profileB.id, serviceType: .sonarr).isEmpty)
        }
    }

    // The two tests above address the *first-connected* profile, which is also the
    // manager's active instance - so a profile-blind client lookup would still
    // route them correctly and they would pass under that bug. These two address
    // the non-active profile instead, which is the case that actually breaks.
    // Creating or renaming an indexer on the wrong server is the most destructive
    // form of misrouting here, so it gets the same non-active-profile treatment
    // the read and delete paths already have.

    @Test("addIndexer POSTs to a non-active instance, the case a profile-blind lookup would misroute")
    func addIndexerRoutesToNonActiveInstance() async throws {
        let created = arrManagedIndexerJSON(id: 9, name: "New Indexer")
        let serverA = try await ArrIndexerFixtureServer(label: "add-nonactive-a") { request in
            arrIndexerDefaultResponse(for: request)
        }
        let serverB = try await ArrIndexerFixtureServer(label: "add-nonactive-b") { request in
            request.method == "POST" && request.path == "/api/v3/indexer" ? .json(created) : arrIndexerDefaultResponse(for: request)
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
            let newIndexer = makeTestArrManagedIndexer(id: 0, name: "New Indexer")

            let added = await viewModel.addIndexer(newIndexer, for: profileB.id, serviceType: .sonarr)

            #expect(added == true)
            #expect(viewModel.error(for: profileB.id) == nil)
            #expect(serverB.requestCount(method: "POST", path: "/api/v3/indexer") == 1)
            // Server A is the active instance. It must not receive the write.
            #expect(serverA.requestCount(method: "POST", path: "/api/v3/indexer") == 0)

            let sentToB = try #require(serverB.requests(path: "/api/v3/indexer").first { $0.method == "POST" })
            #expect(sentToB.jsonObject()?["name"] as? String == "New Indexer")

            #expect(viewModel.indexers(for: profileB.id, serviceType: .sonarr).map(\.id) == [9])
            #expect(viewModel.indexers(for: profileA.id, serviceType: .sonarr).isEmpty)
        }
    }

    @Test("updateIndexer PUTs to a non-active instance, the case a profile-blind lookup would misroute")
    func updateIndexerRoutesToNonActiveInstance() async throws {
        let initialList = arrJSONArray([arrManagedIndexerJSON(id: 1, name: "Alpha")])
        let updated = arrManagedIndexerJSON(id: 1, name: "Alpha Renamed")
        let serverA = try await ArrIndexerFixtureServer(label: "update-nonactive-a") { request in
            arrIndexerDefaultResponse(for: request)
        }
        let serverB = try await ArrIndexerFixtureServer(label: "update-nonactive-b") { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v3/indexer"): return .json(initialList)
            case ("PUT", "/api/v3/indexer/1"): return .json(updated)
            default: return arrIndexerDefaultResponse(for: request)
            }
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
            await viewModel.loadIndexers(for: profileB.id, serviceType: .sonarr)
            let alpha = makeTestArrManagedIndexer(id: 1, name: "Alpha Renamed")

            let saved = await viewModel.updateIndexer(alpha, for: profileB.id, serviceType: .sonarr)

            #expect(saved == true)
            #expect(serverB.requestCount(method: "PUT", path: "/api/v3/indexer/1") == 1)
            #expect(serverA.requestCount(method: "PUT", path: "/api/v3/indexer/1") == 0)
            #expect(viewModel.indexers(for: profileB.id, serviceType: .sonarr).map { $0.name ?? "" } == ["Alpha Renamed"])
            #expect(viewModel.indexers(for: profileA.id, serviceType: .sonarr).isEmpty)
        }
    }

    @Test("deleteIndexer DELETEs the addressed instance only, and only that profile's list loses the row")
    func deleteIndexerRoutesToAddressedInstanceOnly() async throws {
        let listA = arrJSONArray([arrManagedIndexerJSON(id: 1, name: "Alpha")])
        let listB = arrJSONArray([arrManagedIndexerJSON(id: 1, name: "Alpha On B")])
        let serverA = try await ArrIndexerFixtureServer(label: "delete-a") { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v3/indexer"): return .json(listA)
            case ("DELETE", "/api/v3/indexer/1"): return .empty
            default: return arrIndexerDefaultResponse(for: request)
            }
        }
        let serverB = try await ArrIndexerFixtureServer(label: "delete-b") { request in
            request.path == "/api/v3/indexer" ? .json(listB) : arrIndexerDefaultResponse(for: request)
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
            await viewModel.loadIndexers(for: profileA.id, serviceType: .sonarr)
            await viewModel.loadIndexers(for: profileB.id, serviceType: .sonarr)
            // Both profiles happen to hold an indexer with the same id (1) -
            // exactly the shape that would expose a delete keyed on indexer id
            // rather than on (profileID, id).
            let alphaOnA = try #require(viewModel.indexers(for: profileA.id, serviceType: .sonarr).first)

            let removed = await viewModel.deleteIndexer(alphaOnA, for: profileA.id, serviceType: .sonarr)

            #expect(removed == true)
            #expect(serverA.requestCount(method: "DELETE", path: "/api/v3/indexer/1") == 1)
            #expect(serverB.requestCount(method: "DELETE", path: "/api/v3/indexer/1") == 0)
            #expect(viewModel.indexers(for: profileA.id, serviceType: .sonarr).isEmpty)
            // Profile B's own same-id row must survive untouched.
            #expect(viewModel.indexers(for: profileB.id, serviceType: .sonarr).map { $0.name ?? "" } == ["Alpha On B"])
        }
    }

    @Test("testIndexer routes each profile's connectivity test to its own instance and tracks pass/fail independently")
    func testIndexerRoutesToAddressedInstanceOnly() async throws {
        let serverA = try await ArrIndexerFixtureServer(label: "test-a") { request in
            request.method == "POST" && request.path == "/api/v3/indexer/test" ? .empty : arrIndexerDefaultResponse(for: request)
        }
        let serverB = try await ArrIndexerFixtureServer(label: "test-b") { request in
            request.method == "POST" && request.path == "/api/v3/indexer/test"
                ? .failure(status: 500, message: "no results returned")
                : arrIndexerDefaultResponse(for: request)
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
            let alpha = makeTestArrManagedIndexer(id: 1, name: "Alpha")
            let beta = makeTestArrManagedIndexer(id: 2, name: "Beta")

            await viewModel.testIndexer(alpha, for: profileA.id, serviceType: .sonarr)
            #expect(viewModel.testResult == "Alpha passed.")
            #expect(viewModel.testSucceeded == true)
            #expect(serverA.requestCount(method: "POST", path: "/api/v3/indexer/test") == 1)
            #expect(serverB.requestCount(method: "POST", path: "/api/v3/indexer/test") == 0)

            await viewModel.testIndexer(beta, for: profileB.id, serviceType: .sonarr)
            let failure = try #require(viewModel.testResult)
            #expect(failure.hasPrefix("Beta failed:"))
            #expect(failure.contains("500"))
            #expect(viewModel.testSucceeded == false)
            // Profile A's server must not have received a second test call.
            #expect(serverA.requestCount(method: "POST", path: "/api/v3/indexer/test") == 1)
            #expect(serverB.requestCount(method: "POST", path: "/api/v3/indexer/test") == 1)
            #expect(viewModel.isTesting == false)

            viewModel.clearTestResult()
            #expect(viewModel.testResult == nil)
            #expect(viewModel.testSucceeded == nil)
        }
    }

    // MARK: - Schema, per profile

    @Test("loadSchema fetches once per profile, force refetches, and each profile is independent")
    func loadSchemaIsIdempotentPerProfileUntilForced() async throws {
        let schemaA = arrJSONArray([#"{"name":"Newznab","implementation":"Newznab","configContract":"NewznabSettings"}"#])
        let schemaB = arrJSONArray([#"{"name":"Torznab","implementation":"Torznab","configContract":"TorznabSettings"}"#])
        let serverA = try await ArrIndexerFixtureServer(label: "schema-a") { request in
            request.path == "/api/v3/indexer/schema" ? .json(schemaA) : arrIndexerDefaultResponse(for: request)
        }
        let serverB = try await ArrIndexerFixtureServer(label: "schema-b") { request in
            request.path == "/api/v3/indexer/schema" ? .json(schemaB) : arrIndexerDefaultResponse(for: request)
        }
        defer { serverA.stop(); serverB.stop() }

        try await withConnectedArrInstances([
            .init(serverA, .sonarr, "Sonarr Main"),
            .init(serverB, .sonarr, "Sonarr Backup")
        ]) { manager, profiles in
            let profileA = profiles[0]
            let profileB = profiles[1]
            let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)

            await viewModel.loadSchema(for: profileA.id, serviceType: .sonarr)
            #expect(viewModel.schema(for: profileA.id).map { $0.name ?? "" } == ["Newznab"])
            #expect(viewModel.schemaError(for: profileA.id) == nil)

            await viewModel.loadSchema(for: profileA.id, serviceType: .sonarr)
            #expect(serverA.requestCount(path: "/api/v3/indexer/schema") == 1)

            await viewModel.loadSchema(for: profileB.id, serviceType: .sonarr)
            #expect(viewModel.schema(for: profileB.id).map { $0.name ?? "" } == ["Torznab"])
            #expect(serverB.requestCount(path: "/api/v3/indexer/schema") == 1)
            // A's cache must be untouched by B's fetch.
            #expect(viewModel.schema(for: profileA.id).map { $0.name ?? "" } == ["Newznab"])

            await viewModel.loadSchema(for: profileA.id, serviceType: .sonarr, force: true)
            #expect(serverA.requestCount(path: "/api/v3/indexer/schema") == 2)
        }
    }

    // MARK: - Disconnected / unresolvable profile

    @Test("Every entry point reports noServiceConfigured for a profile with no connected client")
    func unresolvableProfileReportsNoServiceConfigured() async throws {
        let manager = ArrServiceManager()
        let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
        let orphanID = UUID()
        let orphanIndexer = makeTestArrManagedIndexer(id: 1, name: "Orphan")
        let noServiceMessage = ArrError.noServiceConfigured.localizedDescription

        await viewModel.loadIndexers(for: orphanID, serviceType: .sonarr)
        #expect(viewModel.error(for: orphanID) == noServiceMessage)
        #expect(viewModel.indexers(for: orphanID, serviceType: .sonarr).isEmpty)
        #expect(viewModel.isLoadingIndexers(for: orphanID) == false)

        await viewModel.loadSchema(for: orphanID, serviceType: .radarr)
        #expect(viewModel.schemaError(for: orphanID) == noServiceMessage)
        #expect(viewModel.schema(for: orphanID).isEmpty)

        let added = await viewModel.addIndexer(orphanIndexer, for: orphanID, serviceType: .sonarr)
        #expect(added == false)
        #expect(viewModel.error(for: orphanID) == noServiceMessage)

        let updated = await viewModel.updateIndexer(orphanIndexer, for: orphanID, serviceType: .radarr)
        #expect(updated == false)
        #expect(viewModel.error(for: orphanID) == noServiceMessage)

        let deleted = await viewModel.deleteIndexer(orphanIndexer, for: orphanID, serviceType: .sonarr)
        #expect(deleted == false)
        #expect(viewModel.error(for: orphanID) == noServiceMessage)

        await viewModel.testIndexer(orphanIndexer, for: orphanID, serviceType: .sonarr)
        let failure = try #require(viewModel.testResult)
        #expect(failure.contains(noServiceMessage))
        #expect(viewModel.testSucceeded == false)
    }

    @Test("Prowlarr and Bazarr profiles report unsupportedIndexerService rather than attempting a request")
    func unsupportedServiceTypesReportTheirOwnError() async throws {
        let manager = ArrServiceManager()
        let viewModel = ArrIndexerManagementViewModel(serviceManager: manager)
        let profileID = UUID()
        let indexer = makeTestArrManagedIndexer(id: 1, name: "Whatever")

        let prowlarrAdded = await viewModel.addIndexer(indexer, for: profileID, serviceType: .prowlarr)
        #expect(prowlarrAdded == false)
        #expect(viewModel.error(for: profileID) == ArrError.unsupportedIndexerService(ArrServiceType.prowlarr.displayName).localizedDescription)

        let bazarrAdded = await viewModel.addIndexer(indexer, for: profileID, serviceType: .bazarr)
        #expect(bazarrAdded == false)
        #expect(viewModel.error(for: profileID) == ArrError.unsupportedIndexerService(ArrServiceType.bazarr.displayName).localizedDescription)

        // loadIndexers/loadSchema short-circuit before ever reaching
        // withIndexerClient for these two service types, so - unlike the
        // mutating entry points above - they leave no error behind at all.
        // Pinning that as current behaviour, not endorsing it as correct.
        await viewModel.loadIndexers(for: profileID, serviceType: .prowlarr)
        #expect(viewModel.error(for: profileID) != nil) // still holds the addIndexer error from above
        viewModel.clearTestResult()
        let freshProfileID = UUID()
        await viewModel.loadIndexers(for: freshProfileID, serviceType: .bazarr)
        #expect(viewModel.error(for: freshProfileID) == nil)
        #expect(viewModel.indexers(for: freshProfileID, serviceType: .bazarr).isEmpty)

        await viewModel.loadSchema(for: freshProfileID, serviceType: .bazarr)
        #expect(viewModel.schemaError(for: freshProfileID) == nil)
        #expect(viewModel.schema(for: freshProfileID).isEmpty)
    }
}
