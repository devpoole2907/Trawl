import Foundation
import Observation

@MainActor
@Observable
final class TorrentListViewModel {
    var selectedFilter: TorrentFilter = .all
    var searchText: String = ""
    var sortOrder: TorrentSortOrder = .addedDate
    var actionErrorAlert: ErrorAlertItem?

    // Cached off-main — only recomputed when inputs change
    private(set) var filteredTorrents: [Torrent] = []
    private(set) var filterCounts: [TorrentFilter: Int] = [:]

    // MARK: - Selection & Processing
    var isSelecting: Bool = false
    var selectedHashes: Set<String> = []
    private(set) var processingHashes: Set<String> = []

    private let syncService: SyncService
    private let torrentService: TorrentService
    private let notificationCenter: InAppNotificationCenter
    private var filterTask: Task<Void, Never>?

    init(
        syncService: SyncService,
        torrentService: TorrentService,
        notificationCenter: InAppNotificationCenter? = nil
    ) {
        self.syncService = syncService
        self.torrentService = torrentService
        self.notificationCenter = notificationCenter ?? .shared
    }

    // MARK: - Passthrough State

    var globalDownloadSpeed: Int64 { syncService.serverState?.dlInfoSpeed ?? 0 }
    var globalUploadSpeed: Int64 { syncService.serverState?.upInfoSpeed ?? 0 }
    var isPolling: Bool { syncService.isPolling }
    var syncError: QBError? { syncService.lastError }
    var categories: [String] { syncService.sortedCategoryNames }
    var isAlternativeSpeedEnabled: Bool = false
    private(set) var isUpdatingAlternativeSpeed = false

    // MARK: - Selection Actions

    func toggleSelection(_ torrent: Torrent) {
        notificationCenter.triggerImpact()
        if selectedHashes.contains(torrent.hash) {
            selectedHashes.remove(torrent.hash)
        } else {
            selectedHashes.insert(torrent.hash)
        }
    }

    func selectAll() {
        selectedHashes = Set(filteredTorrents.map(\.hash))
    }

    func clearSelection() {
        selectedHashes = []
        isSelecting = false
    }

    func pauseSelected() async {
        let hashes = Array(selectedHashes)
        hashes.forEach { processingHashes.insert($0) }
        clearSelection()
        
        do {
            try await torrentService.pauseTorrents(hashes: hashes)
            notificationCenter.showSuccess(title: "Paused", message: "\(hashes.count) torrents paused.")
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Pause Torrents", message: error.localizedDescription)
            hashes.forEach { processingHashes.remove($0) }
        }
    }

    func resumeSelected() async {
        let hashes = Array(selectedHashes)
        hashes.forEach { processingHashes.insert($0) }
        clearSelection()
        
        do {
            try await torrentService.resumeTorrents(hashes: hashes)
            notificationCenter.showSuccess(title: "Resumed", message: "\(hashes.count) torrents resumed.")
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Resume Torrents", message: error.localizedDescription)
            hashes.forEach { processingHashes.remove($0) }
        }
    }

    func recheckSelected() async {
        let hashes = Array(selectedHashes)
        hashes.forEach { processingHashes.insert($0) }
        clearSelection()
        
        do {
            try await torrentService.recheckTorrents(hashes: hashes)
            notificationCenter.showSuccess(title: "Rechecking", message: "\(hashes.count) torrents queued for recheck.")
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Recheck Torrents", message: error.localizedDescription)
            hashes.forEach { processingHashes.remove($0) }
        }
    }

    func deleteSelected(deleteFiles: Bool) async {
        let hashes = Array(selectedHashes)
        hashes.forEach { processingHashes.insert($0) }
        clearSelection()
        
        do {
            try await torrentService.deleteTorrents(hashes: hashes, deleteFiles: deleteFiles)
            notificationCenter.showSuccess(title: "Deleted", message: "\(hashes.count) torrents removed.")
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(
                title: deleteFiles ? "Couldn't Delete Torrents and Files" : "Couldn't Delete Torrents",
                message: error.localizedDescription
            )
            hashes.forEach { processingHashes.remove($0) }
        }
    }

    // MARK: - Sync

    func startSync() {
        scheduleFilterUpdate()
        registerObservation()
    }

    func stopSync() {
        filterTask?.cancel()
    }

    func refresh() async {
        await syncService.refreshNow()
    }

