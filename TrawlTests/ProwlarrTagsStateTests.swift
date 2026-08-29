import Foundation
import Testing
@testable import Trawl

/// `ProwlarrTagsViewModel` - the plain tag CRUD half of
/// `ProwlarrViewModel.swift`. `updateIndexerTags`, which is how a tag actually
/// gets attached to an indexer, is already covered in
/// `ProwlarrIndexerStateTests`; this suite only exercises tag list load/create/
/// delete. Same rules as the other Prowlarr suites: real `ProwlarrAPIClient`,
/// real `ArrServiceManager`, loopback fixture server, request bodies compared
/// as parsed JSON.
@Suite("Prowlarr tags", .serialized)
@MainActor
struct ProwlarrTagsStateTests {
    private static let tagsJSON = #"[{"id":2,"label":"zeta"},{"id":1,"label":"Alpha"}]"#

    private static func standardHandler(
        override: @escaping @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? = { _ in nil }
    ) -> @Sendable (ProwlarrFixtureRequest) -> ProwlarrFixtureResponse? {
        let tags = tagsJSON
        return { request in
            if let response = override(request) { return response }
            switch (request.method, request.path) {
            case ("GET", "/api/v1/tag"): return .json(tags)
            default: return prowlarrDefaultResponse(for: request)
            }
        }
    }

    @Test("loadTags loads server order, and sortedTags sorts case-insensitively")
    func loadTagsAndSortedView() async throws {
        let server = try await ProwlarrFixtureServer(label: "tags-load", handler: Self.standardHandler())
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrTagsViewModel(serviceManager: manager)
            await viewModel.loadTags()

            #expect(viewModel.tags.map(\.label) == ["zeta", "Alpha"])
            #expect(viewModel.sortedTags.map(\.label) == ["Alpha", "zeta"])
            #expect(viewModel.errorMessage == nil)
            #expect(viewModel.isLoading == false)
        }
    }

    @Test("A tags load failure is reported and leaves the list empty")
    func loadTagsFailureReportsError() async throws {
        let handler = Self.standardHandler { request in
            request.method == "GET" && request.path == "/api/v1/tag"
                ? .failure(status: 500, message: "tag list exploded")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "tags-load-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrTagsViewModel(serviceManager: manager)
            await viewModel.loadTags()

            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("500"))
            #expect(viewModel.tags.isEmpty)
            #expect(viewModel.isLoading == false)
        }
    }

    @Test("createTag trims the label, POSTs it, and appends the server's copy")
    func createTagTrimsAndPosts() async throws {
        let created = #"{"id":9,"label":"new tag"}"#
        let handler = Self.standardHandler { request in
            request.method == "POST" && request.path == "/api/v1/tag" ? .json(created) : nil
        }
        let server = try await ProwlarrFixtureServer(label: "tags-create", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrTagsViewModel(serviceManager: manager)
            await viewModel.loadTags()

            let succeeded = await viewModel.createTag(label: "  new tag  ")

            #expect(succeeded == true)
            #expect(viewModel.errorMessage == nil)
            let posts = server.requests.filter { $0.method == "POST" && $0.path == "/api/v1/tag" }
            #expect(posts.count == 1)
            let sent = try #require(posts.first)
            let body = try #require(sent.jsonObject())
            #expect(body["label"] as? String == "new tag")
            #expect(viewModel.tags.map(\.label).contains("new tag"))
            #expect(viewModel.isSubmitting == false)
        }
    }

    @Test("createTag with a blank or whitespace-only label is rejected without a request")
    func createTagRejectsBlankLabel() async throws {
        let server = try await ProwlarrFixtureServer(label: "tags-create-blank", handler: Self.standardHandler())
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrTagsViewModel(serviceManager: manager)

            let created = await viewModel.createTag(label: "   \n  ")

            #expect(created == false)
            #expect(server.requestCount(method: "POST", path: "/api/v1/tag") == 0)
            #expect(viewModel.tags.isEmpty)
            #expect(viewModel.errorMessage == nil)
        }
    }

    @Test("A failed createTag reports the error and does not append a row")
    func createTagFailureReportsError() async throws {
        let handler = Self.standardHandler { request in
            request.method == "POST" && request.path == "/api/v1/tag"
                ? .failure(status: 400, message: "tag rejected")
                : nil
        }
        let server = try await ProwlarrFixtureServer(label: "tags-create-fail", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrTagsViewModel(serviceManager: manager)

            let created = await viewModel.createTag(label: "new tag")

            #expect(created == false)
            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("400"))
            #expect(viewModel.tags.isEmpty)
            #expect(viewModel.isSubmitting == false)
        }
    }

    @Test("deleteTag drops the row only when the server confirms")
    func deleteTagRemovesOnlyOnSuccess() async throws {
        let calls = ProwlarrCallCounter()
        let handler = Self.standardHandler { request in
            guard request.method == "DELETE", request.path == "/api/v1/tag/1" else { return nil }
            return calls.next("delete") == 1 ? .failure(status: 500, message: "delete rejected") : .empty
        }
        let server = try await ProwlarrFixtureServer(label: "tags-delete", handler: handler)
        defer { server.stop() }

        try await withConnectedProwlarr(server: server) { manager in
            let viewModel = ProwlarrTagsViewModel(serviceManager: manager)
            await viewModel.loadTags()
            let matches = viewModel.tags.filter { $0.id == 1 }
            let target = try #require(matches.first)

            let firstAttempt = await viewModel.deleteTag(target)
            #expect(firstAttempt == false)
            #expect(viewModel.tags.map(\.id).sorted() == [1, 2])
            let error = try #require(viewModel.errorMessage)
            #expect(error.contains("500"))

            let secondAttempt = await viewModel.deleteTag(target)
            #expect(secondAttempt == true)
            #expect(viewModel.tags.map(\.id) == [2])
            #expect(viewModel.errorMessage == nil)
            #expect(server.requestCount(method: "DELETE", path: "/api/v1/tag/1") == 2)
        }
    }

    @Test("Every tags entry point reports the disconnected state")
    func entryPointsReportDisconnected() async throws {
        let manager = ArrServiceManager()
        let viewModel = ProwlarrTagsViewModel(serviceManager: manager)

        await viewModel.loadTags()
        #expect(viewModel.errorMessage == "Prowlarr not connected.")
        #expect(viewModel.tags.isEmpty)

        viewModel.clearError()
        let created = await viewModel.createTag(label: "new tag")
        #expect(created == false)
        #expect(viewModel.errorMessage == "Prowlarr not connected.")

        viewModel.clearError()
        let deleted = await viewModel.deleteTag(ArrTag(id: 1, label: "Alpha"))
        #expect(deleted == false)
        #expect(viewModel.errorMessage == "Prowlarr not connected.")
    }
}
