import Foundation
import Testing
@testable import Trawl

/// `ProwlarrApplicationsViewModel` - the linked-applications (Sonarr/Radarr)
/// half of `ProwlarrViewModel.swift`. Same rules as the other two Prowlarr
/// suites: real client, real `ArrServiceManager`, loopback fixture server, and
/// request bodies asserted as parsed JSON.
@Suite("Prowlarr linked applications", .serialized)
@MainActor
struct ProwlarrApplicationsStateTests {
    private static let sonarrAppJSON = prowlarrApplicationJSON(id: 2, name: "Sonarr Main", implementation: "Sonarr", configContract: "SonarrSettings")
    private static let radarrAppJSON = prowlarrApplicationJSON(id: 1, name: "Radarr Main", implementation: "Radarr", configContract: "RadarrSettings")
    /// Not a linked app type, so every `supported*` view must drop it.
    private static let lidarrAppJSON = prowlarrApplicationJSON(id: 3, name: "Lidarr Main", implementation: "Lidarr", configContract: "LidarrSettings")

    private static let schemaJSON = prowlarrJSONArray([
        #"{"id":0,"name":"Sonarr","implementation":"Sonarr","implementationName":"Sonarr","configContract":"SonarrSettings","fields":[]}"#,
        #"{"id":0,"name":"Radarr","implementation":"Radarr","implementationName":"Radarr","configContract":"RadarrSettings","fields":[]}"#,
        #"{"id":0,"name":"Lidarr","implementation":"Lidarr","implementationName":"Lidarr","configContract":"LidarrSettings","fields":[]}"#
    ])

    private static let tagsJSON = #"[{"id":2,"label":"zeta"},{"id":1,"label":"Alpha"}]"#

    private static func newSonarrApplication() -> ProwlarrApplication {
        ProwlarrApplication(
            id: 0,
            name: "Sonarr New",
            fields: nil,
            implementationName: "Sonarr",
            implementation: "Sonarr",
            configContract: "SonarrSettings",
            infoLink: nil,
            message: nil,
            tags: [4],
            presets: nil,
            syncLevel: .fullSync,
            testCommand: nil
        )
    }

    private static func standardHandler(
        override: @escaping @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? = { _ in nil }
    ) -> @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? {
        let applications = prowlarrJSONArray([sonarrAppJSON, radarrAppJSON, lidarrAppJSON])
        let schema = schemaJSON
        let tags = tagsJSON
        return { request in
            if let response = override(request) { return response }
            switch (request.method, request.path) {
            case ("GET", "/api/v1/applications"): return .json(applications)
            case ("GET", "/api/v1/applications/schema"): return .json(schema)
            case ("GET", "/api/v1/tag"): return .json(tags)
            default: return prowlarrDefaultResponse(for: request)
            }
        }
    }

    @Test("loadApplications sorts and filters to the linked app types, and the schema loads once")
    func loadApplicationsAndSchema() async throws {
        let server = try await ProwlarrFixtureServer(label: "apps-load", handler: Self.standardHandler())
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)
            await viewModel.loadApplications()

