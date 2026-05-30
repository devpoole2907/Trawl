import Foundation
import OSLog

protocol SharedArrClient: Actor, Sendable {
    var base: ArrAPIClient { get }
    var apiPath: String { get }
    var importListExclusionsPath: String { get }

    func getBackups() async throws -> [ArrBackup]
    func createBackup() async throws
    func downloadBackup(_ backup: ArrBackup) async throws -> Data
    func restoreBackup(_ backup: ArrBackup) async throws
    func uploadBackup(data: Data, filename: String) async throws
    func deleteBackup(_ backup: ArrBackup) async throws
}

extension SharedArrClient {
    var apiPath: String { "/api/v3" }
    var importListExclusionsPath: String { "\(apiPath)/importlistexclusion" }

    func getSystemStatus() async throws -> ArrSystemStatus { try await base.get("\(apiPath)/system/status") }
    func getHealth() async throws -> [ArrHealthCheck] { try await base.get("\(apiPath)/health") }
    func getQualityProfiles() async throws -> [ArrQualityProfile] { try await base.get("\(apiPath)/qualityprofile") }
    func createQualityProfile(_ profile: ArrQualityProfile) async throws -> ArrQualityProfile { try await base.postCodable("\(apiPath)/qualityprofile", body: profile) }
    func updateQualityProfile(_ profile: ArrQualityProfile) async throws -> ArrQualityProfile { try await base.putCodable("\(apiPath)/qualityprofile/\(profile.id)", body: profile) }
    func deleteQualityProfile(id: Int) async throws { try await base.delete("\(apiPath)/qualityprofile/\(id)") }
    func getRootFolders() async throws -> [ArrRootFolder] { try await base.get("\(apiPath)/rootfolder") }
    func createRootFolder(path: String) async throws -> ArrRootFolder { try await base.postCodable("\(apiPath)/rootfolder", body: ["path": path]) }
    func deleteRootFolder(id: Int) async throws { try await base.delete("\(apiPath)/rootfolder/\(id)") }
    func getFileSystem(path: String = "", includeFiles: Bool = false) async throws -> [ArrFileSystemEntry] {
        let response: ArrFileSystemResponse = try await base.get("\(apiPath)/filesystem", queryItems: Self.fileSystemQueryItems(path: path, includeFiles: includeFiles))
        return response.entries
    }
    func getTags() async throws -> [ArrTag] { try await base.get("\(apiPath)/tag") }
    func getNotifications() async throws -> [ArrNotification] { try await base.get("\(apiPath)/notification") }
    func createNotification(_ notification: ArrNotification) async throws -> ArrNotification { try await base.postCodable("\(apiPath)/notification", body: notification) }
    func updateNotification(_ notification: ArrNotification) async throws -> ArrNotification {
        guard let id = notification.id else { throw ArrError.invalidResponse }
        return try await base.putCodable("\(apiPath)/notification/\(id)", body: notification)
    }
    func testNotification(_ notification: ArrNotification) async throws { try await base.postVoidCodable("\(apiPath)/notification/test", body: notification) }

