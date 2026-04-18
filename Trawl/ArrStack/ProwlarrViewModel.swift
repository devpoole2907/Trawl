import Foundation
import Observation

@MainActor
@Observable
final class ProwlarrViewModel {
    private let serviceManager: ArrServiceManager

    // MARK: - Indexer State
    private(set) var indexers: [ProwlarrIndexer] = []
    private(set) var indexerStatuses: [ProwlarrIndexerStatus] = []
    private(set) var isLoadingIndexers = false
    private(set) var indexerError: String?
    private(set) var testResult: String?
    private(set) var isTesting = false

    // MARK: - Search State
    var searchQuery = ""
    var searchType: ProwlarrSearchType = .search
    var selectedIndexerIds: Set<Int> = []
    private(set) var searchResults: [ProwlarrSearchResult] = []
    private(set) var isSearching = false
    private(set) var searchError: String?

    // MARK: - Stats State
    private(set) var indexerStats: ProwlarrIndexerStats?
    private(set) var isLoadingStats = false
    private(set) var statsError: String?

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    private var client: ProwlarrAPIClient? { serviceManager.prowlarrClient }

    // MARK: - Indexer Operations

    func loadIndexers() async {
        guard let client else {
            indexerError = "Prowlarr not connected."
            return
        }
        isLoadingIndexers = true
        indexerError = nil
        do {
            async let fetchedIndexers = client.getIndexers()
            async let fetchedStatuses = client.getIndexerStatuses()
            let (loaded, statuses) = try await (fetchedIndexers, fetchedStatuses)
            indexers = loaded.sorted { ($0.name ?? "") < ($1.name ?? "") }
            indexerStatuses = statuses
        } catch {
            indexerError = error.localizedDescription
        }
        isLoadingIndexers = false
    }

    func toggleIndexer(_ indexer: ProwlarrIndexer) async {
        guard let client else { return }
        var updated = indexer
        updated.enable = !indexer.enable

        // Optimistic update
        if let idx = indexers.firstIndex(where: { $0.id == indexer.id }) {
            indexers[idx] = updated
        }

        do {
            let result = try await client.updateIndexer(updated)
            if let idx = indexers.firstIndex(where: { $0.id == result.id }) {
                indexers[idx] = result
            }
        } catch {
            // Revert on failure
            if let idx = indexers.firstIndex(where: { $0.id == indexer.id }) {
                indexers[idx] = indexer
            }
            indexerError = error.localizedDescription
        }
    }

    func deleteIndexer(_ indexer: ProwlarrIndexer) async {
        guard let client else { return }
        do {
            try await client.deleteIndexer(id: indexer.id)
            indexers.removeAll { $0.id == indexer.id }
            indexerError = nil
        } catch {
            indexerError = error.localizedDescription
        }
    }

    func testIndexer(_ indexer: ProwlarrIndexer) async {
        guard let client else { return }
        isTesting = true
        testResult = nil
        do {
            try await client.testIndexer(indexer)
            testResult = "\(indexer.name ?? "Indexer") passed."
        } catch {
            testResult = "\(indexer.name ?? "Indexer") failed: \(error.localizedDescription)"
        }
        isTesting = false
    }

    func testAllIndexers() async {
        guard let client else { return }
        isTesting = true
        testResult = nil
        do {
            try await client.testAllIndexers()
            testResult = "All indexers tested."
        } catch {
            testResult = "Test failed: \(error.localizedDescription)"
        }
        isTesting = false
    }

    func statusForIndexer(id: Int) -> ProwlarrIndexerStatus? {
        indexerStatuses.first { $0.indexerId == id }
    }

    var torrentIndexers: [ProwlarrIndexer] {
        indexers.filter { $0.protocol == .torrent }
    }

    var usenetIndexers: [ProwlarrIndexer] {
        indexers.filter { $0.protocol == .usenet }
    }

    var otherIndexers: [ProwlarrIndexer] {
        indexers.filter { $0.protocol == nil }
    }

    // MARK: - Search

    func performSearch() async {
        guard let client else {
            searchError = "Prowlarr not connected."
            return
        }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        searchError = nil
        do {
            let ids = selectedIndexerIds.isEmpty ? nil : Array(selectedIndexerIds)
            searchResults = try await client.search(query: trimmed, indexerIds: ids, type: searchType)
        } catch {
            searchError = error.localizedDescription
            searchResults = []
        }
        isSearching = false
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchError = nil
    }

    // MARK: - Stats

    func loadStats() async {
        guard let client else {
            statsError = "Prowlarr not connected."
            return
        }
        isLoadingStats = true
        statsError = nil
        do {
            indexerStats = try await client.getIndexerStats()
        } catch {
            statsError = error.localizedDescription
        }
        isLoadingStats = false
    }
}
