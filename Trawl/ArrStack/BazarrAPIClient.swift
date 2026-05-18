import Foundation

private nonisolated struct BazarrLanguageProfileSettingsPayload: Encodable {
    let profileId: Int
    let name: String
    let cutoff: Int?
    let items: [BazarrLanguageProfileItem]
    let mustContain: [String]
    let mustNotContain: [String]
    let originalFormat: Int?
    let tag: Int?

    init(profile: BazarrLanguageProfile) {
        profileId = profile.profileId
        name = profile.name
        cutoff = profile.cutoff
        items = profile.parsedItems
        mustContain = profile.mustContain ?? []
        mustNotContain = profile.mustNotContain ?? []
        originalFormat = profile.originalFormat
        tag = profile.tag
    }

    enum CodingKeys: String, CodingKey {
        case profileId, name, cutoff, items, mustContain, mustNotContain, originalFormat, tag
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileId, forKey: .profileId)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
        try container.encode(mustContain, forKey: .mustContain)
        try container.encode(mustNotContain, forKey: .mustNotContain)

        if let cutoff {
            try container.encode(cutoff, forKey: .cutoff)
        } else {
            try container.encodeNil(forKey: .cutoff)
        }

        if let originalFormat {
            try container.encode(originalFormat, forKey: .originalFormat)
        } else {
            try container.encodeNil(forKey: .originalFormat)
        }

        if let tag {
            try container.encode(tag, forKey: .tag)
        } else {
            try container.encodeNil(forKey: .tag)
        }
    }
}

private nonisolated enum BazarrRemotePathMappingSource: String, Sendable {
    case sonarr = "Sonarr"
    case radarr = "Radarr"

    init(mappingID: Int, host: String) {
        if mappingID >= Self.radarrIDOffset || host.localizedCaseInsensitiveCompare(Self.radarr.rawValue) == .orderedSame {
            self = .radarr
        } else {
            self = .sonarr
        }
    }

    var settingsKey: String {
        switch self {
        case .sonarr: "settings-general-path_mappings"
        case .radarr: "settings-general-path_mappings_movie"
        }
    }

    var jsonKey: String {
        switch self {
        case .sonarr: "path_mappings"
        case .radarr: "path_mappings_movie"
        }
    }

    var idOffset: Int {
        switch self {
        case .sonarr: 0
        case .radarr: Self.radarrIDOffset
        }
    }

    static let radarrIDOffset = 100_000
}

