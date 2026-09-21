import Foundation
import Testing
@testable import Trawl

/// Server provenance on the paths where an HD/4K pair's colliding integer IDs used
/// to decide which server an action reached, and the partial-outage state the
/// blended surfaces gate on.
///
/// Both servers number movies, movie files and episode files from their own
/// sequences, so the same integer names unrelated rows on each. Every test here
/// gives the two servers *identical* IDs for *different* content: a route that
/// guesses the server from the ID alone then visibly lands on the wrong one,
/// instead of passing because the IDs happened to differ.
@Suite("Arr dual instance provenance", .serialized)
@MainActor
struct ArrDualInstanceProvenanceTests {

    // MARK: - Radarr movie files

    @Test("A 4K movie's files load from the 4K server when HD holds a different film with the same ID")
    func movieFilesLoadFromTheNamedServer() async throws {
        let hd = try await radarrServer(label: "hd-files", title: "Dune", file: "Dune.1080p.mkv")
        let uhd = try await radarrServer(label: "4k-files", title: "Sinners", file: "Sinners.2160p.mkv")
        defer { hd.stop(); uhd.stop() }

        try await withTieredPair(.radarr, hd: hd, uhd: uhd) { manager, _, uhdID in
            let viewModel = RadarrViewModel(serviceManager: manager)
            await viewModel.loadMovies()
            // Precondition for the collision: both servers' film 211 is loaded.
            #expect(viewModel.movies.filter { $0.id == 211 }.count == 2)

            await viewModel.loadMovieFiles(movieId: 211, instanceID: uhdID)

            #expect(viewModel.movieFiles.map(\.relativePath) == ["Sinners.2160p.mkv"])
            #expect(viewModel.movieFilesByInstance[uhdID]?.map(\.relativePath) == ["Sinners.2160p.mkv"])
            #expect(hd.requestCount(method: "GET", path: "/api/v3/moviefile") == 0)
        }
    }

    @Test("Deleting a 4K movie file reaches only the 4K server and reloads only its copy")
    func movieFileDeleteReachesOnlyTheNamedServer() async throws {
        let hd = try await radarrServer(label: "hd-delete-file", title: "Dune", file: "Dune.1080p.mkv")
        let uhd = try await radarrServer(label: "4k-delete-file", title: "Sinners", file: "Sinners.2160p.mkv")
        defer { hd.stop(); uhd.stop() }

        try await withTieredPair(.radarr, hd: hd, uhd: uhd) { manager, hdID, uhdID in
            let viewModel = RadarrViewModel(serviceManager: manager)
            await viewModel.loadMovies()
            let entry = try #require(viewModel.mergedEntries().first { $0.copies.contains { $0.instanceID == uhdID } })
            await viewModel.loadMovieFiles(for: entry)
            // The HD film's files are on screen too, so the refresh has something
            // of HD's to disturb if it strays.
            await viewModel.loadMovieFiles(movieId: 211, instanceID: hdID)
            #expect(viewModel.movieFilesByInstance[hdID]?.map(\.relativePath) == ["Dune.1080p.mkv"])
            let hdMovieFileGets = hd.requestCount(method: "GET", path: "/api/v3/moviefile")

            let deleted = await viewModel.deleteMovieFile(id: 5, movieID: 211, instanceID: uhdID)

            #expect(deleted)
            #expect(uhd.requestCount(method: "DELETE", path: "/api/v3/moviefile/5") == 1)
            #expect(hd.requestCount(method: "DELETE", path: "/api/v3/moviefile/5") == 0)
            // The refresh follows the delete to its server: the 4K copy's row is
            // gone, and the HD film that shares its IDs is neither re-read nor
            // disturbed.
            #expect(viewModel.movieFilesByInstance[uhdID]?.isEmpty == true)
            #expect(hd.requestCount(method: "GET", path: "/api/v3/moviefile") == hdMovieFileGets)
            #expect(hd.requestCount(method: "GET", path: "/api/v3/movie/211") == 0)
            #expect(viewModel.movieFilesByInstance[hdID]?.map(\.relativePath) == ["Dune.1080p.mkv"])
        }
    }

