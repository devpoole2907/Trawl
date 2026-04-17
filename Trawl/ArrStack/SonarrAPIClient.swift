import Foundation

/// Sonarr-specific API methods. Wraps ArrAPIClient for type-safe Sonarr operations.
actor SonarrAPIClient {
    let base: ArrAPIClient

    init(baseURL: String, apiKey: String) {
        self.base = ArrAPIClient(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - Series

    /// Get all series in the library
    func getSeries() async throws -> [SonarrSeries] {
        try await base.get("/api/v3/series")
    }

    /// Get a single series by ID
    func getSeries(id: Int) async throws -> SonarrSeries {
        try await base.get("/api/v3/series/\(id)")
    }

    /// Search for series to add (TheTVDB lookup)
    func lookupSeries(term: String) async throws -> [SonarrSeries] {
        let params = [URLQueryItem(name: "term", value: term)]
        return try await base.get("/api/v3/series/lookup", queryItems: params)
    }

    /// Add a new series to Sonarr
    func addSeries(_ body: SonarrAddSeriesBody) async throws -> SonarrSeries {
        try await base.postCodable("/api/v3/series", body: body)
    }

    /// Edit an existing series (full replacement)
    func updateSeries(_ series: SonarrSeries, moveFiles: Bool = false) async throws -> SonarrSeries {
        let params = moveFiles ? [URLQueryItem(name: "moveFiles", value: "true")] : []
        return try await base.putCodable("/api/v3/series/\(series.id)", body: series, queryItems: params)
    }

    /// Delete a series
    func deleteSeries(id: Int, deleteFiles: Bool = false, addImportListExclusion: Bool = false) async throws {
        var params = [URLQueryItem(name: "deleteFiles", value: String(deleteFiles))]
        if addImportListExclusion {
            params.append(URLQueryItem(name: "addImportListExclusion", value: "true"))
        }
        try await base.delete("/api/v3/series/\(id)", queryItems: params)
    }

    // MARK: - Episodes

    /// Get all episodes for a series
    func getEpisodes(seriesId: Int) async throws -> [SonarrEpisode] {
        let params = [URLQueryItem(name: "seriesId", value: String(seriesId))]
        return try await base.get("/api/v3/episode", queryItems: params)
    }

    /// Get a single episode by ID
    func getEpisode(id: Int) async throws -> SonarrEpisode {
        try await base.get("/api/v3/episode/\(id)")
    }

    /// Set monitor status for episodes
    func setEpisodeMonitored(episodeIds: [Int], monitored: Bool) async throws -> [SonarrEpisode] {
        let body = SonarrEpisodeMonitorBody(episodeIds: episodeIds, monitored: monitored)
        return try await base.putCodable("/api/v3/episode/monitor", body: body)
    }

    // MARK: - Episode Files

    /// Get episode files for a series
    func getEpisodeFiles(seriesId: Int) async throws -> [SonarrEpisodeFile] {
        let params = [URLQueryItem(name: "seriesId", value: String(seriesId))]
        return try await base.get("/api/v3/episodefile", queryItems: params)
    }

    /// Delete an episode file
    func deleteEpisodeFile(id: Int) async throws {
        try await base.delete("/api/v3/episodefile/\(id)")
    }

    // MARK: - Calendar

    /// Get upcoming episodes within a date range
    func getCalendar(start: Date? = nil, end: Date? = nil, unmonitored: Bool = false, includeSeries: Bool = true) async throws -> [SonarrEpisode] {
        var params: [URLQueryItem] = []
        let formatter = ISO8601DateFormatter()
        if let start { params.append(URLQueryItem(name: "start", value: formatter.string(from: start))) }
        if let end { params.append(URLQueryItem(name: "end", value: formatter.string(from: end))) }
        params.append(URLQueryItem(name: "unmonitored", value: String(unmonitored)))
        params.append(URLQueryItem(name: "includeSeries", value: String(includeSeries)))
        return try await base.get("/api/v3/calendar", queryItems: params)
    }

    // MARK: - Wanted / Missing

    /// Get missing episodes (wanted but not downloaded)
    func getWantedMissing(page: Int = 1, pageSize: Int = 20, sortKey: String = "airDateUtc", sortDirection: String = "descending") async throws -> SonarrWantedPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: sortKey),
            URLQueryItem(name: "sortDirection", value: sortDirection),
            URLQueryItem(name: "includeSeries", value: "true")
        ]
        return try await base.get("/api/v3/wanted/missing", queryItems: params)
    }

    // MARK: - Commands

    func refreshSeries(seriesId: Int? = nil) async throws -> ArrCommand {
        var params: [String: Any] = ["name": SonarrCommand.refreshSeries.rawValue]
        if let seriesId { params["seriesId"] = seriesId }
        return try await base.post("/api/v3/command", jsonBody: params)
    }

    func searchEpisodes(episodeIds: [Int]) async throws -> ArrCommand {
        let params: [String: Any] = [
            "name": SonarrCommand.episodeSearch.rawValue,
            "episodeIds": episodeIds
        ]
        return try await base.post("/api/v3/command", jsonBody: params)
    }

    func searchSeason(seriesId: Int, seasonNumber: Int) async throws -> ArrCommand {
        let params: [String: Any] = [
            "name": SonarrCommand.seasonSearch.rawValue,
            "seriesId": seriesId,
            "seasonNumber": seasonNumber
        ]
        return try await base.post("/api/v3/command", jsonBody: params)
    }

    func searchAllMissing() async throws -> ArrCommand {
        try await base.postCommand(name: SonarrCommand.missingEpisodeSearch.rawValue)
    }

    func rssSync() async throws -> ArrCommand {
        try await base.postCommand(name: SonarrCommand.rssSync.rawValue)
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

// MARK: - Wanted Page (Sonarr-specific paged response)

struct SonarrWantedPage: Codable, Sendable {
    let page: Int?
    let pageSize: Int?
    let sortKey: String?
    let sortDirection: String?
    let totalRecords: Int?
    let records: [SonarrEpisode]?
}
