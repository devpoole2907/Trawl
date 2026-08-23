import Foundation
import Network
import Testing
@testable import Trawl

/// `SearchViewModel` sits directly on the M-05 / N-01 defect classes: a stale
/// Arr lookup overwriting a newer one, or a cancelled query leaving the UI
/// stuck loading. These tests drive the real view model (never a stub) against
/// real loopback Sonarr servers, using checked-continuation gates — never
/// `Task.sleep` — to control which HTTP response lands first.
@Suite("SearchViewModel behavior", .serialized)
@MainActor
struct SearchViewModelTests {

    // MARK: - Library reconciliation (isInLibrary)

    @Test("A movie whose tmdbId matches a Radarr library entry is reported as in the library")
    func movieInLibraryWhenTmdbIdMatches() throws {
        let libraryMovie = try Self.makeRadarrMovie(id: 1, title: "Dune", tmdbId: 693134)
        let viewModel = SearchViewModel(sonarrSeries: [], radarrMovies: [libraryMovie])
        let trending = Self.makeMovie(id: 693134, title: "Dune: Part Two")

        #expect(viewModel.isInLibrary(trending) == true)
    }

    @Test("A movie whose tmdbId does not match any Radarr library entry is reported as not in the library")
    func movieNotInLibraryWhenTmdbIdDiffers() throws {
        let libraryMovie = try Self.makeRadarrMovie(id: 1, title: "Dune", tmdbId: 11_111)
        let viewModel = SearchViewModel(sonarrSeries: [], radarrMovies: [libraryMovie])
        let trending = Self.makeMovie(id: 693134, title: "Dune: Part Two")

        #expect(viewModel.isInLibrary(trending) == false)
    }

    @Test("A Radarr library entry with a nil tmdbId never matches, even against its own arr-internal id")
    func movieWithNilTmdbIdNeverMatches() throws {
        // The library row's *arr* id happens to equal the trending item's TMDb
        // id; isInLibrary must only ever compare tmdbId, never the arr id.
        let libraryMovie = try Self.makeRadarrMovie(id: 693134, title: "Dune", tmdbId: nil)
        let viewModel = SearchViewModel(sonarrSeries: [], radarrMovies: [libraryMovie])
        let trending = Self.makeMovie(id: 693134, title: "Dune")

        #expect(viewModel.isInLibrary(trending) == false)
    }

    @Test("A TV series matches a library title case-insensitively")
    func seriesInLibraryMatchesTitleCaseInsensitively() throws {
        let libraryShow = try Self.makeSonarrSeries(id: 1, title: "Severance")
        let viewModel = SearchViewModel(sonarrSeries: [libraryShow], radarrMovies: [])
        let trending = Self.makeShow(id: 95396, name: "SEVERANCE")

        #expect(viewModel.isInLibrary(trending) == true)
    }

    @Test("A TV series title that only partially overlaps a library title does not match")
    func seriesPartialTitleOverlapDoesNotMatch() throws {
        let libraryShow = try Self.makeSonarrSeries(id: 1, title: "The Bear")
        let viewModel = SearchViewModel(sonarrSeries: [libraryShow], radarrMovies: [])
        let trending = Self.makeShow(id: 136315, name: "The Bear Returns")

        #expect(viewModel.isInLibrary(trending) == false)
    }

    @Test("A TV series title with extra whitespace does not match an otherwise identical library title")
    func seriesWhitespaceDoesNotMatch() throws {
        let libraryShow = try Self.makeSonarrSeries(id: 1, title: "Severance")
        let viewModel = SearchViewModel(sonarrSeries: [libraryShow], radarrMovies: [])
        let trending = Self.makeShow(id: 95396, name: "Severance ")

        #expect(viewModel.isInLibrary(trending) == false)
    }

    // MARK: - Empty search terms