    @Test("A movie file delete naming a server that cannot be resolved fails closed")
    func movieFileDeleteFailsClosedForAnUnknownServer() async throws {
        let hd = try await radarrServer(label: "hd-closed", title: "Dune", file: "Dune.1080p.mkv")
        let uhd = try await radarrServer(label: "4k-closed", title: "Sinners", file: "Sinners.2160p.mkv")
        defer { hd.stop(); uhd.stop() }

        try await withTieredPair(.radarr, hd: hd, uhd: uhd) { manager, _, _ in
            let viewModel = RadarrViewModel(serviceManager: manager)
            await viewModel.loadMovies()

            let deleted = await viewModel.deleteMovieFile(id: 5, movieID: 211, instanceID: UUID())

            #expect(deleted == false)
            #expect(viewModel.error?.isEmpty == false)
            #expect(hd.requestCount(method: "DELETE", path: "/api/v3/moviefile/5") == 0)
            #expect(uhd.requestCount(method: "DELETE", path: "/api/v3/moviefile/5") == 0)
        }
    }

    // MARK: - Sonarr episode files

    @Test("Deleting a 4K episode file refreshes the 4K series, not the HD series sharing the file ID")
    func episodeFileDeleteRefreshesOnlyTheNamedServer() async throws {
        let hdState = FixtureDeletionState()
        let uhdState = FixtureDeletionState()
        let hd = try await sonarrServer(label: "hd-episode", seriesID: 10, file: "HD.S01E01.mkv", state: hdState)
        let uhd = try await sonarrServer(label: "4k-episode", seriesID: 20, file: "4K.S01E01.mkv", state: uhdState)
        defer { hd.stop(); uhd.stop() }

        try await withTieredPair(.sonarr, hd: hd, uhd: uhd) { manager, hdID, uhdID in
            let viewModel = SonarrViewModel(serviceManager: manager)
            await viewModel.loadEpisodeFiles(for: 10, instanceID: hdID)
            await viewModel.loadEpisodeFiles(for: 20, instanceID: uhdID)
            // Precondition for the collision: both caches hold an episode file 71.
            #expect(viewModel.episodeFiles(forSeries: 10, on: hdID).map(\.id) == [71])
            #expect(viewModel.episodeFiles(forSeries: 20, on: uhdID).map(\.id) == [71])
            let hdEpisodeFileGets = hd.requestCount(method: "GET", path: "/api/v3/episodefile")
            let uhdEpisodeFileGets = uhd.requestCount(method: "GET", path: "/api/v3/episodefile")

            let deleted = await viewModel.deleteEpisodeFile(id: 71, instanceID: uhdID)

            #expect(deleted)
            #expect(uhd.requestCount(method: "DELETE", path: "/api/v3/episodefile/71") == 1)
            #expect(hd.requestCount(method: "DELETE", path: "/api/v3/episodefile/71") == 0)
            #expect(uhd.requestCount(method: "GET", path: "/api/v3/episodefile") == uhdEpisodeFileGets + 1)
            #expect(hd.requestCount(method: "GET", path: "/api/v3/episodefile") == hdEpisodeFileGets)
            #expect(viewModel.episodeFiles(forSeries: 20, on: uhdID).isEmpty)
            #expect(viewModel.episodeFiles(forSeries: 10, on: hdID).map(\.relativePath) == ["HD.S01E01.mkv"])
        }
    }

    // MARK: - Partial outage

