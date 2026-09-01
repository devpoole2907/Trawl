import Testing
@testable import Trawl

/// State and feedback ownership for the two Arr mutations that delete one media file
/// from disk.
///
/// The API contracts pin the authenticated DELETE paths. These tests sit one layer
/// above them and protect a subtle UI failure: both view models and every presenting
/// view used to announce the same result, so one confirmed mutation produced two
/// "File Deleted" banners and one rejected mutation produced two "Delete Failed"
/// banners. The view model now owns request/state/error; the presenting view owns the
/// one user-facing announcement appropriate to that screen.
@Suite("Arr media-file deletion", .serialized)
@MainActor
struct ArrMediaFileDeletionTests {
    @Test("Sonarr file deletion returns success without announcing behind the presenting view")
    func sonarrSuccessLeavesFeedbackToTheView() async throws {
        let server = try await server(label: "sonarr-file-delete") { request in
            request.path == "/api/v3/episodefile/71" ? .empty : arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedArrInstances([.init(server, .sonarr, "Sonarr")]) { manager, _ in
            let viewModel = SonarrViewModel(serviceManager: manager)
            let before = fileDeletionNotificationCount()

            let deleted = await viewModel.deleteEpisodeFile(id: 71)

            #expect(deleted == true)
            #expect(viewModel.error == nil)
            #expect(server.requests(path: "/api/v3/episodefile/71").map(\.method) == ["DELETE"])
            #expect(
                fileDeletionNotificationCount() == before,
                "The detail/episode view announces the result. The view model must not queue the same banner behind it."
            )
        }
    }

    @Test("Sonarr rejection stores the error without announcing behind the presenting view")
    func sonarrFailureLeavesFeedbackToTheView() async throws {
        let server = try await server(label: "sonarr-file-reject") { request in
            request.path == "/api/v3/episodefile/71"
                ? .failure(status: 500, message: "disk refused")
                : arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedArrInstances([.init(server, .sonarr, "Sonarr")]) { manager, _ in
            let viewModel = SonarrViewModel(serviceManager: manager)
            let before = fileDeletionNotificationCount()

            let deleted = await viewModel.deleteEpisodeFile(id: 71)

            #expect(deleted == false)
            #expect(viewModel.error?.contains("disk refused") == true)
            #expect(fileDeletionNotificationCount() == before)
        }
    }

    @Test("Radarr file deletion returns success without announcing behind the presenting view")
    func radarrSuccessLeavesFeedbackToTheView() async throws {
        let server = try await server(label: "radarr-file-delete") { request in
            request.path == "/api/v3/moviefile/81" ? .empty : arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedArrInstances([.init(server, .radarr, "Radarr")]) { manager, _ in
            let viewModel = RadarrViewModel(serviceManager: manager)
            let before = fileDeletionNotificationCount()

            let deleted = await viewModel.deleteMovieFile(id: 81)

            #expect(deleted == true)
            #expect(viewModel.error == nil)
            #expect(server.requests(path: "/api/v3/moviefile/81").map(\.method) == ["DELETE"])
            #expect(fileDeletionNotificationCount() == before)
        }
    }

    @Test("Radarr rejection stores the error without announcing behind the presenting view")
    func radarrFailureLeavesFeedbackToTheView() async throws {
        let server = try await server(label: "radarr-file-reject") { request in
            request.path == "/api/v3/moviefile/81"
                ? .failure(status: 500, message: "disk refused")
                : arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        try await withConnectedArrInstances([.init(server, .radarr, "Radarr")]) { manager, _ in
            let viewModel = RadarrViewModel(serviceManager: manager)
            let before = fileDeletionNotificationCount()

            let deleted = await viewModel.deleteMovieFile(id: 81)

            #expect(deleted == false)
            #expect(viewModel.error?.contains("disk refused") == true)
            #expect(fileDeletionNotificationCount() == before)
        }
    }

    @Test("A missing client is stored as an error without stealing deletion feedback from the view")
    func missingClientsRecordErrorsWithoutAnnouncing() async {
        let manager = ArrServiceManager()
        let sonarr = SonarrViewModel(serviceManager: manager)
        let radarr = RadarrViewModel(serviceManager: manager)
        let before = fileDeletionNotificationCount()

        #expect(await sonarr.deleteEpisodeFile(id: 71) == false)
        #expect(await radarr.deleteMovieFile(id: 81) == false)
        #expect(sonarr.error?.isEmpty == false)
        #expect(radarr.error?.isEmpty == false)
        #expect(fileDeletionNotificationCount() == before)
    }

    private func server(
        label: String,
        handler: @escaping ArrIndexerFixtureServer.Handler
    ) async throws -> ArrIndexerFixtureServer {
        try await ArrIndexerFixtureServer(label: label, handler: handler)
    }

    private func fileDeletionNotificationCount() -> Int {
        InAppNotificationCenter.shared.recentNotifications.count {
            $0.title == "File Deleted" || $0.title == "Delete Failed"
        }
    }
}
