import Foundation
import Testing
@testable import Trawl

/// Coverage for `SeerrIssueListViewModel` — pagination, dedup, request versioning,
/// filter switching, and the cross-filter search sweep. Previously untested.
///
/// `SeerrIssueListViewModel` takes a real `SeerrAPIClient` directly, so these drive
/// that real client (request builder, query encoding, decoder) against a recording
/// `URLProtocol` stub, following the pattern in `SeerrContractTests`. The stub type
/// here is private to this file, with its own distinct host, so it cannot collide
/// with `SeerrContractTests`' stub or any other test file's.
///
/// The suite is serialized because the stub protocol holds process-wide state.
@Suite("Seerr issue list view model", .serialized)
@MainActor
struct SeerrIssueListViewModelTests {

    // MARK: - Pagination

    @Test("loadMore requests skip = currentSkip + pageSize, de-duplicates by id, and advances currentSkip")
    func loadMoreDedupsAppendsAndAdvancesSkip() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            .init(body: pagedIssuesJSON(ids: Array(1...20), totalResults: 45)),
            // Page 2 overlaps three ids already loaded; only the two new ones should land.
            .init(body: pagedIssuesJSON(ids: [18, 19, 20, 21, 22], totalResults: 45)),
            .init(body: pagedIssuesJSON(ids: [23], totalResults: 45))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIssues()
        #expect(viewModel.issues.map(\.id) == Array(1...20))

        await viewModel.loadMore()
        #expect(viewModel.issues.map(\.id) == Array(1...22))
        let secondRequest = try #require(SeerrIssueListStubURLProtocol.recordedRequests[safe: 1])
        #expect(secondRequest.queryPairs == ["filter=open", "skip=20", "sort=added", "take=20"])

