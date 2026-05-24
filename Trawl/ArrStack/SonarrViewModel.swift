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
final class SonarrViewModel: ArrMediaLibraryViewModel<SonarrAPIClient, SonarrFilter, SonarrSortOrder> {
    // Library state
    private(set) var series: [SonarrSeries] = [] { didSet { rebuildFilteredItems() } }
    // Episode state (for detail views)
    private(set) var episodes: [Int: [SonarrEpisode]] = [:]  // seriesId -> episodes
    private(set) var isLoadingEpisodes: Bool = false
    private(set) var episodeFiles: [Int: [SonarrEpisodeFile]] = [:]  // seriesId -> files

    init(serviceManager: ArrServiceManager, jellyfinManager: JellyfinServiceManager? = nil) {
        super.init(
            serviceManager: serviceManager,
            client: serviceManager.sonarrClient,
            jellyfinManager: jellyfinManager,
            defaultFilter: .all,
            defaultSort: .title
        )
    }

    /// Convenience init that pre-seeds the series list (used by Search to avoid a fresh empty load).
    init(serviceManager: ArrServiceManager, preloadedSeries: [SonarrSeries], jellyfinManager: JellyfinServiceManager? = nil) {
        super.init(
            serviceManager: serviceManager,
            client: serviceManager.sonarrClient,
            jellyfinManager: jellyfinManager,
            defaultFilter: .all,
            defaultSort: .title
        )
        self.series = preloadedSeries
        setLibraryItems(preloadedSeries)
        rebuildFilteredItems()
    }

    override var nounSingular: String { "series" }
    override var nounPlural: String { "series" }

    override func toggleMonitored(_ item: SonarrSeries) async { await toggleSeriesMonitored(item) }

    override func setLibraryItems(_ items: [SonarrSeries]) {
        super.setLibraryItems(items)
        self.series = items
    }

    // MARK: - Domain-named accessors (compat shims)
    /// Episodes returned from the wanted/missing endpoint.
    var wantedEpisodes: [SonarrEpisode] { wantedRecords }

    override func onJellyfinLibraryCacheChanged() {
        rebuildFilteredItems()
    }