            #expect(viewModel.applications.count == 3)
            #expect(viewModel.supportedApplications.map { $0.name ?? "" } == ["Radarr Main", "Sonarr Main"])
            #expect(viewModel.availableTags.map(\.label) == ["Alpha", "zeta"])
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.isLoadingApplications == false)

            await viewModel.loadSchemaIfNeeded()
            #expect(viewModel.supportedSchemas.map { $0.name ?? "" } == ["Radarr", "Sonarr"])
            #expect(viewModel.schema(for: .sonarr)?.configContract == "SonarrSettings")
            #expect(viewModel.schema(for: .radarr)?.configContract == "RadarrSettings")
            #expect(viewModel.isLoadingSchema == false)

            // Second call is a no-op; reloadSchema forces the refetch.
            await viewModel.loadSchemaIfNeeded()
            #expect(server.requestCount(path: "/api/v1/applications/schema") == 1)
            await viewModel.reloadSchema()
            #expect(server.requestCount(path: "/api/v1/applications/schema") == 2)
        }
    }

    @Test("Saving a new application POSTs it and refreshes the list from the server")
    func saveNewApplicationPosts() async throws {
        let created = prowlarrApplicationJSON(id: 9, name: "Sonarr New", implementation: "Sonarr", configContract: "SonarrSettings")
        let handler = Self.standardHandler { request in
            request.method == "POST" && request.path == "/api/v1/applications" ? .json(created) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "apps-create", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)

            let saved = await viewModel.saveApplication(Self.newSonarrApplication())

            #expect(saved == true)
            #expect(viewModel.errorMessage == nil)
            let posts = server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/applications" }
            #expect(posts.count == 1)
            let sent = try #require(posts.first)
            let body = try #require(sent.jsonObject())
            #expect(body["id"] as? Int == 0)
            #expect(body["name"] as? String == "Sonarr New")
            #expect(body["implementation"] as? String == "Sonarr")
            #expect(body["configContract"] as? String == "SonarrSettings")
            #expect(body["syncLevel"] as? String == "fullSync")
            #expect(body["tags"] as? [Int] == [4])
            // No PUT: a zero id means create, never update.
            #expect(server.requests.filter { $0.method == "PUT" }.isEmpty)
            // The save refreshed the list from the server.
            #expect(server.requestCount(method: "GET", path: "/api/v1/applications") == 1)
            #expect(viewModel.supportedApplications.map { $0.name ?? "" } == ["Radarr Main", "Sonarr Main"])
        }
    }

    @Test("Saving an existing application PUTs to its id")
    func saveExistingApplicationPuts() async throws {
        let updatedApp = prowlarrApplicationJSON(id: 2, name: "Sonarr Renamed", implementation: "Sonarr", configContract: "SonarrSettings")
        let handler = Self.standardHandler { request in
            request.method == "PUT" && request.path == "/api/v1/applications/2" ? .json(updatedApp) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "apps-update", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)
            await viewModel.loadApplications()
            let existingMatches = viewModel.applications.filter { $0.id == 2 }
            var existing = try #require(existingMatches.first)
            existing.name = "Sonarr Renamed"

            let saved = await viewModel.saveApplication(existing)

            #expect(saved == true)
            let puts = server.requests.filter { $0.method == "PUT" }
            #expect(puts.count == 1)
            let sent = try #require(puts.first)
            #expect(sent.path == "/api/v1/applications/2")
            let body = try #require(sent.jsonObject())
            #expect(body["id"] as? Int == 2)
            #expect(body["name"] as? String == "Sonarr Renamed")
            #expect(server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/applications" }.isEmpty)
        }
    }

    @Test("A failed save reports the error and does not refresh the list")
    func failedSaveSkipsRefresh() async throws {
        let handler = Self.standardHandler { request in
            request.method == "POST" && request.path == "/api/v1/applications"
                ? .failure(status: 400, message: "Sonarr rejected the API key")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "apps-create-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)
            await viewModel.loadApplications()
            let getsBeforeSave = server.requestCount(method: "GET", path: "/api/v1/applications")

            let saved = await viewModel.saveApplication(Self.newSonarrApplication())

            #expect(saved == false)
            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("400"))
            #expect(server.requestCount(method: "GET", path: "/api/v1/applications") == getsBeforeSave)
            #expect(viewModel.isLoadingApplications == false)

            viewModel.clearError()
            #expect(viewModel.errorMessage == nil)
        }
    }

    @Test("deleteApplication drops the row only when the server confirms")
    func deleteApplicationRemovesOnlyOnSuccess() async throws {
        let calls = ProwlarrCallCounter()
        let handler = Self.standardHandler { request in
            guard request.method == "DELETE", request.path == "/api/v1/applications/2" else { return nil }
            return calls.next("delete") == 1 ? .failure(status: 500, message: "delete rejected") : .empty
        }
        let server = try await ProwlarrFixtureServer(label: "apps-delete", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)
            await viewModel.loadApplications()
            let targetMatches = viewModel.applications.filter { $0.id == 2 }
            let target = try #require(targetMatches.first)

            let firstAttempt = await viewModel.deleteApplication(target)
            #expect(firstAttempt == false)
            #expect(viewModel.applications.map(\.id).sorted() == [1, 2, 3])
            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("500"))

            let secondAttempt = await viewModel.deleteApplication(target)
            #expect(secondAttempt == true)
            #expect(viewModel.applications.map(\.id).sorted() == [1, 3])
            #expect(viewModel.errorMessage == nil)
            #expect(server.requestCount(method: "DELETE", path: "/api/v1/applications/2") == 2)
        }
    }

    @Test("syncApplications refuses to run when nothing linked is configured")
    func syncWithoutLinkedApplicationsThrows() async throws {
        let onlyUnsupported = prowlarrJSONArray([
            prowlarrApplicationJSON(id: 3, name: "Lidarr Main", implementation: "Lidarr", configContract: "LidarrSettings")
        ])
        let handler = Self.standardHandler { request in
            request.method == "GET" && request.path == "/api/v1/applications" ? .json(onlyUnsupported) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "apps-sync-none", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)

            do {
                try await viewModel.syncApplications()
                Issue.record("syncApplications should refuse to run with no linked Sonarr/Radarr application.")
            } catch {
                #expect(error.localizedDescription.contains("Link Sonarr or Radarr"))
            }

            #expect(server.requestCount(method: "POST", path: "/api/v1/command") == 0)
            #expect(viewModel.isSyncingApplications == false)
        }
    }

    @Test("syncApplications posts the sync command and surfaces a failed command")
    func syncPostsCommandAndReportsFailure() async throws {
        let calls = ProwlarrCallCounter()
        let handler = Self.standardHandler { request in
            guard request.method == "POST", request.path == "/api/v1/command" else { return nil }
            // No `id` in the response, so `postCommandAndWait` returns without
            // entering its polling loop - the command is already terminal.
            return calls.next("command") == 1
                ? .json(#"{"name":"ApplicationIndexerSync","status":"completed"}"#)
                : .json(#"{"name":"ApplicationIndexerSync","status":"failed","exception":"Sonarr refused the indexer push"}"#)
        }
        let server = try await ProwlarrFixtureServer(label: "apps-sync", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)

            try await viewModel.syncApplications()
            #expect(viewModel.isSyncingApplications == false)

            let commands = server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/command" }
            #expect(commands.count == 1)
            let sent = try #require(commands.first)
            #expect(sent.jsonObject()?["name"] as? String == "ApplicationIndexerSync")

            do {
                try await viewModel.syncApplications()
                Issue.record("syncApplications should throw when Prowlarr reports the command failed.")
            } catch {
                #expect(error.localizedDescription.contains("Sonarr refused the indexer push"))
            }
            #expect(viewModel.isSyncingApplications == false)
        }
    }

    @Test("Every applications entry point reports the disconnected state")
    func entryPointsReportDisconnected() async throws {
        let manager = ArrServiceManager()
        let viewModel = ProwlarrApplicationsViewModel(serviceManager: manager)

        await viewModel.loadApplications()
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        viewModel.clearError()
        await viewModel.reloadSchema()
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        viewModel.clearError()
        let saved = await viewModel.saveApplication(Self.newSonarrApplication())
        #expect(saved == false)
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        viewModel.clearError()
        let deleted = await viewModel.deleteApplication(Self.newSonarrApplication())
        #expect(deleted == false)
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        do {
            try await viewModel.syncApplications()
            Issue.record("syncApplications should throw when Prowlarr is not connected.")
        } catch {
            #expect(error.localizedDescription == ArrError.noServiceConfigured.localizedDescription)
        }
    }
}