    func getQueue(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize,
        includeUnknownMovieItems: Bool = true
    ) async throws -> ArrQueuePage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "includeUnknownMovieItems", value: String(includeUnknownMovieItems)),
            URLQueryItem(name: "includeUnknownSeriesItems", value: "true")
        ]
        return try await base.get("\(apiPath)/queue", queryItems: params)
    }

    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        let params = [
            URLQueryItem(name: "removeFromClient", value: String(removeFromClient)),
            URLQueryItem(name: "blocklist", value: String(blocklist))
        ]
        try await base.delete("\(apiPath)/queue/\(id)", queryItems: params)
    }

    func getHistory(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize
    ) async throws -> ArrHistoryPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "date"),
            URLQueryItem(name: "sortDirection", value: "descending")
        ]
        return try await base.get("\(apiPath)/history", queryItems: params)
    }

    func getLog(
        page: Int = 1,
        pageSize: Int = 50,
        level: String? = nil
    ) async throws -> ArrLogPage {
        var params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "time"),
            URLQueryItem(name: "sortDirection", value: "descending")
        ]
        if let level { params.append(URLQueryItem(name: "level", value: level)) }
        return try await base.get("\(apiPath)/log", queryItems: params)
    }

    func getDiskSpace() async throws -> [ArrDiskSpace] { try await base.get("\(apiPath)/diskspace") }
    func getBackups() async throws -> [ArrBackup] { try await base.get("\(apiPath)/system/backup") }
    func createBackup() async throws { _ = try await postCommand(name: "Backup") }
    func downloadBackup(_ backup: ArrBackup) async throws -> Data {
        let backupPath = backup.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let backupPath, !backupPath.isEmpty else {
            return try await base.getData("\(apiPath)/system/backup/\(backup.id)/download")
        }

        let path = backupPath.hasPrefix("/") ? backupPath : "/\(backupPath)"
        return try await base.getData(path)
    }
    func restoreBackup(id: Int) async throws { try await base.postVoid("\(apiPath)/system/backup/restore/\(id)", queryItems: []) }
    func restoreBackup(_ backup: ArrBackup) async throws { try await restoreBackup(id: backup.id) }
    func uploadBackup(data: Data, filename: String) async throws { try await base.postMultipartVoid("\(apiPath)/system/backup/restore/upload", fileData: data, fieldName: "restore", filename: filename) }
    func deleteBackup(id: Int) async throws { try await base.delete("\(apiPath)/system/backup/\(id)") }
    func deleteBackup(_ backup: ArrBackup) async throws { try await deleteBackup(id: backup.id) }
    func getUpdates() async throws -> [ArrUpdateInfo] { try await base.get("\(apiPath)/update") }
    func getDownloadClients() async throws -> [ArrDownloadClient] { try await base.get("\(apiPath)/downloadclient") }
    func getDownloadClientSchema() async throws -> [ArrDownloadClient] { try await base.get("\(apiPath)/downloadclient/schema") }
    func createDownloadClient(_ client: ArrDownloadClient) async throws -> ArrDownloadClient { try await base.postCodable("\(apiPath)/downloadclient", body: client) }
    func updateDownloadClient(_ client: ArrDownloadClient) async throws -> ArrDownloadClient { try await base.putCodable("\(apiPath)/downloadclient/\(client.id)", body: client) }
    func deleteDownloadClient(id: Int) async throws { try await base.delete("\(apiPath)/downloadclient/\(id)") }
    func testDownloadClient(_ client: ArrDownloadClient) async throws { try await base.postVoidCodable("\(apiPath)/downloadclient/test", body: client) }
    func getRemotePathMappings() async throws -> [ArrRemotePathMapping] { try await base.get("\(apiPath)/remotepathmapping") }
    func createRemotePathMapping(_ mapping: ArrRemotePathMapping) async throws -> ArrRemotePathMapping { try await base.postCodable("\(apiPath)/remotepathmapping", body: mapping) }
    func updateRemotePathMapping(_ mapping: ArrRemotePathMapping) async throws -> ArrRemotePathMapping { try await base.putCodable("\(apiPath)/remotepathmapping/\(mapping.id)", body: mapping) }
    func deleteRemotePathMapping(id: Int) async throws { try await base.delete("\(apiPath)/remotepathmapping/\(id)") }

    func getBlocklist(page: Int = 1, pageSize: Int = ArrAPIClient.defaultPageSize) async throws -> ArrBlocklistPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: "date"),
            URLQueryItem(name: "sortDirection", value: "descending")
        ]
        return try await base.get("\(apiPath)/blocklist", queryItems: params)
    }

    func deleteBlocklistItem(id: Int) async throws {
        try await base.delete("\(apiPath)/blocklist/\(id)")
    }

    func deleteBlocklistItems(ids: [Int]) async throws {
        try await base.deleteWithBody("\(apiPath)/blocklist/bulk", jsonBody: ["ids": ids])
    }

    func getImportListExclusions(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize
    ) async throws -> ArrImportListExclusionPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize))
        ]
        return try await base.get("\(importListExclusionsPath)/paged", queryItems: params)
    }

    func deleteImportListExclusion(id: Int) async throws {
        try await base.delete("\(importListExclusionsPath)/\(id)")
    }

    func getManualImport(
        folder: String,
        libraryItemId: Int? = nil,
        libraryItemIDQueryName: String,
        filterExistingFiles: Bool = true,
        requestTimeout: TimeInterval? = nil
    ) async throws -> [JSONValue] {
        var params = [
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "filterExistingFiles", value: String(filterExistingFiles))
        ]
        if let libraryItemId {
            params.append(URLQueryItem(name: libraryItemIDQueryName, value: String(libraryItemId)))
        }
        return try await base.get("\(apiPath)/manualimport", queryItems: params, timeoutInterval: requestTimeout)
    }

    func manualImport(files: [JSONValue], importMode: String = "move") async throws -> ArrCommand {
        let additionalParams: [String: JSONValue] = [
            "files": .array(files),
            "importMode": .string(importMode)
        ]
        return try await postCommandAndWait(
            name: "ManualImport",
            additionalParams: additionalParams,
            timeout: .seconds(600)
        )
    }

    func getNamingConfig<T: Decodable>() async throws -> sending T {
        try await base.get("\(apiPath)/config/naming")
    }

    func updateNamingConfig<T: Codable & ArrAPIOptionalIdentifiable>(_ config: sending T) async throws -> sending T {
        guard let id = config.id else { throw ArrError.invalidResponse }
        return try await base.putCodable("\(apiPath)/config/naming/\(id)", body: config)
    }

    func getIndexers<T: Decodable>() async throws -> sending [T] {
        try await base.get("\(apiPath)/indexer")
    }

    func getIndexer<T: Decodable>(id: Int) async throws -> sending T {
        try await base.get("\(apiPath)/indexer/\(id)")
    }

    func getIndexerSchema<T: Decodable>() async throws -> sending [T] {
        try await base.get("\(apiPath)/indexer/schema")
    }

    func createIndexer<T: Codable>(_ indexer: sending T) async throws -> sending T {
        try await base.postCodable("\(apiPath)/indexer", body: indexer)
    }

    func updateIndexer<T: Codable & ArrAPIIdentifiable>(_ indexer: sending T) async throws -> sending T {
        try await base.putCodable("\(apiPath)/indexer/\(indexer.id)", body: indexer)
    }

    func deleteIndexer(id: Int) async throws {
        try await base.delete("\(apiPath)/indexer/\(id)")
    }

    func testIndexer<T: Encodable>(_ indexer: sending T) async throws {
        try await base.postVoidCodable("\(apiPath)/indexer/test", body: indexer)
    }

    func getQualityDefinitions() async throws -> [ArrQualityDefinition] {
        try await base.get("\(apiPath)/qualitydefinition")
    }

    func updateQualityDefinitions(_ definitions: [ArrQualityDefinition]) async throws -> [ArrQualityDefinition] {
        try await base.putCodable("\(apiPath)/qualitydefinition/update", body: definitions)
    }

    func getScheduledTasks() async throws -> [ArrScheduledTask] {
        try await base.get("\(apiPath)/system/task")
    }

    func getCommandQueue() async throws -> [ArrCommand] {
        try await base.get("\(apiPath)/command")
    }

    func getCommand(id: Int) async throws -> ArrCommand {
        try await base.getCommand(id: id, apiPath: apiPath)
    }

    func postCommand(name: String, additionalParams: [String: JSONValue]? = nil) async throws -> ArrCommand {
        try await base.postCommand(name: name, additionalParams: additionalParams, apiPath: apiPath)
    }

    func postCommandAndWait(
        name: String,
        additionalParams: [String: JSONValue]? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> ArrCommand {
        try await base.postCommandAndWait(name: name, additionalParams: additionalParams, timeout: timeout, apiPath: apiPath)
    }

    func calendarDateParam(name: String, value: Date?) -> URLQueryItem? {
        guard let value else { return nil }
        return URLQueryItem(name: name, value: ISO8601DateFormatter().string(from: value))
    }

    nonisolated func webcalURL(from url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ArrError.invalidURL
        }
        components.scheme = "webcal"
        guard let webcalURL = components.url else {
            throw ArrError.invalidURL
        }
        return webcalURL
    }

    func wantedMissingParams(
        page: Int,
        pageSize: Int,
        sortKey: String,
        sortDirection: String,
        extraItems: [URLQueryItem] = []
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: sortKey),
            URLQueryItem(name: "sortDirection", value: sortDirection)
        ] + extraItems
    }

    nonisolated static func fileSystemQueryItems(path: String, includeFiles: Bool) -> [URLQueryItem] {
        [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "allowFoldersWithoutTrailingSlashes", value: "true"),
            URLQueryItem(name: "includeFiles", value: String(includeFiles))
        ]
    }
}

