import Foundation

/// Radarr-specific API methods. Wraps ArrAPIClient for type-safe Radarr operations.
actor RadarrAPIClient {
    let base: ArrAPIClient

    init(baseURL: String, apiKey: String) {
        self.base = ArrAPIClient(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - Movies

    /// Get all movies in the library
    func getMovies() async throws -> [RadarrMovie] {
        try await base.get("/api/v3/movie")
    }

    /// Get a single movie by ID
    func getMovie(id: Int) async throws -> RadarrMovie {
        try await base.get("/api/v3/movie/\(id)")
    }

    /// Search for movies to add (TMDb lookup)
    func lookupMovie(term: String) async throws -> [RadarrMovie] {
        let params = [URLQueryItem(name: "term", value: term)]
        return try await base.get("/api/v3/movie/lookup", queryItems: params)
    }

    /// Search by TMDb ID
    func lookupMovieByTmdb(tmdbId: Int) async throws -> RadarrMovie {
        let params = [URLQueryItem(name: "tmdbId", value: String(tmdbId))]
        return try await base.get("/api/v3/movie/lookup/tmdb", queryItems: params)
    }

    /// Search by IMDb ID
    func lookupMovieByImdb(imdbId: String) async throws -> [RadarrMovie] {
        let params = [URLQueryItem(name: "imdbId", value: imdbId)]
        return try await base.get("/api/v3/movie/lookup/imdb", queryItems: params)
    }

    /// Add a new movie to Radarr
    func addMovie(_ body: RadarrAddMovieBody) async throws -> RadarrMovie {
        try await base.postCodable("/api/v3/movie", body: body)
    }

    /// Edit an existing movie (full replacement)
    func updateMovie(_ movie: RadarrMovie, moveFiles: Bool = false) async throws -> RadarrMovie {
        let params = moveFiles ? [URLQueryItem(name: "moveFiles", value: "true")] : []
        return try await base.putCodable("/api/v3/movie/\(movie.id)", body: movie, queryItems: params)
    }

    /// Delete a movie
    func deleteMovie(id: Int, deleteFiles: Bool = false, addImportExclusion: Bool = false) async throws {
        var params = [URLQueryItem(name: "deleteFiles", value: String(deleteFiles))]
        if addImportExclusion {
            params.append(URLQueryItem(name: "addImportExclusion", value: "true"))
        }
        try await base.delete("/api/v3/movie/\(id)", queryItems: params)
    }

    // MARK: - Movie Files

    /// Get movie file for a specific movie
    func getMovieFiles(movieId: Int) async throws -> [RadarrMovieFile] {
        let params = [URLQueryItem(name: "movieId", value: String(movieId))]
        return try await base.get("/api/v3/moviefile", queryItems: params)
    }

    /// Delete a movie file
    func deleteMovieFile(id: Int) async throws {
        try await base.delete("/api/v3/moviefile/\(id)")
    }

    // MARK: - Calendar

    /// Get upcoming movies within a date range
    func getCalendar(start: Date? = nil, end: Date? = nil, unmonitored: Bool = false) async throws -> [RadarrMovie] {
        var params: [URLQueryItem] = []
        let formatter = ISO8601DateFormatter()
        if let start { params.append(URLQueryItem(name: "start", value: formatter.string(from: start))) }
        if let end { params.append(URLQueryItem(name: "end", value: formatter.string(from: end))) }
        params.append(URLQueryItem(name: "unmonitored", value: String(unmonitored)))
        return try await base.get("/api/v3/calendar", queryItems: params)
    }

    // MARK: - Wanted / Missing

    /// Get missing movies (monitored, not downloaded, available)
    func getWantedMissing(page: Int = 1, pageSize: Int = 20, sortKey: String = "digitalRelease", sortDirection: String = "descending") async throws -> RadarrWantedPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: sortKey),
            URLQueryItem(name: "sortDirection", value: sortDirection),
            URLQueryItem(name: "monitored", value: "true")
        ]
        return try await base.get("/api/v3/wanted/missing", queryItems: params)
    }

    // MARK: - Commands

    func refreshMovie(movieId: Int? = nil) async throws -> ArrCommand {
        var params: [String: Any] = ["name": RadarrCommand.refreshMovie.rawValue]
        if let movieId { params["movieId"] = movieId }
        return try await base.post("/api/v3/command", jsonBody: params)
    }

    func searchMovie(movieIds: [Int]) async throws -> ArrCommand {
        let params: [String: Any] = [
            "name": RadarrCommand.moviesSearch.rawValue,
            "movieIds": movieIds
        ]
        return try await base.post("/api/v3/command", jsonBody: params)
    }

    func searchAllMissing() async throws -> ArrCommand {
        try await base.postCommand(name: RadarrCommand.missingMoviesSearch.rawValue)
    }

    func rssSync() async throws -> ArrCommand {
        try await base.postCommand(name: RadarrCommand.rssSync.rawValue)
    }

    // MARK: - Shared (delegate to base)

    func getSystemStatus() async throws -> ArrSystemStatus { try await base.getSystemStatus() }
    func getHealth() async throws -> [ArrHealthCheck] { try await base.getHealth() }
    func getQualityProfiles() async throws -> [ArrQualityProfile] { try await base.getQualityProfiles() }
    func getRootFolders() async throws -> [ArrRootFolder] { try await base.getRootFolders() }
    func getTags() async throws -> [ArrTag] { try await base.getTags() }
    func getQueue(page: Int = 1, pageSize: Int = 20) async throws -> ArrQueuePage { try await base.getQueue(page: page, pageSize: pageSize) }
    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws { try await base.deleteQueueItem(id: id, removeFromClient: removeFromClient, blocklist: blocklist) }
    func getHistory(page: Int = 1, pageSize: Int = 20) async throws -> ArrHistoryPage { try await base.getHistory(page: page, pageSize: pageSize) }
    func getDiskSpace() async throws -> [ArrDiskSpace] { try await base.getDiskSpace() }
}

// MARK: - Wanted Page (Radarr-specific paged response)

struct RadarrWantedPage: Codable, Sendable {
    let page: Int?
    let pageSize: Int?
    let sortKey: String?
    let sortDirection: String?
    let totalRecords: Int?
    let records: [RadarrMovie]?
}
