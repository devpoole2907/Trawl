import Foundation
import Observation
import SwiftData
import SwiftUI

enum ArrServiceError: Error, LocalizedError {
    case clientNotAvailable

    var errorDescription: String? {
        switch self {
        case .clientNotAvailable: return "Service not connected"
        }
    }
}

@MainActor
@Observable
final class SonarrViewModel {
    // Library state
    private(set) var series: [SonarrSeries] = [] { didSet { rebuildFilteredSeries() } }
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    // Episode state (for detail views)
    private(set) var episodes: [Int: [SonarrEpisode]] = [:]  // seriesId -> episodes
    private(set) var isLoadingEpisodes: Bool = false
    private(set) var episodeFiles: [Int: [SonarrEpisodeFile]] = [:]  // seriesId -> files
    private(set) var wantedEpisodes: [SonarrEpisode] = []
    private(set) var isLoadingWantedMissing: Bool = false
    private(set) var wantedMissingTotalRecords: Int = 0
    private var wantedMissingPage = 1
    private let wantedMissingPageSize = 20

    // Search state
    var searchText: String = "" { didSet { rebuildFilteredSeries() } }
    private(set) var searchResults: [SonarrSeries] = []
    private(set) var isSearching: Bool = false
    private var searchRequestToken: UUID?

    // Queue state
    private(set) var queue: [ArrQueueItem] = []
    private(set) var history: [ArrHistoryRecord] = []
    private(set) var isLoadingHistory: Bool = false
    private(set) var historyTotalRecords: Int = 0
    private var historyPage = 1
    private let historyPageSize = 20

    // Updates
    private(set) var availableUpdates: [ArrUpdateInfo] = []
    private(set) var isLoadingUpdates: Bool = false

    // Filter & Sort
    var selectedFilter: SonarrFilter = .all { didSet { rebuildFilteredSeries() } }
    var sortOrder: SonarrSortOrder = .title { didSet { rebuildFilteredSeries() } }

    private let serviceManager: ArrServiceManager

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    /// Convenience init that pre-seeds the series list (used by Search to avoid a fresh empty load).
    init(serviceManager: ArrServiceManager, preloadedSeries: [SonarrSeries]) {
        self.serviceManager = serviceManager
        self.series = preloadedSeries
        rebuildFilteredSeries()
    }

    private var client: SonarrAPIClient? { serviceManager.sonarrClient }

    // MARK: - Filtered (cached, updated via didSet observers)

    private(set) var filteredSeries: [SonarrSeries] = []

    private func rebuildFilteredSeries() {
        filteredSeries = FilterSortPipeline.apply(
            items: series,
            filter: selectedFilter,
            searchText: searchText,
            sort: sortOrder,
            matchesSearch: { series, query in
                series.title.localizedCaseInsensitiveContains(query)
            },
            matchesFilter: { series, filter in
                switch filter {
                case .all:
                    return true
                case .monitored:
                    return series.monitored == true
                case .unmonitored:
                    return series.monitored == false
                case .continuing:
                    return series.status == "continuing"
                case .ended:
                    return series.status == "ended"
                case .missing:
                    guard let stats = series.statistics else { return false }
                    return (stats.episodeCount ?? 0) > (stats.episodeFileCount ?? 0)
                }
            },
            areInIncreasingOrder: { a, b, sort in
                switch sort {
                case .title:
                    return (a.sortTitle ?? a.title) < (b.sortTitle ?? b.title)
                case .status:
                    return (a.status ?? "") < (b.status ?? "")
                case .progress:
                    return progressFraction(for: a) > progressFraction(for: b)
                case .network:
                    return (a.network ?? "") < (b.network ?? "")
                }
            }
        )
    }

    private func progressFraction(for series: SonarrSeries) -> Double {
        guard let statistics = series.statistics,
              let episodeCount = statistics.episodeCount,
              episodeCount > 0 else {
            return 0
        }

        return Double(statistics.episodeFileCount ?? 0) / Double(episodeCount)
    }

    var qualityProfiles: [ArrQualityProfile] { serviceManager.sonarrQualityProfiles }
    var rootFolders: [ArrRootFolder] { serviceManager.sonarrRootFolders }
    var tags: [ArrTag] { serviceManager.sonarrTags }
    var isConnected: Bool { serviceManager.sonarrConnected }

