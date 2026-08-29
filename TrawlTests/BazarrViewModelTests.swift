import Foundation
import SwiftUI
import Testing
@testable import Trawl

/// Coverage for `BazarrViewModel.swift`:
///
/// - **Part A** - `SubtitleCoverage`'s computed properties and the
///   `statusColor`/`statusIcon`/`BazarrBrowserTab` helpers. Pure logic, no
///   server involved.
/// - **Part B** - the `searchText` / `showMonitoredOnly` / `showMissingOnly` /
///   `sortNewestFirst` filter pipeline. Seeded via `BazarrViewModel`'s own
///   `#if DEBUG` preview initializer (real production code, not a test double),
///   so this also needs no server - `applyFilters()` only ever reads state
///   already sitting on the view model.
/// - **Part C** - `isConnected` / `isConnecting` / `connectionError` read
///   through a real `ArrServiceManager` against `BazarrFixtureServer`.
/// - **Part D** - `loadSeries` / `loadMovies` / `loadEpisodes(for:)` against
///   `BazarrFixtureServer`, including a test that a retained view model follows
///   an in-place reconnect to the new host - see
///   `retainedViewModelFollowsReconnectedClient`.
@Suite("BazarrViewModel", .serialized)
@MainActor
struct BazarrViewModelTests {

    // MARK: - Part A: SubtitleCoverage

    @Test("hasIndicator is false only for .unknown")
    func hasIndicatorHidesOnlyUnknown() {
        #expect(SubtitleCoverage.unknown.hasIndicator == false)
        #expect(SubtitleCoverage.noneFound.hasIndicator == true)
        #expect(SubtitleCoverage.presentUntracked.hasIndicator == true)
        #expect(SubtitleCoverage.tracked(missing: 0).hasIndicator == true)
        #expect(SubtitleCoverage.tracked(missing: 4).hasIndicator == true)
    }

    @Test(arguments: subtitleCoverageCases)
    fileprivate func subtitleCoverageMatchesExpectation(_ testCase: SubtitleCoverageCase) {
        #expect(testCase.coverage.hasIndicator == testCase.hasIndicator, "\(testCase.name): hasIndicator")
        #expect(testCase.coverage.isFullyCovered == testCase.isFullyCovered, "\(testCase.name): isFullyCovered")
        #expect(testCase.coverage.badgeLabel == testCase.badgeLabel, "\(testCase.name): badgeLabel")
    }

    @Test("iconTint and badgeColor group complete states teal, incomplete orange, and none/unknown secondary")
    func subtitleCoverageColors() {
        // Comparing directly against the same named `Color` constants production
        // uses (.teal/.orange/.secondary), per the guidance that this is reliable
        // for named/system colors even though Color equality isn't reliable in
        // general.
        #expect(SubtitleCoverage.tracked(missing: 0).iconTint == Color.teal)
        #expect(SubtitleCoverage.tracked(missing: 3).iconTint == Color.orange)
        #expect(SubtitleCoverage.presentUntracked.iconTint == Color.teal)
        #expect(SubtitleCoverage.noneFound.iconTint == Color.secondary)
        #expect(SubtitleCoverage.unknown.iconTint == Color.secondary)

        #expect(SubtitleCoverage.tracked(missing: 0).badgeColor == Color.teal)
        #expect(SubtitleCoverage.tracked(missing: 3).badgeColor == Color.orange)
        #expect(SubtitleCoverage.presentUntracked.badgeColor == Color.teal)
        #expect(SubtitleCoverage.noneFound.badgeColor == Color.secondary)
        #expect(SubtitleCoverage.unknown.badgeColor == Color.secondary)
    }

    @Test("statusColor/statusIcon map each BazarrSubtitleStatus to its color and SF Symbol")
    func statusColorAndIcon() {
        let vm = BazarrViewModel(previewState: .empty)
        #expect(vm.statusColor(for: .allPresent) == Color.green)
        #expect(vm.statusIcon(for: .allPresent) == "checkmark.circle.fill")
        #expect(vm.statusColor(for: .partial) == Color.orange)
        #expect(vm.statusIcon(for: .partial) == "exclamationmark.triangle.fill")
        #expect(vm.statusColor(for: .none) == Color.red)
        #expect(vm.statusIcon(for: .none) == "xmark.circle.fill")
        #expect(vm.statusColor(for: .unknown) == Color.gray)
        #expect(vm.statusIcon(for: .unknown) == "questionmark.circle.fill")
    }