        // currentSkip must have advanced to 20, not stayed at 0 or jumped further.
        await viewModel.loadMore()
        let thirdRequest = try #require(SeerrIssueListStubURLProtocol.recordedRequests[safe: 2])
        #expect(thirdRequest.queryPairs == ["filter=open", "skip=40", "sort=added", "take=20"])
        #expect(viewModel.issues.map(\.id) == Array(1...23))
    }

    @Test("hasMore is false exactly at the boundary where currentSkip + pageSize equals totalResults")
    func hasMoreFalseAtBoundary() async throws {
        SeerrIssueListStubURLProtocol.stub(body: pagedIssuesJSON(ids: Array(1...20), totalResults: 20))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIssues()

        #expect(viewModel.hasMore == false)
    }

    @Test("hasMore is false one below the boundary")
    func hasMoreFalseBelowBoundary() async throws {
        SeerrIssueListStubURLProtocol.stub(body: pagedIssuesJSON(ids: Array(1...19), totalResults: 19))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIssues()

        #expect(viewModel.hasMore == false)
    }

    @Test("hasMore is true one above the boundary")
    func hasMoreTrueAboveBoundary() async throws {
        SeerrIssueListStubURLProtocol.stub(body: pagedIssuesJSON(ids: Array(1...20), totalResults: 21))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIssues()

        #expect(viewModel.hasMore == true)
    }

    @Test("totalIssueCount reports the server total when it's larger than the loaded page")
    func totalIssueCountReportsServerTotalWhenLarger() async throws {
        SeerrIssueListStubURLProtocol.stub(body: pagedIssuesJSON(ids: Array(1...20), totalResults: 45))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIssues()

        #expect(viewModel.totalIssueCount == 45)
    }

    @Test("totalIssueCount falls back to the loaded count when the server total is smaller")
    func totalIssueCountFallsBackToLoadedCountWhenSmaller() async throws {
        // A server reporting a smaller `results` total than the page it actually sent.
        SeerrIssueListStubURLProtocol.stub(body: pagedIssuesJSON(ids: Array(1...20), totalResults: 15))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIssues()

        #expect(viewModel.totalIssueCount == 20)
    }

    // MARK: - Request versioning

    @Test("A slow in-flight loadIssues response does not overwrite state from a newer request")
    func staleLoadIssuesResponseIsDiscarded() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            .init(hangs: true),
            .init(body: pagedIssuesJSON(ids: [101, 102], totalResults: 2))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        let staleTask = Task { await viewModel.loadIssues() }
        // Wait until the stale request has genuinely landed before racing a second one.
        await SeerrIssueListStubURLProtocol.requestLog.wait(untilCount: 1)

        await viewModel.loadIssues()

        #expect(viewModel.issues.map(\.id) == [101, 102])
        #expect(viewModel.isLoading == false)
        #expect(viewModel.errorMessage == nil)

        staleTask.cancel()
        _ = try? await staleTask.value
    }

    @Test("Changing selectedFilter reloads with the new filter value and resets currentSkip")
    func selectedFilterChangeReloadsAndResetsSkip() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            .init(body: pagedIssuesJSON(ids: Array(1...20), totalResults: 45)),
            .init(body: pagedIssuesJSON(ids: [21], totalResults: 45)),
            .init(body: pagedIssuesJSON(ids: [301, 302], totalResults: 45)),
            .init(body: pagedIssuesJSON(ids: [303], totalResults: 45))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())
        await viewModel.loadIssues()
        await viewModel.loadMore()
        #expect(SeerrIssueListStubURLProtocol.recordedRequests[1].queryPairs.contains("skip=20"))

        // selectedFilter's didSet spawns an unstructured, unawaited Task to reload —
        // there is no handle to await directly, so poll the observable state it
        // produces rather than sleeping on the clock.
        viewModel.selectedFilter = .resolved
        let reloaded = await awaitCondition { viewModel.issues.map(\.id) == [301, 302] }
        #expect(reloaded)

        let filterChangeRequest = try #require(SeerrIssueListStubURLProtocol.recordedRequests[safe: 2])
        #expect(filterChangeRequest.queryPairs == ["filter=resolved", "skip=0", "sort=added", "take=20"])

        // currentSkip must have been reset to 0 by the reload, not left at 20.
        await viewModel.loadMore()
        let followUpRequest = try #require(SeerrIssueListStubURLProtocol.recordedRequests[safe: 3])
        #expect(followUpRequest.queryPairs == ["filter=resolved", "skip=20", "sort=added", "take=20"])
    }

    @Test("Setting selectedFilter to its current value does not trigger a reload")
    func settingSameFilterValueDoesNotReload() async throws {
        SeerrIssueListStubURLProtocol.stub(body: pagedIssuesJSON(ids: Array(1...5), totalResults: 5))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())
        await viewModel.loadIssues()
        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 1)

        viewModel.selectedFilter = .open // already .open, the default

        // Give any (incorrectly) spawned reload a bounded chance to fire before
        // asserting it did not — there is nothing to await for an event that
        // should never happen.
        for _ in 0..<200 { await Task.yield() }
        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 1)
    }

    // MARK: - loadIfNeeded

    @Test("loadIfNeeded only issues a request the first time it's called")
    func loadIfNeededIsIdempotent() async throws {
        SeerrIssueListStubURLProtocol.stub(body: pagedIssuesJSON(ids: Array(1...3), totalResults: 3))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIfNeeded()
        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 1)

        await viewModel.loadIfNeeded()
        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 1)
    }

    // MARK: - Search

    @Test("An empty or whitespace-only search query clears results without making a request")
    func emptySearchQueryClearsResultsWithoutRequest() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            .init(body: pagedIssuesJSON(ids: [1, 2], totalResults: 2)),
            .init(body: pagedIssuesJSON(ids: [], totalResults: 0))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())
        await viewModel.updateSearchIssues(for: "matrix")
        #expect(!viewModel.searchIssues.isEmpty)
        let requestCountAfterSearch = SeerrIssueListStubURLProtocol.recordedRequests.count

        await viewModel.updateSearchIssues(for: "   \n ")

        #expect(viewModel.searchIssues.isEmpty)
        // The empty-query branch returns before ever calling the API.
        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == requestCountAfterSearch)
    }

    @Test("A non-empty search query loads every page across both filters and sorts by createdAt descending")
    func searchLoadsAllPagesAcrossBothFiltersAndSorts() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            // Open filter: pageInfo.results > searchPageSize (100) forces a second fetch.
            .init(body: pagedIssuesJSON(ids: [1, 2, 3], totalResults: 150, createdAt: { _ in "2026-08-01T00:00:00.000Z" })),
            .init(body: pagedIssuesJSON(ids: [4, 5], totalResults: 150, createdAt: { _ in "2026-08-05T00:00:00.000Z" })),
            // Resolved filter: a single page suffices.
            .init(body: pagedIssuesJSON(ids: [6], totalResults: 1, createdAt: { _ in "2026-08-10T00:00:00.000Z" }))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.updateSearchIssues(for: "leak")

        let requests = SeerrIssueListStubURLProtocol.recordedRequests
        #expect(requests.count == 3)
        #expect(requests[0].queryPairs == ["filter=open", "skip=0", "sort=added", "take=100"])
        #expect(requests[1].queryPairs == ["filter=open", "skip=100", "sort=added", "take=100"])
        #expect(requests[2].queryPairs == ["filter=resolved", "skip=0", "sort=added", "take=100"])

        // Descending by createdAt: id 6 (Aug 10) > ids 4,5 (Aug 5) > ids 1,2,3 (Aug 1).
        #expect(viewModel.searchIssues.map(\.id) == [6, 4, 5, 1, 2, 3])
    }

    @Test("A page reporting a huge total but returning zero items breaks the loop instead of looping forever")
    func searchBreaksOutOnEmptyPageDespiteLargeReportedTotal() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            .init(body: pagedIssuesJSON(ids: [], totalResults: 100_000)),
            .init(body: pagedIssuesJSON(ids: [], totalResults: 100_000))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.updateSearchIssues(for: "ghost")

        // Exactly one request per filter — the empty results array must break the
        // while loop before it can ask for a second page.
        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 2)
        #expect(viewModel.searchIssues.isEmpty)
    }

    @Test("A second search call for the same query after completion issues no further requests")
    func searchIsNotRepeatedAfterCompletion() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            .init(body: pagedIssuesJSON(ids: [1], totalResults: 1)),
            .init(body: pagedIssuesJSON(ids: [], totalResults: 0))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())
        await viewModel.updateSearchIssues(for: "matrix")
        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 2)

        await viewModel.updateSearchIssues(for: "matrix")

        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 2)
    }

    @Test("A concurrent search call while one is already in flight is suppressed")
    func concurrentSearchCallIsSuppressed() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [.init(hangs: true)])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        let firstCall = Task { await viewModel.updateSearchIssues(for: "matrix") }
        await SeerrIssueListStubURLProtocol.requestLog.wait(untilCount: 1)
        #expect(viewModel.isLoadingSearch == true)

        // Directly awaited: the isLoadingSearch guard should make this return
        // immediately without issuing a second request.
        await viewModel.updateSearchIssues(for: "matrix")

        #expect(SeerrIssueListStubURLProtocol.recordedRequests.count == 1)

        firstCall.cancel()
        _ = try? await firstCall.value
    }

    @Test("A failed search sets errorMessage and leaves searchIssues empty")
    func searchFailureSetsErrorMessage() async throws {
        SeerrIssueListStubURLProtocol.stub(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.updateSearchIssues(for: "leak")

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.searchIssues.isEmpty)
    }

    // MARK: - refreshIssue

    @Test("refreshIssue updates the matching entry in both issues and searchIssues")
    func refreshIssueUpdatesBothLists() async throws {
        SeerrIssueListStubURLProtocol.stub(sequence: [
            .init(body: pagedIssuesJSON(ids: [1, 2], totalResults: 2)),
            .init(body: pagedIssuesJSON(ids: [1], totalResults: 1)),
            .init(body: pagedIssuesJSON(ids: [], totalResults: 0))
        ])
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())
        await viewModel.loadIssues()
        await viewModel.updateSearchIssues(for: "leak")
        #expect(viewModel.issues.map(\.id) == [1, 2])
        #expect(viewModel.searchIssues.map(\.id) == [1])

        let updated = SeerrIssue(
            id: 1,
            issueType: 2,
            status: 2,
            media: nil,
            createdBy: nil,
            modifiedBy: nil,
            comments: nil,
            createdAt: nil,
            updatedAt: nil
        )
        viewModel.refreshIssue(updated)

        #expect(viewModel.issues.first(where: { $0.id == 1 })?.issueStatus == .resolved)
        #expect(viewModel.searchIssues.first(where: { $0.id == 1 })?.issueStatus == .resolved)
        // The untouched entry in `issues` is unaffected.
        #expect(viewModel.issues.first(where: { $0.id == 2 })?.issueStatus == .open)
    }

    // MARK: - Errors

    @Test("A failed loadIssues sets errorMessage, and clearError clears it")
    func loadIssuesFailureSetsErrorMessageAndClearErrorClearsIt() async throws {
        SeerrIssueListStubURLProtocol.stub(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8))
        let viewModel = SeerrIssueListViewModel(apiClient: makeClient())

        await viewModel.loadIssues()

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.isLoading == false)

        viewModel.clearError()

        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Helpers

    private func makeClient() -> SeerrAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeerrIssueListStubURLProtocol.self]
        return SeerrAPIClient(baseURL: "https://seerr.issuelist.test", sessionCookie: "vm-session", sessionConfiguration: configuration)
    }

    /// selectedFilter's didSet spawns `Task { await loadIssues() }` with no handle
    /// this test can await directly. Poll the resulting observable state instead of
    /// sleeping on the clock — mirrors `OnboardingViewModelTests.awaitCondition`,
    /// built for the identical "unstructured, unawaited Task" problem.
    private func awaitCondition(maxYields: Int = 5_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Fixtures

private func pagedIssuesJSON(
    ids: [Int],
    totalResults: Int,
    status: Int = 1,
    createdAt: ((Int) -> String?)? = nil
) -> Data {
    let items = ids.map { id -> String in
        var fields = [#""id": \#(id)"#, #""issueType": 1"#, #""status": \#(status)"#]
        if let createdAtValue = createdAt?(id) {
            fields.append(#""createdAt": "\#(createdAtValue)""#)
        }
        return "{ \(fields.joined(separator: ", ")) }"
    }.joined(separator: ",")

    return Data("""
    { "pageInfo": { "pages": 1, "pageSize": 20, "results": \(totalResults), "page": 1 }, "results": [\(items)] }
    """.utf8)
}

// MARK: - Ordering primitive

private nonisolated final class SeerrIssueListEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        let count = events.count
        let ready = waiters.filter { $0.threshold <= count }
        waiters.removeAll { $0.threshold <= count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(untilCount threshold: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if events.count >= threshold {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((threshold, continuation))
                lock.unlock()
            }
        }
    }

    func reset() {
        lock.lock()
        events = []
        waiters = []
        lock.unlock()
    }
}

// MARK: - Stub server

private nonisolated struct SeerrIssueListRecordedRequest: Sendable, Equatable {
    let method: String
    let path: String
    let queryPairs: [String]
}

/// Recording `URLProtocol` stub for `SeerrIssueListViewModelTests`, copied from the
/// pattern in `SeerrContractTests.SeerrContractURLProtocol` under a distinct name and
/// host so the two cannot collide.
private final class SeerrIssueListStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        var headerFields: [String: String] = ["Content-Type": "application/json"]
        var hangs: Bool = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [Stub] = [Stub()]
    nonisolated(unsafe) private static var responseIndex = 0
    nonisolated(unsafe) private static var requests: [SeerrIssueListRecordedRequest] = []
    static let requestLog = SeerrIssueListEventLog()

    static func stub(
        statusCode: Int = 200,
        body: Data = Data(),
        headerFields: [String: String] = ["Content-Type": "application/json"],
        hangs: Bool = false
    ) {
        stub(sequence: [Stub(statusCode: statusCode, body: body, headerFields: headerFields, hangs: hangs)])
    }

    /// Responses are consumed in order; the last one repeats for any extra request.
    static func stub(sequence: [Stub]) {
        lock.lock()
        responses = sequence.isEmpty ? [Stub()] : sequence
        responseIndex = 0
        requests = []
        lock.unlock()
        requestLog.reset()
    }

    static var recordedRequests: [SeerrIssueListRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "seerr.issuelist.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let recorded = SeerrIssueListRecordedRequest(
            method: request.httpMethod ?? "",
            path: url.path,
            queryPairs: Self.queryPairs(from: components)
        )

        Self.lock.lock()
        Self.requests.append(recorded)
        let stub = Self.responses[min(Self.responseIndex, Self.responses.count - 1)]
        Self.responseIndex += 1
        Self.lock.unlock()

        Self.requestLog.record(recorded.path)

        guard !stub.hangs else { return }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func queryPairs(from components: URLComponents) -> [String] {
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return [] }
        return query.split(separator: "&").map(String.init).sorted()
    }
}
