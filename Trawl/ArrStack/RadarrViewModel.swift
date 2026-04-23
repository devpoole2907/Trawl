import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class RadarrViewModel {
    // Library state
    private(set) var movies: [RadarrMovie] = [] { didSet { rebuildFilteredMovies() } }
    private(set) var movieFiles: [RadarrMovieFile] = []
    private(set) var isLoading: Bool = false
    private(set) var isLoadingFiles: Bool = false
    private(set) var error: String?

    // Search state
    var searchText: String = "" { didSet { rebuildFilteredMovies() } }
    private(set) var searchResults: [RadarrMovie] = []
    private(set) var isSearching: Bool = false
    private var searchRequestToken: UUID?
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

    // Updates
    private(set) var availableUpdates: [ArrUpdateInfo] = []
    private(set) var isLoadingUpdates: Bool = false

    // Filter & Sort
    var selectedFilter: RadarrFilter = .all { didSet { rebuildFilteredMovies() } }
    var sortOrder: RadarrSortOrder = .title { didSet { rebuildFilteredMovies() } }

    // Race-condition guard for loadMovieFiles
    private var latestRequestedMovieId: Int?

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
        filteredMovies = FilterSortPipeline.apply(
            items: movies,
            filter: selectedFilter,
            searchText: searchText,
            sort: sortOrder,
            matchesSearch: { movie, query in
                movie.title.localizedCaseInsensitiveContains(query)
            },
            matchesFilter: { movie, filter in
                switch filter {
                case .all:
                    true
                case .monitored:
                    movie.monitored == true
                case .unmonitored:
                    movie.monitored == false
                case .missing:
                    movie.hasFile != true && movie.monitored == true
                case .downloaded:
                    movie.hasFile == true
                case .wanted:
                    movie.hasFile != true && movie.monitored == true && movie.isAvailable == true
                }
            },
            areInIncreasingOrder: { a, b, sort in
                switch sort {
                case .title:
                    (a.sortTitle ?? a.title) < (b.sortTitle ?? b.title)
                case .year:
                    (a.year ?? 0) > (b.year ?? 0)
                case .size:
                    (a.sizeOnDisk ?? 0) > (b.sizeOnDisk ?? 0)
                case .status:
                    a.displayStatus < b.displayStatus
                }
            }
        )
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

    func loadMovieFiles(movieId: Int) async {
        guard let client else { return }
        latestRequestedMovieId = movieId
        movieFiles = []
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            let files = try await client.getMovieFiles(movieId: movieId)
            guard latestRequestedMovieId == movieId else { return }
            movieFiles = files
        } catch {
            guard latestRequestedMovieId == movieId else { return }
            self.error = error.localizedDescription
            movieFiles = []
        }
    }

    func refreshMovies() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.refreshMovie()
        InAppNotificationCenter.shared.showSuccess(title: "Refresh Started", message: "Library refresh command sent.")
        try? await Task.sleep(for: .seconds(2))
        await loadMovies()
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
        guard !isLoadingWantedMissing else { return }
        guard let client else { return }
        isLoadingWantedMissing = true
        defer { isLoadingWantedMissing = false }
        error = nil
        do {
            let page = try await client.getWantedMissing(page: 1, pageSize: wantedMissingPageSize)
            wantedMovies = page.records ?? []
            wantedMissingPage = page.page ?? 1
            wantedMissingTotalRecords = page.totalRecords ?? wantedMovies.count
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
            isSearching = false
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
            let results = try await client.lookupMovie(term: term)
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
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showMonitoringChanged(
                itemName: title,
                itemType: "Movies",
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
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showSuccess(title: "Updated", message: movie.title)
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error.localizedDescription)
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
            await loadMovies()
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showMonitoringChanged(
                itemName: movie.title,
                itemType: "Movies",
                isMonitoring: newMonitored
            )
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: error.localizedDescription)
            await loadMovies() // Revert on failure
        }
    }

    func deleteMovie(id: Int, deleteFiles: Bool = false) async -> Bool {
        guard let client else { return false }
        let movieTitle = movies.first(where: { $0.id == id })?.title ?? "Movie"
        do {
            try await client.deleteMovie(id: id, deleteFiles: deleteFiles)
            movies.removeAll { $0.id == id }
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showSuccess(title: "Deleted", message: movieTitle)
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Search for existing

    func searchMovie(movieId: Int) async {
        guard let client else { return }
        error = nil
        do {
            _ = try await client.searchMovie(movieIds: [movieId])
            InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching for movie.")
            error = nil
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error.localizedDescription)
        }
    }

    func interactiveSearchMovie(movieId: Int) async -> [ArrRelease] {
        guard let client else { return [] }
        error = nil
        do {
            return try await client.getReleases(movieId: movieId)
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

    func searchAllMissing() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.searchAllMissing()
        InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching for all missing movies.")
    }

    func rssSync() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.rssSync()
        InAppNotificationCenter.shared.showSuccess(title: "RSS Sync", message: "Sync command sent.")
    }

    func deleteMovieFile(id: Int) async -> Bool {
        guard let client else { return false }
        let movieId = movies.first(where: { $0.movieFile?.id == id })?.id ?? movieFiles.first(where: { $0.id == id })?.movieId

        do {
            try await client.deleteMovieFile(id: id)
            InAppNotificationCenter.shared.showSuccess(title: "File Deleted", message: "Movie file removed.")
            if let movieId {
                await refreshMovieInLibrary(id: movieId)
                await loadMovieFiles(movieId: movieId)
                await loadMovies()
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