    @Test("BazarrBrowserTab exposes exactly Series and Movies with matching raw values")
    func browserTabCases() {
        let cases = BazarrBrowserTab.allCases
        #expect(cases.count == 2)
        #expect(cases.map(\.rawValue) == ["Series", "Movies"])
        #expect(BazarrBrowserTab(rawValue: "Series") != nil)
        #expect(BazarrBrowserTab(rawValue: "Movies") != nil)
        #expect(BazarrBrowserTab(rawValue: "series") == nil) // raw values are case-sensitive
    }

    // MARK: - Part B: filter pipeline

    @Test("With no filters set, all series and movies show newest-first (source order reversed)")
    func defaultFiltersShowEverythingReversed() {
        let vm = makeFilterViewModel()
        #expect(vm.filteredSeries.map(\.id) == [4, 3, 2, 1])
        #expect(vm.filteredMovies.map(\.id) == [4, 3, 2, 1])
    }

    @Test("Turning off sortNewestFirst restores source order")
    func sortOrderTogglesDirection() async {
        let vm = makeFilterViewModel()
        vm.sortNewestFirst = false
        let settled = await awaitCondition { vm.filteredSeries.map(\.id) == [1, 2, 3, 4] }
        #expect(settled)
    }

    @Test("Search text matches case-insensitively and on partial substrings, and non-matches yield nothing")
    func searchMatchesCaseInsensitivelyAndPartially() async {
        let vm = makeFilterViewModel()

        vm.searchText = "ALPHA"
        var settled = await awaitCondition { vm.filteredSeries.map(\.id) == [1] }
        #expect(settled)

        vm.searchText = "lph"
        settled = await awaitCondition { vm.filteredSeries.map(\.id) == [1] }
        #expect(settled)

        vm.searchText = "no-such-title"
        settled = await awaitCondition { vm.filteredSeries.isEmpty }
        #expect(settled)
    }

    @Test("A whitespace-only search is not treated as empty; it filters literally against a space")
    func whitespaceOnlySearchIsLiteral() async {
        let vm = makeFilterViewModel() // titles are Alpha/Bravo/Charlie/Delta - none contain a space
        vm.searchText = " "
        let settled = await awaitCondition { vm.filteredSeries.isEmpty && vm.filteredMovies.isEmpty }
        #expect(settled)
    }

    @Test("showMonitoredOnly and showMissingOnly each filter series independently")
    func monitoredAndMissingFilterSeriesIndependently() async {
        let vm = makeFilterViewModel()

        vm.showMonitoredOnly = true
        var settled = await awaitCondition { vm.filteredSeries.map(\.id) == [2, 1] } // Alpha & Bravo are monitored
        #expect(settled)

        vm.showMonitoredOnly = false
        vm.showMissingOnly = true
        settled = await awaitCondition { vm.filteredSeries.map(\.id) == [4, 2] } // Bravo & Delta have missing > 0
        #expect(settled)
    }

    @Test("Monitored and missing filters compose (intersect) rather than override each other")
    func monitoredAndMissingFiltersCompose() async {
        let vm = makeFilterViewModel()
        vm.showMonitoredOnly = true
        vm.showMissingOnly = true
        // Only Bravo is both monitored AND has missing subtitles > 0.
        let settled = await awaitCondition { vm.filteredSeries.map(\.id) == [2] }
        #expect(settled)
    }

    @Test("Search composes with the monitored filter instead of replacing it")
    func searchComposesWithMonitoredFilter() async {
        let vm = makeFilterViewModel()
        vm.searchText = "l" // matches Alpha, Charlie, Delta (not Bravo)
        vm.showMonitoredOnly = true // narrows further to Alpha only
        let settled = await awaitCondition { vm.filteredSeries.map(\.id) == [1] }
        #expect(settled)
    }

