import Foundation
import Testing
@testable import Trawl

/// Work that outlives a screen lives in a manager, not in a view's `@State`:
/// an automatic search and the wait for its result, a backup being created, and a
/// Jellyfin library scan. These drive each one through the real manager against a
/// loopback server and check what a screen opened later would see.
@Suite("Manager-owned work", .serialized)
@MainActor
struct ManagerOwnedWorkTests {

    // MARK: - Automatic search

    @Test("An automatic search is sent once, and a new queue item for the movie reads as found")
    func automaticSearchFindsAQueuedResult() async throws {
        let radarr = try await DualInstanceRadarrServer(label: "auto-search-found", movies: "[]")
        defer { radarr.stop() }
        // Already queued on the server, but not yet in the manager's cached queue -
        // so the baseline is empty and the first check sees it as new.
        radarr.queueBody = Self.queuePage(movieID: 42)

        try await withRadarr(radarr) { manager in
            manager.automaticSearchCheckInterval = .zero
            let scope = ArrAutomaticSearchScope.movie(instanceID: nil, movieID: 42)

            let search = manager.startAutomaticSearch(scope, title: "Arrival")
            #expect(manager.automaticSearches[scope] == .searching)
            #expect(manager.startAutomaticSearch(scope, title: "Arrival") == nil, "A running search is not sent twice.")

            await search?.value
            #expect(manager.automaticSearches[scope] == .found)
            let commands = radarr.commandBodies.filter { $0.contains("MoviesSearch") }
            #expect(commands.count == 1)
            #expect(commands.first?.contains("42") == true)
        }
    }

    @Test("With nothing new in the queue the search ends as no results, and leaving clears only a finished search")
    func automaticSearchWithoutResultEndsAndClears() async throws {
        let radarr = try await DualInstanceRadarrServer(label: "auto-search-none", movies: "[]")
        defer { radarr.stop() }

        try await withRadarr(radarr) { manager in
            manager.automaticSearchCheckInterval = .zero
            manager.automaticSearchChecks = 2
            let scope = ArrAutomaticSearchScope.movie(instanceID: nil, movieID: 7)

            let search = manager.startAutomaticSearch(scope, title: "Heat")
            // Leaving the screen while it runs keeps it.
            manager.dismissFinishedAutomaticSearch(scope)
            #expect(manager.automaticSearches[scope] == .searching)

            await search?.value
            #expect(manager.automaticSearches[scope] == .noResults)
            manager.dismissFinishedAutomaticSearch(scope)
            #expect(manager.automaticSearches[scope] == nil)
        }
    }

    // MARK: - Backups

    @Test("Creating a backup is held by the manager until it finishes, then bumps the revision")
    func backupCreationIsManagerOwned() async throws {
        let radarr = try await DualInstanceRadarrServer(label: "backup-create", movies: "[]")
        defer { radarr.stop() }

        try await withRadarr(radarr) { manager in
            manager.backupSettleDelay = .zero
            let instance = try #require(manager.refs(for: .radarr).first)
            let revision = manager.backupRevision

            let work = manager.createBackup(on: instance)
            #expect(manager.backupWork[instance.id] == .creating)
            #expect(manager.createBackup(on: instance) == nil, "One piece of backup work per server at a time.")

            await work?.value
            #expect(manager.backupWork[instance.id] == nil)
            #expect(manager.backupRevision == revision &+ 1)
            #expect(radarr.commandBodies.filter { $0.contains("Backup") }.count == 1)
        }
    }

    // MARK: - Jellyfin library scan

    @Test("Two cards asking for a rescan start one scan, which ends once the title shows up")
    func libraryScanIsSharedAcrossCards() async throws {
        let server = try await Self.jellyfinServer(label: "scan-shared", itemsPage: Self.arrivalPage)
        defer { server.stop() }

        try await withJellyfin(server) { manager in
            manager.libraryScanRecheckInterval = .zero
            let media = Self.arrival

            let first = manager.scanLibraries(watching: .title(media))
            let second = manager.scanLibraries(watching: .title(media))
            #expect(first == second)
            #expect(manager.isScanningLibraries)

            await first?.value
            #expect(!manager.isScanningLibraries)
            #expect(manager.libraryScanWatches.isEmpty)
            #expect(server.requestCount(path: "/Library/Refresh") == 1)
        }
    }

