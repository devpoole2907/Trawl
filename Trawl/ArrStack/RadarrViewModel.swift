import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class RadarrViewModel {
    // Library state
    private(set) var movies: [RadarrMovie] = [] { didSet { rebuildFilteredMovies() } }
    private(set) var isLoading: Bool = false
    private(set) var error: String?

    // Search state
    var searchText: String = "" { didSet { rebuildFilteredMovies() } }
    private(set) var searchResults: [RadarrMovie] = []
    private(set) var isSearching: Bool = false
    private(set) var wantedMovies: [RadarrMovie] = []
    private(set) var isLoadingWantedMissing: Bool = false
    private(set) var wantedMissingTotalRecords: Int = 0
    private var wantedMissingPage = 1
    private let wantedMissingPageSize = 20

    // Queue state
    private(set) var queue: [ArrQueueItem] = []
    private(set) var history: [ArrHistoryRecord] = []
    private(set) var isLoadingHistory: Bool = false
    private(set) var historyTotalRecords: Int = 0
    private var historyPage = 1
    private let historyPageSize = 20

    // Filter & Sort
    var selectedFilter: RadarrFilter = .all { didSet { rebuildFilteredMovies() } }
    var sortOrder: RadarrSortOrder = .title { didSet { rebuildFilteredMovies() } }

    private let serviceManager: ArrServiceManager

    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    /// Convenience init that pre-seeds the movie list (used by Search to avoid a fresh empty load).
    init(serviceManager: ArrServiceManager, preloadedMovies: [RadarrMovie]) {
        self.serviceManager = serviceManager
        self.movies = preloadedMovies
        rebuildFilteredMovies()
    }

    private var client: RadarrAPIClient? { serviceManager.radarrClient }

    // MARK: - Filtered (cached, updated via didSet observers)

    private(set) var filteredMovies: [RadarrMovie] = []

    private func rebuildFilteredMovies() {
        var result = movies

        switch selectedFilter {
        case .all: break
        case .monitored: result = result.filter { $0.monitored == true }
        case .unmonitored: result = result.filter { $0.monitored == false }
        case .missing: result = result.filter { $0.hasFile != true && $0.monitored == true }
        case .downloaded: result = result.filter { $0.hasFile == true }
        case .wanted: result = result.filter { $0.hasFile != true && $0.monitored == true && $0.isAvailable == true }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.title.lowercased().contains(query) }
        }

        result.sort { a, b in
            switch sortOrder {
            case .title:  (a.sortTitle ?? a.title) < (b.sortTitle ?? b.title)
            case .year:   (a.year ?? 0) > (b.year ?? 0)
            case .size:   (a.sizeOnDisk ?? 0) > (b.sizeOnDisk ?? 0)
            case .status: a.displayStatus < b.displayStatus
            }
        }
        filteredMovies = result
    }

    var qualityProfiles: [ArrQualityProfile] { serviceManager.radarrQualityProfiles }
    var rootFolders: [ArrRootFolder] { serviceManager.radarrRootFolders }
    var tags: [ArrTag] { serviceManager.radarrTags }
    var isConnected: Bool { serviceManager.radarrConnected }

    // MARK: - Library

    func loadMovies() async {
        guard let client else { return }
        isLoading = true
        error = nil
        do {
            movies = try await client.getMovies()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func refreshMovies() async {
        guard let client else { return }
        do {
            _ = try await client.refreshMovie()
            try? await Task.sleep(for: .seconds(2))
            await loadMovies()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Movie Detail

    func getMovie(id: Int) async -> RadarrMovie? {
        guard let client else { return nil }
        do {
            return try await client.getMovie(id: id)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func refreshMovieInLibrary(id: Int) async {
        guard let refreshedMovie = await getMovie(id: id) else { return }
        if let index = movies.firstIndex(where: { $0.id == id }) {
            movies[index] = refreshedMovie
        } else {
            movies.append(refreshedMovie)
        }
    }

    func loadWantedMissing() async {
        guard let client else { return }
        isLoadingWantedMissing = true
        error = nil
        do {
            let page = try await client.getWantedMissing(page: 1, pageSize: wantedMissingPageSize)
            wantedMovies = page.records ?? []
            wantedMissingPage = page.page ?? 1
            wantedMissingTotalRecords = page.totalRecords ?? wantedMovies.count
        } catch {
            self.error = error.localizedDescription
        }
        isLoadingWantedMissing = false
    }

    func loadMoreWantedMissing() async {
        guard !isLoadingWantedMissing && canLoadMoreWantedMissing else { return }
        guard let client else { return }
        isLoadingWantedMissing = true
        defer { isLoadingWantedMissing = false }

        let nextPage = wantedMissingPage + 1
        do {
            let page = try await client.getWantedMissing(page: nextPage, pageSize: wantedMissingPageSize)
            wantedMovies.append(contentsOf: page.records ?? [])
            wantedMissingPage = page.page ?? nextPage
            wantedMissingTotalRecords = page.totalRecords ?? wantedMovies.count
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Search for new movies

    func searchForNewMovies(term: String) async {
        guard let client, !term.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        searchResults = []
        error = nil
        defer { isSearching = false }
        do {
            let results = try await client.lookupMovie(term: term)
            guard !Task.isCancelled else { return }
            searchResults = results
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            searchResults = []
        }
    }

    func clearSearchResults() {
        searchResults = []
        error = nil
        isSearching = false
    }

    func addMovie(
        title: String,
        tmdbId: Int,
        qualityProfileId: Int,
        rootFolderPath: String,
        monitored: Bool = true,
        minimumAvailability: String = "released",
        monitorOption: String = "movieOnly",
        searchForMovie: Bool = true
    ) async -> Bool {
        guard let client else { return false }
        let body = RadarrAddMovieBody(
            title: title,
            tmdbId: tmdbId,
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath,
            monitored: monitored,
            minimumAvailability: minimumAvailability,
            addOptions: RadarrAddOptions(
                searchForMovie: searchForMovie,
                monitor: monitorOption
            ),
            tags: nil
        )
        do {
            _ = try await client.addMovie(body)
            await loadMovies()
            await MainActor.run {
                InAppNotificationCenter.shared.showMonitoringChanged(
                    itemName: title,
                    itemType: "Movies",
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

    func updateMovie(
        _ movie: RadarrMovie,
        monitored: Bool,
        qualityProfileId: Int,
        minimumAvailability: String,
        rootFolderPath: String,
        tags: [Int]
    ) async -> Bool {
        guard let client else { return false }
        do {
            let updatedMovie = movie.updatingForEdit(
                monitored: monitored,
                qualityProfileId: qualityProfileId,
                minimumAvailability: minimumAvailability,
                rootFolderPath: rootFolderPath,
                tags: tags
            )
            _ = try await client.updateMovie(updatedMovie, moveFiles: false)
            await loadMovies()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func toggleMovieMonitored(_ movie: RadarrMovie) async {
        guard let client else { return }
        guard movie.id > 0 else {
            await loadMovies()
            return
        }
        let newMonitored = !(movie.monitored ?? true)
        do {
            let canonicalMovie = try await client.getMovie(id: movie.id)
            guard canonicalMovie.qualityProfileId != nil,
                  let rootFolderPath = canonicalMovie.rootFolderPath,
                  !rootFolderPath.isEmpty else {
                await loadMovies()
                return
            }

            let updatedMovie = canonicalMovie.updatingForEdit(
                monitored: newMonitored,
                qualityProfileId: canonicalMovie.qualityProfileId ?? 0,
                minimumAvailability: canonicalMovie.minimumAvailability ?? "released",
                rootFolderPath: rootFolderPath,
                tags: canonicalMovie.tags ?? []
            )

            if let idx = self.movies.firstIndex(where: { $0.id == movie.id }) {
                self.movies[idx] = updatedMovie
            }
            _ = try await client.updateMovie(updatedMovie, moveFiles: false)
            await MainActor.run {
                InAppNotificationCenter.shared.showMonitoringChanged(
                    itemName: movie.title,
                    itemType: "Movies",
                    isMonitoring: newMonitored
                )
            }
        } catch {
            self.error = error.localizedDescription
            await loadMovies() // Revert on failure
        }
    }

    func deleteMovie(id: Int, deleteFiles: Bool = false) async {
        guard let client else { return }
        do {
            try await client.deleteMovie(id: id, deleteFiles: deleteFiles)
            movies.removeAll { $0.id == id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Search for existing

    func searchMovie(movieId: Int) async {
        guard let client else { return }
        do {
            _ = try await client.searchMovie(movieIds: [movieId])
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

    func deleteMovieFile(id: Int) async {
        guard let client else { return }
        let movieId = movies.first(where: { $0.movieFile?.id == id })?.id

        do {
            try await client.deleteMovieFile(id: id)
            if let movieId {
                await refreshMovieInLibrary(id: movieId)
                await loadMovies()
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
        } catch {
            self.error = error.localizedDescription
        }
    }

    var canLoadMoreWantedMissing: Bool {
        wantedMovies.count < wantedMissingTotalRecords
    }

    var canLoadMoreHistory: Bool {
        history.count < historyTotalRecords
    }
}

// MARK: - Filter

enum RadarrFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case monitored = "Monitored"
    case unmonitored = "Unmonitored"
    case missing = "Missing"
    case downloaded = "Downloaded"
    case wanted = "Wanted"

    var id: String { rawValue }
}

enum RadarrSortOrder: String, CaseIterable, Identifiable {
    case title = "Title"
    case year = "Year"
    case size = "Size"
    case status = "Status"

    var id: String { rawValue }
}
