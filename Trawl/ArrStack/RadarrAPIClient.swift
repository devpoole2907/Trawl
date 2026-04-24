import Foundation

/// Radarr-specific API methods. Wraps ArrAPIClient for type-safe Radarr operations.
actor RadarrAPIClient: SharedArrClient {
    let base: ArrAPIClient

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false) {
        self.base = ArrAPIClient(baseURL: baseURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
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

    func getReleases(movieId: Int) async throws -> [ArrRelease] {
        let params = [URLQueryItem(name: "movieId", value: String(movieId))]
        return try await base.get("/api/v3/release", queryItems: params)
    }

    func grabRelease(_ release: ArrRelease) async throws {
        guard let guid = release.guid, let indexerId = release.indexerId else {
            throw ArrError.invalidResponse
        }
        try await base.postVoidCodable("/api/v3/release", body: ArrReleaseGrabRequest(guid: guid, indexerId: indexerId))
    }

    // MARK: - Wanted / Missing

    /// Get missing movies (monitored, not downloaded, available)
    func getWantedMissing(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize,
        sortKey: String = "digitalRelease",
        sortDirection: String = "descending"
    ) async throws -> RadarrWantedPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: sortKey),
            URLQueryItem(name: "sortDirection", value: sortDirection),
            URLQueryItem(name: "monitored", value: "true")
        ]
        return try await base.get("/api/v3/wanted/missing", queryItems: params)
    }

    // MARK: - Blocklist

    func getBlocklist(page: Int = 1, pageSize: Int = ArrAPIClient.defaultPageSize) async throws -> ArrBlocklistPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "date"),
            URLQueryItem(name: "sortDirection", value: "descending")
        ]
        return try await base.get("/api/v3/blocklist", queryItems: params)
    }

    func deleteBlocklistItem(id: Int) async throws {
        try await base.delete("/api/v3/blocklist/\(id)")
    }

    func deleteBlocklistItems(ids: [Int]) async throws {
        try await base.deleteWithBody("/api/v3/blocklist/bulk", jsonBody: ["ids": ids])
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

    func installUpdate() async throws -> ArrCommand {
        try await base.postCommand(name: RadarrCommand.applicationUpdate.rawValue)
    }

    // MARK: - Manual Import

    /// Get list of files that can be manually imported from a folder
    func getManualImport(folder: String, movieId: Int? = nil, filterExistingFiles: Bool = true) async throws -> [JSONValue] {
        var params = [
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "filterExistingFiles", value: String(filterExistingFiles))
        ]
        if let movieId {
            params.append(URLQueryItem(name: "movieId", value: String(movieId)))
        }
        return try await base.get("/api/v3/manualimport", queryItems: params)
    }

    /// Perform a manual import of specific files, waiting for the command to complete.
    func manualImport(files: [JSONValue], importMode: String = "move") async throws -> ArrCommand {
        let additionalParams: [String: Any] = [
            "files": files.map { $0.rawValue },
            "importMode": importMode
        ]
        return try await base.postCommandAndWait(name: "ManualImport", additionalParams: additionalParams)
    }
}

// MARK: - Wanted Page (Radarr-specific paged response)

nonisolated struct RadarrWantedPage: Codable, Sendable {
    let page: Int?
    let pageSize: Int?
    let sortKey: String?
    let sortDirection: String?
    let totalRecords: Int?
    let records: [RadarrMovie]?
}
