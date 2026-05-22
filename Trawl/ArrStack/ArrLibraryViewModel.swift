import Foundation
import Observation
import SwiftUI

// MARK: - Library-client contract

/// A paged "wanted / missing" response. Both Sonarr and Radarr return the same
/// shape but with different record types.
protocol ArrWantedPageResponse: Sendable {
    associatedtype Record: Sendable
    var records: [Record]? { get }
    var page: Int? { get }
    var totalRecords: Int? { get }
}

/// Capability set the Sonarr / Radarr library view-model needs from its API client.
/// Lets us share queue, history, updates, lookup-search, wanted/missing, and
/// grab/install/RSS operations on a single intermediate base class.
protocol ArrLibraryAPIClient: SharedArrClient {
    associatedtype LibraryItem: Identifiable & Sendable where LibraryItem.ID == Int
    associatedtype WantedRecord: Sendable
    associatedtype WantedPage: ArrWantedPageResponse where WantedPage.Record == WantedRecord

    static var serviceType: ArrServiceType { get }

    func getLibraryItems() async throws -> [LibraryItem]
    func lookup(term: String) async throws -> [LibraryItem]
    func wantedMissingPage(page: Int, pageSize: Int) async throws -> WantedPage
    func searchAllMissing() async throws -> ArrCommand
    func refreshLibrary() async throws -> ArrCommand
    func rssSync() async throws -> ArrCommand
    func installUpdate() async throws -> ArrCommand
    func grabRelease(_ release: ArrRelease) async throws
    func deleteLibraryItem(id: Int, deleteFiles: Bool) async throws
}

/// Lets a library item be matched against the Jellyfin library by provider ID
/// or title/year fallback.
protocol JellyfinMatchable: Sendable {
    static var jellyfinIncludeItemTypes: [String] { get }
    static var jellyfinNumericProviderKeys: [String] { get }
    var jellyfinMatchTitle: String { get }
    var jellyfinMatchYear: Int? { get }
    var jellyfinNumericProviderId: Int? { get }
    var jellyfinImdbProviderId: String? { get }
}

@MainActor
class ArrLibraryViewModel<Item: Identifiable, Client: SharedArrClient> where Item.ID == Int {
    var items: [Item] = []
    var isLoading = false
    var error: String?

    private(set) var history: [ArrHistoryRecord] = []
    private(set) var isLoadingHistory: Bool = false
    private(set) var historyTotalRecords: Int = 0
    private var historyLoader = PaginatedLoader<ArrHistoryRecord>(pageSize: 20)

    var client: Client?
    var serviceManager: ArrServiceManager

    init(serviceManager: ArrServiceManager, client: Client?) {
        self.serviceManager = serviceManager
        self.client = client
    }

    @discardableResult
    func performLoad<T>(_ work: (Client) async throws -> T) async -> T? {
        guard let client else { return nil }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            return try await work(client)
        } catch is CancellationError {
            return nil
        } catch {
            captureAndNotify(error, title: "Load Failed")
            return nil
        }
    }

    func captureAndNotify(_ error: Error, title: String) {
        self.error = error.localizedDescription
        InAppNotificationCenter.shared.showError(
            title: title,
            message: error.localizedDescription
        )
    }

    func notifySuccess(title: String, message: String) {
        error = nil
        InAppNotificationCenter.shared.showSuccess(title: title, message: message)
    }

    func setLibraryItems(_ items: [Item]) {
        self.items = items
    }

    func refreshConfiguration() async {
        await serviceManager.refreshConfiguration()
    }

    func afterMutation(reload: () async -> Void, refreshCalendar: Bool = true) async {
        await reload()
        if refreshCalendar {
            await serviceManager.calendarViewModel.refresh()
        }
    }

    var canLoadMoreHistory: Bool { history.count < historyTotalRecords }

    func loadHistory(page: Int = 1) async {
        guard let client else { return }
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let historyPageResult = try await client.getHistory(page: page, pageSize: historyLoader.pageSize)
            let records = historyPageResult.records ?? []

            if page == 1 {
                historyLoader.replace(
                    with: records,
                    page: historyPageResult.page ?? page,
                    totalRecords: historyPageResult.totalRecords
                )
            } else {
                historyLoader.append(
                    records,
                    page: historyPageResult.page ?? page,
                    totalRecords: historyPageResult.totalRecords
                )
            }

            history = historyLoader.items
            historyTotalRecords = historyLoader.totalRecords
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNextHistoryPage() async {
        guard !isLoadingHistory && canLoadMoreHistory else { return }
        await loadHistory(page: historyLoader.page + 1)
    }
}

