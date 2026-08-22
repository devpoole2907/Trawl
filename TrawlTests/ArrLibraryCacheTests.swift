import Testing
import Foundation
import Network
@testable import Trawl

private struct StubItem: Sendable, Equatable {
    let id: Int
}

@Suite("Arr Library Cache")
@MainActor
struct ArrLibraryCacheTests {
    private func makeCache() -> (ArrLibraryCache<StubItem>, UUID) {
        (ArrLibraryCache<StubItem>(), UUID())
    }

    @Test("Cold cache reports no items and never looks fresh")
    func coldCache() {
        let (cache, instance) = makeCache()
        #expect(cache.hasItems(for: instance) == false)
        #expect(cache.items(for: instance).isEmpty)
        #expect(cache.isFresh(instance, maxAge: 3600) == false)
    }

    @Test("An empty library is cached, not mistaken for unloaded")
    func emptyLibraryIsStillALoad() async throws {
        let (cache, instance) = makeCache()
        _ = try await cache.load(instanceID: instance, maxAge: 60) { [] }
        #expect(cache.hasItems(for: instance))
        #expect(cache.isFresh(instance, maxAge: 60))
    }

    @Test("A fresh cache is reused instead of refetched")
    func freshCacheSkipsFetch() async throws {
        let (cache, instance) = makeCache()
        let calls = Counter()

        _ = try await cache.load(instanceID: instance, maxAge: 60) {
            calls.increment()
            return [StubItem(id: 1)]
        }
        let second = try await cache.load(instanceID: instance, maxAge: 60) {
            calls.increment()
            return [StubItem(id: 2)]
        }

        #expect(calls.value == 1)
        #expect(second == [StubItem(id: 1)])
    }

    @Test("maxAge of zero always refetches")
    func forcedLoadAlwaysRefetches() async throws {
        let (cache, instance) = makeCache()
        let calls = Counter()

        _ = try await cache.load(instanceID: instance) {
            calls.increment()
            return [StubItem(id: 1)]
        }
        let second = try await cache.load(instanceID: instance) {
            calls.increment()
            return [StubItem(id: 2)]
        }

        #expect(calls.value == 2)
        #expect(second == [StubItem(id: 2)])
        #expect(cache.items(for: instance) == [StubItem(id: 2)])
    }

    @Test("Concurrent appear-time loads share one request")
    func concurrentLoadsCoalesce() async throws {
        let (cache, instance) = makeCache()
        let calls = Counter()

        func slowLoad() async throws -> [StubItem] {
            try await cache.load(instanceID: instance, maxAge: 60) {
                calls.increment()
                try await Task.sleep(for: .milliseconds(50))
                return [StubItem(id: 1)]
            }
        }

        async let a = slowLoad()
        async let b = slowLoad()
        let (first, second) = try await (a, b)

        #expect(calls.value == 1)
        #expect(first == [StubItem(id: 1)])
        #expect(second == [StubItem(id: 1)])
    }

    @Test("A forced load does not join a request that started before it")
    func forcedLoadDoesNotJoinInFlight() async throws {
        let (cache, instance) = makeCache()

        // Stands in for a poll that started before a delete landed.
        async let stale: [StubItem] = cache.load(instanceID: instance, maxAge: 60) {
            try await Task.sleep(for: .milliseconds(80))
            return [StubItem(id: 1), StubItem(id: 2)]
        }
        try await Task.sleep(for: .milliseconds(10))

        // The post-mutation reload must see post-mutation state.
        let forced = try await cache.load(instanceID: instance) { [StubItem(id: 1)] }
        #expect(forced == [StubItem(id: 1)])

        _ = try await stale
        // The older, slower answer must not overwrite the newer one.
        #expect(cache.items(for: instance) == [StubItem(id: 1)])
    }

    @Test("Invalidating keeps items but forces the next load to refetch")
    func invalidateKeepsItems() async throws {
        let (cache, instance) = makeCache()
        _ = try await cache.load(instanceID: instance, maxAge: 60) { [StubItem(id: 1)] }

        cache.invalidate(instance)

        #expect(cache.hasItems(for: instance))
        #expect(cache.items(for: instance) == [StubItem(id: 1)])
        #expect(cache.isFresh(instance, maxAge: 60) == false)
    }

    @Test("Pruning drops instances that no longer exist")
    func pruneDropsRemovedInstances() async throws {
        let cache = ArrLibraryCache<StubItem>()
        let kept = UUID()
        let removed = UUID()
        _ = try await cache.load(instanceID: kept, maxAge: 60) { [StubItem(id: 1)] }
        _ = try await cache.load(instanceID: removed, maxAge: 60) { [StubItem(id: 2)] }

        cache.prune(keeping: [kept])

        #expect(cache.hasItems(for: kept))
        #expect(cache.hasItems(for: removed) == false)
    }

    @Test("Libraries are kept apart per instance")
    func instancesAreIsolated() async throws {
        let cache = ArrLibraryCache<StubItem>()
        let first = UUID()
        let second = UUID()

        _ = try await cache.load(instanceID: first, maxAge: 60) { [StubItem(id: 1)] }

        #expect(cache.isFresh(second, maxAge: 60) == false)
        #expect(cache.items(for: second).isEmpty)
    }

    @Test("A failed fetch leaves the previous library in place")
    func failedFetchKeepsPreviousItems() async throws {
        let (cache, instance) = makeCache()
        _ = try await cache.load(instanceID: instance, maxAge: 60) { [StubItem(id: 1)] }

        await #expect(throws: (any Error).self) {
            try await cache.load(instanceID: instance) {
                throw ArrError.connectionFailed
            }
        }

