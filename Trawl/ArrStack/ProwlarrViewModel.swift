import Foundation
import OSLog
import Observation
import SwiftUI

enum ProwlarrOperation: Hashable {
    case indexer
    case schema
    case search
    case stats
}

protocol IndexerCapableClient {
    func getIndexers() async throws -> [ArrManagedIndexer]
    func getIndexerSchema() async throws -> [ArrManagedIndexer]
    func createIndexer(_ indexer: ArrManagedIndexer) async throws -> ArrManagedIndexer
    func updateIndexer(_ indexer: ArrManagedIndexer) async throws -> ArrManagedIndexer
    func deleteIndexer(id: Int) async throws
    func testIndexer(_ indexer: ArrManagedIndexer) async throws
}

extension SonarrAPIClient: IndexerCapableClient {}
extension RadarrAPIClient: IndexerCapableClient {}

@MainActor
@Observable
final class ProwlarrViewModel: ArrLibraryViewModel<ProwlarrIndexer, ProwlarrAPIClient> {
    private let logger = Logger(subsystem: "com.poole.james.Trawl", category: "ProwlarrViewModel")

    // MARK: - Indexer State
    private(set) var indexers: [ProwlarrIndexer] = []
    private(set) var indexerStatuses: [ProwlarrIndexerStatus] = []
    private(set) var isLoadingIndexers = false
    private(set) var errors: [ProwlarrOperation: String] = [:]
    private(set) var testResult: String?
    private(set) var testSucceeded: Bool?
    private(set) var isTesting = false
    private(set) var isSyncingApplications = false

    var indexerError: String? { errors[.indexer] }
    var schemaError: String? { errors[.schema] }
    var searchError: String? { errors[.search] }
    var statsError: String? { errors[.stats] }

    // MARK: - Schema State
    private(set) var schemaIndexers: [ProwlarrIndexer] = []
    private(set) var isLoadingSchema = false

    // MARK: - Search State
    var searchQuery = ""
    var searchType: ProwlarrSearchType = .search
    var selectedIndexerIds: Set<Int> = []
    private(set) var searchResults: [ProwlarrSearchResult] = []
    private(set) var isSearching: Bool = false
    private var searchTracker = StreamingSearchTracker<ProwlarrSearchResult>()

    // MARK: - Stats State
    private(set) var indexerStats: ProwlarrIndexerStats?
    private(set) var isLoadingStats = false

    init(serviceManager: ArrServiceManager) {
        super.init(serviceManager: serviceManager, client: serviceManager.prowlarrClient)
    }

    // MARK: - Indexer Operations

    func loadIndexers() async {
        guard let client else {
            errors[.indexer] = "Prowlarr not connected."
            return
        }
        isLoadingIndexers = true
        errors[.indexer] = nil

        // Load indexers and statuses together
        do {
            async let fetchedIndexers: [ProwlarrIndexer] = client.getIndexers()
            async let fetchedStatuses = client.getIndexerStatuses()
            let (loaded, statuses) = try await (fetchedIndexers, fetchedStatuses)
            indexers = loaded.sorted { ($0.name ?? "") < ($1.name ?? "") }
            setLibraryItems(indexers)
            indexerStatuses = statuses
        } catch {
            errors[.indexer] = error.localizedDescription
        }

        isLoadingIndexers = false

        // Load stats separately so failures don't affect indexers/statuses
        isLoadingStats = true
        defer { isLoadingStats = false }
        errors[.stats] = nil
        do {
            indexerStats = try await client.getIndexerStats()
        } catch {
            errors[.stats] = error.localizedDescription
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
            errors[.indexer] = error.localizedDescription
        }
    }

    func deleteIndexer(_ indexer: ProwlarrIndexer) async -> Bool {
        guard let client else { return false }
        do {
            try await client.deleteIndexer(id: indexer.id)
            indexers.removeAll { $0.id == indexer.id }
            errors[.indexer] = nil
            return true
        } catch {
            errors[.indexer] = error.localizedDescription
            return false
        }
    }

    func clearIndexerError() {
        errors[.indexer] = nil
    }

    func containsIndexer(id: Int) -> Bool {
        indexers.contains { $0.id == id }
    }

    func reloadSchema() async {
        schemaIndexers = []
        errors[.schema] = nil
        await loadSchema()
    }

    func loadSchema() async {
        guard let client else { return }
        guard schemaIndexers.isEmpty else { return }
        isLoadingSchema = true
        errors[.schema] = nil
        do {
            let schemas: [ProwlarrIndexer] = try await client.getIndexerSchema()
            schemaIndexers = schemas
                .sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            logger.error("Failed to load Prowlarr schema: \(error.localizedDescription, privacy: .public)")
            errors[.schema] = error.localizedDescription
        }
        isLoadingSchema = false
    }

    func addIndexer(_ indexer: ProwlarrIndexer) async -> Bool {
        guard let client else { return false }
        errors[.indexer] = nil
        do {
            let created = try await client.createIndexer(indexer)
            indexers.append(created)
            indexers.sort { ($0.name ?? "") < ($1.name ?? "") }
            return true
        } catch {
            errors[.indexer] = error.localizedDescription
            return false
        }
    }

