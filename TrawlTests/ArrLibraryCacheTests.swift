import Testing
import Foundation
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