    @Test("Movie filters mirror series filters: monitored, missing, and their composition")
    func movieFiltersMirrorSeriesFilters() async {
        let vm = makeFilterViewModel()
        vm.showMonitoredOnly = true
        var settled = await awaitCondition { vm.filteredMovies.map(\.id) == [2, 1] }
        #expect(settled)

        vm.showMissingOnly = true
        settled = await awaitCondition { vm.filteredMovies.map(\.id) == [2] }
        #expect(settled)
    }

    @Test("An empty source list stays empty no matter which filters are set")
    func emptySourceStaysEmpty() async {
        let vm = BazarrViewModel(previewSeries: [], previewMovies: [], serviceManager: .preview(.allConfigured))
        #expect(vm.filteredSeries.isEmpty)
        #expect(vm.filteredMovies.isEmpty)

        vm.showMonitoredOnly = true
        vm.showMissingOnly = true
        vm.searchText = "anything"
        vm.sortNewestFirst = false
        let settled = await awaitCondition { vm.filteredSeries.isEmpty && vm.filteredMovies.isEmpty }
        #expect(settled)
    }

    // MARK: - Part C: connection state passthrough

    @Test("isConnected/isConnecting/connectionError read live off ArrServiceManager, including mid-flight isConnecting on a reconnect")
    func connectionStateTracksLiveDuringReconnect() async throws {
        let serverA = try await BazarrFixtureServer(label: "conn-a") { _ in .genericOK }
        defer { serverA.stop() }

        let profile = ArrServiceProfile(displayName: "Bazarr", hostURL: serverA.baseURL, serviceType: .bazarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let vm = BazarrViewModel(serviceManager: manager)
            #expect(vm.isConnected == true)
            #expect(vm.isConnecting == false)
            #expect(vm.connectionError == nil)

            // Reconnect the same profile to a server that parks its status
            // request, so isConnecting is observably true while it's in flight -
            // a real barrier via BazarrFixtureServer's park/release, no sleeping.
            let serverB = try await BazarrFixtureServer(label: "conn-b") { request in
                request.path == "/api/system/status" ? nil : .genericOK
            }
            defer { serverB.stop() }
            profile.hostURL = serverB.baseURL

            let reconnectTask = Task { await manager.connectService(profile) }

            let becameConnecting = await awaitCondition { vm.isConnecting == true }
            #expect(becameConnecting)
            // Stale value from the still-active serverA connection - unaffected
            // mid-flight, since setConnecting doesn't touch isConnected.
            #expect(vm.isConnected == true)
            #expect(vm.connectionError == nil)

            await serverB.waitForReceivedRequests(1)
            serverB.releaseParked(with: .genericOK)
            await reconnectTask.value

            let becameIdle = await awaitCondition { vm.isConnecting == false }
            #expect(becameIdle)
            #expect(vm.isConnected == true)
            #expect(vm.connectionError == nil)
        }
    }

