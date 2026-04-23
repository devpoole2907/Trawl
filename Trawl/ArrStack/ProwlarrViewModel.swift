import Foundation
import OSLog
import Observation
import SwiftUI

@MainActor
@Observable
final class ProwlarrViewModel {
    private let logger = Logger(subsystem: "com.poole.james.Trawl", category: "ProwlarrViewModel")
    private let serviceManager: ArrServiceManager

    // MARK: - Indexer State
    private(set) var indexers: [ProwlarrIndexer] = []
    private(set) var indexerStatuses: [ProwlarrIndexerStatus] = []
    private(set) var isLoadingIndexers = false
    private(set) var indexerError: String?
    private(set) var testResult: String?
    private(set) var testSucceeded: Bool?
    private(set) var isTesting = false

    // MARK: - Schema State
    private(set) var schemaIndexers: [ProwlarrIndexer] = []
    private(set) var isLoadingSchema = false
    private(set) var schemaError: String?

    // MARK: - Search State
    var searchQuery = ""
    var searchType: ProwlarrSearchType = .search
    var selectedIndexerIds: Set<Int> = []
    private(set) var searchResults: [ProwlarrSearchResult] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private var currentRequestToken: UUID?

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

        // Load indexers and statuses together
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

        // Load stats separately so failures don't affect indexers/statuses
        isLoadingStats = true
        defer { isLoadingStats = false }
        statsError = nil
        do {
            indexerStats = try await client.getIndexerStats()
        } catch {
            statsError = error.localizedDescription
        }
    }

    func statsForIndexer(id: Int) -> ProwlarrIndexerStatEntry? {
        indexerStats?.indexers?.first(where: { $0.indexerId == id })
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

    func deleteIndexer(_ indexer: ProwlarrIndexer) async -> Bool {
        guard let client else { return false }
        do {
            try await client.deleteIndexer(id: indexer.id)
            indexers.removeAll { $0.id == indexer.id }
            indexerError = nil
            return true
        } catch {
            indexerError = error.localizedDescription
            return false
        }
    }

    func clearIndexerError() {
        indexerError = nil
    }

    func containsIndexer(id: Int) -> Bool {
        indexers.contains { $0.id == id }
    }

    func reloadSchema() async {
        schemaIndexers = []
        schemaError = nil
        await loadSchema()
    }

    func loadSchema() async {
        guard let client else { return }
        guard schemaIndexers.isEmpty else { return }
        isLoadingSchema = true
        schemaError = nil
        do {
            schemaIndexers = try await client.getIndexerSchema()
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            logger.error("Failed to load Prowlarr schema: \(error.localizedDescription, privacy: .public)")
            schemaError = error.localizedDescription
        }
        isLoadingSchema = false
    }

    func addIndexer(_ indexer: ProwlarrIndexer) async -> Bool {
        guard let client else { return false }
        indexerError = nil
        do {
            let created = try await client.createIndexer(indexer)
            indexers.append(created)
            indexers.sort { ($0.name ?? "") < ($1.name ?? "") }
            return true
        } catch {
            indexerError = error.localizedDescription
            return false
        }
    }

    func clearTestResult() {
        testResult = nil
        testSucceeded = nil
    }

    func clearTestOutcome() {
        clearTestResult()
        indexerError = nil
    }

    func testIndexer(_ indexer: ProwlarrIndexer) async {
        guard let client else { return }
        isTesting = true
        testResult = nil
        testSucceeded = nil
        do {
            try await client.testIndexer(indexer)
            testResult = "\(indexer.name ?? "Indexer") passed."
            testSucceeded = true
        } catch {
            testResult = "\(indexer.name ?? "Indexer") failed: \(error.localizedDescription)"
            testSucceeded = false
        }
        isTesting = false
    }

    func testAllIndexers() async {
        guard let client else { return }
        isTesting = true
        testResult = nil
        testSucceeded = nil
        let count = indexers.count
        do {
            try await client.testAllIndexers()
            let label = count == 1 ? "1 indexer" : "\(count) indexers"
            testResult = "All \(label) passed their connectivity tests."
            testSucceeded = true
        } catch {
            testResult = "One or more indexers failed their test. Check Prowlarr for details.\n\n\(error.localizedDescription)"
            testSucceeded = false
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

        let requestToken = UUID()
        currentRequestToken = requestToken

        isSearching = true
        searchError = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            searchResults = []
        }

        do {
            let ids = selectedIndexerIds.isEmpty ? nil : Array(selectedIndexerIds)
            let results = try await client.search(query: trimmed, indexerIds: ids, type: searchType)

            // Only apply results if this is still the current request
            guard currentRequestToken == requestToken else { return }

            let batchSize = results.count > 30 ? 10 : 5
            for batch in results.chunked(into: batchSize) {
                guard currentRequestToken == requestToken && !Task.isCancelled else { break }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    searchResults.append(contentsOf: batch)
                }
            }
        } catch {
            // Only apply error if this is still the current request
            guard currentRequestToken == requestToken else { return }
            searchError = error.localizedDescription
        }

        // Only update isSearching if this is still the current request
        guard currentRequestToken == requestToken && !Task.isCancelled else { return }
        isSearching = false
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchError = nil
        currentRequestToken = nil
        isSearching = false
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