    @Test("An empty Arr search term resets lookup state instead of starting a search")
    func emptyArrSearchTermResetsLookupState() {
        let viewModel = SearchViewModel()
        viewModel.hasSearchedArr = true
        viewModel.searchText = "   "

        viewModel.startArrLookup(arrServiceManager: ArrServiceManager())

        #expect(viewModel.hasSearchedArr == false)
        #expect(viewModel.arrLookupTask == nil)
    }

    @Test("An empty library search term clears matched results")
    func emptyLibrarySearchTermClearsMatches() throws {
        let series = try Self.makeSonarrSeries(id: 1, title: "Severance")
        let movie = try Self.makeRadarrMovie(id: 1, title: "Dune", tmdbId: 1)
        let viewModel = SearchViewModel(
            sonarrSeries: [series],
            radarrMovies: [movie],
            matchedSeries: [series],
            matchedMovies: [movie]
        )
        viewModel.searchText = ""

        viewModel.startLibrarySearch()

        #expect(viewModel.matchedSeries.isEmpty)
        #expect(viewModel.matchedMovies.isEmpty)
    }

    // MARK: - Library search matching

    @Test("A library search term with no matches produces empty results, not a stuck task")
    func libraryTermWithNoMatchesProducesEmptyResults() async throws {
        let series = try Self.makeSonarrSeries(id: 1, title: "Severance")
        let viewModel = SearchViewModel(sonarrSeries: [series], radarrMovies: [])
        viewModel.searchText = "zzz-no-such-show-zzz"

        viewModel.startLibrarySearch()
        await viewModel.librarySearchTask?.value

        #expect(viewModel.matchedSeries.isEmpty)
        #expect(viewModel.matchedMovies.isEmpty)
    }

    @Test("A library search term matches by substring and sorts the results by title")
    func libraryTermWithMatchesReturnsSortedResults() async throws {
        let beta = try Self.makeSonarrSeries(id: 1, title: "Beta Show")
        let alpha = try Self.makeSonarrSeries(id: 2, title: "Alpha Show")
        let unrelated = try Self.makeSonarrSeries(id: 3, title: "Unrelated")
        let viewModel = SearchViewModel(sonarrSeries: [beta, alpha, unrelated], radarrMovies: [])
        viewModel.searchText = "Show"

        viewModel.startLibrarySearch()
        await viewModel.librarySearchTask?.value

        #expect(viewModel.matchedSeries.map(\.title) == ["Alpha Show", "Beta Show"])
    }

    // MARK: - Stale-result suppression (M-05 defect class)

