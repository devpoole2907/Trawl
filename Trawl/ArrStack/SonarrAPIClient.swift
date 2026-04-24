import Foundation

/// Sonarr-specific API methods. Wraps ArrAPIClient for type-safe Sonarr operations.
actor SonarrAPIClient: SharedArrClient {
    let base: ArrAPIClient

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false) {
        self.base = ArrAPIClient(baseURL: baseURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
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

    func getReleases(episodeId: Int? = nil, seriesId: Int? = nil, seasonNumber: Int? = nil) async throws -> [ArrRelease] {
        var params: [URLQueryItem] = []
        if let episodeId {
            params.append(URLQueryItem(name: "episodeId", value: String(episodeId)))
        }
        if let seriesId {
            params.append(URLQueryItem(name: "seriesId", value: String(seriesId)))
        }
        if let seasonNumber {
            params.append(URLQueryItem(name: "seasonNumber", value: String(seasonNumber)))
        }
        return try await base.get("/api/v3/release", queryItems: params)
    }

    func grabRelease(_ release: ArrRelease) async throws {
        guard let guid = release.guid, let indexerId = release.indexerId else {
            throw ArrError.invalidResponse
        }
        let trimmedGuid = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuid.isEmpty else {
            throw ArrError.invalidResponse
        }
        try await base.postVoidCodable("/api/v3/release", body: ArrReleaseGrabRequest(guid: trimmedGuid, indexerId: indexerId))
    }

    // MARK: - Wanted / Missing

    /// Get missing episodes (wanted but not downloaded)
    func getWantedMissing(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize,
        sortKey: String = "airDateUtc",
        sortDirection: String = "descending"
    ) async throws -> SonarrWantedPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: sortKey),
            URLQueryItem(name: "sortDirection", value: sortDirection),
            URLQueryItem(name: "includeSeries", value: "true")
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

    func installUpdate() async throws -> ArrCommand {
        try await base.postCommand(name: SonarrCommand.applicationUpdate.rawValue)
    }

    // MARK: - Manual Import

    /// Get list of files that can be manually imported from a folder
    func getManualImport(folder: String, seriesId: Int? = nil, filterExistingFiles: Bool = true) async throws -> [JSONValue] {
        var params = [
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "filterExistingFiles", value: String(filterExistingFiles))
        ]
        if let seriesId {
            params.append(URLQueryItem(name: "seriesId", value: String(seriesId)))
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

// MARK: - Wanted Page (Sonarr-specific paged response)

struct SonarrWantedPage: Codable, Sendable {
    let page: Int?
    let pageSize: Int?
    let sortKey: String?
    let sortDirection: String?
    let totalRecords: Int?
    let records: [SonarrEpisode]?

    enum CodingKeys: String, CodingKey {
        case page
        case pageSize
        case sortKey
        case sortDirection
        case totalRecords
        case records
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        page = try container.decodeIfPresent(Int.self, forKey: .page)
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize)
        sortKey = try container.decodeIfPresent(String.self, forKey: .sortKey)
        sortDirection = try container.decodeIfPresent(String.self, forKey: .sortDirection)
        totalRecords = try container.decodeIfPresent(Int.self, forKey: .totalRecords)
        records = try container.decodeIfPresent([SonarrEpisode].self, forKey: .records)
    }
}
