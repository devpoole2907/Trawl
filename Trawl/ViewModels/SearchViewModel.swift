import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class SearchViewModel {
    var searchText = ""
    var isSearchPresented = false
    var scope: SearchScope = .arr
    var filter: ResultKind = .all
    var actionErrorAlert: ErrorAlertItem?
    var arrAddInFlightIDs: Set<String> = []

    // Loaded library
    var sonarrSeries: [SonarrSeries] = []
    var radarrMovies: [RadarrMovie] = []
    private var sonarrTitleIndex: [(lower: String, series: SonarrSeries)] = []
    private var radarrTitleIndex: [(lower: String, movie: RadarrMovie)] = []
    var isLoadingLibrary = false

    // Arr lookup
    var sonarrLookupVM: SonarrViewModel?
    var radarrLookupVM: RadarrViewModel?
    var arrFilter: ArrResultKind = .all
    var hasSearchedArr = false
    var arrLookupTask: Task<Void, Never>?
    private var activeArrLookupTerm = ""
    private var lastCompletedArrLookupTerm = ""
    private var sonarrLookupContextKey = ""
    private var radarrLookupContextKey = ""

    // TMDb trending
    var tmdbAPIKey: String = ""
    var trendingMovies: [TMDbItem] = []
    var trendingTV: [TMDbItem] = []
    var isLoadingTrending = false
    var trendingError: String?

    // Pre-fetched Arr matches for trending items (keyed by TMDb ID)
    var movieMatches: [Int: RadarrMovie] = [:]
    var seriesMatches: [Int: SonarrSeries] = [:]

    // Incremental Library Matches
    var matchedTorrents: [Torrent] = []
    var matchedSeries: [SonarrSeries] = []
    var matchedMovies: [RadarrMovie] = []
    var librarySearchTask: Task<Void, Never>?

    var searchPrompt: String {
        switch scope {
        case .library: "Your library"
        case .arr:     "Sonarr & Radarr"
        }
    }

    var arrLookupErrors: [ArrLookupError] {
        var errors: [ArrLookupError] = []

        if let error = sonarrLookupVM?.error, !error.isEmpty {
            errors.append(ArrLookupError(service: "Sonarr", message: error))
        }

        if let error = radarrLookupVM?.error, !error.isEmpty {
            errors.append(ArrLookupError(service: "Radarr", message: error))
        }

        return errors
    }

    func isInLibrary(_ item: TMDbItem) -> Bool {
        if item.isMovie {
            return radarrMovies.contains { $0.tmdbId == item.id }
        } else {
            let title = item.displayTitle.lowercased()
            return sonarrTitleIndex.contains { $0.lower == title }
        }
    }

    func createLookupViewModels(arrServiceManager: ArrServiceManager) {
        let nextSonarrKey = sonarrLookupKey(
            isConnected: arrServiceManager.sonarrConnected,
            series: sonarrSeries
        )
        if !arrServiceManager.sonarrConnected {
            sonarrLookupVM = nil
            sonarrLookupContextKey = nextSonarrKey
        } else if sonarrLookupVM == nil || sonarrLookupContextKey != nextSonarrKey {
            sonarrLookupVM = SonarrViewModel(serviceManager: arrServiceManager, preloadedSeries: sonarrSeries)
            sonarrLookupContextKey = nextSonarrKey
        }

        let nextRadarrKey = radarrLookupKey(
            isConnected: arrServiceManager.radarrConnected,
            movies: radarrMovies
        )
        if !arrServiceManager.radarrConnected {
            radarrLookupVM = nil
            radarrLookupContextKey = nextRadarrKey
        } else if radarrLookupVM == nil || radarrLookupContextKey != nextRadarrKey {
            radarrLookupVM = RadarrViewModel(serviceManager: arrServiceManager, preloadedMovies: radarrMovies)
            radarrLookupContextKey = nextRadarrKey
        }
    }

    func reconcileTrendingMatches(arrServiceManager: ArrServiceManager) async {
        guard !trendingMovies.isEmpty || !trendingTV.isEmpty else {
            movieMatches.removeAll()
            seriesMatches.removeAll()
            return
        }

        if arrServiceManager.radarrConnected || arrServiceManager.sonarrConnected {
            await resolveTrendingMatches(movies: trendingMovies, tv: trendingTV, arrServiceManager: arrServiceManager)
        } else {
            movieMatches.removeAll()
            seriesMatches.removeAll()
        }
    }

    func startArrLookup(arrServiceManager: ArrServiceManager, immediate: Bool = false) {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            resetArrLookup()
            return
        }

        let isCurrentlySearchingTerm = activeArrLookupTerm == term
            && ((sonarrLookupVM?.isSearching ?? false) || (radarrLookupVM?.isSearching ?? false))
        if isCurrentlySearchingTerm || (lastCompletedArrLookupTerm == term && !immediate) {
            return
        }

        arrLookupTask?.cancel()
        arrLookupTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            await performArrLookup(term: term)
        }
    }

    func performArrLookup(term: String) async {
        guard sonarrLookupVM != nil || radarrLookupVM != nil else {
            hasSearchedArr = false
            activeArrLookupTerm = ""
            return
        }

        hasSearchedArr = true
        activeArrLookupTerm = term
        sonarrLookupVM?.clearSearchResults()
        radarrLookupVM?.clearSearchResults()

        defer {
            if activeArrLookupTerm == term {
                activeArrLookupTerm = ""
                lastCompletedArrLookupTerm = term
            }
        }

        await withTaskGroup(of: Void.self) { group in
            if let sonarrLookupVM {
                group.addTask {
                    await sonarrLookupVM.searchForNewSeries(term: term)
                }
            }
            if let radarrLookupVM {
                group.addTask {
                    await radarrLookupVM.searchForNewMovies(term: term)
                }
            }
        }
    }

    func resetArrLookup() {
        arrLookupTask?.cancel()
        activeArrLookupTerm = ""
        lastCompletedArrLookupTerm = ""
        hasSearchedArr = false
        sonarrLookupVM?.clearSearchResults()
        radarrLookupVM?.clearSearchResults()
    }

    func startLibrarySearch(appServices: AppServices?) {
        librarySearchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            matchedTorrents = []
            matchedSeries = []
            matchedMovies = []
            return
        }

        let sonarrTitleIndex = sonarrTitleIndex
        let radarrTitleIndex = radarrTitleIndex
        let syncService = appServices?.syncService

        librarySearchTask = Task { @MainActor in
            if let syncService {
                let torrents = syncService.torrents.values
                    .filter { $0.name.lowercased().contains(query) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

                matchedTorrents = []
                for chunk in torrents.chunked(into: 5) {
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.3)) {
                        matchedTorrents.append(contentsOf: chunk)
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }

            let series = sonarrTitleIndex
                .filter { $0.lower.contains(query) }
                .map(\.series)
                .sorted { ($0.sortTitle ?? $0.title) < ($1.sortTitle ?? $1.title) }

            matchedSeries = []
            for chunk in series.chunked(into: 5) {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.3)) {
                    matchedSeries.append(contentsOf: chunk)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }

            let movies = radarrTitleIndex
                .filter { $0.lower.contains(query) }
                .map(\.movie)
                .sorted { ($0.sortTitle ?? $0.title) < ($1.sortTitle ?? $1.title) }

            matchedMovies = []
            for chunk in movies.chunked(into: 5) {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.3)) {
                    matchedMovies.append(contentsOf: chunk)
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func refreshLibrary(arrServiceManager: ArrServiceManager) async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        let sonarrClient = arrServiceManager.sonarrClient
        let radarrClient = arrServiceManager.radarrClient
        let existingSonarrSeries = sonarrSeries
        let existingRadarrMovies = radarrMovies

        async let sonarrTask: [SonarrSeries] = {
            guard let client = sonarrClient else { return [] }
            do {
                return try await client.getSeries()
            } catch {
                return existingSonarrSeries
            }
        }()
        async let radarrTask: [RadarrMovie] = {
            guard let client = radarrClient else { return [] }
            do {
                return try await client.getMovies()
            } catch {
                return existingRadarrMovies
            }
        }()

        let (series, movies) = await (sonarrTask, radarrTask)
        sonarrSeries = series
        radarrMovies = movies
        sonarrTitleIndex = series.map { (lower: $0.title.lowercased(), series: $0) }
        radarrTitleIndex = movies.map { (lower: $0.title.lowercased(), movie: $0) }
        createLookupViewModels(arrServiceManager: arrServiceManager)
    }

    func loadStoredTMDbAPIKeyAndTrending(arrServiceManager: ArrServiceManager) async {
        if let key = try? await KeychainHelper.shared.read(key: "tmdb.apiKey") {
            tmdbAPIKey = key
        }
        await loadTrending(arrServiceManager: arrServiceManager)
    }

    func loadTrending(arrServiceManager: ArrServiceManager) async {
        guard !tmdbAPIKey.isEmpty else {
            trendingMovies = []
            trendingTV = []
            return
        }
        isLoadingTrending = true
        trendingError = nil
        defer { isLoadingTrending = false }

        let client = TMDbClient(apiKey: tmdbAPIKey)
        do {
            async let moviesTask = client.trendingMovies()
            async let tvTask = client.trendingTV()
            let (movies, tv) = try await (moviesTask, tvTask)
            trendingMovies = movies
            trendingTV = tv
            await resolveTrendingMatches(movies: movies, tv: tv, arrServiceManager: arrServiceManager)
        } catch {
            trendingError = error.localizedDescription
        }
    }

    /// Resolve TMDb trending items to their Radarr/Sonarr representations in the background.
    func resolveTrendingMatches(movies: [TMDbItem], tv: [TMDbItem], arrServiceManager: ArrServiceManager) async {
        let radarrClient = arrServiceManager.radarrClient
        let sonarrClient = arrServiceManager.sonarrClient

        if let radarrClient {
            for item in movies.prefix(20) {
                movieMatches.removeValue(forKey: item.id)
            }

            await withTaskGroup(of: (Int, RadarrMovie?).self) { group in
                for item in movies.prefix(20) {
                    group.addTask {
                        let match = try? await radarrClient.lookupMovieByTmdb(tmdbId: item.id)
                        return (item.id, match)
                    }
                }
                for await (tmdbId, match) in group {
                    if let match {
                        movieMatches[tmdbId] = match
                    }
                }
            }
        } else {
            for item in movies.prefix(20) {
                movieMatches.removeValue(forKey: item.id)
            }
        }

        if let sonarrClient {
            let tvItems = Array(tv.prefix(20).map { (id: $0.id, title: $0.displayTitle, year: $0.year) })
            for item in tvItems {
                seriesMatches.removeValue(forKey: item.id)
            }

            await withTaskGroup(of: (Int, SonarrSeries?).self) { group in
                for item in tvItems {
                    group.addTask {
                        guard let results = try? await sonarrClient.lookupSeries(term: item.title),
                              !results.isEmpty else { return (item.id, nil) }
                        if let yearStr = item.year, let year = Int(yearStr) {
                            if let yearMatch = results.first(where: { $0.year == year }) {
                                return (item.id, yearMatch)
                            }
                        }
                        return (item.id, results.first)
                    }
                }
                for await (tmdbId, match) in group {
                    if let match {
                        seriesMatches[tmdbId] = match
                    }
                }
            }
        } else {
            for item in tv.prefix(20) {
                seriesMatches.removeValue(forKey: item.id)
            }
        }
    }

    func makeSonarrViewModel(arrServiceManager: ArrServiceManager) -> SonarrViewModel? {
        guard arrServiceManager.sonarrConnected else { return nil }
        return SonarrViewModel(serviceManager: arrServiceManager, preloadedSeries: sonarrSeries)
    }

    func makeRadarrViewModel(arrServiceManager: ArrServiceManager) -> RadarrViewModel? {
        guard arrServiceManager.radarrConnected else { return nil }
        return RadarrViewModel(serviceManager: arrServiceManager, preloadedMovies: radarrMovies)
    }

    func toggleLibrarySeriesMonitored(_ series: SonarrSeries, arrServiceManager: ArrServiceManager) async {
        guard let viewModel = makeSonarrViewModel(arrServiceManager: arrServiceManager) else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Series", message: "Sonarr is not connected.")
            return
        }

        await viewModel.toggleSeriesMonitored(series)
        await refreshLibrary(arrServiceManager: arrServiceManager)

        if let error = viewModel.error, !error.isEmpty {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Series", message: error)
        }
    }

    func toggleLibraryMovieMonitored(_ movie: RadarrMovie, arrServiceManager: ArrServiceManager) async {
        guard let viewModel = makeRadarrViewModel(arrServiceManager: arrServiceManager) else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Movie", message: "Radarr is not connected.")
            return
        }

        await viewModel.toggleMovieMonitored(movie)
        await refreshLibrary(arrServiceManager: arrServiceManager)

        if let error = viewModel.error, !error.isEmpty {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Movie", message: error)
        }
    }

    func quickAddSeries(_ series: SonarrSeries, arrServiceManager: ArrServiceManager) async {
        guard let viewModel = sonarrLookupVM else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "Sonarr is not connected.")
            return
        }
        guard let tvdbId = series.tvdbId else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "This search result is missing a TVDB ID.")
            return
        }

        let flightID = "series-\(tvdbId)"
        guard !arrAddInFlightIDs.contains(flightID) else { return }
        arrAddInFlightIDs.insert(flightID)
        defer { arrAddInFlightIDs.remove(flightID) }

        guard let titleSlug = series.titleSlug, !titleSlug.isEmpty else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "This search result is missing a title slug.")
            return
        }
        guard let qualityProfileId = viewModel.qualityProfiles.first?.id else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "No Sonarr quality profile is available.")
            return
        }
        guard let rootFolderPath = viewModel.rootFolders.first?.path else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "No Sonarr root folder is configured.")
            return
        }

        let wasAdded = await viewModel.addSeries(
            tvdbId: tvdbId,
            title: series.title,
            titleSlug: titleSlug,
            images: series.images ?? [],
            seasons: series.seasons ?? [],
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath
        )

        if wasAdded {
            await refreshLibrary(arrServiceManager: arrServiceManager)
        } else {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Add Series",
                message: viewModel.error ?? "Sonarr rejected the add request."
            )
        }
    }

    func quickAddMovie(_ movie: RadarrMovie, arrServiceManager: ArrServiceManager) async {
        guard let viewModel = radarrLookupVM else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "Radarr is not connected.")
            return
        }
        guard let tmdbId = movie.tmdbId else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "This search result is missing a TMDb ID.")
            return
        }

        let flightID = "movie-\(tmdbId)"
        guard !arrAddInFlightIDs.contains(flightID) else { return }
        arrAddInFlightIDs.insert(flightID)
        defer { arrAddInFlightIDs.remove(flightID) }

        guard let qualityProfileId = viewModel.qualityProfiles.first?.id else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "No Radarr quality profile is available.")
            return
        }
        guard let rootFolderPath = viewModel.rootFolders.first?.path else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "No Radarr root folder is configured.")
            return
        }

        let wasAdded = await viewModel.addMovie(
            title: movie.title,
            tmdbId: tmdbId,
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath
        )

        if wasAdded {
            await refreshLibrary(arrServiceManager: arrServiceManager)
        } else {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Add Movie",
                message: viewModel.error ?? "Radarr rejected the add request."
            )
        }
    }

    private func sonarrLookupKey(isConnected: Bool, series: [SonarrSeries]) -> String {
        guard isConnected else { return "disconnected" }
        let fingerprint = series
            .sorted { $0.id < $1.id }
            .map {
                [
                    String($0.id),
                    $0.title,
                    $0.status ?? "",
                    $0.monitored.map(String.init) ?? "",
                    $0.qualityProfileId.map(String.init) ?? "",
                    $0.rootFolderPath ?? "",
                    $0.path ?? ""
                ].joined(separator: "|")
            }
            .joined(separator: ",")
        return "connected:\(fingerprint)"
    }

    private func radarrLookupKey(isConnected: Bool, movies: [RadarrMovie]) -> String {
        guard isConnected else { return "disconnected" }
        let fingerprint = movies
            .sorted { $0.id < $1.id }
            .map {
                [
                    String($0.id),
                    $0.title,
                    $0.status ?? "",
                    $0.monitored.map(String.init) ?? "",
                    $0.qualityProfileId.map(String.init) ?? "",
                    $0.rootFolderPath ?? "",
                    $0.path ?? ""
                ].joined(separator: "|")
            }
            .joined(separator: ",")
        return "connected:\(fingerprint)"
    }
}
