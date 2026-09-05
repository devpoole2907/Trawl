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
    /// Keyed by (server, series ID) rather than by series ID alone. Both halves of
    /// an HD/4K pair hand out a series 1, so a bare-Int key means whichever server
    /// loaded last wins and the other's episodes are silently displayed under it.
    private(set) var episodes: [ArrScopedID: [SonarrEpisode]] = [:]
    private(set) var isLoadingEpisodes: Bool = false
    private(set) var episodeFiles: [ArrScopedID: [SonarrEpisodeFile]] = [:]

    /// Episodes for one server's copy of a series. `instanceID` nil keeps the
    /// pre-pair behaviour of reading whatever the bound client loaded.
    func episodes(forSeries seriesId: Int, on instanceID: UUID?) -> [SonarrEpisode] {
        episodes[ArrScopedID(instanceID, seriesId)] ?? []
    }

    func episodeFiles(forSeries seriesId: Int, on instanceID: UUID?) -> [SonarrEpisodeFile] {
        episodeFiles[ArrScopedID(instanceID, seriesId)] ?? []
    }

    /// The client that owns a copy, falling back to the bound one when no server is
    /// named - a preview, or a caller that predates the pair.
    private func client(for instanceID: UUID?) -> SonarrAPIClient? {
        guard let instanceID else { return client }
        return serviceManager.sonarrClient(for: instanceID)
    }

    init(serviceManager: ArrServiceManager, jellyfinManager: JellyfinServiceManager? = nil) {
        super.init(
            serviceManager: serviceManager,
            client: serviceManager.sonarrClient,
            clientProvider: { [weak serviceManager] in serviceManager?.sonarrClient },
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
            clientProvider: { [weak serviceManager] in serviceManager?.sonarrClient },
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
        filteredItems = makeFilteredEntries(
            from: series,
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
                    return serviceManager.subtitleCoverage(for: series).isFullyCovered
                case .inJellyfinLibrary:
                    return isInJellyfinLibrary(series)
                }
            },
            areInIncreasingOrder: { lhs, rhs, sort in
                let a = lhs.primary
                let b = rhs.primary
                switch sort {
                case .title:
                    return (a.sortTitle ?? a.title) < (b.sortTitle ?? b.title)
                case .recentlyAdded:
                    return (a.added ?? "") > (b.added ?? "")
                case .status:
                    return (a.status ?? "") < (b.status ?? "")
                case .progress:
                    // The best-served copy wins: a series complete on the HD
                    // server shouldn't sort as incomplete because the 4K server
                    // has only half of it.
                    let lhsProgress = lhs.copies.map { self.progressFraction(for: $0) }.max() ?? 0
                    let rhsProgress = rhs.copies.map { self.progressFraction(for: $0) }.max() ?? 0
                    return lhsProgress > rhsProgress
                case .network:
                    return (a.network ?? "") < (b.network ?? "")
                }
            }
        )
    }

    /// Deletes every server's copy of each selected title, routing each delete to
    /// the server that holds it.
    override func deleteEntries(_ entries: [ArrLibraryEntry<SonarrSeries>], deleteFiles: Bool) async {
        var deleted: [(instanceID: UUID?, id: Int)] = []
        var failures: [String] = []

        for entry in entries {
            for copy in entry.copies {
                guard let client = serviceManager.sonarrClient(owning: copy) else {
                    failures.append("\(copy.title): Sonarr isn’t connected.")
                    continue
                }
                do {
                    try await client.deleteSeries(id: copy.id, deleteFiles: deleteFiles)
                    deleted.append((copy.instanceID, copy.id))
                } catch {
                    failures.append("\(copy.title): \(error.localizedDescription)")
                }
            }
        }

        if !deleted.isEmpty {
            series.removeAll { item in
                deleted.contains { $0.instanceID == item.instanceID && $0.id == item.id }
            }
            await serviceManager.calendarViewModel.refresh()
            ArrOperationFeedback.showSuccess(
                title: "Deleted",
                message: Self.bulkDeleteSuccessMessage(count: entries.count, singular: "series", plural: "series")
            )
        }

        if failures.isEmpty {
            error = nil
        } else {
            error = failures.first
            ArrOperationFeedback.showFailure(
                title: "Delete Failed",
                message: Self.bulkDeleteFailureMessage(failures, singular: "series", plural: "series")
            )
        }
    }

    private func progressFraction(for series: SonarrSeries) -> Double {
        guard let statistics = series.statistics,
              let episodeCount = statistics.episodeCount,
              episodeCount > 0 else {
            return 0
        }

        return Double(statistics.episodeFileCount ?? 0) / Double(episodeCount)
    }

    /// Config for one server. The pair do not share quality profiles or root
    /// folders - an HD profile ID posted to the 4K server names a different profile
    /// or none at all.
    func qualityProfiles(on instanceID: UUID?) -> [ArrQualityProfile] {
        guard let instanceID else { return qualityProfiles }
        return serviceManager.qualityProfilesByInstance.first { $0.ref.id == instanceID }?.values ?? []
    }

    func rootFolders(on instanceID: UUID?) -> [ArrRootFolder] {
        guard let instanceID else { return rootFolders }
        return serviceManager.rootFolders(for: instanceID)
    }

    var qualityProfiles: [ArrQualityProfile] { serviceManager.sonarrQualityProfiles }
    var rootFolders: [ArrRootFolder] { serviceManager.sonarrRootFolders }
    var tags: [ArrTag] { serviceManager.sonarrTags }
    var isConnected: Bool { serviceManager.sonarrConnected }

    /// Both Sonarr servers, so the queue, history and library this view model
    /// exposes cover the whole blended library rather than one half of it.
    override var routedInstances: [(ref: ArrInstanceRef, client: SonarrAPIClient)] {
        serviceManager.visibleSonarr
    }

    override func client(forExplicitInstanceID instanceID: UUID) -> SonarrAPIClient? {
        serviceManager.sonarrClient(for: instanceID)
    }

    // MARK: - Library

    /// Domain-named alias for `loadLibraryItems(maxAge:)`, which is where the
    /// shared per-instance cache lives. `setLibraryItems` assigns `series`, so
    /// there is nothing extra to do here.
    func loadSeries(maxAge: TimeInterval = 0) async {
        await loadLibraryItems(maxAge: maxAge)
    }

    func refreshSeries() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.refreshSeries()
        ArrOperationFeedback.showSuccess(title: "Refresh Started", message: "Library refresh command sent.")
        // Re-fetch after a brief delay for the refresh command to process
        try? await Task.sleep(for: .seconds(2))
        await loadSeries()
    }

    // MARK: - Episodes

    func loadEpisodes(for seriesId: Int, instanceID: UUID? = nil) async {
        guard let client = client(for: instanceID) else {
            captureEpisodeLoadFailure(ArrServiceError.clientNotAvailable)
            return
        }
        isLoadingEpisodes = true
        do {
            let eps = try await client.getEpisodes(seriesId: seriesId).stamped(with: instanceID)
            episodes[ArrScopedID(instanceID, seriesId)] = eps
        } catch is CancellationError {
            // ignore
        } catch {
            captureEpisodeLoadFailure(error)
        }
        isLoadingEpisodes = false
    }

    func loadEpisodeFiles(for seriesId: Int, instanceID: UUID? = nil) async {
        guard let client = client(for: instanceID) else {
            captureEpisodeLoadFailure(ArrServiceError.clientNotAvailable)
            return
        }
        do {
            let files = try await client.getEpisodeFiles(seriesId: seriesId)
            episodeFiles[ArrScopedID(instanceID, seriesId)] = files.sorted {
                ($0.seasonNumber ?? 0, $0.relativePath ?? "") < ($1.seasonNumber ?? 0, $1.relativePath ?? "")
            }
        } catch is CancellationError {
            // ignore
        } catch {
            captureEpisodeLoadFailure(error)
        }
    }

    private func captureEpisodeLoadFailure(_ failure: Error) {
        capture(failure, notificationTitle: "Episode Load Failed")
    }

    func toggleEpisodeMonitored(_ episode: SonarrEpisode) async {
        guard let client else { return }
        let newMonitored = !(episode.monitored ?? true)
        do {
            _ = try await client.setEpisodeMonitored(episodeIds: [episode.id], monitored: newMonitored)
            if let seriesId = episode.seriesId {
                await loadEpisodes(for: seriesId, instanceID: episode.instanceID)
            }
        } catch {
            capture(error, notificationTitle: "Update Failed")
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
            capture(error, notificationTitle: "Update Failed")
            await loadSeries() // Revert on failure
        }
    }

    func searchEpisode(_ episode: SonarrEpisode) async {
        guard let client else { return }
        error = nil
        do {
            _ = try await client.searchEpisodes(episodeIds: [episode.id])
            // Silent: callers show their own visible confirmation (banner or in-view
            // feedback card) so this doesn't stack a redundant banner on top of it.
            InAppNotificationCenter.shared.logSilently(title: "Search Started", message: "Searching for episode.")
        } catch {
            capture(error, notificationTitle: "Search Failed")
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
            // Silent: callers show their own visible confirmation (banner or in-view
            // feedback card) so this doesn't stack a redundant banner on top of it.
            InAppNotificationCenter.shared.logSilently(title: "Search Started", message: "Searching for season \(seasonNumber).")
            return true
        } catch {
            capture(error, notificationTitle: "Search Failed")
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
            // Silent: callers show their own visible confirmation (banner or in-view
            // feedback card) so this doesn't stack a redundant banner on top of it.
            InAppNotificationCenter.shared.logSilently(title: "Search Started", message: "Searching all monitored episodes.")
            return true
        } catch {
            capture(error, notificationTitle: "Search Failed")
            return false
        }
    }

    /// `instanceID` names the server the ids belong to. It is not optional context:
    /// Sonarr and Sonarr 4K hand out the same small integers, so searching on the
    /// merely-active client returns a different show's releases whenever the two
    /// libraries disagree about which title owns an id.
    func interactiveSearch(
        episodeId: Int? = nil,
        seriesId: Int? = nil,
        seasonNumber: Int? = nil,
        instanceID: UUID? = nil
    ) async throws -> [ArrRelease] {
        guard let client = client(for: instanceID) else { throw ArrError.noServiceConfigured }
        error = nil
        #if DEBUG
        print("[InteractiveSearch][Sonarr] start episodeId=\(episodeId.map(String.init) ?? "nil") seriesId=\(seriesId.map(String.init) ?? "nil") seasonNumber=\(seasonNumber.map(String.init) ?? "nil")")
        #endif
        do {
            let releases: [ArrRelease]
            if episodeId == nil, seasonNumber == nil, let seriesId {
                // Series-root search: Sonarr's ReleaseController falls back to its recent
                // RSS feed when only seriesId is given, returning unrelated releases.
                // Fan out one request per season instead and merge the results.
                releases = try await interactiveSearchAllSeasons(seriesId: seriesId, client: client)
            } else {
                releases = try await client.getReleases(episodeId: episodeId, seriesId: seriesId, seasonNumber: seasonNumber)
            }
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

    /// Fans out one `getReleases(seriesId:seasonNumber:)` call per season (with episodes)
    /// concurrently, then merges and de-duplicates by guid. Used for series-root interactive
    /// search, where a seriesId-only query would otherwise return Sonarr's unrelated RSS feed.
    private func interactiveSearchAllSeasons(seriesId: Int, client: SonarrAPIClient) async throws -> [ArrRelease] {
        let seasonNumbers = series
            .first(where: { $0.id == seriesId })?
            .seasons?
            .filter { ($0.statistics?.episodeCount ?? 0) > 0 }
            .map(\.seasonNumber)
            .sorted() ?? []

        guard !seasonNumbers.isEmpty else {
            #if DEBUG
            print("[InteractiveSearch][Sonarr] no seasons with episodes found for seriesId=\(seriesId); falling back to seriesId-only query")
            #endif
            return try await client.getReleases(seriesId: seriesId)
        }

        #if DEBUG
        print("[InteractiveSearch][Sonarr] fanning out across \(seasonNumbers.count) season(s) for seriesId=\(seriesId): \(seasonNumbers)")
        #endif

        let results = await withTaskGroup(of: (Int, Result<[ArrRelease], Error>).self) { group -> [(Int, Result<[ArrRelease], Error>)] in
            for seasonNum in seasonNumbers {
                group.addTask {
                    do {
                        return (seasonNum, .success(try await client.getReleases(seriesId: seriesId, seasonNumber: seasonNum)))
                    } catch {
                        return (seasonNum, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[ArrRelease], Error>)] = []
            for await entry in group {
                collected.append(entry)
            }
            return collected
        }

        // Preserve season-ascending order of the fan-out.
        let ordered = results.sorted { $0.0 < $1.0 }

        var merged: [ArrRelease] = []
        var seenGuids = Set<String>()
        var firstError: Error?
        var successCount = 0

        for (seasonNum, result) in ordered {
            switch result {
            case .success(let releases):
                successCount += 1
                #if DEBUG
                print("[InteractiveSearch][Sonarr] season \(seasonNum) returned \(releases.count) release(s)")
                #endif
                for release in releases {
                    guard let guid = release.guid else {
                        merged.append(release)
                        continue
                    }
                    if seenGuids.insert(guid).inserted {
                        merged.append(release)
                    }
                }
            case .failure(let seasonError):
                #if DEBUG
                print("[InteractiveSearch][Sonarr] season \(seasonNum) failed: \(seasonError.localizedDescription)")
                #endif
                if firstError == nil { firstError = seasonError }
            }
        }

        if successCount == 0, let firstError {
            throw firstError
        }

        return merged
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
        searchForMissing: Bool = true,
        instanceID: UUID? = nil,
        announcesResult: Bool = true
    ) async -> Bool {
        // The server is part of the request, not a detail of it: the quality profile
        // ID and root folder path below only mean anything on the server they were
        // read from, so an add that routes elsewhere posts one server's IDs to
        // another's library.
        guard let client = client(for: instanceID) else {
            let failure = ArrServiceError.clientNotAvailable
            capture(failure, notificationTitle: announcesResult ? "Add Failed" : nil)
            return false
        }
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
            if announcesResult {
                InAppNotificationCenter.shared.showMonitoringChanged(
                    itemName: title,
                    itemType: "Series",
                    isMonitoring: monitored
                )
            }
            return true
        } catch {
            capture(error, notificationTitle: announcesResult ? "Add Failed" : nil)
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
        moveFiles: Bool = false,
        monitorAllSeasons: Bool = false
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
                tags: tags,
                monitorAllSeasons: monitorAllSeasons
            )
            _ = try await client.updateSeries(updatedSeries, moveFiles: moveFiles)
            await loadSeries()
            if series.id > 0 {
                await loadEpisodes(for: series.id, instanceID: series.instanceID)
                await loadEpisodeFiles(for: series.id, instanceID: series.instanceID)
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
            ArrOperationFeedback.showSuccess(title: "Updated", message: message)
            return true
        } catch {
            capture(error, notificationTitle: "Update Failed")
            return false
        }
    }

    /// Marks every episode of a series as monitored. Used when a user re-enables series
    /// monitoring and opts to cascade that to episodes, since Sonarr does not do this itself.
    func monitorAllEpisodes(seriesId: Int, instanceID: UUID? = nil) async -> Bool {
        guard let client = client(for: instanceID) else {
            capture(ArrServiceError.clientNotAvailable, notificationTitle: "Update Failed")
            return false
        }
        do {
            let existing = episodes(forSeries: seriesId, on: instanceID)
            let eps = existing.isEmpty ? try await client.getEpisodes(seriesId: seriesId) : existing
            let episodeIds = eps.map(\.id)
            if !episodeIds.isEmpty {
                _ = try await client.setEpisodeMonitored(episodeIds: episodeIds, monitored: true)
            }
            await loadEpisodes(for: seriesId, instanceID: instanceID)
            return true
        } catch {
            capture(error, notificationTitle: "Update Failed")
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
            ArrOperationFeedback.showSuccess(title: "Deleted", message: seriesTitle)
        } catch {
            capture(error, notificationTitle: "Delete Failed")
        }
    }

    func deleteSeries(ids: Set<Int>, deleteFiles: Bool = false) async {
        let idsToDelete = ids.sorted()
        guard !idsToDelete.isEmpty else { return }
        guard let client else {
            capture(ArrServiceError.clientNotAvailable, notificationTitle: "Delete Failed")
            return
        }

        // Only used to name a failure, so the first copy's title is fine - but it
        // must not trap: with a pair configured this list is the union of both
        // servers, and they number their libraries from the same sequence.
        let titlesByID = Dictionary(
            series
                .filter { ids.contains($0.id) }
                .map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
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
            ArrOperationFeedback.showSuccess(
                title: "Deleted",
                message: Self.bulkDeleteSuccessMessage(count: deletedIDs.count, singular: "series", plural: "series")
            )
        }

        if failures.isEmpty {
            error = nil
        } else {
            error = failures.first
            ArrOperationFeedback.showFailure(
                title: "Delete Failed",
                message: Self.bulkDeleteFailureMessage(failures, singular: "series", plural: "series")
            )
        }
    }

    func deleteEpisodeFile(id: Int, instanceID: UUID? = nil) async -> Bool {
        guard let client = client(for: instanceID) else {
            capture(ArrServiceError.clientNotAvailable)
            return false
        }
        // The cache key already carries the server, so the reload below goes back to
        // the one the file actually came from.
        let scopedID = episodeFiles.first(where: { $0.value.contains(where: { $0.id == id }) })?.key

        do {
            error = nil
            try await client.deleteEpisodeFile(id: id)

            if let scopedID {
                await loadEpisodeFiles(for: scopedID.id, instanceID: scopedID.instanceID)
                await loadEpisodes(for: scopedID.id, instanceID: scopedID.instanceID)
                await loadSeries()
            }
            return true
        } catch {
            capture(error)
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
    case recentlyAdded = "Recently Added"
    case status = "Status"
    case progress = "Progress"
    case network = "Network"

    var id: String { rawValue }
}

#if DEBUG
extension SonarrViewModel {
    enum PreviewState {
        case loaded
        case heavy
        case empty
        case loading
        case error(String)
    }

    convenience init(
        previewState: PreviewState,
        serviceManager: ArrServiceManager = .preview(.sonarrOnly),
        jellyfinManager: JellyfinServiceManager? = .preview()
    ) {
        switch previewState {
        case .loaded:
            self.init(previewSeries: SonarrSeries.previewList, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .heavy:
            self.init(previewSeries: SonarrSeries.previewHeavyList, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .empty:
            self.init(previewSeries: [], serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .loading:
            self.init(previewSeries: [], isLoading: true, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .error(let message):
            self.init(previewSeries: [], error: message, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        }
    }

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
        detachClientForPreview()
        self.isLoading = isLoading
        self.error = error
        // Previews seed by plain series ID and have no server, which is exactly the
        // unstamped case `ArrScopedID` represents with a nil instance.
        self.episodes = Dictionary(
            uniqueKeysWithValues: episodes.map { (ArrScopedID(nil, $0.key), $0.value) }
        )
        self.isLoadingEpisodes = isLoadingEpisodes
        self.episodeFiles = Dictionary(
            uniqueKeysWithValues: episodeFiles.map { (ArrScopedID(nil, $0.key), $0.value) }
        )
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