    @Test("A slower first Arr lookup cannot overwrite a faster, newer one that completes first")
    func staleArrLookupCannotOverwriteNewerResults() async throws {
        let server = try await SearchLookupTestServer(label: "stale-result")
        defer { server.stop() }
        server.setLookupResponse(term: "Alpha", body: #"[{"id":1,"title":"Alpha Series"}]"#, gated: true)
        server.setLookupResponse(term: "Beta", body: #"[{"id":2,"title":"Beta Series"}]"#, gated: true)

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: server.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await Self.withSavedAPIKeys(for: [profile]) {
            await manager.connectService(profile)
            #expect(manager.sonarrConnected)

            let viewModel = SearchViewModel()
            viewModel.createLookupViewModels(arrServiceManager: manager)
            let sonarrVM = try #require(viewModel.sonarrLookupVM)

            // Query A starts and is held mid-flight by the server.
            let alphaTask = Task { @MainActor in await viewModel.performArrLookup(term: "Alpha") }
            await server.gate.waitUntilStarted("Alpha")
            #expect(sonarrVM.isSearching == true)

            // Query B starts on the same lookup view model while A is still in flight.
            let betaTask = Task { @MainActor in await viewModel.performArrLookup(term: "Beta") }
            await server.gate.waitUntilStarted("Beta")

            // B completes first.
            await server.gate.release("Beta")
            await betaTask.value

            #expect(sonarrVM.searchResults.map(\.title) == ["Beta Series"])
            #expect(sonarrVM.isSearching == false)
            #expect(viewModel.hasSearchedArr == true)

            // A completes after B. Its stale results must not replace B's.
            await server.gate.release("Alpha")
            await alphaTask.value

            #expect(sonarrVM.searchResults.map(\.title) == ["Beta Series"])
            #expect(sonarrVM.isSearching == false)
        }
    }

    // MARK: - Cancellation

    @Test("Resetting Arr lookup mid-flight leaves no stale results or a stuck loading state, even if the cancelled request later responds")
    func resetArrLookupDuringInFlightRequestLeavesCleanState() async throws {
        let server = try await SearchLookupTestServer(label: "cancellation")
        defer { server.stop() }
        server.setLookupResponse(term: "Alpha", body: #"[{"id":1,"title":"Alpha Series"}]"#, gated: true)

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: server.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await Self.withSavedAPIKeys(for: [profile]) {
            await manager.connectService(profile)

            let viewModel = SearchViewModel()
            viewModel.createLookupViewModels(arrServiceManager: manager)
            let sonarrVM = try #require(viewModel.sonarrLookupVM)

            viewModel.searchText = "Alpha"
            viewModel.startArrLookup(arrServiceManager: manager, immediate: true)
            let task = try #require(viewModel.arrLookupTask)
            await server.gate.waitUntilStarted("Alpha")
            #expect(sonarrVM.isSearching == true)
            #expect(viewModel.hasSearchedArr == true)

            viewModel.resetArrLookup()
            // Release the gate regardless, so a broken cancellation path can't
            // deadlock this test on a response that never arrives.
            await server.gate.release("Alpha")
            await task.value

            #expect(sonarrVM.isSearching == false)
            #expect(sonarrVM.searchResults.isEmpty)
            #expect(viewModel.hasSearchedArr == false)
        }
    }

    // MARK: - Failing search

    @Test("A failing Arr lookup surfaces a real error instead of a silent empty list")
    func failingArrLookupSurfacesError() async throws {
        let server = try await SearchLookupTestServer(label: "failing-lookup")
        defer { server.stop() }
        server.setLookupResponse(term: "Foo", statusCode: 500, body: #"{"message":"lookup rejected"}"#)

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: server.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await Self.withSavedAPIKeys(for: [profile]) {
            await manager.connectService(profile)

            let viewModel = SearchViewModel()
            viewModel.createLookupViewModels(arrServiceManager: manager)

            await viewModel.performArrLookup(term: "Foo")

            #expect(viewModel.arrLookupErrors.count == 1)
            #expect(viewModel.arrLookupErrors.first?.service == "Sonarr")
            #expect(viewModel.arrLookupErrors.first?.message == "Server error (500): lookup rejected")
            #expect(viewModel.sonarrLookupVM?.searchResults.isEmpty == true)
            #expect(viewModel.sonarrLookupVM?.isSearching == false)
        }
    }

    // MARK: - Profile changes

    @Test("Switching the active Sonarr instance discards the previous lookup view model and its results")
    func switchingActiveSonarrInstanceDiscardsStaleLookupResults() async throws {
        let serverA = try await SearchLookupTestServer(label: "profile-a")
        let serverB = try await SearchLookupTestServer(label: "profile-b")
        defer { serverA.stop(); serverB.stop() }
        serverA.setLookupResponse(term: "Alpha", body: #"[{"id":1,"title":"Alpha Series"}]"#)

        let profileA = ArrServiceProfile(displayName: "Sonarr A", hostURL: serverA.baseURL, serviceType: .sonarr)
        let profileB = ArrServiceProfile(displayName: "Sonarr B", hostURL: serverB.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await Self.withSavedAPIKeys(for: [profileA, profileB]) {
            await manager.connectService(profileA)
            await manager.connectService(profileB)
            #expect(manager.activeSonarrInstanceID == profileA.id)

            let viewModel = SearchViewModel()
            viewModel.createLookupViewModels(arrServiceManager: manager)
            let firstVM = try #require(viewModel.sonarrLookupVM)

            await viewModel.performArrLookup(term: "Alpha")
            #expect(firstVM.searchResults.map(\.title) == ["Alpha Series"])

            manager.setActiveSonarr(profileB.id)
            viewModel.createLookupViewModels(arrServiceManager: manager)
            let secondVM = try #require(viewModel.sonarrLookupVM)

            #expect(secondVM !== firstVM)
            #expect(secondVM.searchResults.isEmpty)
            #expect(secondVM.isSearching == false)
        }
    }

    @Test("Disconnecting Sonarr clears the search lookup view model instead of keeping stale results visible")
    func disconnectingSonarrClearsLookupViewModel() async throws {
        let workingServer = try await SearchLookupTestServer(label: "disconnect-working")
        let failingServer = try await SearchLookupTestServer(label: "disconnect-failing", systemStatusCode: 401)
        defer { workingServer.stop(); failingServer.stop() }
        workingServer.setLookupResponse(term: "Foo", body: #"[{"id":1,"title":"Foo Series"}]"#)

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: workingServer.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await Self.withSavedAPIKeys(for: [profile]) {
            await manager.connectService(profile)
            #expect(manager.sonarrConnected)

            let viewModel = SearchViewModel()
            viewModel.createLookupViewModels(arrServiceManager: manager)
            let connectedVM = try #require(viewModel.sonarrLookupVM)
            await viewModel.performArrLookup(term: "Foo")
            #expect(connectedVM.searchResults.map(\.title) == ["Foo Series"])

            profile.hostURL = failingServer.baseURL
            await manager.connectService(profile)
            #expect(manager.sonarrConnected == false)

            viewModel.createLookupViewModels(arrServiceManager: manager)
            #expect(viewModel.sonarrLookupVM == nil)
        }
    }

    // MARK: - Fixtures

    private static func makeMovie(id: Int, title: String) -> TMDbItem {
        TMDbItem(
            id: id,
            title: title,
            name: nil,
            posterPath: nil,
            backdropPath: nil,
            overview: nil,
            voteAverage: nil,
            releaseDate: nil,
            firstAirDate: nil,
            mediaType: "movie",
            genreIds: nil
        )
    }

    private static func makeShow(id: Int, name: String) -> TMDbItem {
        TMDbItem(
            id: id,
            title: nil,
            name: name,
            posterPath: nil,
            backdropPath: nil,
            overview: nil,
            voteAverage: nil,
            releaseDate: nil,
            firstAirDate: nil,
            mediaType: "tv",
            genreIds: nil
        )
    }

    private static func makeSonarrSeries(id: Int, title: String) throws -> SonarrSeries {
        try JSONDecoder().decode(SonarrSeries.self, from: Data(#"{"id": \#(id), "title": "\#(title)"}"#.utf8))
    }

    private static func makeRadarrMovie(id: Int, title: String, tmdbId: Int?) throws -> RadarrMovie {
        let tmdbField = tmdbId.map(String.init) ?? "null"
        let json = #"{"id": \#(id), "title": "\#(title)", "tmdbId": \#(tmdbField)}"#
        return try JSONDecoder().decode(RadarrMovie.self, from: Data(json.utf8))
    }

    private static func withSavedAPIKeys(
        for profiles: [ArrServiceProfile],
        operation: () async throws -> Void
    ) async throws {
        for profile in profiles {
            try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "search-vm-test-key")
        }
        do {
            try await operation()
        } catch {
            for profile in profiles {
                try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            }
            throw error
        }
        for profile in profiles {
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        }
    }
}

// MARK: - Gated loopback Sonarr server

/// Coordinates ordering between the test and a `SearchLookupTestServer`'s
/// in-flight lookup responses. `waitUntilStarted` resumes once the server has
/// received a given term's full request; `waitForRelease`/`release` hold (or
/// free) that term's HTTP response so a test can dictate completion order
/// without any `Task.sleep`.
private actor SearchViewModelLookupGate {
    private var startedTerms: Set<String> = []
    private var startContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedTerms: Set<String> = []
    private var releaseContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    func markStarted(_ term: String) {
        startedTerms.insert(term)
        if let waiters = startContinuations.removeValue(forKey: term) {
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilStarted(_ term: String) async {
        if startedTerms.contains(term) { return }
        await withCheckedContinuation { continuation in
            startContinuations[term, default: []].append(continuation)
        }
    }

    func waitForRelease(_ term: String) async {
        if releasedTerms.contains(term) { return }
        await withCheckedContinuation { continuation in
            releaseContinuations[term] = continuation
        }
    }

    func release(_ term: String) {
        releasedTerms.insert(term)
        releaseContinuations.removeValue(forKey: term)?.resume()
    }
}

/// A minimal loopback Sonarr server for `SearchViewModel` tests. Answers the
/// endpoints `ArrServiceManager.connectService` and Sonarr lookup need; a
/// lookup response can be gated so a test controls exactly when its HTTP
/// response lands, mirroring `ArrClientLifecycleTests`' server pattern.
private final class SearchLookupTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let systemStatusCode: Int
    let gate = SearchViewModelLookupGate()
    private let lock = NSLock()
    private var lookupFixtures: [String: (statusCode: Int, body: String)] = [:]
    private var gatedTerms: Set<String> = []

    init(label: String, systemStatusCode: Int = 200) async throws {
        self.queue = DispatchQueue(label: "SearchLookupTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.systemStatusCode = systemStatusCode
        listener.newConnectionHandler = { [weak self] connection in
            self?.respond(to: connection)
        }
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else { fatalError("Search lookup test server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    func stop() { listener.cancel() }

    /// Registers the response for a Sonarr `/series/lookup?term=` request.
    /// `gated: true` makes the server hold the response until the test calls
    /// `gate.release(term)`.
    func setLookupResponse(term: String, statusCode: Int = 200, body: String, gated: Bool = false) {
        lock.lock()
        lookupFixtures[term] = (statusCode, body)
        if gated { gatedTerms.insert(term) }
        lock.unlock()
    }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let (path, query) = Self.parse(data)

            if path == "/api/v3/series/lookup" {
                let term = Self.queryValue(query, name: "term") ?? ""
                self.lock.lock()
                let fixture = self.lookupFixtures[term] ?? (200, "[]")
                let isGated = self.gatedTerms.contains(term)
                self.lock.unlock()

                Task {
                    await self.gate.markStarted(term)
                    if isGated {
                        await self.gate.waitForRelease(term)
                    }
                    connection.send(
                        content: Self.httpResponse(statusCode: fixture.statusCode, body: fixture.body),
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                }
                return
            }

            let status: Int
            let body: String
            switch path {
            case "/api/v3/system/status":
                status = self.systemStatusCode
                body = self.systemStatusCode == 200 ? "{}" : #"{"message":"unauthorized"}"#
            case "/api/v3/qualityprofile", "/api/v3/rootfolder", "/api/v3/tag", "/api/v3/series":
                status = 200
                body = "[]"
            default:
                status = 200
                body = "[]"
            }
            connection.send(
                content: Self.httpResponse(statusCode: status, body: body),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func parse(_ data: Data) -> (path: String, query: String?) {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return ("", nil)
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return ("", nil) }
        let rawPath = String(parts[1])
        let components = rawPath.split(separator: "?", maxSplits: 1)
        let path = String(components.first ?? "")
        let query = components.count > 1 ? String(components[1]) : nil
        return (path, query)
    }

    private static func queryValue(_ query: String?, name: String) -> String? {
        guard let query else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == name else { continue }
            return kv[1].removingPercentEncoding
        }
        return nil
    }

    private static func httpResponse(statusCode: Int, body: String) -> Data {
        let statusText = statusCode == 200 ? "OK" : "Error"
        let bytes = Data(body.utf8)
        return Data(
            "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8
        ) + bytes
    }
}