actor BazarrAPIClient: SharedArrClient {
    let base: ArrAPIClient
    let apiPath = "/api"

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

    // MARK: - Backups

    func getBackups() async throws -> [ArrBackup] {
        let response: BazarrArrayResponse<BazarrBackup> = try await base.get("/api/system/backups")
        return response.values.map(\.arrBackup)
    }

    func createBackup() async throws {
        try await base.postVoid("/api/system/backups", queryItems: [])
    }

    func downloadBackup(_ backup: ArrBackup) async throws -> Data {
        let filename = try backupFilename(for: backup)
        return try await base.getData("/system/backup/download/\(filename)")
    }

    func restoreBackup(_ backup: ArrBackup) async throws {
        try await base.patchVoid("/api/system/backups", queryItems: [
            URLQueryItem(name: "filename", value: try backupFilename(for: backup))
        ])
    }

    func uploadBackup(data: Data, filename: String) async throws {
        throw ArrError.serverError(statusCode: 405, message: "Bazarr does not support uploading backups.")
    }

    func deleteBackup(_ backup: ArrBackup) async throws {
        try await base.delete("/api/system/backups", queryItems: [
            URLQueryItem(name: "filename", value: try backupFilename(for: backup))
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

    // MARK: - Remote Path Mappings

    func getRemotePathMappings() async throws -> [ArrRemotePathMapping] {
        let settings = try await getSettings()
        return Self.remotePathMappings(from: settings, source: .sonarr)
            + Self.remotePathMappings(from: settings, source: .radarr)
    }

    func createRemotePathMapping(_ mapping: ArrRemotePathMapping) async throws -> ArrRemotePathMapping {
        let source = BazarrRemotePathMappingSource(mappingID: mapping.id, host: mapping.host)
        let settings = try await getSettings()
        var mappings = Self.remotePathMappings(from: settings, source: source)
        let nextID = (mappings.map(\.id).max() ?? source.idOffset) + 1
        var saved = mapping
        saved.id = nextID
        saved.host = source.rawValue
        mappings.append(saved)
        try await saveBazarrRemotePathMappings(mappings, source: source, settings: settings)
        return saved
    }

    func updateRemotePathMapping(_ mapping: ArrRemotePathMapping) async throws -> ArrRemotePathMapping {
        let source = BazarrRemotePathMappingSource(mappingID: mapping.id, host: mapping.host)
        let settings = try await getSettings()
        var mappings = Self.remotePathMappings(from: settings, source: source)
        guard let index = mappings.firstIndex(where: { $0.id == mapping.id }) else {
            throw ArrError.invalidResponse
        }
        var saved = mapping
        saved.host = source.rawValue
        mappings[index] = saved
        try await saveBazarrRemotePathMappings(mappings, source: source, settings: settings)
        return saved
    }

    func deleteRemotePathMapping(id: Int) async throws {
        let source = BazarrRemotePathMappingSource(mappingID: id, host: "")
        let settings = try await getSettings()
        var mappings = Self.remotePathMappings(from: settings, source: source)
        mappings.removeAll { $0.id == id }
        try await saveBazarrRemotePathMappings(mappings, source: source, settings: settings)
    }

    private func saveBazarrRemotePathMappings(
        _ mappings: [ArrRemotePathMapping],
        source: BazarrRemotePathMappingSource,
        settings: [String: JSONValue]
    ) async throws {
        var formItems = Self.formItems(for: mappings, source: source)

        let otherSource: BazarrRemotePathMappingSource = source == .sonarr ? .radarr : .sonarr
        formItems.append(contentsOf: Self.formItems(
            for: Self.remotePathMappings(from: settings, source: otherSource),
            source: otherSource
        ))

        try await saveSettings(formItems)
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
        let formItems: [URLQueryItem]
        if codes.isEmpty {
            formItems = [URLQueryItem(name: "languages-enabled", value: "")]
        } else {
            formItems = codes.map {
                URLQueryItem(name: "languages-enabled", value: $0)
            }
        }
        try await saveSettings(formItems)
    }

    func saveLanguageProfiles(_ profiles: [BazarrLanguageProfile]) async throws {
        let encoder = JSONEncoder()
        let payload = profiles.map(BazarrLanguageProfileSettingsPayload.init(profile:))
        let jsonData = try encoder.encode(payload)
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

    private nonisolated static func remotePathMappings(
        from settings: [String: JSONValue],
        source: BazarrRemotePathMappingSource
    ) -> [ArrRemotePathMapping] {
        guard case .object(let general)? = settings["general"],
              let value = general[source.jsonKey] else {
            return []
        }

        return mappingPairs(from: value).enumerated().map { index, pair in
            ArrRemotePathMapping(
                id: source.idOffset + index + 1,
                host: source.rawValue,
                remotePath: pair.0,
                localPath: pair.1
            )
        }
    }

    private nonisolated static func mappingPairs(from value: JSONValue) -> [(String, String)] {
        switch value {
        case .array(let values):
            values.compactMap(mappingPair(from:))
        case .string(let string):
            mappingPair(from: string).map { [$0] } ?? []
        case .number, .bool, .object, .null:
            []
        }
    }

    private nonisolated static func mappingPair(from value: JSONValue) -> (String, String)? {
        switch value {
        case .array(let values):
            let strings = values.compactMap { item -> String? in
                guard case .string(let string) = item else { return nil }
                return string
            }
            guard strings.count >= 2 else { return nil }
            return (strings[0], strings[1])
        case .string(let string):
            return mappingPair(from: string)
        case .number, .bool, .object, .null:
            return nil
        }
    }

    private nonisolated static func mappingPair(from string: String) -> (String, String)? {
        let parts = string
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private nonisolated static func formItems(
        for mappings: [ArrRemotePathMapping],
        source: BazarrRemotePathMappingSource
    ) -> [URLQueryItem] {
        let key = source.settingsKey
        guard !mappings.isEmpty else {
            return [URLQueryItem(name: key, value: "")]
        }

        return mappings.map {
            URLQueryItem(name: key, value: "\($0.remotePath),\($0.localPath)")
        }
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
        guard seriesIds.count == profileIds.count else {
            throw ArrError.profileSelectionCountMismatch(itemCount: seriesIds.count, profileCount: profileIds.count)
        }

        var formItems: [URLQueryItem] = []
        for (index, id) in seriesIds.enumerated() {
            formItems.append(URLQueryItem(name: "seriesid", value: String(id)))
            formItems.append(URLQueryItem(name: "profileid", value: profileIds[index] ?? "null"))
        }
        try await base.postFormItems("/api/series", formItems: formItems)
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
        guard radarrIds.count == profileIds.count else {
            throw ArrError.profileSelectionCountMismatch(itemCount: radarrIds.count, profileCount: profileIds.count)
        }

        var formItems: [URLQueryItem] = []
        for (index, id) in radarrIds.enumerated() {
            formItems.append(URLQueryItem(name: "radarrid", value: String(id)))
            formItems.append(URLQueryItem(name: "profileid", value: profileIds[index] ?? "null"))
        }
        try await base.postFormItems("/api/movies", formItems: formItems)
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

    // MARK: - Logs

    func getLogs(start: Int = 0, length: Int = 50) async throws -> BazarrPage<BazarrLogEntry> {
        try await base.get("/api/system/logs", queryItems: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "length", value: String(length))
        ])
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

    private func backupFilename(for backup: ArrBackup) throws -> String {
        let filename = (backup.path ?? backup.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else { throw ArrError.invalidResponse }
        return filename
    }
}

nonisolated private struct BazarrBackup: Decodable, Sendable {
    let date: String
    let filename: String
    let size: String
    let type: String

    var arrBackup: ArrBackup {
        ArrBackup(
            id: Self.stableID(for: filename),
            name: filename,
            type: type,
            time: Self.isoTime(from: date),
            size: Self.byteCount(from: size),
            path: filename
        )
    }

    private static func stableID(for filename: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in filename.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash & UInt64(Int.max))
    }

    private static func isoTime(from dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM dd yyyy"

        guard let date = formatter.date(from: dateString) else {
            return dateString
        }

        return ISO8601DateFormatter().string(from: date)
    }

    private static func byteCount(from sizeString: String) -> Int? {
        let parts = sizeString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        guard let valuePart = parts.first, let value = Double(valuePart) else {
            return nil
        }

        let unit = parts.dropFirst().first?.uppercased() ?? "B"
        let multiplier: Double = switch unit {
        case "B": 1
        case "KB": 1_000
        case "MB": 1_000_000
        case "GB": 1_000_000_000
        case "TB": 1_000_000_000_000
        case "PB": 1_000_000_000_000_000
        default: 1
        }
        return Int(value * multiplier)
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
