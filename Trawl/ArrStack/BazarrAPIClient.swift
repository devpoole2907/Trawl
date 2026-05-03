import Foundation

actor BazarrAPIClient {
    let base: ArrAPIClient

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false) {
        self.base = ArrAPIClient(
            baseURL: baseURL,
            apiKey: apiKey,
            allowsUntrustedTLS: allowsUntrustedTLS,
            apiKeyHeaderName: "X-API-KEY"
        )
    }

    // MARK: - System

    func getSystemStatus() async throws -> BazarrSystemStatus {
        let response: BazarrStatusResponse = try await base.get("/api/system/status")
        return response.status
    }

    func getHealth() async throws -> [BazarrHealthCheck] {
        let response: BazarrArrayResponse<BazarrHealthCheck> = try await base.get("/api/system/health")
        return response.values
    }

    func getBadges() async throws -> BazarrBadges {
        try await base.get("/api/badges")
    }

    func getTasks() async throws -> [BazarrTask] {
        let response: BazarrArrayResponse<BazarrTask> = try await base.get("/api/system/tasks")
        return response.values
    }

    func runTask(taskId: String) async throws {
        try await base.postVoid("/api/system/tasks", queryItems: [
            URLQueryItem(name: "taskid", value: taskId)
        ])
    }

    func getAnnouncements() async throws -> [BazarrAnnouncement] {
        let response: BazarrArrayResponse<BazarrAnnouncement> = try await base.get("/api/system/announcements")
        return response.values
    }

    func dismissAnnouncement(hash: String) async throws {
        try await base.postVoid("/api/system/announcements", queryItems: [
            URLQueryItem(name: "hash", value: hash)
        ])
    }

    // MARK: - Settings

    func getSettings() async throws -> [String: JSONValue] {
        try await base.get("/api/system/settings")
    }

    func saveSettings(_ changes: [String: String]) async throws {
        try await base.postForm("/api/system/settings", formFields: changes)
    }

    func saveSettings(_ formItems: [URLQueryItem]) async throws {
        try await base.postFormItems("/api/system/settings", formItems: formItems)
    }

    // MARK: - Languages

    func getLanguages(history: Bool = false) async throws -> [BazarrLanguage] {
        let response: BazarrArrayResponse<BazarrLanguage> = try await base.get(
            "/api/system/languages",
            queryItems: [URLQueryItem(name: "history", value: history ? "true" : "false")]
        )
        return response.values
    }

    func getLanguageProfiles() async throws -> [BazarrLanguageProfile] {
        let response: BazarrArrayResponse<BazarrLanguageProfile> = try await base.get("/api/system/languages/profiles")
        return response.values
    }

    func saveEnabledLanguages(_ codes: [String]) async throws {
        var fields: [String: String] = [:]
        for code in codes {
            fields["languages-enabled"] = code
        }
        try await saveSettings(fields)
    }

    func saveLanguageProfiles(_ profiles: [BazarrLanguageProfile]) async throws {
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(profiles)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ArrError.invalidResponse
        }
        try await saveSettings(["languages-profiles": jsonString])
    }

    // MARK: - Providers

    func getProviders() async throws -> [BazarrProvider] {
        let response: BazarrArrayResponse<BazarrProvider> = try await base.get("/api/providers")
        return response.values
    }

    func resetProviders() async throws {
        try await base.postVoid("/api/providers", queryItems: [
            URLQueryItem(name: "action", value: "reset")
        ])
    }

    func saveEnabledProviders(_ providerKeys: [String], fieldValues: [String: String] = [:]) async throws {
        var formItems: [URLQueryItem]
        if providerKeys.isEmpty {
            formItems = [URLQueryItem(name: "settings-general-enabled_providers", value: "")]
        } else {
            formItems = providerKeys.map {
                URLQueryItem(name: "settings-general-enabled_providers", value: $0)
            }
        }

        formItems.append(contentsOf: fieldValues.map { key, value in
            URLQueryItem(name: key, value: value)
        })
        try await saveSettings(formItems)
    }

    // MARK: - Series

    func getSeries(start: Int = 0, length: Int = -1, ids: [Int] = []) async throws -> BazarrPage<BazarrSeries> {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "length", value: String(length))
        ]
        for id in ids {
            queryItems.append(URLQueryItem(name: "seriesid[]", value: String(id)))
        }
        return try await base.get("/api/series", queryItems: queryItems)
    }

    func updateSeriesProfile(seriesIds: [Int], profileIds: [String?]) async throws {
        var queryItems: [URLQueryItem] = []
        for (index, id) in seriesIds.enumerated() {
            queryItems.append(URLQueryItem(name: "seriesid", value: String(id)))
            queryItems.append(URLQueryItem(name: "profileid", value: profileIds[index] ?? "none"))
        }
        try await base.postVoid("/api/series", queryItems: queryItems)
    }

    func runSeriesAction(seriesId: Int, action: BazarrSeriesAction) async throws {
        try await base.patchVoid("/api/series", queryItems: [
            URLQueryItem(name: "seriesid", value: String(seriesId)),
            URLQueryItem(name: "action", value: action.rawValue)
        ])
    }

    // MARK: - Movies

    func getMovies(start: Int = 0, length: Int = -1, ids: [Int] = []) async throws -> BazarrPage<BazarrMovie> {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "length", value: String(length))
        ]
        for id in ids {
            queryItems.append(URLQueryItem(name: "radarrid[]", value: String(id)))
        }
        return try await base.get("/api/movies", queryItems: queryItems)
    }

    func updateMovieProfile(radarrIds: [Int], profileIds: [String?]) async throws {
        var queryItems: [URLQueryItem] = []
        for (index, id) in radarrIds.enumerated() {
            queryItems.append(URLQueryItem(name: "radarrid", value: String(id)))
            queryItems.append(URLQueryItem(name: "profileid", value: profileIds[index] ?? "none"))
        }
        try await base.postVoid("/api/movies", queryItems: queryItems)
    }

    func runMovieAction(radarrId: Int, action: BazarrSeriesAction) async throws {
        try await base.patchVoid("/api/movies", queryItems: [
            URLQueryItem(name: "radarrid", value: String(radarrId)),
            URLQueryItem(name: "action", value: action.rawValue)
        ])
    }

    // MARK: - Episodes

    func getEpisodes(seriesIds: [Int]) async throws -> [BazarrEpisode] {
        var queryItems: [URLQueryItem] = []
        for id in seriesIds {
            queryItems.append(URLQueryItem(name: "seriesid[]", value: String(id)))
        }
        let response: BazarrArrayResponse<BazarrEpisode> = try await base.get("/api/episodes", queryItems: queryItems)
        return response.values
    }

    func getEpisodes(episodeIds: [Int]) async throws -> [BazarrEpisode] {
        var queryItems: [URLQueryItem] = []
        for id in episodeIds {
            queryItems.append(URLQueryItem(name: "episodeid[]", value: String(id)))
        }
        let response: BazarrArrayResponse<BazarrEpisode> = try await base.get("/api/episodes", queryItems: queryItems)
        return response.values
    }

    func downloadEpisodeSubtitles(seriesId: Int, episodeId: Int, language: String, forced: Bool, hi: Bool) async throws {
        try await base.patchVoid("/api/episodes/subtitles", queryItems: [
            URLQueryItem(name: "seriesid", value: String(seriesId)),
            URLQueryItem(name: "episodeid", value: String(episodeId)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "forced", value: String(forced)),
            URLQueryItem(name: "hi", value: String(hi))
        ])
    }

    func deleteEpisodeSubtitles(seriesId: Int, episodeId: Int, language: String, forced: Bool, hi: Bool, path: String) async throws {
        try await base.delete("/api/episodes/subtitles", queryItems: [
            URLQueryItem(name: "seriesid", value: String(seriesId)),
            URLQueryItem(name: "episodeid", value: String(episodeId)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "forced", value: String(forced)),
            URLQueryItem(name: "hi", value: String(hi)),
            URLQueryItem(name: "path", value: path)
        ])
    }

    // MARK: - Movie Subtitles

    func downloadMovieSubtitles(radarrId: Int, language: String, forced: Bool, hi: Bool) async throws {
        try await base.patchVoid("/api/movies/subtitles", queryItems: [
            URLQueryItem(name: "radarrid", value: String(radarrId)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "forced", value: String(forced)),
            URLQueryItem(name: "hi", value: String(hi))
        ])
    }

    func deleteMovieSubtitles(radarrId: Int, language: String, forced: Bool, hi: Bool, path: String) async throws {
        try await base.delete("/api/movies/subtitles", queryItems: [
            URLQueryItem(name: "radarrid", value: String(radarrId)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "forced", value: String(forced)),
            URLQueryItem(name: "hi", value: String(hi)),
            URLQueryItem(name: "path", value: path)
        ])
    }

    // MARK: - Subtitle Tools

    func getSubtitleTracks(subtitlesPath: String, episodeId: Int?, movieId: Int?) async throws -> BazarrSubtitleTrackInfo {
        var queryItems = [URLQueryItem(name: "subtitlesPath", value: subtitlesPath)]
        if let eid = episodeId {
            queryItems.append(URLQueryItem(name: "sonarrEpisodeId", value: String(eid)))
        }
        if let mid = movieId {
            queryItems.append(URLQueryItem(name: "radarrMovieId", value: String(mid)))
        }
        let response: BazarrValueResponse<BazarrSubtitleTrackInfo> = try await base.get("/api/subtitles", queryItems: queryItems)
        return response.value
    }

    func applySubtitleAction(
        action: String,
        language: String,
        path: String,
        type: String,
        id: Int,
        forced: Bool = false,
        hi: Bool = false,
        reference: String? = nil,
        maxOffsetSeconds: String? = nil,
        noFixFramerate: Bool = false,
        gss: Bool = false,
        originalFormat: Bool = false
    ) async throws {
        var queryItems = [
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "forced", value: String(forced)),
            URLQueryItem(name: "hi", value: String(hi))
        ]
        if let ref = reference { queryItems.append(URLQueryItem(name: "reference", value: ref)) }
        if let maxOffset = maxOffsetSeconds { queryItems.append(URLQueryItem(name: "max_offset_seconds", value: maxOffset)) }
        if noFixFramerate { queryItems.append(URLQueryItem(name: "no_fix_framerate", value: "True")) }
        if gss { queryItems.append(URLQueryItem(name: "gss", value: "True")) }
        if originalFormat { queryItems.append(URLQueryItem(name: "original_format", value: "True")) }
        try await base.patchVoid("/api/subtitles", queryItems: queryItems)
    }

    // MARK: - History

    func getHistoryStats(
        timeFrame: String = "month",
        action: String = "All",
        provider: String = "All",
        language: String = "All"
    ) async throws -> BazarrHistoryStats {
        let queryItems = [
            URLQueryItem(name: "timeFrame", value: timeFrame),
            URLQueryItem(name: "action", value: action),
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "language", value: language)
        ]
        return try await base.get("/api/history/stats", queryItems: queryItems)
    }

    // MARK: - Search

    func search(query: String) async throws -> [BazarrSearchResult] {
        try await base.get("/api/system/searches", queryItems: [
            URLQueryItem(name: "query", value: query)
        ])
    }

    // MARK: - Wanted

    func getWantedEpisodes(start: Int = 0, length: Int = -1) async throws -> BazarrPage<BazarrWantedEpisode> {
        try await base.get("/api/episodes/wanted", queryItems: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "length", value: String(length))
        ])
    }

    func getWantedMovies(start: Int = 0, length: Int = -1) async throws -> BazarrPage<BazarrMovie> {
        try await base.get("/api/movies/wanted", queryItems: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "length", value: String(length))
        ])
    }

    // MARK: - Interactive Search

    func interactiveSearchEpisode(episodeId: Int, language: String, hi: Bool, forced: Bool) async throws -> [BazarrInteractiveSearchResult] {
        try await base.get("/api/providers/episodes", queryItems: [
            URLQueryItem(name: "episodeid", value: String(episodeId)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hi", value: String(hi)),
            URLQueryItem(name: "forced", value: String(forced))
        ])
    }

    func downloadInteractiveEpisodeSubtitle(
        episodeId: Int,
        seriesId: Int,
        provider: String,
        subtitle: String,
        language: String,
        hi: Bool,
        forced: Bool
    ) async throws {
        try await base.postVoid("/api/providers/episodes", queryItems: [
            URLQueryItem(name: "episodeid", value: String(episodeId)),
            URLQueryItem(name: "seriesid", value: String(seriesId)),
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "subtitle", value: subtitle),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hi", value: String(hi)),
            URLQueryItem(name: "forced", value: String(forced))
        ])
    }

    func interactiveSearchMovie(radarrId: Int, language: String, hi: Bool, forced: Bool) async throws -> [BazarrInteractiveSearchResult] {
        try await base.get("/api/providers/movies", queryItems: [
            URLQueryItem(name: "radarrid", value: String(radarrId)),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hi", value: String(hi)),
            URLQueryItem(name: "forced", value: String(forced))
        ])
    }

    func downloadInteractiveMovieSubtitle(
        radarrId: Int,
        provider: String,
        subtitle: String,
        language: String,
        hi: Bool,
        forced: Bool
    ) async throws {
        try await base.postVoid("/api/providers/movies", queryItems: [
            URLQueryItem(name: "radarrid", value: String(radarrId)),
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "subtitle", value: subtitle),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hi", value: String(hi)),
            URLQueryItem(name: "forced", value: String(forced))
        ])
    }

    // MARK: - Connection Test

    func testConnection() async throws -> BazarrSystemStatus {
        try await getSystemStatus()
    }
}

nonisolated private struct BazarrStatusResponse: Decodable {
    let status: BazarrSystemStatus

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        if let wrapped = try? decoder.container(keyedBy: CodingKeys.self),
           let status = try? wrapped.decode(BazarrSystemStatus.self, forKey: .data) {
            self.status = status
            return
        }

        if let wrapped = try? decoder.container(keyedBy: CodingKeys.self),
           let statuses = try? wrapped.decode([BazarrSystemStatus].self, forKey: .data),
           let status = statuses.first {
            self.status = status
            return
        }

        self.status = try BazarrSystemStatus(from: decoder)
    }
}

nonisolated private struct BazarrArrayResponse<Element: Decodable>: Decodable {
    let values: [Element]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        if let direct = try? [Element](from: decoder) {
            values = direct
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode([Element].self, forKey: .data)
    }
}

nonisolated private struct BazarrValueResponse<Value: Decodable>: Decodable {
    let value: Value

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        if let direct = try? Value(from: decoder) {
            value = direct
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Value.self, forKey: .data)
    }
}