    func clearTestResult() {
        testResult = nil
        testSucceeded = nil
    }

    func clearTestOutcome() {
        clearTestResult()
        errors[.indexer] = nil
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

        guard !isSyncingApplications else {
            return
        }
        isSyncingApplications = true
        defer { isSyncingApplications = false }

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
            errors[.search] = "Prowlarr not connected."
            return
        }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let requestToken = searchTracker.begin()

        isSearching = true
        errors[.search] = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            searchResults = []
        }

        do {
            let ids = selectedIndexerIds.isEmpty ? nil : Array(selectedIndexerIds)
            let results = try await client.search(query: trimmed, indexerIds: ids, type: searchType)

            // Only apply results if this is still the current request
            guard searchTracker.isCurrent(requestToken) else { return }

            await searchTracker.stream(results, token: requestToken) { item in
                self.searchResults.append(item)
            }
        } catch is CancellationError {
            if searchTracker.isCurrent(requestToken) {
                isSearching = false
            }
            return
        } catch {
            // Only apply error if this is still the current request
            guard searchTracker.isCurrent(requestToken) else { return }
            errors[.search] = error.localizedDescription
        }

        // Only update isSearching if this is still the current request
        guard searchTracker.isCurrent(requestToken) && !Task.isCancelled else { return }
        isSearching = false
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        errors[.search] = nil
        searchTracker.cancel()
        isSearching = false
    }

    // MARK: - Stats

    func loadStats() async {
        guard let client else {
            errors[.stats] = "Prowlarr not connected."
            return
        }
        isLoadingStats = true
        errors[.stats] = nil
        do {
            indexerStats = try await client.getIndexerStats()
        } catch {
            errors[.stats] = error.localizedDescription
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

        // Refresh the application list, but don't let refresh-side state affect save result
        await loadApplications()

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
        guard serviceType != .prowlarr && serviceType != .bazarr else { return }
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
        guard let keyPath = indexerStorageKeyPath(for: serviceType) else { return [] }
        return self[keyPath: keyPath][profileID] ?? []
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

    private func withIndexerClient<T>(
        profileID: UUID,
        serviceType: ArrServiceType,
        op: (any IndexerCapableClient) async throws -> T
    ) async throws -> T {
        switch serviceType {
        case .sonarr:
            guard let client = serviceManager.sonarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await op(client)
        case .radarr:
            guard let client = serviceManager.radarrClient(for: profileID) else { throw ArrError.noServiceConfigured }
            return try await op(client)
        case .prowlarr, .bazarr:
            throw ArrError.unsupportedIndexerService(serviceType.displayName)
        }
    }

    private func fetchIndexers(for profileID: UUID, serviceType: ArrServiceType) async throws -> [ArrManagedIndexer] {
        if serviceType == .prowlarr || serviceType == .bazarr { return [] }
        return try await withIndexerClient(profileID: profileID, serviceType: serviceType) { client in
            try await client.getIndexers()
        }
    }

    private func fetchSchema(for profileID: UUID, serviceType: ArrServiceType) async throws -> [ArrManagedIndexer] {
        if serviceType == .prowlarr || serviceType == .bazarr { return [] }
        return try await withIndexerClient(profileID: profileID, serviceType: serviceType) { client in
            try await client.getIndexerSchema()
        }
    }

    private func createIndexer(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async throws -> ArrManagedIndexer {
        try await withIndexerClient(profileID: profileID, serviceType: serviceType) { client in
            try await client.createIndexer(indexer)
        }
    }

    private func updateIndexerRequest(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async throws -> ArrManagedIndexer {
        try await withIndexerClient(profileID: profileID, serviceType: serviceType) { client in
            try await client.updateIndexer(indexer)
        }
    }

    private func deleteIndexerRequest(id: Int, for profileID: UUID, serviceType: ArrServiceType) async throws {
        try await withIndexerClient(profileID: profileID, serviceType: serviceType) { client in
            try await client.deleteIndexer(id: id)
        }
    }

    private func testIndexerRequest(_ indexer: ArrManagedIndexer, for profileID: UUID, serviceType: ArrServiceType) async throws {
        try await withIndexerClient(profileID: profileID, serviceType: serviceType) { client in
            try await client.testIndexer(indexer)
        }
    }

    private func assign(_ indexers: [ArrManagedIndexer], to profileID: UUID, serviceType: ArrServiceType) {
        guard let keyPath = indexerStorageKeyPath(for: serviceType) else { return }
        self[keyPath: keyPath][profileID] = indexers
    }

    private func indexerStorageKeyPath(
        for serviceType: ArrServiceType
    ) -> ReferenceWritableKeyPath<ArrIndexerManagementViewModel, [UUID: [ArrManagedIndexer]]>? {
        switch serviceType {
        case .sonarr:
            \.sonarrIndexersByProfileID
        case .radarr:
            \.radarrIndexersByProfileID
        case .prowlarr, .bazarr:
            nil
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