    override func rebuildFilteredItems() {
        filteredItems = FilterSortPipeline.apply(
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
                case .subtitlesPresent:
                    return serviceManager.bazarrSubtitleStatus(forSonarrSeriesId: series.id) == .allPresent
                case .inJellyfinLibrary:
                    return isInJellyfinLibrary(series)
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
        guard let loadedSeries = await performLoad({ try await $0.getSeries() }) else { return }
        series = loadedSeries
        setLibraryItems(loadedSeries)
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
        } catch is CancellationError {
            // ignore
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
        } catch is CancellationError {
            // ignore
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

    func interactiveSearch(episodeId: Int? = nil, seriesId: Int? = nil, seasonNumber: Int? = nil) async throws -> [ArrRelease] {
        guard let client else { throw ArrError.noServiceConfigured }
        error = nil
        #if DEBUG
        print("[InteractiveSearch][Sonarr] start episodeId=\(episodeId.map(String.init) ?? "nil") seriesId=\(seriesId.map(String.init) ?? "nil") seasonNumber=\(seasonNumber.map(String.init) ?? "nil")")
        #endif
        do {
            let releases = try await client.getReleases(episodeId: episodeId, seriesId: seriesId, seasonNumber: seasonNumber)
            #if DEBUG
            print("[InteractiveSearch][Sonarr] success releases=\(releases.count)")
            #endif
            return releases
        } catch is CancellationError {
            #if DEBUG
            print("[InteractiveSearch][Sonarr] cancelled")
            #endif
            throw CancellationError()
        } catch {
            self.error = error.localizedDescription
            let nsError = error as NSError
            #if DEBUG
            print("[InteractiveSearch][Sonarr] failed domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)")
            #endif
            throw error
        }
    }

    // MARK: - Add Series

    func searchForNewSeries(term: String) async {
        await performLookup(term: term)
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

    func deleteSeries(ids: Set<Int>, deleteFiles: Bool = false) async {
        let idsToDelete = ids.sorted()
        guard !idsToDelete.isEmpty else { return }
        guard let client else {
            error = ArrServiceError.clientNotAvailable.localizedDescription
            InAppNotificationCenter.shared.showError(
                title: "Delete Failed",
                message: ArrServiceError.clientNotAvailable.localizedDescription
            )
            return
        }

        let titlesByID = Dictionary(uniqueKeysWithValues: series
            .filter { ids.contains($0.id) }
            .map { ($0.id, $0.title) })
        var deletedIDs = Set<Int>()
        var failures: [String] = []

        for id in idsToDelete {
            let seriesTitle = titlesByID[id] ?? "Series \(id)"
            do {
                try await client.deleteSeries(id: id, deleteFiles: deleteFiles)
                deletedIDs.insert(id)
            } catch {
                failures.append("\(seriesTitle): \(error.localizedDescription)")
            }
        }

        if !deletedIDs.isEmpty {
            series.removeAll { deletedIDs.contains($0.id) }
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showSuccess(
                title: "Deleted",
                message: Self.bulkDeleteSuccessMessage(count: deletedIDs.count, singular: "series", plural: "series")
            )
        }

        if failures.isEmpty {
            error = nil
        } else {
            error = failures.first
            InAppNotificationCenter.shared.showError(
                title: "Delete Failed",
                message: Self.bulkDeleteFailureMessage(failures, singular: "series", plural: "series")
            )
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
}

// MARK: - Filter

nonisolated enum SonarrFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case monitored = "Monitored"
    case unmonitored = "Unmonitored"
    case continuing = "Continuing"
    case ended = "Ended"
    case missing = "Missing"
    case subtitlesPresent = "Subtitles Present"
    case inJellyfinLibrary = "In Jellyfin Library"

    var id: String { rawValue }
}

nonisolated enum SonarrSortOrder: String, CaseIterable, Identifiable, Sendable {
    case title = "Title"
    case status = "Status"
    case progress = "Progress"
    case network = "Network"

    var id: String { rawValue }
}

#if DEBUG
extension SonarrViewModel {
    convenience init(
        previewSeries: [SonarrSeries] = SonarrSeries.previewList,
        isLoading: Bool = false,
        error: String? = nil,
        episodes: [Int: [SonarrEpisode]] = [:],
        isLoadingEpisodes: Bool = false,
        episodeFiles: [Int: [SonarrEpisodeFile]] = [:],
        serviceManager: ArrServiceManager = .preview(.sonarrOnly),
        jellyfinManager: JellyfinServiceManager? = .preview()
    ) {
        self.init(serviceManager: serviceManager, preloadedSeries: previewSeries, jellyfinManager: jellyfinManager)
        self.client = nil
        self.isLoading = isLoading
        self.error = error
        self.episodes = episodes
        self.isLoadingEpisodes = isLoadingEpisodes
        self.episodeFiles = episodeFiles
    }

    static func previewDetail(
        _ series: SonarrSeries = .preview,
        serviceManager: ArrServiceManager = .preview(.sonarrOnly),
        isLoadingEpisodes: Bool = false,
        error: String? = nil
    ) -> SonarrViewModel {
        SonarrViewModel(
            previewSeries: [series],
            error: error,
            episodes: [series.id: SonarrEpisode.previewList],
            isLoadingEpisodes: isLoadingEpisodes,
            episodeFiles: [series.id: SonarrEpisodeFile.previewList],
            serviceManager: serviceManager
        )
    }
}

@MainActor
struct SonarrPreviewHost<Content: View>: View {
    let profiles: PreviewSupport.ProfileScenario
    let arr: ArrServiceManager
    let sync: SyncService
    let torrent: TorrentService
    let content: (ArrServiceManager) -> Content

    init(
        profiles: PreviewSupport.ProfileScenario = .arrOnly,
        state: ArrServiceManager.PreviewState = .sonarrOnly,
        @ViewBuilder content: @escaping (ArrServiceManager) -> Content
    ) {
        self.profiles = profiles
        self.arr = ArrServiceManager.preview(state)
        self.sync = SyncService.preview()
        self.torrent = TorrentService.preview()
        self.content = content
    }

    var body: some View {
        PreviewHost(profiles: profiles, arr: arr) {
            content(arr)
                .environment(sync)
                .environment(torrent)
        }
    }
}
#endif