    @Test("A failed reconnect clears isConnected and surfaces connectionError, with isConnecting settled back to false")
    func failedReconnectSurfacesConnectionError() async throws {
        let serverA = try await BazarrFixtureServer(label: "conn-fail-a") { _ in .genericOK }
        defer { serverA.stop() }
        let failingServer = try await BazarrFixtureServer(label: "conn-fail-b") { request in
            request.path == "/api/system/status"
                ? .json(#"{"message":"credentials rejected"}"#, status: 500)
                : .genericOK
        }
        defer { failingServer.stop() }

        let profile = ArrServiceProfile(displayName: "Bazarr", hostURL: serverA.baseURL, serviceType: .bazarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let vm = BazarrViewModel(serviceManager: manager)
            #expect(vm.isConnected == true)

            profile.hostURL = failingServer.baseURL
            await manager.connectService(profile)

            #expect(vm.isConnected == false)
            #expect(vm.isConnecting == false)
            let message = try #require(vm.connectionError)
            #expect(message.contains("500"))
        }
    }

    // MARK: - Part D: load paths

    @Test("loadSeries and loadMovies populate state and the filter pipeline on success")
    func loadSeriesAndMoviesSucceed() async throws {
        let server = try await BazarrFixtureServer(label: "load-success") { request in
            switch request.path {
            case "/api/series":
                return .json(#"{"data":[{"sonarrSeriesId":1,"title":"Alpha","year":null,"overview":null,"poster":null,"fanart":null,"audio_language":[],"episodeFileCount":10,"episodeMissingCount":0,"monitored":true,"profileId":1,"seriesType":null,"tags":[],"alternativeTitles":[],"ended":null,"lastAired":null},{"sonarrSeriesId":2,"title":"Bravo","year":null,"overview":null,"poster":null,"fanart":null,"audio_language":[],"episodeFileCount":10,"episodeMissingCount":2,"monitored":true,"profileId":1,"seriesType":null,"tags":[],"alternativeTitles":[],"ended":null,"lastAired":null}],"total":2}"#)
            case "/api/movies":
                return .json(#"{"data":[{"radarrId":1,"title":"Movie A","year":null,"overview":null,"poster":null,"fanart":null,"audio_language":[],"monitored":true,"profileId":1,"subtitles":[],"missing_subtitles":[],"tags":[],"alternativeTitles":[],"sceneName":null}],"total":1}"#)
            default:
                return .genericOK
            }
        }
        defer { server.stop() }

        let profile = ArrServiceProfile(displayName: "Bazarr", hostURL: server.baseURL, serviceType: .bazarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let vm = BazarrViewModel(serviceManager: manager)

            await vm.loadSeries()
            #expect(vm.series.map(\.id) == [1, 2])
            #expect(vm.filteredSeries.map(\.id) == [2, 1]) // reversed by default sortNewestFirst
            #expect(vm.seriesError == nil)
            #expect(vm.isLoadingSeries == false)

            await vm.loadMovies()
            #expect(vm.movies.map(\.id) == [1])
            #expect(vm.filteredMovies.map(\.id) == [1])
            #expect(vm.moviesError == nil)
            #expect(vm.isLoadingMovies == false)
        }
    }

    @Test("loadSeries surfaces a server error and clears series (production wipes rather than preserves prior state on failure)")
    func loadSeriesFailureClearsStateAndSurfacesError() async throws {
        let server = try await BazarrFixtureServer(label: "load-series-fail") { request in
            request.path == "/api/series"
                ? .json(#"{"message":"boom"}"#, status: 500)
                : .genericOK
        }
        defer { server.stop() }

        let profile = ArrServiceProfile(displayName: "Bazarr", hostURL: server.baseURL, serviceType: .bazarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let vm = BazarrViewModel(serviceManager: manager)

            await vm.loadSeries()
            #expect(vm.series.isEmpty)
            #expect(vm.filteredSeries.isEmpty)
            #expect(vm.isLoadingSeries == false)
            let message = try #require(vm.seriesError)
            #expect(message.contains("500"))
        }
    }

    @Test("loadEpisodes(for:) populates episodes on success and surfaces the error with an empty array on failure")
    func loadEpisodesSucceedsAndFails() async throws {
        let successServer = try await BazarrFixtureServer(label: "episodes-success") { request in
            request.path == "/api/episodes"
                ? .json(#"[{"sonarrEpisodeId":30,"sonarrSeriesId":10,"season":1,"episode":1,"title":"Pilot","monitored":true,"subtitles":[],"missing_subtitles":[],"audio_language":[],"path":null,"sceneName":null}]"#)
                : .genericOK
        }
        defer { successServer.stop() }

        let successProfile = ArrServiceProfile(displayName: "Bazarr", hostURL: successServer.baseURL, serviceType: .bazarr)
        let successManager = ArrServiceManager()
        try await withSavedAPIKey(for: successProfile) {
            await successManager.connectService(successProfile)
            let vm = BazarrViewModel(serviceManager: successManager)
            await vm.loadEpisodes(for: 10)
            #expect(vm.episodes[10]?.map(\.id) == [30])
            #expect(vm.episodesError == nil)
            #expect(vm.isLoadingEpisodes == false)
        }

        let failingServer = try await BazarrFixtureServer(label: "episodes-fail") { request in
            request.path == "/api/episodes"
                ? .json(#"{"message":"boom"}"#, status: 500)
                : .genericOK
        }
        defer { failingServer.stop() }

        let failingProfile = ArrServiceProfile(displayName: "Bazarr", hostURL: failingServer.baseURL, serviceType: .bazarr)
        let failingManager = ArrServiceManager()
        try await withSavedAPIKey(for: failingProfile) {
            await failingManager.connectService(failingProfile)
            let vm = BazarrViewModel(serviceManager: failingManager)
            await vm.loadEpisodes(for: 10)
            #expect(vm.episodes[10]?.isEmpty == true)
            #expect(vm.isLoadingEpisodes == false)
            #expect(vm.episodesError != nil)
        }
    }

    @Test("With no connected Bazarr instance, load calls set their guard error and clear state without touching the network")
    func loadCallsGuardWhenNoClientIsConnected() async {
        let manager = ArrServiceManager()
        let vm = BazarrViewModel(serviceManager: manager)

        await vm.loadSeries()
        #expect(vm.seriesError == "No connected Bazarr instance")
        #expect(vm.series.isEmpty)
        #expect(vm.filteredSeries.isEmpty)

        await vm.loadMovies()
        #expect(vm.moviesError == "No connected Bazarr instance")
        #expect(vm.movies.isEmpty)

        await vm.loadEpisodes(for: 1)
        #expect(vm.episodesError == "No connected Bazarr instance")
        #expect(vm.episodes[1]?.isEmpty == true)
    }

    /// `SonarrViewModel` and `RadarrViewModel` construct their base
    /// `ArrLibraryViewModel` with a `clientProvider` closure so a retained view
    /// model picks up the replacement client after an in-place reconnect -
    /// `ArrClientLifecycleTests` proves that for both. `BazarrViewModel` was the
    /// odd one out: it passed only a static client snapshot, so a retained view
    /// model went on talking to the host it was born with. This is the same
    /// stale-client bug, and this test is what stops it coming back.
    @Test("A retained BazarrViewModel follows the manager to the reconnected host")
    func retainedViewModelFollowsReconnectedClient() async throws {
        let serverA = try await BazarrFixtureServer(label: "stale-a") { request in
            request.path == "/api/series" ? .json(#"{"data":[{"sonarrSeriesId":1,"title":"From A","year":null,"overview":null,"poster":null,"fanart":null,"audio_language":[],"episodeFileCount":1,"episodeMissingCount":0,"monitored":true,"profileId":1,"seriesType":null,"tags":[],"alternativeTitles":[],"ended":null,"lastAired":null}],"total":1}"#) : .genericOK
        }
        defer { serverA.stop() }
        let serverB = try await BazarrFixtureServer(label: "stale-b") { request in
            request.path == "/api/series" ? .json(#"{"data":[{"sonarrSeriesId":2,"title":"From B","year":null,"overview":null,"poster":null,"fanart":null,"audio_language":[],"episodeFileCount":1,"episodeMissingCount":0,"monitored":true,"profileId":1,"seriesType":null,"tags":[],"alternativeTitles":[],"ended":null,"lastAired":null}],"total":1}"#) : .genericOK
        }
        defer { serverB.stop() }

        let profile = ArrServiceProfile(displayName: "Bazarr", hostURL: serverA.baseURL, serviceType: .bazarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let vm = BazarrViewModel(serviceManager: manager)
            await vm.loadSeries()
            #expect(vm.series.map(\.title) == ["From A"])
            let requestsToABeforeReconnect = serverA.requestCount(path: "/api/series")

            profile.hostURL = serverB.baseURL
            await manager.connectService(profile)
            #expect(manager.bazarrClient(for: profile.id) != nil)

            await vm.loadSeries()

            // The refresh must land on the reconnected host, and server A must
            // see no further traffic at all - a stale client would show up as
            // both the old title and an extra request to A.
            #expect(vm.series.map(\.title) == ["From B"])
            #expect(serverA.requestCount(path: "/api/series") == requestsToABeforeReconnect)
            #expect(serverB.requestCount(path: "/api/series") >= 1)
        }
    }

    // MARK: - Helpers

    private func makeFilterViewModel() -> BazarrViewModel {
        let series = [
            makeSeries(id: 1, title: "Alpha", monitored: true, missingCount: 0),
            makeSeries(id: 2, title: "Bravo", monitored: true, missingCount: 3),
            makeSeries(id: 3, title: "Charlie", monitored: false, missingCount: 0),
            makeSeries(id: 4, title: "Delta", monitored: false, missingCount: 5),
        ]
        let nonEmptyMissing = BazarrMovie.previewMissingSubtitles.missingSubtitles
        // No spaces in any title (series or movie): the whitespace-only search
        // test relies on none of these matching a literal " " query.
        let movies = [
            makeMovie(id: 1, title: "AlphaMovie", monitored: true, missingSubtitles: []),
            makeMovie(id: 2, title: "BravoMovie", monitored: true, missingSubtitles: nonEmptyMissing),
            makeMovie(id: 3, title: "CharlieMovie", monitored: false, missingSubtitles: []),
            makeMovie(id: 4, title: "DeltaMovie", monitored: false, missingSubtitles: nonEmptyMissing),
        ]
        return BazarrViewModel(previewSeries: series, previewMovies: movies, serviceManager: .preview(.allConfigured))
    }

    private func makeSeries(id: Int, title: String, monitored: Bool, missingCount: Int) -> BazarrSeries {
        BazarrSeries(
            sonarrSeriesId: id, title: title, year: nil, overview: nil, poster: nil, fanart: nil,
            audioLanguages: [], episodeFileCount: 10, episodeMissingCount: missingCount,
            monitored: monitored, profileId: 1, seriesType: nil, tags: [], alternativeTitles: [],
            ended: nil, lastAired: nil
        )
    }

    private func makeMovie(id: Int, title: String, monitored: Bool, missingSubtitles: [BazarrSubtitleLanguage]) -> BazarrMovie {
        BazarrMovie(
            radarrId: id, title: title, year: nil, overview: nil, poster: nil, fanart: nil,
            audioLanguages: [], monitored: monitored, profileId: 1, subtitles: [],
            missingSubtitles: missingSubtitles, tags: [], alternativeTitles: [], sceneName: nil
        )
    }

    /// `searchText`/`showMonitoredOnly`/`showMissingOnly`/`sortNewestFirst` each
    /// fire an unstructured, unawaited `Task { await applyFilters() }` from
    /// `didSet` with no seam to await directly - matching the documented
    /// exception to "no sleeping." Mirrors `OnboardingViewModelTests.awaitCondition`
    /// and `SeerrIssueListViewModelTests.awaitCondition`.
    private func awaitCondition(maxYields: Int = 2_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func withSavedAPIKey(
        for profile: ArrServiceProfile,
        operation: () async throws -> Void
    ) async throws {
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "bazarr-view-model-test-key")
        do {
            try await operation()
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        } catch {
            try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            throw error
        }
    }
}

// MARK: - Table-driven SubtitleCoverage fixture

fileprivate struct SubtitleCoverageCase: Sendable {
    let name: String
    let coverage: SubtitleCoverage
    let hasIndicator: Bool
    let isFullyCovered: Bool
    let badgeLabel: String
}

fileprivate let subtitleCoverageCases: [SubtitleCoverageCase] = [
    .init(name: "unknown", coverage: .unknown, hasIndicator: false, isFullyCovered: false, badgeLabel: ""),
    .init(name: "noneFound", coverage: .noneFound, hasIndicator: true, isFullyCovered: false, badgeLabel: "No Subs"),
    .init(name: "presentUntracked", coverage: .presentUntracked, hasIndicator: true, isFullyCovered: true, badgeLabel: "Subs Present"),
    .init(name: "tracked(missing: 0) - the complete boundary", coverage: .tracked(missing: 0), hasIndicator: true, isFullyCovered: true, badgeLabel: "Subs Complete"),
    .init(name: "tracked(missing: 1) - just past the boundary", coverage: .tracked(missing: 1), hasIndicator: true, isFullyCovered: false, badgeLabel: "1 Missing"),
    .init(name: "tracked(missing: 6)", coverage: .tracked(missing: 6), hasIndicator: true, isFullyCovered: false, badgeLabel: "6 Missing"),
]
