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
    private(set) var isSyncingApplications = false

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

    func syncApplications() async throws {
        guard let client else {
            throw ArrError.noServiceConfigured
        }

        let linkedApplications = try await client.getApplications()
            .filter { $0.linkedAppType == .sonarr || $0.linkedAppType == .radarr }
        guard !linkedApplications.isEmpty else {
            throw NSError(
                domain: "ProwlarrSync",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Link Sonarr or Radarr in Prowlarr before running an indexer sync."]
            )
        }

        let appNames = linkedApplications
            .compactMap { $0.name ?? $0.linkedAppType?.displayName }
            .sorted()
        let targetSummary = appNames.formatted(.list(type: .and))

        isSyncingApplications = true
        defer { isSyncingApplications = false }

        InAppNotificationCenter.shared.showSuccess(
            title: "Sync Started",
            message: "Syncing Prowlarr indexers to \(targetSummary)."
        )

        let command = try await client.syncApplications()
        guard command.succeeded else {
            throw NSError(
                domain: "ProwlarrSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: command.exception ?? "Prowlarr did not complete the application sync."]
            )
        }

        await loadIndexers()

        InAppNotificationCenter.shared.showSuccess(
            title: "Sync Complete",
            message: "Prowlarr indexers synced to \(targetSummary)."
        )
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

@MainActor
@Observable
final class ProwlarrApplicationsViewModel {
    private let serviceManager: ArrServiceManager

    private(set) var applications: [ProwlarrApplication] = []
    private(set) var schemaApplications: [ProwlarrApplication] = []
    private(set) var availableTags: [ArrTag] = []
    private(set) var isLoadingApplications = false
    private(set) var isLoadingSchema = false
    private(set) var errorMessage: String?

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    private var client: ProwlarrAPIClient? { serviceManager.prowlarrClient }

    var supportedApplications: [ProwlarrApplication] {
        applications
            .filter { $0.linkedAppType != nil }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    var supportedSchemas: [ProwlarrApplication] {
        schemaApplications
            .filter { $0.linkedAppType != nil }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    func schema(for type: ProwlarrLinkedAppType) -> ProwlarrApplication? {
        supportedSchemas.first(where: { $0.linkedAppType == type })
    }

    func loadApplications() async {
        guard let client else {
            errorMessage = "Prowlarr not connected."
            return
        }

        isLoadingApplications = true
        errorMessage = nil
        defer { isLoadingApplications = false }

        do {
            async let loadedApplications = client.getApplications()
            async let loadedTags = client.getTags()
            let (apps, tags) = try await (loadedApplications, loadedTags)
            applications = apps
            availableTags = tags.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSchemaIfNeeded() async {
        guard schemaApplications.isEmpty else { return }
        await reloadSchema()
    }

    func reloadSchema() async {
        guard let client else {
            errorMessage = "Prowlarr not connected."
            return
        }

        isLoadingSchema = true
        errorMessage = nil
        defer { isLoadingSchema = false }

        do {
            schemaApplications = try await client.getApplicationSchema()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveApplication(_ application: ProwlarrApplication) async -> Bool {
        guard let client else {
            errorMessage = "Prowlarr not connected."
            return false
        }

        errorMessage = nil
        var saveSucceeded = false

        do {
            if application.id == 0 {
                _ = try await client.createApplication(application)
            } else {
                _ = try await client.updateApplication(application)
            }
            saveSucceeded = true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        // Refresh the application list, but don't let refresh errors affect save result
        do {
            await loadApplications()
        } catch {
            // loadApplications sets errorMessage on failure, but we still return saveSucceeded
        }

        return saveSucceeded
    }

    func deleteApplication(_ application: ProwlarrApplication) async -> Bool {
        guard let client else {
            errorMessage = "Prowlarr not connected."
            return false
        }

        errorMessage = nil

        do {
            try await client.deleteApplication(id: application.id)
            applications.removeAll { $0.id == application.id }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearError() {
        errorMessage = nil
    }
}

@MainActor
@Observable
final class ArrIndexerManagementViewModel {
    private let serviceManager: ArrServiceManager

    private(set) var sonarrIndexersByProfileID: [UUID: [ArrManagedIndexer]] = [:]
    private(set) var radarrIndexersByProfileID: [UUID: [ArrManagedIndexer]] = [:]
    private(set) var schemaByProfileID: [UUID: [ArrManagedIndexer]] = [:]
    private(set) var errorsByProfileID: [UUID: String] = [:]
    private(set) var schemaErrorsByProfileID: [UUID: String] = [:]
    private(set) var loadingProfileIDs: Set<UUID> = []
    private(set) var loadingSchemaProfileIDs: Set<UUID> = []
    private(set) var testResult: String?
    private(set) var testSucceeded: Bool?
    private(set) var isTesting = false

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    func loadAllIndexers() async {
        await withTaskGroup(of: Void.self) { group in
            for entry in serviceManager.sonarrInstances where entry.isConnected {
                group.addTask { await self.loadIndexers(for: entry.id, serviceType: .sonarr) }
            }
            for entry in serviceManager.radarrInstances where entry.isConnected {
                group.addTask { await self.loadIndexers(for: entry.id, serviceType: .radarr) }
            }
        }
    }

    func loadIndexers(for profileID: UUID, serviceType: ArrServiceType) async {
        guard serviceType != .prowlarr else { return }
        loadingProfileIDs.insert(profileID)
        errorsByProfileID[profileID] = nil
        defer { loadingProfileIDs.remove(profileID) }

        do {
            let indexers = try await fetchIndexers(for: profileID, serviceType: serviceType)
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
            assign(indexers, to: profileID, serviceType: serviceType)
        } catch {
            errorsByProfileID[profileID] = error.localizedDescription
        }
    }

    func loadSchema(for profileID: UUID, serviceType: ArrServiceType, force: Bool = false) async {
        guard serviceType != .prowlarr else { return }
        if !force, schemaByProfileID[profileID] != nil {
            return
        }

        loadingSchemaProfileIDs.insert(profileID)
        schemaErrorsByProfileID[profileID] = nil
        defer { loadingSchemaProfileIDs.remove(profileID) }

        do {
            let schema = try await fetchSchema(for: profileID, serviceType: serviceType)
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
            schemaByProfileID[profileID] = schema
        } catch {
            schemaErrorsByProfileID[profileID] = error.localizedDescription
        }
    }

    func indexers(for profileID: UUID, serviceType: ArrServiceType) -> [ArrManagedIndexer] {
        switch serviceType {
        case .sonarr:
            sonarrIndexersByProfileID[profileID] ?? []
        case .radarr:
            radarrIndexersByProfileID[profileID] ?? []
        case .prowlarr:
            []
        }
    }

    func schema(for profileID: UUID) -> [ArrManagedIndexer] {
        schemaByProfileID[profileID] ?? []
    }

    func error(for profileID: UUID) -> String? {
        errorsByProfileID[profileID]
    }

    func schemaError(for profileID: UUID) -> String? {
        schemaErrorsByProfileID[profileID]
    }

    func isLoadingIndexers(for profileID: UUID) -> Bool {
        loadingProfileIDs.contains(profileID)
    }

    func isLoadingSchema(for profileID: UUID) -> Bool {
        loadingSchemaProfileIDs.contains(profileID)
    }

    func addIndexer(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async -> Bool {
        do {
            let created = try await createIndexer(indexer, for: profileID, serviceType: serviceType)
            upsert(created, for: profileID, serviceType: serviceType)
            errorsByProfileID[profileID] = nil
            return true
        } catch {
            errorsByProfileID[profileID] = error.localizedDescription
            return false
        }
    }

    func updateIndexer(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async -> Bool {
        do {
            let updated = try await updateIndexerRequest(indexer, for: profileID, serviceType: serviceType)
            upsert(updated, for: profileID, serviceType: serviceType)
            errorsByProfileID[profileID] = nil
            return true
        } catch {
            errorsByProfileID[profileID] = error.localizedDescription
            return false
        }
    }

    func deleteIndexer(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async -> Bool {
        do {
            try await deleteIndexerRequest(id: indexer.id, for: profileID, serviceType: serviceType)
            remove(indexerID: indexer.id, from: profileID, serviceType: serviceType)
            errorsByProfileID[profileID] = nil
            return true
        } catch {
            errorsByProfileID[profileID] = error.localizedDescription
            return false
        }
    }

    func testIndexer(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async {
        isTesting = true
        testResult = nil
        testSucceeded = nil
        defer { isTesting = false }

        do {
            try await testIndexerRequest(indexer, for: profileID, serviceType: serviceType)
            testResult = "\(indexer.name ?? "Indexer") passed."
            testSucceeded = true
        } catch {
            testResult = "\(indexer.name ?? "Indexer") failed: \(error.localizedDescription)"
            testSucceeded = false
        }
    }

    func clearTestResult() {
        testResult = nil
        testSucceeded = nil
    }

    private func fetchIndexers(for profileID: UUID, serviceType: ArrServiceType) async throws -> [ArrManagedIndexer] {
        switch serviceType {
        case .sonarr:
            guard let client = serviceManager.sonarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.getIndexers()
        case .radarr:
            guard let client = serviceManager.radarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.getIndexers()
        case .prowlarr:
            return []
        }
    }

    private func fetchSchema(for profileID: UUID, serviceType: ArrServiceType) async throws -> [ArrManagedIndexer] {
        switch serviceType {
        case .sonarr:
            guard let client = serviceManager.sonarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.getIndexerSchema()
        case .radarr:
            guard let client = serviceManager.radarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.getIndexerSchema()
        case .prowlarr:
            return []
        }
    }

    private func createIndexer(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async throws -> ArrManagedIndexer {
        switch serviceType {
        case .sonarr:
            guard let client = serviceManager.sonarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.createIndexer(indexer)
        case .radarr:
            guard let client = serviceManager.radarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.createIndexer(indexer)
        case .prowlarr:
            throw ArrError.unsupportedIndexerService(serviceType.displayName)
        }
    }

    private func updateIndexerRequest(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async throws -> ArrManagedIndexer {
        switch serviceType {
        case .sonarr:
            guard let client = serviceManager.sonarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.updateIndexer(indexer)
        case .radarr:
            guard let client = serviceManager.radarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await client.updateIndexer(indexer)
        case .prowlarr:
            throw ArrError.unsupportedIndexerService(serviceType.displayName)
        }
    }

    private func deleteIndexerRequest(id: Int, for profileID: UUID, serviceType: ArrServiceType) async throws {
        switch serviceType {
        case .sonarr:
            guard let client = serviceManager.sonarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            try await client.deleteIndexer(id: id)
        case .radarr:
            guard let client = serviceManager.radarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            try await client.deleteIndexer(id: id)
        case .prowlarr:
            throw ArrError.unsupportedIndexerService(serviceType.displayName)
        }
    }

    private func testIndexerRequest(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async throws {
        switch serviceType {
        case .sonarr:
            guard let client = serviceManager.sonarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            try await client.testIndexer(indexer)
        case .radarr:
            guard let client = serviceManager.radarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            try await client.testIndexer(indexer)
        case .prowlarr:
            throw ArrError.unsupportedIndexerService(serviceType.displayName)
        }
    }

    private func assign(_ indexers: [ArrManagedIndexer], to profileID: UUID, serviceType: ArrServiceType) {
        switch serviceType {
        case .sonarr:
            sonarrIndexersByProfileID[profileID] = indexers
        case .radarr:
            radarrIndexersByProfileID[profileID] = indexers
        case .prowlarr:
            break
        }
    }

    private func upsert(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) {
        var items = indexers(for: profileID, serviceType: serviceType)
        if let index = items.firstIndex(where: { $0.id == indexer.id }) {
            items[index] = indexer
        } else {
            items.append(indexer)
        }
        items.sort { ($0.name ?? "") < ($1.name ?? "") }
        assign(items, to: profileID, serviceType: serviceType)
    }

    private func remove(indexerID: Int, from profileID: UUID, serviceType: ArrServiceType) {
        let items = indexers(for: profileID, serviceType: serviceType).filter { $0.id != indexerID }
        assign(items, to: profileID, serviceType: serviceType)
    }
}
