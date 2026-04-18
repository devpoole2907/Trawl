import Foundation
import Observation
import SwiftData

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

    // Queue state
    private(set) var queue: [ArrQueueItem] = []
    private(set) var history: [ArrHistoryRecord] = []
    private(set) var isLoadingHistory: Bool = false
    private(set) var historyTotalRecords: Int = 0
    private var historyPage = 1
    private let historyPageSize = 20

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
        var result = series

        switch selectedFilter {
        case .all: break
        case .monitored: result = result.filter { $0.monitored == true }
        case .unmonitored: result = result.filter { $0.monitored == false }
        case .continuing: result = result.filter { $0.status == "continuing" }
        case .ended: result = result.filter { $0.status == "ended" }
        case .missing: result = result.filter {
            guard let stats = $0.statistics else { return false }
            return (stats.episodeCount ?? 0) > (stats.episodeFileCount ?? 0)
        }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.title.lowercased().contains(query) }
        }

        result.sort { a, b in
            switch sortOrder {
            case .title:
                return (a.sortTitle ?? a.title) < (b.sortTitle ?? b.title)
            case .status:
                return (a.status ?? "") < (b.status ?? "")
            case .progress:
                let aFrac = { guard let s = a.statistics, let t = s.episodeCount, t > 0 else { return 0.0 }; return Double(s.episodeFileCount ?? 0) / Double(t) }()
                let bFrac = { guard let s = b.statistics, let t = s.episodeCount, t > 0 else { return 0.0 }; return Double(s.episodeFileCount ?? 0) / Double(t) }()
                return aFrac > bFrac
            case .network:
                return (a.network ?? "") < (b.network ?? "")
            }
        }
        filteredSeries = result
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

    func refreshSeries() async {
        guard let client else { return }
        do {
            _ = try await client.refreshSeries()
            // Re-fetch after a brief delay for the refresh command to process
            try? await Task.sleep(for: .seconds(2))
            await loadSeries()
        } catch {
            self.error = error.localizedDescription
        }
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
        }
    }

    func toggleSeriesMonitored(_ series: SonarrSeries) async {
        guard let client else { return }
        let newMonitored = !(series.monitored ?? true)
        let updatedSeries = series.updatingForEdit(
            monitored: newMonitored,
            qualityProfileId: series.qualityProfileId ?? qualityProfiles.first?.id ?? 0,
            seriesType: series.seriesType ?? "standard",
            seasonFolder: series.seasonFolder ?? true,
            rootFolderPath: series.rootFolderPath ?? rootFolders.first?.path ?? "",
            tags: series.tags ?? []
        )
        // Optimistic update — UI responds immediately
        if let idx = self.series.firstIndex(where: { $0.id == series.id }) {
            self.series[idx] = updatedSeries
        }
        do {
            _ = try await client.updateSeries(updatedSeries, moveFiles: false)
            await MainActor.run {
                InAppNotificationCenter.shared.showMonitoringChanged(
                    itemName: series.title,
                    itemType: "Series",
                    isMonitoring: newMonitored
                )
            }
        } catch {
            self.error = error.localizedDescription
            await loadSeries() // Revert on failure
        }
    }

    func searchEpisode(_ episode: SonarrEpisode) async {
        guard let client else { return }
        do {
            _ = try await client.searchEpisodes(episodeIds: [episode.id])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func searchSeason(seriesId: Int, seasonNumber: Int) async {
        guard let client else { return }
        do {
            _ = try await client.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadWantedMissing() async {
        guard let client else { return }
        isLoadingWantedMissing = true
        error = nil
        do {
            let page = try await client.getWantedMissing(page: 1, pageSize: wantedMissingPageSize)
            wantedEpisodes = page.records ?? []
            wantedMissingPage = page.page ?? 1
            wantedMissingTotalRecords = page.totalRecords ?? wantedEpisodes.count
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingWantedMissing = false
    }

    func loadMoreWantedMissing() async {
        guard let client, canLoadMoreWantedMissing else { return }
        isLoadingWantedMissing = true
        do {
            let nextPage = wantedMissingPage + 1
            let page = try await client.getWantedMissing(page: nextPage, pageSize: wantedMissingPageSize)
            wantedEpisodes.append(contentsOf: page.records ?? [])
            wantedMissingPage = page.page ?? nextPage
            wantedMissingTotalRecords = page.totalRecords ?? wantedEpisodes.count
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingWantedMissing = false
    }

    // MARK: - Add Series

    func searchForNewSeries(term: String) async {
        guard let client, !term.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        error = nil
        do {
            searchResults = try await client.lookupSeries(term: term)
        } catch {
            self.error = error.localizedDescription
            searchResults = []
        }
        isSearching = false
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
            await MainActor.run {
                InAppNotificationCenter.shared.showMonitoringChanged(
                    itemName: title,
                    itemType: "Series",
                    isMonitoring: monitored
                )
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Delete

    func updateSeries(
        _ series: SonarrSeries,
        monitored: Bool,
        qualityProfileId: Int,
        seriesType: String,
        seasonFolder: Bool,
        rootFolderPath: String,
        tags: [Int]
    ) async -> Bool {
        guard let client else { return false }
        do {
            let updatedSeries = series.updatingForEdit(
                monitored: monitored,
                qualityProfileId: qualityProfileId,
                seriesType: seriesType,
                seasonFolder: seasonFolder,
                rootFolderPath: rootFolderPath,
                tags: tags
            )
            _ = try await client.updateSeries(updatedSeries, moveFiles: false)
            await loadSeries()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteSeries(id: Int, deleteFiles: Bool = false) async {
        guard let client else { return }
        do {
            try await client.deleteSeries(id: id, deleteFiles: deleteFiles)
            series.removeAll { $0.id == id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteEpisodeFile(id: Int) async {
        guard let client else { return }
        let seriesId = episodeFiles.first(where: { $0.value.contains(where: { $0.id == id }) })?.key

        do {
            try await client.deleteEpisodeFile(id: id)

            if let seriesId {
                await loadEpisodeFiles(for: seriesId)
                await loadEpisodes(for: seriesId)
                await loadSeries()
            }
        } catch {
            self.error = error.localizedDescription
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
        isLoadingHistory = true
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
        isLoadingHistory = false
    }

    func loadNextHistoryPage() async {
        await loadHistory(page: historyPage + 1)
    }

    func removeQueueItem(id: Int, blocklist: Bool = false) async {
        guard let client else { return }
        do {
            try await client.deleteQueueItem(id: id, blocklist: blocklist)
            queue.removeAll { $0.id == id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func searchAllMissing() async {
        guard let client else { return }
        do {
            _ = try await client.searchAllMissing()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rssSync() async {
        guard let client else { return }
        do {
            _ = try await client.rssSync()
        } catch {
            self.error = error.localizedDescription
        }
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
