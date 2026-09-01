import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class RadarrViewModel: ArrMediaLibraryViewModel<RadarrAPIClient, RadarrFilter, RadarrSortOrder> {
    // Library state
    private(set) var movies: [RadarrMovie] = [] { didSet { rebuildFilteredItems() } }
    /// Files for the copy most recently asked for, kept for callers that only
    /// deal with one server.
    private(set) var movieFiles: [RadarrMovieFile] = []
    /// Files per server, for a merged detail view that shows what each half of an
    /// HD/4K pair actually holds. Keyed by instance ID.
    private(set) var movieFilesByInstance: [UUID: [RadarrMovieFile]] = [:]
    private(set) var isLoadingFiles: Bool = false

    // Race-condition guard for loadMovieFiles
    @ObservationIgnored private var latestRequestedMovieId: Int?

    init(serviceManager: ArrServiceManager, jellyfinManager: JellyfinServiceManager? = nil) {
        super.init(
            serviceManager: serviceManager,
            client: serviceManager.radarrClient,
            clientProvider: { [weak serviceManager] in serviceManager?.radarrClient },
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
            clientProvider: { [weak serviceManager] in serviceManager?.radarrClient },
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
        filteredItems = makeFilteredEntries(
            from: movies,
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
                    serviceManager.subtitleCoverage(for: movie).isFullyCovered
                case .inJellyfinLibrary:
                    isInJellyfinLibrary(movie)
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
                case .year:
                    return (a.year ?? 0) > (b.year ?? 0)
                case .size:
                    // Summed across servers: a film held in both HD and 4K really
                    // is occupying both, and sorting by one copy would rank it as
                    // though the other weren't there.
                    let lhsSize = lhs.copies.reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
                    let rhsSize = rhs.copies.reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
                    return lhsSize > rhsSize
                case .status:
                    return a.displayStatus < b.displayStatus
                }
            }
        )
    }

    /// Deletes every server's copy of each selected title, routing each delete to
    /// the server that holds it.
    override func deleteEntries(_ entries: [ArrLibraryEntry<RadarrMovie>], deleteFiles: Bool) async {
        var deleted: [(instanceID: UUID?, id: Int)] = []
        var failures: [String] = []

        for entry in entries {
            for copy in entry.copies {
                guard let client = serviceManager.radarrClient(owning: copy) else {
                    failures.append("\(copy.title): Radarr isn’t connected.")
                    continue
                }
                do {
                    try await client.deleteMovie(id: copy.id, deleteFiles: deleteFiles)
                    deleted.append((copy.instanceID, copy.id))
                } catch {
                    failures.append("\(copy.title): \(error.localizedDescription)")
                }
            }
        }

        if !deleted.isEmpty {
            movies.removeAll { movie in
                deleted.contains { $0.instanceID == movie.instanceID && $0.id == movie.id }
            }
            await serviceManager.calendarViewModel.refresh()
            ArrOperationFeedback.showSuccess(
                title: "Deleted",
                message: Self.bulkDeleteSuccessMessage(count: entries.count, singular: "movie", plural: "movies")
            )
        }

        if failures.isEmpty {
            error = nil
        } else {
            error = failures.first
            ArrOperationFeedback.showFailure(
                title: "Delete Failed",
                message: Self.bulkDeleteFailureMessage(failures, singular: "movie", plural: "movies")
            )
        }
    }

    /// The client that owns a copy, falling back to the bound one when no server is
    /// named - a preview, or a caller that predates the pair.
    private func client(for instanceID: UUID?) -> RadarrAPIClient? {
        guard let instanceID else { return client }
        return serviceManager.radarrClient(for: instanceID)
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

    var qualityProfiles: [ArrQualityProfile] { serviceManager.radarrQualityProfiles }
    var rootFolders: [ArrRootFolder] { serviceManager.radarrRootFolders }
    var tags: [ArrTag] { serviceManager.radarrTags }
    var isConnected: Bool { serviceManager.radarrConnected }


    // MARK: - Instance routing

    /// The Radarr server holding a given library ID.
    ///
    /// Every mutation goes through here rather than through `client`, which is
    /// still whichever instance is nominally active. In a blended library the row
    /// the user acted on may belong to either server, and the two hand out the
    /// same integer IDs - so sending an update to the active client can silently
    /// modify a different film that happens to share the ID.
    ///
    /// Falls back to the active client only for IDs that aren't in the loaded
    /// union at all: freshly added movies, and preview/fixture view models that
    /// never loaded from a server.
    func routedClient(forMovieID id: Int, instanceID: UUID? = nil) -> RadarrAPIClient? {
        if let instanceID, let client = serviceManager.radarrClient(for: instanceID) {
            return client
        }
        if let owner = movies.first(where: { $0.id == id })?.instanceID,
           let client = serviceManager.radarrClient(for: owner) {
            return client
        }
        return client
    }

    func routedClient(for movie: RadarrMovie) -> RadarrAPIClient? {
        routedClient(forMovieID: movie.id, instanceID: movie.instanceID)
    }

    /// Both Radarr servers, so the queue, history and library this view model
    /// exposes cover the whole blended library rather than one half of it.
    override var routedInstances: [(ref: ArrInstanceRef, client: RadarrAPIClient)] {
        serviceManager.visibleRadarr
    }

    override func client(forExplicitInstanceID instanceID: UUID) -> RadarrAPIClient? {
        serviceManager.radarrClient(for: instanceID)
    }

    // MARK: - Library

    /// Domain-named alias for `loadLibraryItems(maxAge:)`, which is where the
    /// shared per-instance cache lives. `setLibraryItems` assigns `movies`, so
    /// there is nothing extra to do here.
    func loadMovies(maxAge: TimeInterval = 0) async {
        await loadLibraryItems(maxAge: maxAge)
    }

    func loadMovieFiles(movieId: Int) async {
        guard let client = routedClient(forMovieID: movieId) else { return }
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

    /// Loads files for every server's copy of one title, so a merged detail view
    /// can show what the HD server holds next to what the 4K server holds rather
    /// than picking one and implying it speaks for both.
    func loadMovieFiles(for entry: ArrLibraryEntry<RadarrMovie>) async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }

        var byInstance: [UUID: [RadarrMovieFile]] = [:]
        for copy in entry.copies {
            guard let instanceID = copy.instanceID,
                  let client = serviceManager.radarrClient(owning: copy) else { continue }
            byInstance[instanceID] = (try? await client.getMovieFiles(movieId: copy.id)) ?? []
        }
        movieFilesByInstance = byInstance
        // Keep the flat list in step for the single-server callers.
        movieFiles = entry.copies.compactMap(\.instanceID).flatMap { byInstance[$0] ?? [] }
    }

    func refreshMovies() async throws {
        guard let client else { throw ArrServiceError.clientNotAvailable }
        _ = try await client.refreshMovie()
        ArrOperationFeedback.showSuccess(title: "Refresh Started", message: "Library refresh command sent.")
        try? await Task.sleep(for: .seconds(2))
        await loadMovies()
    }

    // MARK: - Movie Detail

    func getMovie(id: Int, instanceID: UUID? = nil) async -> RadarrMovie? {
        let owner = instanceID ?? movies.first(where: { $0.id == id })?.instanceID
        guard let client = routedClient(forMovieID: id, instanceID: owner) else { return nil }
        do {
            // Re-stamped on the way back: a movie fetched from a specific server
            // has to remember which one, or the next command on it loses its route.
            return try await client.getMovie(id: id).stamped(with: owner)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func refreshMovieInLibrary(id: Int, instanceID: UUID? = nil) async {
        let owner = instanceID ?? movies.first(where: { $0.id == id })?.instanceID
        guard let refreshedMovie = await getMovie(id: id, instanceID: owner) else { return }
        if let index = movies.firstIndex(where: { $0.id == id && $0.instanceID == owner }) {
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
        searchForMovie: Bool = true,
        instanceID: UUID? = nil,
        announcesResult: Bool = true
    ) async -> Bool {
        // See `SonarrViewModel.addSeries`: the profile ID and root folder path are
        // only meaningful on the server they came from.
        guard let client = client(for: instanceID) else {
            let failure = ArrServiceError.clientNotAvailable
            capture(failure, notificationTitle: announcesResult ? "Add Failed" : nil)
            return false
        }
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
            if announcesResult {
                InAppNotificationCenter.shared.showMonitoringChanged(
                    itemName: title,
                    itemType: "Movies",
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

    func updateMovie(
        _ movie: RadarrMovie,
        monitored: Bool,
        qualityProfileId: Int,
        minimumAvailability: String,
        rootFolderPath: String,
        tags: [Int],
        moveFiles: Bool = false
    ) async -> Bool {
        guard let client = routedClient(for: movie) else { return false }
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
            ArrOperationFeedback.showSuccess(title: "Updated", message: message)
            return true
        } catch {
            capture(error, notificationTitle: "Update Failed")
            return false
        }
    }

    func toggleMovieMonitored(_ movie: RadarrMovie) async {
        guard let client = routedClient(for: movie) else { return }
        guard movie.id > 0 else {
            await loadMovies()
            return
        }
        let newMonitored = !(movie.monitored ?? true)
        do {
            let canonicalMovie = try await client.getMovie(id: movie.id).stamped(with: movie.instanceID)
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

            if let idx = self.movies.firstIndex(where: {
                $0.id == movie.id && $0.instanceID == movie.instanceID
            }) {
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
            capture(error, notificationTitle: "Update Failed")
            await loadMovies() // Revert on failure
        }
    }

    func deleteMovie(id: Int, deleteFiles: Bool = false, instanceID: UUID? = nil) async -> Bool {
        let owner = instanceID ?? movies.first(where: { $0.id == id })?.instanceID
        guard let client = routedClient(forMovieID: id, instanceID: owner) else { return false }
        let movieTitle = movies.first(where: { $0.id == id && $0.instanceID == owner })?.title ?? "Movie"
        do {
            try await client.deleteMovie(id: id, deleteFiles: deleteFiles)
            movies.removeAll { $0.id == id && $0.instanceID == owner }
            await serviceManager.calendarViewModel.refresh()
            ArrOperationFeedback.showSuccess(title: "Deleted", message: movieTitle)
            return true
        } catch {
            capture(error, notificationTitle: "Delete Failed")
            return false
        }
    }

    func deleteMovies(ids: Set<Int>, deleteFiles: Bool = false) async {
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
            movies
                .filter { ids.contains($0.id) }
                .map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
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
            ArrOperationFeedback.showSuccess(
                title: "Deleted",
                message: Self.bulkDeleteSuccessMessage(count: deletedIDs.count, singular: "movie", plural: "movies")
            )
        }

        if failures.isEmpty {
            error = nil
        } else {
            error = failures.first
            ArrOperationFeedback.showFailure(
                title: "Delete Failed",
                message: Self.bulkDeleteFailureMessage(failures, singular: "movie", plural: "movies")
            )
        }
    }

    // MARK: - Search for existing

    @discardableResult
    func searchMovie(movieId: Int, instanceID: UUID? = nil) async -> Bool {
        guard let client = routedClient(forMovieID: movieId, instanceID: instanceID) else {
            self.error = ArrServiceError.clientNotAvailable.errorDescription
            return false
        }
        error = nil
        do {
            _ = try await client.searchMovie(movieIds: [movieId])
            // Callers already show their own "Search Queued" feedback - log this one silently
            // to avoid a duplicate banner.
            InAppNotificationCenter.shared.logSilently(title: "Search Started", message: "Searching for movie.")
            error = nil
            return true
        } catch {
            capture(error, notificationTitle: "Search Failed")
            return false
        }
    }

    func interactiveSearchMovie(movieId: Int, instanceID: UUID? = nil) async throws -> [ArrRelease] {
        guard let client = routedClient(forMovieID: movieId, instanceID: instanceID) else {
            throw ArrError.noServiceConfigured
        }
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

    func deleteMovieFile(id: Int, instanceID: UUID? = nil) async -> Bool {
        let owner = instanceID ?? movies.first(where: { $0.movieFile?.id == id })?.instanceID
        let movieId = movies.first(where: { $0.movieFile?.id == id })?.id ?? movieFiles.first(where: { $0.id == id })?.movieId
        guard let client = routedClient(forMovieID: movieId ?? 0, instanceID: owner) else {
            capture(ArrServiceError.clientNotAvailable)
            return false
        }

        do {
            try await client.deleteMovieFile(id: id)
            if let movieId {
                await refreshMovieInLibrary(id: movieId)
                await loadMovieFiles(movieId: movieId)
                await loadMovies()
            }
            return true
        } catch {
            capture(error)
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
    case wanted = "Missing & Available"
    case subtitlesPresent = "Subtitles Present"
    case inJellyfinLibrary = "In Jellyfin Library"

    var id: String { rawValue }
}

nonisolated enum RadarrSortOrder: String, CaseIterable, Identifiable, Sendable {
    case title = "Title"
    case recentlyAdded = "Recently Added"
    case year = "Year"
    case size = "Size"
    case status = "Status"

    var id: String { rawValue }
}

#if DEBUG
extension RadarrViewModel {
    enum PreviewState {
        case loaded
        case heavy
        case empty
        case loading
        case error(String)
    }

    convenience init(
        previewState: PreviewState = .loaded,
        serviceManager: ArrServiceManager = .preview(.radarrOnly),
        jellyfinManager: JellyfinServiceManager? = .preview()
    ) {
        switch previewState {
        case .loaded:
            self.init(previewMovies: RadarrMovie.previewList, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .heavy:
            self.init(previewMovies: RadarrMovie.previewHeavyList, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .empty:
            self.init(previewMovies: [], serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .loading:
            self.init(previewMovies: [], isLoading: true, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        case .error(let message):
            self.init(previewMovies: [], error: message, serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        }
    }

    convenience init(
        previewMovies: [RadarrMovie],
        isLoading: Bool = false,
        error: String? = nil,
        movieFiles: [RadarrMovieFile] = [],
        isLoadingFiles: Bool = false,
        serviceManager: ArrServiceManager = .preview(.radarrOnly),
        jellyfinManager: JellyfinServiceManager? = .preview()
    ) {
        self.init(serviceManager: serviceManager, jellyfinManager: jellyfinManager)
        detachClientForPreview()
        setLibraryItems(previewMovies)
        self.isLoading = isLoading
        self.error = error
        self.movieFiles = movieFiles
        self.isLoadingFiles = isLoadingFiles
        rebuildFilteredItems()
    }
}

@MainActor
struct RadarrPreviewHost<Content: View>: View {
    let profiles: PreviewSupport.ProfileScenario
    let arr: ArrServiceManager
    let jellyfin: JellyfinServiceManager
    let content: () -> Content

    init(
        profiles: PreviewSupport.ProfileScenario = .arrOnly,
        arr: ArrServiceManager = .preview(.radarrOnly),
        jellyfin: JellyfinServiceManager = .preview(),
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.profiles = profiles
        self.arr = arr
        self.jellyfin = jellyfin
        self.content = content
    }

    var body: some View {
        PreviewHost(profiles: profiles, arr: arr, jellyfin: jellyfin) {
            content()
                .environment(SyncService.preview())
                .environment(TorrentService.preview())
        }
    }
}
#endif