        #expect(cache.items(for: instance) == [StubItem(id: 1)])
    }

    @Test("Nil instance still fetches but caches nothing")
    func nilInstanceIsUncached() async throws {
        let cache = ArrLibraryCache<StubItem>()
        let result = try await cache.load(instanceID: nil, maxAge: 60) { [StubItem(id: 1)] }

        #expect(result == [StubItem(id: 1)])
        #expect(cache.hasItems(for: nil) == false)
    }
}

/// Main-actor call counter — the cache is `@MainActor`, so every fetch closure
/// runs there and a plain counter is enough.
@MainActor
private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite("Arr service library cache repointing", .serialized)
@MainActor
struct ArrServiceLibraryCacheRepointingTests {
    @Test("Reconnecting a Sonarr profile ID to a new server refetches that profile's appear-time library")
    func reconnectingSonarrProfileRefetchesItsLibrary() async throws {
        try await assertRepointedSonarrProfileRefetches()
    }

    @Test("Reconnecting a Radarr profile ID to a new server refetches that profile's appear-time library")
    func reconnectingRadarrProfileRefetchesItsLibrary() async throws {
        try await assertRepointedRadarrProfileRefetches()
    }

    private func assertRepointedSonarrProfileRefetches() async throws {
        let serverA = try await RepointingArrTestServer(label: "server-a", libraryBody: #"[{"id": 1, "title": "Server A Series"}]"#)
        let serverB = try await RepointingArrTestServer(label: "server-b", libraryBody: #"[{"id": 2, "title": "Server B Series"}]"#)
        defer {
            serverA.stop()
            serverB.stop()
        }
        let profile = ArrServiceProfile(
            displayName: "Sonarr",
            hostURL: serverA.baseURL,
            serviceType: .sonarr
        )
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let fromServerA = try await manager.loadSeriesLibrary(maxAge: ArrLibraryCachePolicy.appearMaxAge)

            let unaffectedID = UUID()
            _ = try await manager.seriesLibrary.load(instanceID: unaffectedID, maxAge: 60) { [] }

            profile.hostURL = serverB.baseURL
            await manager.connectService(profile)
            let fromServerB = try await manager.loadSeriesLibrary(maxAge: ArrLibraryCachePolicy.appearMaxAge)

            #expect(fromServerA.map(\.title) == ["Server A Series"])
            #expect(fromServerB.map(\.title) == ["Server B Series"])
            #expect(serverA.requestedPaths == ["/api/v3/series"])
            #expect(serverB.requestedPaths == ["/api/v3/series"])
            #expect(manager.seriesLibrary.isFresh(unaffectedID, maxAge: 60))
        }
    }

    private func assertRepointedRadarrProfileRefetches() async throws {
        let serverA = try await RepointingArrTestServer(label: "server-a", libraryBody: #"[{"id": 1, "title": "Server A Movie"}]"#)
        let serverB = try await RepointingArrTestServer(label: "server-b", libraryBody: #"[{"id": 2, "title": "Server B Movie"}]"#)
        defer {
            serverA.stop()
            serverB.stop()
        }
        let profile = ArrServiceProfile(
            displayName: "Radarr",
            hostURL: serverA.baseURL,
            serviceType: .radarr
        )
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let fromServerA = try await manager.loadMovieLibrary(maxAge: ArrLibraryCachePolicy.appearMaxAge)

            let unaffectedID = UUID()
            _ = try await manager.movieLibrary.load(instanceID: unaffectedID, maxAge: 60) { [] }

            profile.hostURL = serverB.baseURL
            await manager.connectService(profile)
            let fromServerB = try await manager.loadMovieLibrary(maxAge: ArrLibraryCachePolicy.appearMaxAge)

            #expect(fromServerA.map(\.title) == ["Server A Movie"])
            #expect(fromServerB.map(\.title) == ["Server B Movie"])
            #expect(serverA.requestedPaths == ["/api/v3/movie"])
            #expect(serverB.requestedPaths == ["/api/v3/movie"])
            #expect(manager.movieLibrary.isFresh(unaffectedID, maxAge: 60))
        }
    }

    private func withSavedAPIKey(
        for profile: ArrServiceProfile,
        operation: () async throws -> Void
    ) async throws {
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "test-api-key")
        do {
            try await operation()
        } catch {
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            throw error
        }
        try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
    }

}

private final class RepointingArrTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let libraryBody: String
    private let lock = NSLock()
    private var paths: [String] = []

    init(label: String, libraryBody: String) async throws {
        self.libraryBody = libraryBody
        self.queue = DispatchQueue(label: "RepointingArrTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.respond(to: connection)
        }
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else {
            fatalError("Repointing test server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths.filter { $0 == "/api/v3/series" || $0 == "/api/v3/movie" }
    }

    func stop() {
        listener.cancel()
    }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let path = Self.requestPath(from: data)
            self.lock.lock()
            self.paths.append(path)
            self.lock.unlock()

            let body: String
            switch path {
            case "/api/v3/system/status":
                body = "{}"
            case "/api/v3/qualityprofile", "/api/v3/rootfolder", "/api/v3/tag":
                body = "[]"
            case "/api/v3/series", "/api/v3/movie":
                body = self.libraryBody
            default:
                body = "[]"
            }
            let response = Self.httpResponse(body: body)
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func requestPath(from data: Data) -> String {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.split(separator: "\r\n", maxSplits: 1).first else {
            return ""
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return "" }
        return String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
    }

    private static func httpResponse(body: String) -> Data {
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }
}