    // MARK: - Library

    func loadSeries() async {
        guard let client else { return }
        isLoading = true
        error = nil
        do {
            series = try await client.getSeries()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func refreshSeries() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.refreshSeries()
        InAppNotificationCenter.shared.showSuccess(title: "Refresh Started", message: "Library refresh command sent.")
        // Re-fetch after a brief delay for the refresh command to process
        try? await Task.sleep(for: .seconds(2))
        await loadSeries()
    }

    // MARK: - Episodes

    func loadEpisodes(for seriesId: Int) async {
        guard let client else { return }
        isLoadingEpisodes = true
        do {
            let eps = try await client.getEpisodes(seriesId: seriesId)
            episodes[seriesId] = eps
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingEpisodes = false
    }

    func loadEpisodeFiles(for seriesId: Int) async {
        guard let client else { return }
        do {
            let files = try await client.getEpisodeFiles(seriesId: seriesId)
            episodeFiles[seriesId] = files.sorted {
                ($0.seasonNumber ?? 0, $0.relativePath ?? "") < ($1.seasonNumber ?? 0, $1.relativePath ?? "")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleEpisodeMonitored(_ episode: SonarrEpisode) async {
        guard let client else { return }
        let newMonitored = !(episode.monitored ?? true)
        do {
            _ = try await client.setEpisodeMonitored(episodeIds: [episode.id], monitored: newMonitored)
            if let seriesId = episode.seriesId {
                await loadEpisodes(for: seriesId)
            }
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error.localizedDescription)
        }
    }

    func toggleSeriesMonitored(_ series: SonarrSeries) async {
        guard let client else { return }
        let newMonitored = !(series.monitored ?? true)

        do {
            // Fetch canonical series from API to ensure we have all required fields
            let canonicalSeries = try await client.getSeries(id: series.id)

            // Verify canonical series has required fields
            guard let qualityProfileId = canonicalSeries.qualityProfileId,
                  let rootFolderPath = canonicalSeries.rootFolderPath,
                  !rootFolderPath.isEmpty,
                  let seriesType = canonicalSeries.seriesType,
                  let seasonFolder = canonicalSeries.seasonFolder else {
                // Missing required fields
                await loadSeries()
                return
            }

            // Build the update from canonical fields
            let updatedSeries = canonicalSeries.updatingForEdit(
                monitored: newMonitored,
                qualityProfileId: qualityProfileId,
                seriesType: seriesType,
                seasonFolder: seasonFolder,
                rootFolderPath: rootFolderPath,
                tags: canonicalSeries.tags ?? []
            )

            // Update UI with the correct data
            if let idx = self.series.firstIndex(where: { $0.id == series.id }) {
                self.series[idx] = updatedSeries
            }

            _ = try await client.updateSeries(updatedSeries, moveFiles: false)
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showMonitoringChanged(
                itemName: series.title,
                itemType: "Series",
                isMonitoring: newMonitored
            )
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error.localizedDescription)
            await loadSeries() // Revert on failure
        }
    }

    func searchEpisode(_ episode: SonarrEpisode) async {
        guard let client else { return }
        do {
            _ = try await client.searchEpisodes(episodeIds: [episode.id])
            InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching for episode.")
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error.localizedDescription)
        }
    }

    @discardableResult
    func searchSeason(seriesId: Int, seasonNumber: Int) async -> Bool {
        guard let client else {
            self.error = ArrServiceError.clientNotAvailable.errorDescription
            return false
        }
        error = nil
        do {
            _ = try await client.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
            InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching for season \(seasonNumber).")
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func searchSeries(seriesId: Int) async -> Bool {
        guard let client else {
            self.error = ArrServiceError.clientNotAvailable.errorDescription
            return false
        }
        error = nil
        do {
            _ = try await client.searchSeries(seriesId: seriesId)
            InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching all monitored episodes.")
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error.localizedDescription)
            return false
        }
    }

    func interactiveSearch(episodeId: Int? = nil, seriesId: Int? = nil, seasonNumber: Int? = nil) async -> [ArrRelease] {
        guard let client else { return [] }
        error = nil
        do {
            return try await client.getReleases(episodeId: episodeId, seriesId: seriesId, seasonNumber: seasonNumber)
        } catch is CancellationError {
            return []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    func grabRelease(_ release: ArrRelease) async -> Bool {
        guard let client else { return false }
        error = nil
        do {
            try await client.grabRelease(release)
            InAppNotificationCenter.shared.showSuccess(title: "Grabbed", message: release.title ?? "Release")
            await loadQueue()
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Grab Failed", message: error.localizedDescription)
            return false
        }
    }

    func loadWantedMissing() async {
        guard !isLoadingWantedMissing else { return }
        guard let client else { return }
        isLoadingWantedMissing = true
        defer { isLoadingWantedMissing = false }
        error = nil
        do {
            let page = try await client.getWantedMissing(page: 1, pageSize: wantedMissingPageSize)
            wantedEpisodes = page.records ?? []
            wantedMissingPage = page.page ?? 1
            wantedMissingTotalRecords = page.totalRecords ?? wantedEpisodes.count
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMoreWantedMissing() async {
        guard !isLoadingWantedMissing && canLoadMoreWantedMissing else { return }
        guard let client else { return }
        isLoadingWantedMissing = true
        defer { isLoadingWantedMissing = false }

        let nextPage = wantedMissingPage + 1
        do {
            let page = try await client.getWantedMissing(page: nextPage, pageSize: wantedMissingPageSize)
            wantedEpisodes.append(contentsOf: page.records ?? [])
            wantedMissingPage = page.page ?? nextPage
            wantedMissingTotalRecords = page.totalRecords ?? wantedEpisodes.count
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Add Series

    func searchForNewSeries(term: String) async {
        guard let client, !term.isEmpty else {
            searchResults = []
            searchRequestToken = nil
            return
        }

        let requestToken = UUID()
        searchRequestToken = requestToken
        isSearching = true
        searchResults = []
        error = nil

        do {
            let results = try await client.lookupSeries(term: term)
            guard !Task.isCancelled else { return }
            guard searchRequestToken == requestToken else {
                return
            }
            
            // Stream in the results one by one for a more async feel
            for result in results {
                guard !Task.isCancelled && searchRequestToken == requestToken else { break }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    searchResults.append(result)
                }
                try? await Task.sleep(for: .milliseconds(40))
            }

            // Only turn off spinner if still the active request
            if !Task.isCancelled && searchRequestToken == requestToken {
                isSearching = false
            }
        } catch is CancellationError {
            if searchRequestToken == requestToken {
                isSearching = false
            }
            return
        } catch {
            guard !Task.isCancelled else { return }
            guard searchRequestToken == requestToken else {
                return
            }
            self.error = error.localizedDescription
            searchResults = []
            isSearching = false
        }
    }

    func clearSearchResults() {
        searchResults = []
        error = nil
        isSearching = false
        searchRequestToken = nil
    }

    func addSeries(
        tvdbId: Int,
        title: String,
        titleSlug: String,
        images: [ArrImage],
        seasons: [SonarrSeason],
        qualityProfileId: Int,
        rootFolderPath: String,
        monitored: Bool = true,
        seasonFolder: Bool = true,
        seriesType: String = "standard",
        monitorOption: String = "all",
        searchForMissing: Bool = true
    ) async -> Bool {
        guard let client else { return false }
        let addSeasons = seasons.map { SonarrAddSeason(seasonNumber: $0.seasonNumber, monitored: $0.monitored ?? true) }
        let body = SonarrAddSeriesBody(
            tvdbId: tvdbId,
            title: title,
            qualityProfileId: qualityProfileId,
            languageProfileId: nil,
            titleSlug: titleSlug,
            images: images,
            seasons: addSeasons,
            rootFolderPath: rootFolderPath,
            monitored: monitored,
            seasonFolder: seasonFolder,
            seriesType: seriesType,
            addOptions: SonarrAddOptions(
                monitor: monitorOption,
                searchForMissingEpisodes: searchForMissing,
                searchForCutoffUnmetEpisodes: false
            ),
            tags: nil
        )
        do {
            _ = try await client.addSeries(body)
            await loadSeries()
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showMonitoringChanged(
                itemName: title,
                itemType: "Series",
                isMonitoring: monitored
            )
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Add Failed", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Update

    func updateSeries(
        _ series: SonarrSeries,
        monitored: Bool,
        qualityProfileId: Int,
        seriesType: String,
        seasonFolder: Bool,
        rootFolderPath: String,
        tags: [Int],
        moveFiles: Bool = false
    ) async -> Bool {
        guard let client else { return false }
        do {
            let rootFolderChanged = rootFolderPath != (series.rootFolderPath ?? "")
            let updatedSeries = series.updatingForEdit(
                monitored: monitored,
                qualityProfileId: qualityProfileId,
                seriesType: seriesType,
                seasonFolder: seasonFolder,
                rootFolderPath: rootFolderPath,
                tags: tags
            )
            _ = try await client.updateSeries(updatedSeries, moveFiles: moveFiles)
            await loadSeries()
            if series.id > 0 {
                await loadEpisodes(for: series.id)
                await loadEpisodeFiles(for: series.id)
            }
            await loadQueue()
            await serviceManager.calendarViewModel.refresh()
            let message: String
            if rootFolderChanged {
                message = moveFiles
                    ? "Root folder updated to \(rootFolderPath) and Sonarr was asked to move existing files."
                    : "Root folder updated to \(rootFolderPath). Import status was refreshed."
            } else {
                message = series.title
            }
            InAppNotificationCenter.shared.showSuccess(title: "Updated", message: message)
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Delete

    func deleteSeries(id: Int, deleteFiles: Bool = false) async {
        guard let client else { return }
        let seriesTitle = series.first(where: { $0.id == id })?.title ?? "Series"
        do {
            try await client.deleteSeries(id: id, deleteFiles: deleteFiles)
            series.removeAll { $0.id == id }
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showSuccess(title: "Deleted", message: seriesTitle)
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    func deleteEpisodeFile(id: Int) async -> Bool {
        guard let client else { return false }
        let seriesId = episodeFiles.first(where: { $0.value.contains(where: { $0.id == id }) })?.key

        do {
            error = nil
            try await client.deleteEpisodeFile(id: id)
            InAppNotificationCenter.shared.showSuccess(title: "File Deleted", message: "Episode file removed.")

            if let seriesId {
                await loadEpisodeFiles(for: seriesId)
                await loadEpisodes(for: seriesId)
                await loadSeries()
            }
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Queue

    func loadQueue() async {
        guard let client else { return }
        do {
            let page = try await client.getQueue(page: 1, pageSize: 50)
            queue = page.records ?? []
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadHistory(page: Int = 1) async {
        guard let client else { return }
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let historyPageResult = try await client.getHistory(page: page, pageSize: historyPageSize)
            let records = historyPageResult.records ?? []

            if page == 1 {
                history = records
            } else {
                history.append(contentsOf: records)
            }

            historyPage = historyPageResult.page ?? page
            historyTotalRecords = historyPageResult.totalRecords ?? history.count
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNextHistoryPage() async {
        guard !isLoadingHistory && canLoadMoreHistory else { return }
        await loadHistory(page: historyPage + 1)
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

    func searchAllMissing() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.searchAllMissing()
        InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching for all missing episodes.")
    }

    func rssSync() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.rssSync()
        InAppNotificationCenter.shared.showSuccess(title: "RSS Sync", message: "Sync command sent.")
    }

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

    var canLoadMoreWantedMissing: Bool {
        wantedEpisodes.count < wantedMissingTotalRecords
    }

    var canLoadMoreHistory: Bool {
        history.count < historyTotalRecords
    }
}

// MARK: - Filter

enum SonarrFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case monitored = "Monitored"
    case unmonitored = "Unmonitored"
    case continuing = "Continuing"
    case ended = "Ended"
    case missing = "Missing"

    var id: String { rawValue }
}

enum SonarrSortOrder: String, CaseIterable, Identifiable {
    case title = "Title"
    case status = "Status"
    case progress = "Progress"
    case network = "Network"

    var id: String { rawValue }
}
