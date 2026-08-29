import Foundation
import Testing
@testable import Trawl

/// Stateful-logic tests for `JellyfinAvailabilityResolver`.
///
/// Every test drives the real resolver against a real `JellyfinAPIClient`
/// pointed at a loopback `JellyfinFixtureServer`. Nothing is mocked at the
/// method level: the tier ordering, the local match filter, the cache/dedupe
/// rules and the LRU eviction are all observed through the resolver's own public
/// surface (`state(for:)` / `episodesState(for:)`) and through what the server
/// actually received.
///
/// Synchronisation is entirely continuation-based - the server resumes a
/// `CheckedContinuation` when it has served (or had torn down) the expected
/// number of requests. There are no sleeps and no timing assumptions.
@Suite("Jellyfin availability resolver state", .serialized)
@MainActor
struct JellyfinAvailabilityResolverTests {

    // MARK: - Lookup tier ordering

    @Test("A provider-ID hit at tier 1 short-circuits: the title and distinctive-word searches are never requested")
    func providerHitShortCircuitsFallbackTiers() async throws {
        let providerPage = #"{"Items":[{"Id":"arrival","Name":"Totally Different Name","Type":"Movie","ProductionYear":1990,"ProviderIds":{"Tmdb":"329865"}}],"TotalRecordCount":1}"#

        let server = try await JellyfinFixtureServer(label: "tier-one-hit") { _ in
            JellyfinFixtureResponse.json(providerPage)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(
            title: "Arrival",
            year: 2016,
            tmdbId: 329865,
            imdbId: nil
        )
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        let items = try await jellyfinSettledItems(resolver, key: key)

        #expect(items.map(\.id) == ["arrival"])
        // The item's name and year deliberately match nothing, so only the
        // provider-ID branch of localMatches can have accepted it.
        #expect(server.requests.count == 1)
        #expect(server.requests[0].queryValue("AnyProviderIdEquals") == "Tmdb.329865")
        #expect(server.requests[0].queryValue("SearchTerm") == nil)
    }

    @Test("Media with no provider IDs at all skips the provider tier and searches by title on the first request")
    func mediaWithoutProviderIDsSkipsProviderTier() async throws {
        let searchPage = #"{"Items":[{"Id":"arrival","Name":"Arrival","Type":"Movie","ProductionYear":2016}],"TotalRecordCount":1}"#

        let server = try await JellyfinFixtureServer(label: "no-provider-ids") { _ in
            JellyfinFixtureResponse.json(searchPage)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(
            title: "Arrival",
            year: 2016,
            tmdbId: nil,
            imdbId: nil
        )
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        let items = try await jellyfinSettledItems(resolver, key: key)

        #expect(items.map(\.id) == ["arrival"])
        #expect(server.requests.count == 1)
        #expect(server.requests[0].queryValue("AnyProviderIdEquals") == nil)
        #expect(server.requests[0].queryValue("SearchTerm") == "Arrival")
    }

    @Test("Resolved items are sorted by name, not by the order the server returned them")
    func resolvedItemsAreSortedByName() async throws {
        // Both items carry the queried Tmdb id, so both survive localMatches;
        // the server returns them in reverse alphabetical order.
        let page = """
        {"Items":[\
        {"Id":"zulu","Name":"Zulu Cut","Type":"Movie","ProviderIds":{"Tmdb":"777"}},\
        {"Id":"mid","Name":"Midnight Cut","Type":"Movie","ProviderIds":{"Tmdb":"777"}},\
        {"Id":"alpha","Name":"Alpha Cut","Type":"Movie","ProviderIds":{"Tmdb":"777"}}\
        ],"TotalRecordCount":3}
        """

        let server = try await JellyfinFixtureServer(label: "sorting") { _ in
            JellyfinFixtureResponse.json(page)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(
            title: "Some Cut",
            year: nil,
            tmdbId: 777,
            imdbId: nil
        )
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        let items = try await jellyfinSettledItems(resolver, key: key)

        #expect(items.map(\.name) == ["Alpha Cut", "Midnight Cut", "Zulu Cut"])
    }

    // MARK: - localMatches rules

    /// One fixture server per case, all serving the same candidate page for
    /// every tier. That makes the request count itself an assertion about which
    /// tier accepted the candidate: 1 means the first tier attempted matched, a
    /// higher count means the candidate was rejected and the resolver fell
    /// through.
    @Test("The local match filter accepts or rejects candidates by the documented provider-ID and title/year rules", arguments: JellyfinMatchCase.all)
    fileprivate func localMatchRules(_ testCase: JellyfinMatchCase) async throws {
        let page = testCase.candidatesJSON
        let server = try await JellyfinFixtureServer(label: "match-\(testCase.label)") { _ in
            JellyfinFixtureResponse.json(page)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = testCase.makeMedia()
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        // Barrier on the first response only; the remaining tiers (if any) are
        // drained by the settle helper, so a wrong expectation shows up as a
        // failed count assertion rather than as a stuck continuation.
        await server.waitForServedResponses(1)
        let items = try await jellyfinSettledItems(resolver, key: key)

        #expect(items.map(\.id) == testCase.expectedIDs, "\(testCase.label)")
        #expect(server.requests.count == testCase.expectedRequestCount, "\(testCase.label)")
    }

    // MARK: - Cache and dedupe

    @Test("Two ensureLoaded calls for the same key issue exactly one request, and a third after resolution issues none")
    func ensureLoadedDedupesWhileLoadingAndAfterResolving() async throws {
        let page = #"{"Items":[{"Id":"dedupe","Name":"Dedupe","Type":"Movie","ProviderIds":{"Tmdb":"42"}}],"TotalRecordCount":1}"#
        let server = try await JellyfinFixtureServer(label: "dedupe") { _ in
            JellyfinFixtureResponse.json(page)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Dedupe", year: nil, tmdbId: 42, imdbId: nil)
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        // The second call happens while the first is still `.loading`.
        resolver.ensureLoaded(key, media: media, client: client)
        if case .loading = resolver.state(for: key) {} else {
            Issue.record("Expected the key to be .loading immediately after the first ensureLoaded.")
        }
        resolver.ensureLoaded(key, media: media, client: client)

        await server.waitForServedResponses(1)
        let items = try await jellyfinSettledItems(resolver, key: key)
        #expect(items.map(\.id) == ["dedupe"])

        // The third call happens once the key is `.resolved`.
        resolver.ensureLoaded(key, media: media, client: client)
        let itemsAfter = try await jellyfinSettledItems(resolver, key: key)

        #expect(itemsAfter.map(\.id) == ["dedupe"])
        #expect(server.requests.count == 1)
    }

    @Test("Keys are namespaced by profile: the same media under a different profile is looked up again")
    func cacheIsScopedPerProfile() async throws {
        let page = #"{"Items":[{"Id":"shared","Name":"Shared","Type":"Movie","ProviderIds":{"Tmdb":"9"}}],"TotalRecordCount":1}"#
        let server = try await JellyfinFixtureServer(label: "per-profile") { _ in
            JellyfinFixtureResponse.json(page)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Shared", year: nil, tmdbId: 9, imdbId: nil)
        let first = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)
        let second = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(first, media: media, client: client)
        await server.waitForServedResponses(1)
        _ = try await jellyfinSettledItems(resolver, key: first)

        #expect(resolver.state(for: second).isIdle)
        resolver.ensureLoaded(second, media: media, client: client)
        await server.waitForServedResponses(2)
        _ = try await jellyfinSettledItems(resolver, key: second)

        #expect(server.requests.count == 2)
    }

    @Test("A failed lookup is cached and not retried by ensureLoaded while it is still fresh")
    func failedLookupIsStickyAndNotRetried() async throws {
        let server = try await JellyfinFixtureServer(label: "failure") { _ in
            JellyfinFixtureResponse.json(#"{"Message":"Boom."}"#, status: 500)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Broken", year: nil, tmdbId: 5, imdbId: nil)
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        let state = try await jellyfinSettledState(resolver, key: key)

        guard case .failed(let message) = state else {
            Issue.record("Expected .failed, got \(state).")
            return
        }
        #expect(message == JellyfinAPIError.http(status: 500, body: #"{"Message":"Boom."}"#).localizedDescription)

        // ensureLoaded returns early on `.failed`, so a repeat call inside the
        // failure TTL issues no second request. (Expiry past that TTL is covered
        // by the clock-driven tests below.)
        resolver.ensureLoaded(key, media: media, client: client)
        #expect(server.requests.count == 1)
        guard case .failed = resolver.state(for: key) else {
            Issue.record("Expected the key to stay .failed.")
            return
        }
    }

    // MARK: - TTL expiry (driven by an injected clock, never by waiting)

    @Test("A resolved entry expires after the 300s TTL and the next ensureLoaded fetches again")
    func resolvedEntryExpiresAfterTTL() async throws {
        let server = try await JellyfinFixtureServer(label: "ttl-resolved") { _ in
            JellyfinFixtureResponse.json(
                #"{"Items":[{"Id":"i1","Name":"Broken","ProviderIds":{"Tmdb":"5"}}],"TotalRecordCount":1}"#
            )
        }
        defer { server.stop() }

        let clock = JellyfinManualClock()
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver(now: clock.reader)
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Broken", year: nil, tmdbId: 5, imdbId: nil)
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        _ = try await jellyfinSettledState(resolver, key: key)

        // One second short of the TTL the answer is still served from cache.
        clock.advance(by: 299)
        guard case .resolved = resolver.state(for: key) else {
            Issue.record("Expected the entry to still be resolved at 299s.")
            return
        }
        resolver.ensureLoaded(key, media: media, client: client)
        #expect(server.requests.count == 1)

        // Past it, the entry reads as idle and ensureLoaded refetches.
        clock.advance(by: 2)
        guard case .idle = resolver.state(for: key) else {
            Issue.record("Expected the entry to expire past the 300s TTL.")
            return
        }
        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(2)
        #expect(server.requests.count == 2)
    }

    @Test("A failed entry expires after the shorter 60s failure TTL, so a transient error self-heals")
    func failedEntryExpiresAfterFailureTTL() async throws {
        let server = try await JellyfinFixtureServer(label: "ttl-failed") { _ in
            JellyfinFixtureResponse.json(#"{"Message":"Boom."}"#, status: 500)
        }
        defer { server.stop() }

        let clock = JellyfinManualClock()
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver(now: clock.reader)
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Broken", year: nil, tmdbId: 5, imdbId: nil)
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        _ = try await jellyfinSettledState(resolver, key: key)

        clock.advance(by: 59)
        guard case .failed = resolver.state(for: key) else {
            Issue.record("Expected the failure to still be cached at 59s.")
            return
        }
        resolver.ensureLoaded(key, media: media, client: client)
        #expect(server.requests.count == 1)

        // A failure must not outlive its own TTL - the whole point of the shorter
        // window is that a dropped connection stops pinning the card in an error.
        clock.advance(by: 2)
        guard case .idle = resolver.state(for: key) else {
            Issue.record("Expected the failure to expire past the 60s failure TTL.")
            return
        }
        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(2)
        #expect(server.requests.count == 2)
    }

    @Test("A failure is still cached at the point a success would have been, proving the two TTLs differ")
    func failureTTLIsShorterThanResolvedTTL() async throws {
        let server = try await JellyfinFixtureServer(label: "ttl-asymmetry") { _ in
            JellyfinFixtureResponse.json(#"{"Message":"Boom."}"#, status: 500)
        }
        defer { server.stop() }

        let clock = JellyfinManualClock()
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver(now: clock.reader)
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Broken", year: nil, tmdbId: 5, imdbId: nil)
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        _ = try await jellyfinSettledState(resolver, key: key)

        // 120s: past the failure TTL, well short of the resolved TTL.
        clock.advance(by: 120)
        guard case .idle = resolver.state(for: key) else {
            Issue.record("A failure at 120s should have expired even though a success would not have.")
            return
        }
    }

    @Test("An episode failure expires on the same shorter failure TTL")
    func episodeFailureExpiresAfterFailureTTL() async throws {
        let server = try await JellyfinFixtureServer(label: "ttl-episodes") { request in
            request.path.hasSuffix("/Episodes")
                ? JellyfinFixtureResponse.json(#"{"Message":"No."}"#, status: 404)
                : JellyfinFixtureResponse.json(#"{"Items":[],"TotalRecordCount":0}"#)
        }
        defer { server.stop() }

        let clock = JellyfinManualClock()
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver(now: clock.reader)
        let key = JellyfinAvailabilityResolver.EpisodesKey(profileID: UUID(), seriesItemID: "series-1")

        resolver.ensureEpisodesLoaded(key, client: client)
        await server.waitForServedResponses(1)
        _ = try await jellyfinSettledEpisodeState(resolver, key: key)

        clock.advance(by: 61)
        guard case .idle = resolver.episodesState(for: key) else {
            Issue.record("Expected the episode failure to expire past the 60s failure TTL.")
            return
        }
        resolver.ensureEpisodesLoaded(key, client: client)
        await server.waitForServedResponses(2)
        #expect(server.requests.count == 2)
    }

    @Test("invalidate returns the key to idle and lets the next ensureLoaded fetch again")
    func invalidateReturnsKeyToIdleAndRefetches() async throws {
        let page = #"{"Items":[{"Id":"again","Name":"Again","Type":"Movie","ProviderIds":{"Tmdb":"3"}}],"TotalRecordCount":1}"#
        let server = try await JellyfinFixtureServer(label: "invalidate") { _ in
            JellyfinFixtureResponse.json(page)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Again", year: nil, tmdbId: 3, imdbId: nil)
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        _ = try await jellyfinSettledItems(resolver, key: key)

        resolver.invalidate(key)
        #expect(resolver.state(for: key).isIdle)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(2)
        let items = try await jellyfinSettledItems(resolver, key: key)

        #expect(items.map(\.id) == ["again"])
        #expect(server.requests.count == 2)
    }

    @Test("invalidateAll clears resolved availability and resolved episodes together")
    func invalidateAllClearsBothCaches() async throws {
        let itemsPage = #"{"Items":[{"Id":"series-1","Name":"Series One","Type":"Series","ProviderIds":{"Tvdb":"100"}}],"TotalRecordCount":1}"#
        let episodesPage = #"{"Items":[{"Id":"ep-1","Name":"Pilot","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1}],"TotalRecordCount":1}"#

        let server = try await JellyfinFixtureServer(label: "invalidate-all") { request in
            request.path == "/Items"
                ? JellyfinFixtureResponse.json(itemsPage)
                : JellyfinFixtureResponse.json(episodesPage)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let profileID = UUID()
        let media = JellyfinMediaAvailabilityCard.Media.series(
            title: "Series One",
            year: nil,
            tvdbId: 100,
            tmdbId: nil,
            imdbId: nil,
            totalEpisodes: 1
        )
        let key = JellyfinAvailabilityResolver.Key(profileID: profileID, mediaTaskKey: media.taskKey)
        let episodesKey = JellyfinAvailabilityResolver.EpisodesKey(profileID: profileID, seriesItemID: "series-1")

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForServedResponses(1)
        _ = try await jellyfinSettledItems(resolver, key: key)

        resolver.ensureEpisodesLoaded(episodesKey, client: client)
        await server.waitForServedResponses(2)
        _ = try await jellyfinSettledEpisodeState(resolver, key: episodesKey)

        resolver.invalidateAll()

        #expect(resolver.state(for: key).isIdle)
        #expect(resolver.episodesState(for: episodesKey).isIdle)
    }

    @Test(
        "invalidate cancels the in-flight lookup at the socket, and the late response never lands in the cache",
        .timeLimit(.minutes(1))
    )
    func invalidateCancelsInFlightLookup() async throws {
        // Returning nil parks the connection: the server never answers, so the
        // request stays in flight until something cancels it.
        let server = try await JellyfinFixtureServer(label: "cancel-inflight") { _ in nil }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Parked", year: nil, tmdbId: 8, imdbId: nil)
        let key = JellyfinAvailabilityResolver.Key(profileID: UUID(), mediaTaskKey: media.taskKey)

        resolver.ensureLoaded(key, media: media, client: client)
        await server.waitForReceivedRequests(1)
        if case .loading = resolver.state(for: key) {} else {
            Issue.record("Expected the key to be .loading while the request is parked.")
        }

        resolver.invalidate(key)
        #expect(resolver.state(for: key).isIdle)

        // The client tearing the parked socket down is the observable proof that
        // Task.cancel() reached URLSession - no polling, no sleeping.
        await server.waitForClosedConnections(1)

        // Nothing the server could now say can revive the entry: the cancelled
        // task's `guard !Task.isCancelled` gate stops it writing back.
        server.releaseParked(with: .json(#"{"Items":[],"TotalRecordCount":0}"#))
        #expect(resolver.state(for: key).isIdle)
        #expect(server.requests.count == 1)
    }

    // MARK: - LRU eviction

    @Test("The availability cache holds 64 entries: inserting a 65th evicts the oldest and keeps the newest")
    func availabilityCacheEvictsOldestPastSixtyFour() throws {
        // `ensureLoaded` writes the `.loading` entry synchronously before it
        // spawns the lookup task, so the eviction is fully observable without
        // ever letting a request complete. The client points at a port nothing
        // listens on, and every spawned task is cancelled by `invalidateAll()`
        // below, so no network work outlives this test.
        let client = JellyfinAPIClient(baseURL: "http://127.0.0.1:1", accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        defer { resolver.invalidateAll() }

        let profileID = UUID()
        var keys: [JellyfinAvailabilityResolver.Key] = []
        // No `await` between these calls, so the main actor never yields and no
        // lookup can mutate the cache mid-loop.
        for index in 0..<65 {
            let media = JellyfinMediaAvailabilityCard.Media.movie(
                title: "Movie \(index)",
                year: nil,
                tmdbId: index,
                imdbId: nil
            )
            let key = JellyfinAvailabilityResolver.Key(profileID: profileID, mediaTaskKey: media.taskKey)
            keys.append(key)
            resolver.ensureLoaded(key, media: media, client: client)
        }

        #expect(resolver.state(for: keys[0]).isIdle, "The oldest entry should have been evicted.")
        #expect(resolver.state(for: keys[1]).isLoading, "The second-oldest entry should have survived.")
        #expect(resolver.state(for: keys[64]).isLoading, "The newest entry should have survived.")
    }

    @Test("The episode cache holds 32 entries: inserting a 33rd evicts the oldest and keeps the newest")
    func episodeCacheEvictsOldestPastThirtyTwo() throws {
        let client = JellyfinAPIClient(baseURL: "http://127.0.0.1:1", accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        defer { resolver.invalidateAll() }

        let profileID = UUID()
        var keys: [JellyfinAvailabilityResolver.EpisodesKey] = []
        for index in 0..<33 {
            let key = JellyfinAvailabilityResolver.EpisodesKey(profileID: profileID, seriesItemID: "series-\(index)")
            keys.append(key)
            resolver.ensureEpisodesLoaded(key, client: client)
        }

        #expect(resolver.episodesState(for: keys[0]).isIdle, "The oldest episode entry should have been evicted.")
        #expect(resolver.episodesState(for: keys[1]).isLoading, "The second-oldest episode entry should have survived.")
        #expect(resolver.episodesState(for: keys[32]).isLoading, "The newest episode entry should have survived.")
    }

    // MARK: - Episodes

    @Test("ensureEpisodesLoaded requests the series episode path once, keeps server order, and dedupes")
    func episodesResolveOnceAndKeepServerOrder() async throws {
        let episodesPage = """
        {"Items":[\
        {"Id":"e3","Name":"Zeta","Type":"Episode","IndexNumber":3,"ParentIndexNumber":1},\
        {"Id":"e1","Name":"Alpha","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1}\
        ],"TotalRecordCount":2}
        """
        let server = try await JellyfinFixtureServer(label: "episodes") { _ in
            JellyfinFixtureResponse.json(episodesPage)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let key = JellyfinAvailabilityResolver.EpisodesKey(profileID: UUID(), seriesItemID: "series-77")

        resolver.ensureEpisodesLoaded(key, client: client)
        resolver.ensureEpisodesLoaded(key, client: client)

        await server.waitForServedResponses(1)
        let state = try await jellyfinSettledEpisodeState(resolver, key: key)

        guard case .resolved(let items) = state else {
            Issue.record("Expected .resolved, got \(state).")
            return
        }
        // Unlike the availability path, episodes are stored in the order the
        // server returned them - they are not re-sorted by name.
        #expect(items.map(\.id) == ["e3", "e1"])

        resolver.ensureEpisodesLoaded(key, client: client)
        #expect(server.requests.count == 1)
        #expect(server.requests[0].path == "/Shows/series-77/Episodes")
    }

    @Test("A failing episode lookup caches .failed and is not retried until invalidateEpisodes clears it")
    func episodeFailureIsStickyUntilInvalidated() async throws {
        let server = try await JellyfinFixtureServer(label: "episodes-failure") { request in
            request.path.hasSuffix("/Episodes")
                ? JellyfinFixtureResponse.json(#"{"Message":"No."}"#, status: 404)
                : JellyfinFixtureResponse.json(#"{"Items":[],"TotalRecordCount":0}"#)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let resolver = JellyfinAvailabilityResolver()
        let key = JellyfinAvailabilityResolver.EpisodesKey(profileID: UUID(), seriesItemID: "missing")

        resolver.ensureEpisodesLoaded(key, client: client)
        await server.waitForServedResponses(1)
        let state = try await jellyfinSettledEpisodeState(resolver, key: key)

        guard case .failed = state else {
            Issue.record("Expected .failed, got \(state).")
            return
        }

        resolver.ensureEpisodesLoaded(key, client: client)
        #expect(server.requests.count == 1)

        resolver.invalidateEpisodes(key)
        #expect(resolver.episodesState(for: key).isIdle)

        resolver.ensureEpisodesLoaded(key, client: client)
        await server.waitForServedResponses(2)
        _ = try await jellyfinSettledEpisodeState(resolver, key: key)
        #expect(server.requests.count == 2)
    }
}

// MARK: - Convenience state predicates

extension JellyfinAvailabilityResolver.State {
    fileprivate var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    fileprivate var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - localMatches case table

/// Plain data only - the `JellyfinMediaAvailabilityCard.Media` value is built
/// inside the `@MainActor` test body, which keeps this table usable from the
/// nonisolated context `@Test(arguments:)` evaluates it in.
private nonisolated struct JellyfinMatchCase: Sendable, CustomStringConvertible {
    enum Kind: Sendable { case movie, series }

    let label: String
    let kind: Kind
    let title: String
    var year: Int?
    var tvdbId: Int?
    var tmdbId: Int?
    var imdbId: String?
    let candidatesJSON: String
    let expectedIDs: [String]
    /// 1 when the first tier attempted matched. With provider IDs present a
    /// rejection costs 3 requests (provider, title, distinctive word); without
    /// them, 2 (title, distinctive word).
    let expectedRequestCount: Int

    var description: String { label }

    @MainActor
    func makeMedia() -> JellyfinMediaAvailabilityCard.Media {
        switch kind {
        case .movie:
            return .movie(title: title, year: year, tmdbId: tmdbId, imdbId: imdbId)
        case .series:
            return .series(title: title, year: year, tvdbId: tvdbId, tmdbId: tmdbId, imdbId: imdbId, totalEpisodes: nil)
        }
    }

    /// A single-item page whose name and year deliberately match nothing, so
    /// only a provider-ID match can accept it.
    static func providerOnlyItem(id: String, providerIds: String) -> String {
        #"{"Items":[{"Id":"\#(id)","Name":"Nothing Like The Title","Type":"Movie","ProductionYear":1901,"ProviderIds":\#(providerIds)}],"TotalRecordCount":1}"#
    }

    static func titleItem(id: String, name: String, year: Int?) -> String {
        let yearField = year.map { #","ProductionYear":\#($0)"# } ?? ""
        return #"{"Items":[{"Id":"\#(id)","Name":"\#(name)","Type":"Movie"\#(yearField)}],"TotalRecordCount":1}"#
    }

    static let all: [JellyfinMatchCase] = [
        // --- provider-ID tier ---
        JellyfinMatchCase(
            label: "tmdb-exact",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            tmdbId: 329_865,
            candidatesJSON: providerOnlyItem(id: "hit", providerIds: #"{"Tmdb":"329865"}"#),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "tmdb-value-whitespace-trimmed",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            tmdbId: 329_865,
            candidatesJSON: providerOnlyItem(id: "hit", providerIds: #"{"Tmdb":"  329865 "}"#),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "tmdb-provider-key-case-insensitive",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            tmdbId: 329_865,
            candidatesJSON: providerOnlyItem(id: "hit", providerIds: #"{"tmdb":"329865"}"#),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "imdb-value-case-insensitive",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            imdbId: "tt2543164",
            candidatesJSON: providerOnlyItem(id: "hit", providerIds: #"{"Imdb":"TT2543164"}"#),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "provider-mismatch-falls-through-and-finds-nothing",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            tmdbId: 329_865,
            candidatesJSON: providerOnlyItem(id: "miss", providerIds: #"{"Tmdb":"111"}"#),
            expectedIDs: [],
            expectedRequestCount: 3
        ),
        JellyfinMatchCase(
            label: "series-tvdb-exact",
            kind: .series,
            title: "Severance",
            year: 2022,
            tvdbId: 371_980,
            candidatesJSON: providerOnlyItem(id: "hit", providerIds: #"{"Tvdb":"371980"}"#),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "series-tmdb-when-tvdb-absent",
            kind: .series,
            title: "Severance",
            year: 2022,
            tmdbId: 95_396,
            candidatesJSON: providerOnlyItem(id: "hit", providerIds: #"{"Tmdb":"95396"}"#),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "empty-imdb-string-never-matches",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            imdbId: "",
            candidatesJSON: providerOnlyItem(id: "miss", providerIds: #"{"Imdb":""}"#),
            expectedIDs: [],
            // An empty imdbId produces no provider pair at all, so tier 1 is skipped.
            expectedRequestCount: 2
        ),

        // --- title / year fallback (no provider IDs on the media at all) ---
        JellyfinMatchCase(
            label: "title-and-year-exact",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            candidatesJSON: titleItem(id: "hit", name: "Arrival", year: 2016),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "year-one-below-is-within-tolerance",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            candidatesJSON: titleItem(id: "hit", name: "Arrival", year: 2015),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "year-one-above-is-within-tolerance",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            candidatesJSON: titleItem(id: "hit", name: "Arrival", year: 2017),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "year-two-apart-is-rejected",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            candidatesJSON: titleItem(id: "miss", name: "Arrival", year: 2018),
            expectedIDs: [],
            expectedRequestCount: 2
        ),
        JellyfinMatchCase(
            label: "item-without-production-year-matches-on-title-alone",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            candidatesJSON: titleItem(id: "hit", name: "Arrival", year: nil),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "media-without-year-matches-on-title-alone",
            kind: .movie,
            title: "Arrival",
            year: nil,
            candidatesJSON: titleItem(id: "hit", name: "Arrival", year: 1901),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "jellyfin-disambiguation-year-suffix-is-stripped",
            kind: .series,
            title: "A Knight of the Seven Kingdoms",
            year: 2025,
            candidatesJSON: titleItem(id: "hit", name: "A Knight of the Seven Kingdoms (2025)", year: 2025),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "non-19xx-20xx-parenthetical-is-not-stripped",
            kind: .movie,
            title: "Arrival",
            year: nil,
            candidatesJSON: titleItem(id: "miss", name: "Arrival (1899)", year: nil),
            expectedIDs: [],
            expectedRequestCount: 2
        ),
        JellyfinMatchCase(
            label: "punctuation-and-case-are-normalised-away",
            kind: .movie,
            title: "Spider-Man: No Way Home",
            year: 2021,
            candidatesJSON: titleItem(id: "hit", name: "spider man   no way home!", year: 2021),
            expectedIDs: ["hit"],
            expectedRequestCount: 1
        ),
        JellyfinMatchCase(
            label: "different-title-is-rejected",
            kind: .movie,
            title: "Arrival",
            year: 2016,
            candidatesJSON: titleItem(id: "miss", name: "Departure", year: 2016),
            expectedIDs: [],
            expectedRequestCount: 2
        )
    ]
}