protocol ArrAPIIdentifiable {
    nonisolated var id: Int { get }
}

protocol ArrAPIOptionalIdentifiable {
    nonisolated var id: Int? { get }
}

/// Base actor handling shared HTTP infrastructure for all *arr services.
/// Both SonarrAPIClient and RadarrAPIClient build on this.
actor ArrAPIClient {
    private static let logger = Logger(subsystem: "com.poole.james.Trawl", category: "ArrAPIClient")
    static let defaultPageSize = 20

    nonisolated var baseURL: String { transport.baseURL }
    let apiKeyHeaderName: String
    private let apiKey: String
    private let transport: HTTPTransport

    /// Re-exposed here (also lives on `SharedArrClient`) so tests and
    /// non-conforming call sites can build the standard filesystem query
    /// without going through a service-specific actor.
    nonisolated static func fileSystemQueryItems(path: String, includeFiles: Bool) -> [URLQueryItem] {
        [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "allowFoldersWithoutTrailingSlashes", value: "true"),
            URLQueryItem(name: "includeFiles", value: String(includeFiles))
        ]
    }

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false, apiKeyHeaderName: String = "X-Api-Key") {
        self.apiKeyHeaderName = apiKeyHeaderName
        self.apiKey = apiKey
        let mapper = HTTPErrorMapper(
            badURL: { ArrError.invalidURL },
            transport: { ArrError.networkError($0) },
            unauthorized: { ArrError.invalidAPIKey },
            http: { code, body in ArrError.serverError(statusCode: code, message: body) },
            decode: { ArrError.decodingError($0) },
            invalidResponse: { ArrError.invalidResponse },
            unauthorizedStatusCodes: [401]
        )
        let diagnostics = HTTPDiagnostics(
            shouldLog: { $0.contains("/api/v3/release") },
            networkError: { path, _, error in
                Self.logger.error("Interactive search diagnostic: Network error")
                Self.logger.error("Interactive search path: \(path, privacy: .public)")
                Self.logger.error("Interactive search error: \(error.localizedDescription, privacy: .private)")
            },
            httpError: { path, url, code, data in
                Self.logger.error("Arr request failed for \(path, privacy: .public) with status \(code)")
                if let data, let body = String(data: data, encoding: .utf8) {
                    Self.logger.debug("Arr request failure body for \(path, privacy: .public): \(body, privacy: .private)")
                    Self.logger.error("Interactive search diagnostic: HTTP error \(code)")
                    Self.logger.error("Interactive search URL: \(url, privacy: .private)")
                    if !body.isEmpty {
                        Self.logger.error("Interactive search response body: \(body, privacy: .private)")
                    }
                }
            },
            decodingError: { path, url, error, data in
                Self.logger.error("Interactive search diagnostic: Decoding error")
                Self.logger.error("Interactive search URL: \(url, privacy: .private)")
                Self.logger.error("Interactive search error: \(error.localizedDescription, privacy: .private)")
                if let data, let body = String(data: data, encoding: .utf8), !body.isEmpty {
                    Self.logger.error("Interactive search response body: \(body, privacy: .private)")
                }
                _ = path
            }
        )
        self.transport = HTTPTransport(
            baseURL: baseURL,
            auth: .staticHeader(name: apiKeyHeaderName, value: apiKey),
            allowsUntrustedTLS: allowsUntrustedTLS,
            sessionConfiguration: .makeTrawlSecure(),
            errorMapper: mapper,
            diagnostics: diagnostics
        )
    }

    // MARK: - Command primitives (per-service apiPath)
    // The "shared endpoints" (getSystemStatus, getQualityProfiles, getRootFolders, getTags,
    // getQueue, getHistory, getDownloadClients, getRemotePathMappings, etc.) live on the
    // SharedArrClient protocol extension above, which parametrises on `apiPath` so each
    // conformer (Sonarr /api/v3, Radarr /api/v3, Prowlarr /api/v1, Bazarr /api) hits the
    // right endpoint. Only command-related calls live on the actor because they're invoked
    // directly via `base.postCommand(...)` from the conforming clients.

    func getCommand(id: Int, apiPath: String = "/api/v3") async throws -> ArrCommand {
        return try await get("\(apiPath)/command/\(id)")
    }

    /// Posts a command and polls until it reaches a terminal state (completed/failed) or the timeout elapses.
    /// Throws ArrError.commandTimeout if the command does not reach a terminal state within the timeout period.
    func postCommandAndWait(
        name: String,
        additionalParams: [String: JSONValue]? = nil,
        timeout: Duration = .seconds(30),
        apiPath: String = "/api/v3"
    ) async throws -> ArrCommand {
        let command = try await postCommand(name: name, additionalParams: additionalParams, apiPath: apiPath)
        guard let commandId = command.id else { return command }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            do {
                let updated = try await getCommand(id: commandId, apiPath: apiPath)
                if updated.isTerminal { return updated }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Transient network error — continue polling until deadline
            }
        }
        // Timed out — fetch final state and throw if non-terminal
        let finalCommand = (try? await getCommand(id: commandId, apiPath: apiPath)) ?? command
        if !finalCommand.isTerminal {
            throw ArrError.commandTimeout(commandId: commandId, lastKnownCommand: finalCommand)
        }
        return finalCommand
    }

    func postCommand(
        name: String,
        additionalParams: [String: JSONValue]? = nil,
        apiPath: String = "/api/v3"
    ) async throws -> ArrCommand {
        var body: [String: JSONValue] = ["name": .string(name)]
        if let params = additionalParams {
            for (key, value) in params { body[key] = value }
        }
        return try await postCodable("\(apiPath)/command", body: body)
    }

    // MARK: - HTTP Infrastructure

    func get<T: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        timeoutInterval: TimeInterval? = nil
    ) async throws -> sending T {
        try await transport.get(path, queryItems: queryItems, timeoutInterval: timeoutInterval)
    }

    func getData(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        try await transport.getData(path, queryItems: queryItems)
    }

    func authenticatedFeedURL(_ path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        var items = queryItems
        items.append(URLQueryItem(name: "apikey", value: apiKey))
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw ArrError.invalidURL
        }
        components.queryItems = items
        guard let url = components.url else {
            throw ArrError.invalidURL
        }
        return url
    }

    func post<T: Decodable>(_ path: String, jsonBody: sending Any) async throws -> sending T {
        try await transport.postJSON(path, jsonBody: jsonBody)
    }

    func postCodable<T: Decodable, B: Encodable>(_ path: String, body: sending B) async throws -> sending T {
        try await transport.postCodable(path, body: body)
    }

    func putCodable<T: Decodable, B: Encodable>(_ path: String, body: sending B, queryItems: [URLQueryItem] = []) async throws -> sending T {
        try await transport.putCodable(path, body: body, queryItems: queryItems)
    }

    func delete(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        try await transport.delete(path, queryItems: queryItems)
    }

    /// DELETE with a JSON body (e.g. bulk blocklist delete)
    func deleteWithBody(_ path: String, jsonBody: sending Any) async throws {
        try await transport.deleteJSONBody(path, jsonBody: jsonBody)
    }

    /// Fire-and-forget POST (for commands that return empty body)
    func postVoid(_ path: String, jsonBody: sending Any) async throws {
        try await transport.postVoidJSON(path, jsonBody: jsonBody)
    }

    /// Fire-and-forget POST with query parameters.
    func postVoid(_ path: String, queryItems: [URLQueryItem]) async throws {
        try await transport.postVoid(path, queryItems: queryItems)
    }

    /// Fire-and-forget PATCH with query parameters.
    func patchVoid(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        try await transport.patchVoid(path, queryItems: queryItems)
    }

    /// Fire-and-forget POST with a Codable body (for commands that return empty body)
    func postVoidCodable<B: Encodable>(_ path: String, body: sending B) async throws {
        try await transport.postVoidCodable(path, body: body)
    }

    func postMultipartVoid(_ path: String, fileData: Data, fieldName: String, filename: String) async throws {
        try await transport.postMultipartVoid(path, fileData: fileData, fieldName: fieldName, filename: filename)
    }

    /// POST with form-urlencoded body (used by Bazarr settings endpoint)
    func postForm(_ path: String, formFields: [String: String]) async throws {
        try await postFormItems(
            path,
            formItems: formFields.map { URLQueryItem(name: $0.key, value: $0.value) }
        )
    }

    /// POST with form-urlencoded body preserving repeated keys and empty list sentinels.
    func postFormItems(_ path: String, formItems: [URLQueryItem]) async throws {
        try await transport.postFormItems(path, formItems: formItems)
    }
}