    @Test("Disconnecting ends a scan that is still waiting for its title")
    func disconnectEndsAWaitingScan() async throws {
        let server = try await Self.jellyfinServer(label: "scan-disconnect", itemsPage: #"{"Items":[],"TotalRecordCount":0}"#)
        defer { server.stop() }

        try await withJellyfin(server) { manager in
            manager.libraryScanRecheckInterval = .seconds(3_600)
            let scan = manager.scanLibraries(watching: .title(Self.arrival))
            // The scan request itself is the barrier: by then the scan is running.
            await server.waitForReceivedRequests(server.requests.count + 1)

            manager.disconnect()
            #expect(!manager.isScanningLibraries)
            await scan?.value
            #expect(!manager.isScanningLibraries, "A cancelled scan finishing late must not touch the new state.")
            #expect(manager.libraryScanWatches.isEmpty)
        }
    }

    @Test("A refreshed item stays marked for every card until the connection changes")
    func refreshedItemIsManagerOwned() async throws {
        let server = try await Self.jellyfinServer(label: "item-refresh", itemsPage: Self.arrivalPage)
        defer { server.stop() }

        try await withJellyfin(server) { manager in
            let item = try JSONDecoder().decode(JellyfinLibraryItem.self, from: Data(#"{"Id":"arrival","Name":"Arrival","Type":"Movie"}"#.utf8))
            await manager.refreshItem(item, for: Self.arrival)
            #expect(manager.refreshedItemIDs == ["arrival"])
            #expect(server.requestCount(path: "/Items/arrival/Refresh") == 1)

            manager.disconnect()
            #expect(manager.refreshedItemIDs.isEmpty)
        }
    }

    // MARK: - Helpers

    private static let arrival = JellyfinMediaAvailabilityCard.Media.movie(title: "Arrival", year: 2016, tmdbId: 329865, imdbId: nil)
    private static let arrivalPage = #"{"Items":[{"Id":"arrival","Name":"Arrival","Type":"Movie","ProductionYear":2016,"ProviderIds":{"Tmdb":"329865"}}],"TotalRecordCount":1}"#

    private static func queuePage(movieID: Int) -> String {
        #"{"page":1,"pageSize":100,"totalRecords":1,"records":[{"id":501,"movieId":\#(movieID),"title":"Arrival.2016.1080p","status":"downloading"}]}"#
    }

    private static func jellyfinServer(label: String, itemsPage: String) async throws -> JellyfinFixtureServer {
        try await JellyfinFixtureServer(label: label) { request in
            switch request.path {
            case "/System/Info": .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.11.0"}"#)
            case "/Users": .json(#"[{"Id":"u1","Name":"sam"}]"#)
            case "/Library/Refresh": .noContent
            case let path where path.hasSuffix("/Refresh"): .noContent
            default: .json(itemsPage)
            }
        }
    }

    private func withRadarr(_ server: DualInstanceRadarrServer, _ body: (ArrServiceManager) async throws -> Void) async throws {
        let manager = ArrServiceManager()
        let profile = ArrServiceProfile(displayName: "Radarr", hostURL: server.baseURL, serviceType: .radarr, qualityTier: .hd)
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "work-key")
        defer {
            let key = profile.apiKeyKeychainKey
            Task { try? await KeychainHelper.shared.delete(key: key) }
        }
        await manager.connectService(profile)
        #expect(manager.connectedRadarr.count == 1)
        try await body(manager)
    }

    private func withJellyfin(_ server: JellyfinFixtureServer, _ body: (JellyfinServiceManager) async throws -> Void) async throws {
        let profile = JellyfinServiceProfile(displayName: "Test Jellyfin", hostURL: server.baseURL, authMode: .apiKey)
        try await KeychainHelper.shared.save(key: profile.accessTokenKey, value: "work-token")
        defer {
            let key = profile.accessTokenKey
            Task { try? await KeychainHelper.shared.delete(key: key) }
        }
        let manager = JellyfinServiceManager()
        await manager.connectService(profile)
        #expect(manager.isConnected)
        try await body(manager)
    }
}