    /// `radarrConnected`/`sonarrConnected` follow the *active* server, and the
    /// active server does not move when it goes down. Every blended surface used to
    /// gate on them, so the HD server dropping blanked Movies, Series, Blocklist,
    /// Missing, Import and Root Folders while the 4K server could still fill them.
    /// The HD server is taken down through the production unreachable path, and
    /// each surface's gate and loader is read afterwards.
    @Test("The active Radarr going offline leaves the 4K server's content on every blended surface")
    func activeRadarrOutageKeepsTheConnectedPartner() async throws {
        let hd = try await radarrServer(label: "hd-outage", title: "Dune", file: "Dune.1080p.mkv")
        let uhd = try await radarrServer(label: "4k-outage", title: "Sinners", file: "Sinners.2160p.mkv")
        defer { hd.stop(); uhd.stop() }

        try await withTieredPair(.radarr, hd: hd, uhd: uhd) { manager, hdID, uhdID in
            #expect(manager.activeRadarrEntry?.id == hdID)
            try await takeDown(hd, in: manager, id: hdID, serviceType: .radarr)

            // The state the old gates read, and why they were wrong to read it.
            #expect(manager.isConnected(.radarr) == false)
            #expect(manager.hasAnyConnectedInstance(.radarr))
            #expect(manager.hasAnyConnectedRadarrInstance)

            // Movies: the list root's gate and the library it then loads.
            let viewModel = RadarrViewModel(serviceManager: manager)
            #expect(viewModel.isConnected)
            await viewModel.loadMovies()
            #expect(viewModel.movies.map(\.title) == ["Sinners"])
            #expect(viewModel.movies.allSatisfy { $0.instanceID == uhdID })

            // Missing: the Wanted screen gates on the view model's `isConnected`.
            await viewModel.loadWantedMissing()
            #expect(viewModel.wantedRecords.count == 1)

            // Blocklist.
            await manager.loadBlocklist()
            #expect(manager.radarrBlocklist.map(\.instance.id) == [uhdID])

            // Import and Root Folders pick from the visible servers.
            #expect(manager.visibleArrInstances.map(\.ref.id) == [uhdID])
            #expect(manager.rootFoldersByInstance.map(\.ref.id) == [uhdID])
            #expect(manager.rootFolders(for: uhdID).map(\.path) == ["/movies"])
        }
    }

    @Test("The active Sonarr going offline leaves the 4K server's series in the library")
    func activeSonarrOutageKeepsTheConnectedPartner() async throws {
        let hd = try await sonarrServer(label: "hd-sonarr-outage", seriesID: 10, file: "HD.S01E01.mkv", state: FixtureDeletionState())
        let uhd = try await sonarrServer(label: "4k-sonarr-outage", seriesID: 20, file: "4K.S01E01.mkv", state: FixtureDeletionState())
        defer { hd.stop(); uhd.stop() }

        try await withTieredPair(.sonarr, hd: hd, uhd: uhd) { manager, hdID, uhdID in
            #expect(manager.activeSonarrEntry?.id == hdID)
            try await takeDown(hd, in: manager, id: hdID, serviceType: .sonarr)

            #expect(manager.isConnected(.sonarr) == false)
            #expect(manager.hasAnyConnectedInstance(.sonarr))

            let viewModel = SonarrViewModel(serviceManager: manager)
            #expect(viewModel.isConnected)
            await viewModel.loadSeries()
            #expect(viewModel.series.map(\.id) == [20])
            #expect(viewModel.series.allSatisfy { $0.instanceID == uhdID })
        }
    }

    // MARK: - Fixtures

    /// Stops a connected server and drives the queue poller until the manager
    /// marks it unreachable - the same evidence a real outage produces.
    private func takeDown(
        _ server: ArrIndexerFixtureServer,
        in manager: ArrServiceManager,
        id: UUID,
        serviceType: ArrServiceType
    ) async throws {
        server.stop()
        for _ in 0..<ArrServiceManager.unreachableFailureThreshold {
            await manager.refreshQueues()
        }
        #expect(manager.isConnected(serviceType, profileID: id) == false)
    }