struct PaginatedLoader<Item> {
    private(set) var page = 1
    let pageSize: Int
    private(set) var totalRecords = 0
    private(set) var items: [Item] = []

    init(pageSize: Int = 20) {
        self.pageSize = pageSize
    }

    var canLoadMore: Bool {
        items.count < totalRecords
    }

    mutating func reset() {
        page = 1
        totalRecords = 0
        items = []
    }

    mutating func replace(with records: [Item], page: Int = 1, totalRecords: Int? = nil) {
        self.items = records
        self.page = page
        self.totalRecords = totalRecords ?? records.count
    }

    mutating func append(_ records: [Item], page: Int, totalRecords: Int? = nil) {
        items.append(contentsOf: records)
        self.page = page
        self.totalRecords = totalRecords ?? items.count
    }
}

struct StreamingSearchTracker<Result> {
    private(set) var token: UUID?

    mutating func begin() -> UUID {
        let token = UUID()
        self.token = token
        return token
    }

    mutating func cancel() {
        token = nil
    }

    func isCurrent(_ token: UUID) -> Bool {
        self.token == token
    }

    func stream(_ items: [Result], token: UUID, onAppend: @MainActor @Sendable (Result) -> Void) async {
        for item in items {
            guard !Task.isCancelled && isCurrent(token) else { break }
            await MainActor.run {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    onAppend(item)
                }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
}

// MARK: - Media library view model (Sonarr / Radarr shared base)

/// Shared queue / history / updates / lookup-search / wanted-missing / Jellyfin-match
/// behaviour for the Sonarr & Radarr view-models. Bazarr and Prowlarr keep using
/// `ArrLibraryViewModel` directly because they don't have library items in the
/// same sense.
@MainActor
@Observable
class ArrMediaLibraryViewModel<
    Client: ArrLibraryAPIClient,
    Filter: RawRepresentable & CaseIterable & Identifiable & Hashable,
    Sort: RawRepresentable & CaseIterable & Identifiable & Hashable
>: ArrLibraryViewModel<Client.LibraryItem, Client>, ArrMediaListViewModel
where Client.LibraryItem: JellyfinMatchable, Client.LibraryItem: Equatable,
      Filter.RawValue == String, Sort.RawValue == String {
    typealias LibraryItem = Client.LibraryItem
    typealias WantedRecord = Client.WantedRecord
    typealias Item = LibraryItem

    // List State
    var searchText: String = "" { didSet { rebuildFilteredItems() } }
    var selectedFilter: Filter { didSet { rebuildFilteredItems() } }
    var sortOrder: Sort { didSet { rebuildFilteredItems() } }
    var filteredItems: [Item] = []

    // Queue
    private(set) var queue: [ArrQueueItem] = []

    // Updates
    private(set) var availableUpdates: [ArrUpdateInfo] = []
    private(set) var isLoadingUpdates: Bool = false

    // Lookup-based add-new search
    private(set) var searchResults: [LibraryItem] = []
    private(set) var isSearching: Bool = false
    @ObservationIgnored private var searchTracker = StreamingSearchTracker<LibraryItem>()

    // Wanted missing
    private(set) var wantedRecords: [WantedRecord] = []
    private(set) var isLoadingWantedMissing: Bool = false
    private(set) var wantedMissingTotalRecords: Int = 0
    @ObservationIgnored private var wantedMissingLoader = PaginatedLoader<WantedRecord>(pageSize: 20)

    // Jellyfin library presence cache
    @ObservationIgnored let jellyfinManager: JellyfinServiceManager?
    @ObservationIgnored private var jellyfinLibraryItems: [JellyfinLibraryItem] = []

    private let defaultSort: Sort

    var isNonDefaultSortOrder: Bool { sortOrder != defaultSort }

    init(serviceManager: ArrServiceManager, client: Client?, jellyfinManager: JellyfinServiceManager? = nil, defaultFilter: Filter, defaultSort: Sort) {
        self.selectedFilter = defaultFilter
        self.sortOrder = defaultSort
        self.defaultSort = defaultSort
        self.jellyfinManager = jellyfinManager
        super.init(serviceManager: serviceManager, client: client)
    }

    func refreshFilters() {
        rebuildFilteredItems()
    }

    /// Override hook
    func rebuildFilteredItems() {}

    /// Override hook
    func toggleMonitored(_ item: Item) async {}

    var nounSingular: String { "" }
    var nounPlural: String { "" }

    func deleteItem(id: Int, deleteFiles: Bool) async {
        await deleteItem(id: id, deleteFiles: deleteFiles, noun: nounSingular)
    }

    func deleteItems(ids: Set<Int>, deleteFiles: Bool) async {
        await deleteItems(ids: ids, deleteFiles: deleteFiles, nounSingular: nounSingular, nounPlural: nounPlural)
    }

    // MARK: - Library

    func loadLibraryItems() async {
        guard let loadedItems = await performLoad({ try await $0.getLibraryItems() }) else { return }
        setLibraryItems(loadedItems)
        onLibraryLoaded()
    }

    /// Override hook
    func onLibraryLoaded() {}

    func refreshLibrary() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.refreshLibrary()
        InAppNotificationCenter.shared.showSuccess(title: "Refresh Started", message: "Library refresh command sent.")
        // Re-fetch after a brief delay for the refresh command to process
        try? await Task.sleep(for: .seconds(2))
        await loadLibraryItems()
    }

    func rssSync() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.rssSync()
        InAppNotificationCenter.shared.showSuccess(title: "RSS Sync", message: "Sync command sent.")
    }

