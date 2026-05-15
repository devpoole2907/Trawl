import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class RadarrViewModel: ArrMediaLibraryViewModel<RadarrAPIClient, RadarrFilter, RadarrSortOrder> {
    // Library state
    private(set) var movies: [RadarrMovie] = [] { didSet { rebuildFilteredItems() } }
    private(set) var movieFiles: [RadarrMovieFile] = []
    private(set) var isLoadingFiles: Bool = false

    // Race-condition guard for loadMovieFiles
    @ObservationIgnored private var latestRequestedMovieId: Int?

    init(serviceManager: ArrServiceManager, jellyfinManager: JellyfinServiceManager? = nil) {
        super.init(
            serviceManager: serviceManager,
            client: serviceManager.radarrClient,
            jellyfinManager: jellyfinManager,
            defaultFilter: .all,
            defaultSort: .title
        )
    }

    /// Convenience init that pre-seeds the movie list (used by Search to avoid a fresh empty load).
    init(serviceManager: ArrServiceManager, preloadedMovies: [RadarrMovie], jellyfinManager: JellyfinServiceManager? = nil) {
        super.init(
            serviceManager: serviceManager,
            client: serviceManager.radarrClient,
            jellyfinManager: jellyfinManager,
            defaultFilter: .all,
            defaultSort: .title
        )
        self.movies = preloadedMovies
        setLibraryItems(preloadedMovies)
        rebuildFilteredItems()
    }

    override var nounSingular: String { "movie" }
    override var nounPlural: String { "movies" }

    override func toggleMonitored(_ item: RadarrMovie) async { await toggleMovieMonitored(item) }

    override func setLibraryItems(_ items: [RadarrMovie]) {
        super.setLibraryItems(items)
        self.movies = items
    }

    // MARK: - Domain-named accessors (compat shims)
    /// Movies returned from the wanted/missing endpoint.
    var wantedMovies: [RadarrMovie] { wantedRecords }

    override func onJellyfinLibraryCacheChanged() {
        rebuildFilteredItems()
    }

    override func rebuildFilteredItems() {
        filteredItems = FilterSortPipeline.apply(
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
                case .subtitlesPresent:
                    serviceManager.bazarrSubtitleStatus(forRadarrId: movie.id) == .allPresent
                case .inJellyfinLibrary:
                    isInJellyfinLibrary(movie)
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
        guard let loadedMovies = await performLoad({ try await $0.getMovies() }) else { return }
        movies = loadedMovies
        setLibraryItems(loadedMovies)
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

    // MARK: - Search for new movies

    func searchForNewMovies(term: String) async {
        await performLookup(term: term)
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
        tags: [Int],
        moveFiles: Bool = false
    ) async -> Bool {
        guard let client else { return false }
        do {
            let rootFolderChanged = rootFolderPath != (movie.rootFolderPath ?? "")
            let updatedMovie = movie.updatingForEdit(
                monitored: monitored,
                qualityProfileId: qualityProfileId,
                minimumAvailability: minimumAvailability,
                rootFolderPath: rootFolderPath,
                tags: tags
            )
            _ = try await client.updateMovie(updatedMovie, moveFiles: moveFiles)
            await loadMovies()
            if movie.id > 0 {
                await loadMovieFiles(movieId: movie.id)
            }
            await loadQueue()
            await serviceManager.calendarViewModel.refresh()
            let message: String
            if rootFolderChanged {
                message = moveFiles
                    ? "Root folder updated to \(rootFolderPath) and Radarr was asked to move existing files."
                    : "Root folder updated to \(rootFolderPath). Import status was refreshed."
            } else {
                message = movie.title
            }
            InAppNotificationCenter.shared.showSuccess(title: "Updated", message: message)
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

    func deleteMovies(ids: Set<Int>, deleteFiles: Bool = false) async {
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

        let titlesByID = Dictionary(uniqueKeysWithValues: movies
            .filter { ids.contains($0.id) }
            .map { ($0.id, $0.title) })
        var deletedIDs = Set<Int>()
        var failures: [String] = []

        for id in idsToDelete {
            let movieTitle = titlesByID[id] ?? "Movie \(id)"
            do {
                try await client.deleteMovie(id: id, deleteFiles: deleteFiles)
                deletedIDs.insert(id)
            } catch {
                failures.append("\(movieTitle): \(error.localizedDescription)")
            }
        }

        if !deletedIDs.isEmpty {
            movies.removeAll { deletedIDs.contains($0.id) }
            await serviceManager.calendarViewModel.refresh()
            InAppNotificationCenter.shared.showSuccess(
                title: "Deleted",
                message: Self.bulkDeleteSuccessMessage(count: deletedIDs.count, singular: "movie", plural: "movies")
            )
        }

        if failures.isEmpty {
            error = nil
        } else {
            error = failures.first
            InAppNotificationCenter.shared.showError(
                title: "Delete Failed",
                message: Self.bulkDeleteFailureMessage(failures, singular: "movie", plural: "movies")
            )
        }
    }

    // MARK: - Search for existing

    @discardableResult
    func searchMovie(movieId: Int) async -> Bool {
        guard let client else {
            self.error = ArrServiceError.clientNotAvailable.errorDescription
            return false
        }
        error = nil
        do {
            _ = try await client.searchMovie(movieIds: [movieId])
            InAppNotificationCenter.shared.showSuccess(title: "Search Started", message: "Searching for movie.")
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error.localizedDescription)
            return false
        }
    }

    func interactiveSearchMovie(movieId: Int) async throws -> [ArrRelease] {
        guard let client else { throw ArrError.noServiceConfigured }
        error = nil
        #if DEBUG
        print("[InteractiveSearch][Radarr] start movieId=\(movieId)")
        #endif
        do {
            let releases = try await client.getReleases(movieId: movieId)
            #if DEBUG
            print("[InteractiveSearch][Radarr] success releases=\(releases.count)")
            #endif
            return releases
        } catch is CancellationError {
            #if DEBUG
            print("[InteractiveSearch][Radarr] cancelled")
            #endif
            throw CancellationError()
        } catch {
            self.error = error.localizedDescription
            let nsError = error as NSError
            #if DEBUG
            print("[InteractiveSearch][Radarr] failed domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)")
            #endif
            throw error
        }
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
}

// MARK: - Filter

nonisolated enum RadarrFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case monitored = "Monitored"
    case unmonitored = "Unmonitored"
    case missing = "Missing"
    case downloaded = "Downloaded"
    case wanted = "Wanted"
    case subtitlesPresent = "Subtitles Present"
    case inJellyfinLibrary = "In Jellyfin Library"

    var id: String { rawValue }
}

nonisolated enum RadarrSortOrder: String, CaseIterable, Identifiable, Sendable {
    case title = "Title"
    case year = "Year"
    case size = "Size"
    case status = "Status"

    var id: String { rawValue }
}