    func loadAlternativeSpeedMode() async {
        guard !isUpdatingAlternativeSpeed else { return }
        do {
            isAlternativeSpeedEnabled = try await torrentService.isAlternativeSpeedEnabled()
            actionErrorAlert = nil
        } catch {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Load Speed Mode",
                message: error.localizedDescription
            )
        }
    }

    func toggleAlternativeSpeed() async {
        guard !isUpdatingAlternativeSpeed else { return }
        isUpdatingAlternativeSpeed = true
        defer { isUpdatingAlternativeSpeed = false }

        do {
            try await torrentService.toggleAlternativeSpeed()
            isAlternativeSpeedEnabled = try await torrentService.isAlternativeSpeedEnabled()
            await syncService.refreshNow()
            notificationCenter.showSuccess(title: "Speed Mode Changed", message: "Alternative speed mode is now \(isAlternativeSpeedEnabled ? "enabled" : "disabled").")
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Toggle Alternative Speed",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Observation

    /// Re-registers after each change so we react to every future update.
    @MainActor
    private func registerObservation() {
        withObservationTracking {
            _ = syncService.torrents
            _ = selectedFilter
            _ = searchText
            _ = sortOrder
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleFilterUpdate()
                self.registerObservation()
            }
        }
    }

    /// Cancels any in-flight work and starts a new computation on a background thread.
    private func scheduleFilterUpdate() {
        filterTask?.cancel()
        let snapshot = syncService.torrents
        let filter = selectedFilter
        let search = searchText
        let sort = sortOrder
        filterTask = Task.detached(priority: .userInitiated) {
            let result = Self.compute(torrents: snapshot, filter: filter, searchText: search, sortOrder: sort)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.filteredTorrents = result.sorted
                self.filterCounts = result.counts

                // Remove from processing hashes if the torrent is no longer in the sync data
                // or if we want to be safe and just clear them after any successful sync.
                // For simplicity, let's clear processing hashes that are now represented in the new data.
                for hash in self.processingHashes {
                    if snapshot[hash] != nil {
                        self.processingHashes.remove(hash)
                    }
                }
            }
        }
    }

    /// Pure, nonisolated — safe to run on any thread.
    nonisolated private static func compute(
        torrents: [String: Torrent],
        filter: TorrentFilter,
        searchText: String,
        sortOrder: TorrentSortOrder
    ) -> (sorted: [Torrent], counts: [TorrentFilter: Int]) {
        let all = Array(torrents.values)

        // Compute all filter counts in a single pass
        var counts: [TorrentFilter: Int] = [
            .all: all.count,
            .downloading: 0, .seeding: 0, .paused: 0, .completed: 0, .errored: 0
        ]
        for torrent in all {
            switch torrent.state.filterCategory {
            case .downloading: counts[.downloading]! += 1
            case .seeding:     counts[.seeding]! += 1
            case .paused:      counts[.paused]! += 1
            case .errored:     counts[.errored]! += 1
            default:           break
            }
            if torrent.state.isCompleted { counts[.completed]! += 1 }
        }

        let result = FilterSortPipeline.apply(
            items: all,
            filter: filter,
            searchText: searchText,
            sort: sortOrder,
            matchesSearch: { torrent, query in
                torrent.name.localizedCaseInsensitiveContains(query)
            },
            matchesFilter: { torrent, selectedFilter in
                switch selectedFilter {
                case .all:         true
                case .downloading: torrent.state.filterCategory == .downloading
                case .seeding:     torrent.state.filterCategory == .seeding
                case .paused:      torrent.state.filterCategory == .paused
                case .completed:   torrent.state.isCompleted
                case .errored:     torrent.state.filterCategory == .errored
                }
            },
            areInIncreasingOrder: { a, b, selectedSort in
                switch selectedSort {
                case .name:          a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .addedDate:     a.addedOn > b.addedOn
                case .size:          a.size > b.size
                case .progress:      a.progress > b.progress
                case .downloadSpeed: a.dlspeed > b.dlspeed
                case .uploadSpeed:   a.upspeed > b.upspeed
                case .eta:           a.eta < b.eta
                }
            }
        )

        return (result, counts)
    }

    // MARK: - Actions

    func pauseTorrent(_ torrent: Torrent) async {
        processingHashes.insert(torrent.hash)
        do {
            try await torrentService.pauseTorrents(hashes: [torrent.hash])
            notificationCenter.showSuccess(title: "Paused", message: torrent.name)
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Pause Torrent",
                message: error.localizedDescription
            )
            processingHashes.remove(torrent.hash)
        }
    }

    func resumeTorrent(_ torrent: Torrent) async {
        processingHashes.insert(torrent.hash)
        do {
            try await torrentService.resumeTorrents(hashes: [torrent.hash])
            notificationCenter.showSuccess(title: "Resumed", message: torrent.name)
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Resume Torrent",
                message: error.localizedDescription
            )
            processingHashes.remove(torrent.hash)
        }
    }

    func recheckTorrent(_ torrent: Torrent) async {
        processingHashes.insert(torrent.hash)
        do {
            try await torrentService.recheckTorrents(hashes: [torrent.hash])
            notificationCenter.showSuccess(title: "Rechecking", message: torrent.name)
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Recheck Torrent",
                message: error.localizedDescription
            )
            processingHashes.remove(torrent.hash)
        }
    }

    func deleteTorrent(_ torrent: Torrent, deleteFiles: Bool) async {
        processingHashes.insert(torrent.hash)
        do {
            try await torrentService.deleteTorrents(hashes: [torrent.hash], deleteFiles: deleteFiles)
            notificationCenter.showSuccess(title: "Deleted", message: torrent.name)
            actionErrorAlert = nil
        } catch {
            notificationCenter.showError(title: "Error", message: error.localizedDescription)
            actionErrorAlert = ErrorAlertItem(
                title: deleteFiles ? "Couldn't Delete Torrent and Files" : "Couldn't Delete Torrent",
                message: error.localizedDescription
            )
            processingHashes.remove(torrent.hash)
        }
    }
}

enum TorrentSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case addedDate = "Date Added"
    case size = "Size"
    case progress = "Progress"
    case downloadSpeed = "Download Speed"
    case uploadSpeed = "Upload Speed"
    case eta = "ETA"

    var id: String { rawValue }
}