    func searchAllMissing(noun: String) async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.searchAllMissing()
        InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching for all missing \(noun).")
    }

    func deleteItem(id: Int, deleteFiles: Bool, noun: String) async {
        guard let client else { return }
        do {
            try await client.deleteLibraryItem(id: id, deleteFiles: deleteFiles)
            items.removeAll { $0.id == id }
            await afterMutation(reload: { await loadLibraryItems() })
            InAppNotificationCenter.shared.showSuccess(title: "Deleted", message: noun.capitalized)
        } catch {
            captureAndNotify(error, title: "Delete Failed")
        }
    }

    func deleteItems(ids: Set<Int>, deleteFiles: Bool, nounSingular: String, nounPlural: String) async {
        let idsToDelete = ids.sorted()
        guard !idsToDelete.isEmpty else { return }
        guard let client else {
            captureAndNotify(ArrServiceError.clientNotAvailable, title: "Delete Failed")
            return
        }

        var deletedIDs = Set<Int>()
        var failures: [String] = []

        for id in idsToDelete {
            do {
                try await client.deleteLibraryItem(id: id, deleteFiles: deleteFiles)
                deletedIDs.insert(id)
            } catch {
                failures.append("\(id): \(error.localizedDescription)")
            }
        }

        if !deletedIDs.isEmpty {
            items.removeAll { deletedIDs.contains($0.id) }
            await afterMutation(reload: { await loadLibraryItems() })
            InAppNotificationCenter.shared.showSuccess(
                title: "Deleted",
                message: Self.bulkDeleteSuccessMessage(count: deletedIDs.count, singular: nounSingular, plural: nounPlural)
            )
        }

        if !failures.isEmpty {
            InAppNotificationCenter.shared.showError(
                title: "Delete Failed",
                message: Self.bulkDeleteFailureMessage(failures, singular: nounSingular, plural: nounPlural)
            )
        }
    }

    // MARK: - Queue

    func loadQueue() async {
        guard let client else { return }
        do {
            let page = try await client.getQueue(page: 1, pageSize: 250)
            queue = page.records ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeQueueItem(id: Int, blocklist: Bool = false) async {
        guard let client else { return }
        do {
            try await client.deleteQueueItem(id: id, blocklist: blocklist)
            queue.removeAll { $0.id == id }
            InAppNotificationCenter.shared.showSuccess(title: "Removed", message: "Queue item removed.")
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Remove Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Updates

    func checkForUpdates() async {
        guard let client else { return }
        isLoadingUpdates = true
        defer { isLoadingUpdates = false }
        do {
            availableUpdates = try await client.getUpdates()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func installUpdate() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.installUpdate()
        InAppNotificationCenter.shared.showSuccess(title: "Update Started", message: "Application update command sent.")
    }

    // MARK: - Release grab

    func grabRelease(_ release: ArrRelease) async -> Bool {
        guard let client else { return false }
        error = nil
        do {
            try await client.grabRelease(release)
            let expectsWebhook = await expectsReleaseGrabWebhook()
            InAppNotificationCenter.shared.showSuccess(
                title: expectsWebhook ? "Release Sent" : "Grabbed",
                message: release.title ?? "Release"
            )
            await loadQueue()
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Grab Failed", message: error.localizedDescription)
            return false
        }
    }

    private func expectsReleaseGrabWebhook() async -> Bool {
        #if os(iOS)
        guard let profile = serviceManager.resolvedProfile(for: Client.serviceType, allowErroredFallback: false),
              serviceManager.isConnected(Client.serviceType, profileID: profile.id),
              let token = await NotificationService.shared.deviceToken,
              !token.isEmpty else {
            return false
        }

        do {
            return try await serviceManager.notificationSetupStatus(
                for: profile,
                workerURL: NotificationService.shared.workerURL,
                deviceToken: token
            ) == .configured
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Lookup (add-new search)

    func performLookup(term: String) async {
        guard let client, !term.isEmpty else {
            isSearching = false
            searchResults = []
            searchTracker.cancel()
            return
        }

        let requestToken = searchTracker.begin()
        isSearching = true
        searchResults = []
        error = nil

        do {
            let results = try await client.lookup(term: term)
            guard !Task.isCancelled else { return }
            guard searchTracker.isCurrent(requestToken) else { return }

            await searchTracker.stream(results, token: requestToken) { item in
                self.searchResults.append(item)
            }

            if !Task.isCancelled && searchTracker.isCurrent(requestToken) {
                isSearching = false
            }
        } catch is CancellationError {
            if searchTracker.isCurrent(requestToken) {
                isSearching = false
            }
            return
        } catch {
            guard !Task.isCancelled else { return }
            guard searchTracker.isCurrent(requestToken) else { return }
            self.error = error.localizedDescription
            searchResults = []
            isSearching = false
        }
    }

    func clearSearchResults() {
        searchResults = []
        error = nil
        isSearching = false
        searchTracker.cancel()
    }

    // MARK: - Wanted / missing

    var canLoadMoreWantedMissing: Bool { wantedRecords.count < wantedMissingTotalRecords }

    func loadWantedMissing() async {
        guard !isLoadingWantedMissing else { return }
        guard let client else { return }
        isLoadingWantedMissing = true
        defer { isLoadingWantedMissing = false }
        error = nil
        do {
            let page = try await client.wantedMissingPage(page: 1, pageSize: wantedMissingLoader.pageSize)
            wantedMissingLoader.replace(
                with: page.records ?? [],
                page: page.page ?? 1,
                totalRecords: page.totalRecords
            )
            wantedRecords = wantedMissingLoader.items
            wantedMissingTotalRecords = wantedMissingLoader.totalRecords
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMoreWantedMissing() async {
        guard !isLoadingWantedMissing && canLoadMoreWantedMissing else { return }
        guard let client else { return }
        isLoadingWantedMissing = true
        defer { isLoadingWantedMissing = false }

        let nextPage = wantedMissingLoader.page + 1
        do {
            let page = try await client.wantedMissingPage(page: nextPage, pageSize: wantedMissingLoader.pageSize)
            wantedMissingLoader.append(
                page.records ?? [],
                page: page.page ?? nextPage,
                totalRecords: page.totalRecords
            )
            wantedRecords = wantedMissingLoader.items
            wantedMissingTotalRecords = wantedMissingLoader.totalRecords
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Jellyfin library matching

    func refreshJellyfinLibraryCache() async {
        guard let client = jellyfinManager?.activeClient else {
            jellyfinLibraryItems = []
            onJellyfinLibraryCacheChanged()
            return
        }
        do {
            jellyfinLibraryItems = try await client.getAllLibraryItems(includeItemTypes: LibraryItem.jellyfinIncludeItemTypes)
            onJellyfinLibraryCacheChanged()
        } catch {
            jellyfinLibraryItems = []
            onJellyfinLibraryCacheChanged()
        }
    }

    /// Override hook — subclasses invalidate their filtered cache when the
    /// Jellyfin presence cache changes.
    func onJellyfinLibraryCacheChanged() {}

    func isInJellyfinLibrary(_ item: LibraryItem) -> Bool {
        guard !jellyfinLibraryItems.isEmpty else { return false }
        let title = item.jellyfinMatchTitle
        let year = item.jellyfinMatchYear
        let numericId = item.jellyfinNumericProviderId
        let imdbId = item.jellyfinImdbProviderId

        for jelly in jellyfinLibraryItems {
            if let numericId,
               Self.matchesNumericProvider(jelly, keys: LibraryItem.jellyfinNumericProviderKeys, id: numericId) {
                return true
            }
            if let imdbId,
               Self.matchesStringProvider(jelly, keys: ["Imdb", "IMDb", "IMDB"], id: imdbId) {
                return true
            }
            if Self.titleYearFallbackMatches(jelly, title: title, year: year) { return true }
        }
        return false
    }

    private static func matchesNumericProvider(_ item: JellyfinLibraryItem, keys: [String], id: Int) -> Bool {
        guard let value = item.providerID(for: keys) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == String(id)
    }

    private static func matchesStringProvider(_ item: JellyfinLibraryItem, keys: [String], id: String) -> Bool {
        guard !id.isEmpty, let value = item.providerID(for: keys) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(id) == .orderedSame
    }

    private static func titleYearFallbackMatches(_ item: JellyfinLibraryItem, title: String, year: Int?) -> Bool {
        guard normalizedTitle(item.name) == normalizedTitle(title) else { return false }
        guard let year else { return true }
        return item.productionYear == nil || item.productionYear == year
    }

    private static func normalizedTitle(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    // MARK: - Bulk delete copy helpers

    static func bulkDeleteSuccessMessage(count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular) removed." : "\(count) \(plural) removed."
    }

    static func bulkDeleteFailureMessage(_ failures: [String], singular: String, plural: String) -> String {
        let itemLabel = failures.count == 1 ? singular : plural
        let visibleFailures = failures.prefix(3).joined(separator: "\n")
        let remainingCount = failures.count - min(failures.count, 3)
        let remainingMessage = remainingCount > 0 ? "\n...and \(remainingCount) more failed." : ""
        return "\(failures.count) \(itemLabel) failed:\n\(visibleFailures)\(remainingMessage)"
    }
}

/// Common interface for Sonarr and Radarr view models to drive the generic list view.
@MainActor
protocol ArrMediaListViewModel: AnyObject, Sendable {
    associatedtype Item: Identifiable & JellyfinMatchable & Equatable where Item.ID == Int
    associatedtype Filter: RawRepresentable & CaseIterable & Identifiable & Hashable where Filter.RawValue == String
    associatedtype Sort: RawRepresentable & CaseIterable & Identifiable & Hashable where Sort.RawValue == String

    var filteredItems: [Item] { get }
    var searchText: String { get set }
    var selectedFilter: Filter { get set }
    var sortOrder: Sort { get set }
    var isNonDefaultSortOrder: Bool { get }
    var isLoading: Bool { get }
    var items: [Item] { get }
    var queue: [ArrQueueItem] { get }

    func loadLibraryItems() async
    func loadQueue() async
    func refreshLibrary() async throws
    func rssSync() async throws
    func searchAllMissing(noun: String) async throws
    func deleteItem(id: Int, deleteFiles: Bool) async
    func deleteItems(ids: Set<Int>, deleteFiles: Bool) async
    func toggleMonitored(_ item: Item) async
    func refreshFilters()
    func refreshJellyfinLibraryCache() async
}

// MARK: - Wanted-page conformances
// Live here (Trawl-only target) because `ArrWantedPageResponse` isn't compiled
// into the widget / share extensions.

extension SonarrWantedPage: ArrWantedPageResponse {}
extension RadarrWantedPage: ArrWantedPageResponse {}

// MARK: - API-client conformances

extension SonarrAPIClient: ArrLibraryAPIClient {
    typealias LibraryItem = SonarrSeries
    typealias WantedRecord = SonarrEpisode
    typealias WantedPage = SonarrWantedPage

    static var serviceType: ArrServiceType { .sonarr }

    func getLibraryItems() async throws -> [SonarrSeries] {
        try await getSeries()
    }

    func lookup(term: String) async throws -> [SonarrSeries] {
        try await lookupSeries(term: term)
    }

    func wantedMissingPage(page: Int, pageSize: Int) async throws -> SonarrWantedPage {
        try await getWantedMissing(page: page, pageSize: pageSize)
    }

    func refreshLibrary() async throws -> ArrCommand {
        try await refreshSeries()
    }

    func deleteLibraryItem(id: Int, deleteFiles: Bool) async throws {
        try await deleteSeries(id: id, deleteFiles: deleteFiles)
    }
}

extension RadarrAPIClient: ArrLibraryAPIClient {
    typealias LibraryItem = RadarrMovie
    typealias WantedRecord = RadarrMovie
    typealias WantedPage = RadarrWantedPage

    static var serviceType: ArrServiceType { .radarr }

    func getLibraryItems() async throws -> [RadarrMovie] {
        try await getMovies()
    }

    func lookup(term: String) async throws -> [RadarrMovie] {
        try await lookupMovie(term: term)
    }

    func wantedMissingPage(page: Int, pageSize: Int) async throws -> RadarrWantedPage {
        try await getWantedMissing(page: page, pageSize: pageSize)
    }

    func refreshLibrary() async throws -> ArrCommand {
        try await refreshMovie(movieId: nil)
    }

    func deleteLibraryItem(id: Int, deleteFiles: Bool) async throws {
        try await deleteMovie(id: id, deleteFiles: deleteFiles)
    }
}

// MARK: - JellyfinMatchable conformances

extension SonarrSeries: JellyfinMatchable {
    static var jellyfinIncludeItemTypes: [String] { ["Series"] }
    static var jellyfinNumericProviderKeys: [String] { ["Tvdb", "TVDB"] }
    var jellyfinMatchTitle: String { title }
    var jellyfinMatchYear: Int? { year }
    var jellyfinNumericProviderId: Int? { tvdbId }
    var jellyfinImdbProviderId: String? { imdbId }
}

extension RadarrMovie: JellyfinMatchable {
    static var jellyfinIncludeItemTypes: [String] { ["Movie"] }
    static var jellyfinNumericProviderKeys: [String] { ["Tmdb", "TMDb"] }
    var jellyfinMatchTitle: String { title }
    var jellyfinMatchYear: Int? { year }
    var jellyfinNumericProviderId: Int? { tmdbId }
    var jellyfinImdbProviderId: String? { imdbId }
}