    /// A Radarr whose film 211 carries movie file 5 - the same IDs on every server
    /// built here, with a different title and file name each time.
    private func radarrServer(label: String, title: String, file: String) async throws -> ArrIndexerFixtureServer {
        // Distinct TMDb IDs keep the two films as separate library entries.
        let tmdbID = title == "Dune" ? 438631 : 1233413
        let movie = #"{"id":211,"title":"\#(title)","tmdbId":\#(tmdbID),"hasFile":true,"movieFile":{"id":5,"movieId":211,"relativePath":"\#(file)"}}"#
        let deleted = FixtureDeletionState()
        return try await ArrIndexerFixtureServer(label: "provenance-\(label)") { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v3/movie"): return .json("[\(movie)]")
            case ("GET", "/api/v3/movie/211"): return .json(movie)
            case ("GET", "/api/v3/moviefile"):
                return .json(deleted.isDeleted ? "[]" : #"[{"id":5,"movieId":211,"relativePath":"\#(file)"}]"#)
            case ("DELETE", "/api/v3/moviefile/5"):
                deleted.markDeleted()
                return .empty
            case ("GET", "/api/v3/rootfolder"): return .json(#"[{"id":1,"path":"/movies"}]"#)
            case ("GET", "/api/v3/wanted/missing"):
                return .json(#"{"page":1,"pageSize":50,"totalRecords":1,"records":[\#(movie)]}"#)
            case ("GET", "/api/v3/blocklist"):
                return .json(#"{"page":1,"pageSize":50,"totalRecords":1,"records":[{"id":9,"movieId":211,"sourceTitle":"\#(title).2160p"}]}"#)
            case ("GET", "/api/v3/queue"), ("GET", "/api/v3/history"):
                return .json(#"{"page":1,"pageSize":100,"totalRecords":0,"records":[]}"#)
            default: return arrIndexerDefaultResponse(for: request)
            }
        }
    }

    /// A Sonarr whose one series holds episode file 71.
    private func sonarrServer(
        label: String,
        seriesID: Int,
        file: String,
        state: FixtureDeletionState
    ) async throws -> ArrIndexerFixtureServer {
        try await ArrIndexerFixtureServer(label: "provenance-\(label)") { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v3/series"):
                return .json(#"[{"id":\#(seriesID),"title":"Series \#(seriesID)","tvdbId":\#(seriesID * 1000)}]"#)
            case ("GET", "/api/v3/episodefile"):
                return .json(state.isDeleted ? "[]" : #"[{"id":71,"seriesId":\#(seriesID),"seasonNumber":1,"relativePath":"\#(file)"}]"#)
            case ("DELETE", "/api/v3/episodefile/71"):
                state.markDeleted()
                return .empty
            case ("GET", "/api/v3/queue"), ("GET", "/api/v3/history"):
                return .json(#"{"page":1,"pageSize":100,"totalRecords":0,"records":[]}"#)
            default: return arrIndexerDefaultResponse(for: request)
            }
        }
    }

    /// Connects an HD/4K pair of one service, HD first so it is the active entry,
    /// and removes the Keychain entries and persisted filter afterwards.
    private func withTieredPair(
        _ serviceType: ArrServiceType,
        hd: ArrIndexerFixtureServer,
        uhd: ArrIndexerFixtureServer,
        _ body: (ArrServiceManager, UUID, UUID) async throws -> Void
    ) async throws {
        let manager = ArrServiceManager()
        let name = serviceType.displayName
        let hdProfile = ArrServiceProfile(displayName: "\(name) HD", hostURL: hd.baseURL, serviceType: serviceType, qualityTier: .hd)
        let uhdProfile = ArrServiceProfile(displayName: "4K \(name)", hostURL: uhd.baseURL, serviceType: serviceType, qualityTier: .uhd)
        let keys = [hdProfile.apiKeyKeychainKey, uhdProfile.apiKeyKeychainKey]
        for key in keys {
            try await KeychainHelper.shared.save(key: key, value: "provenance-key")
        }

        do {
            await manager.connectService(hdProfile)
            await manager.connectService(uhdProfile)
            try #require(manager.isConnected(serviceType, profileID: hdProfile.id))
            try #require(manager.isConnected(serviceType, profileID: uhdProfile.id))

            try await body(manager, hdProfile.id, uhdProfile.id)
        } catch {
            manager.showAllInstances(of: serviceType)
            for key in keys { try? await KeychainHelper.shared.delete(key: key) }
            throw error
        }
        manager.showAllInstances(of: serviceType)
        for key in keys { try? await KeychainHelper.shared.delete(key: key) }
    }
}

/// Whether a fixture server has had its file deleted, so the reload after a
/// DELETE sees the row gone the way a real server would report it.
private final class FixtureDeletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var deleted = false

    var isDeleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return deleted
    }

    func markDeleted() {
        lock.lock(); deleted = true; lock.unlock()
    }
}
