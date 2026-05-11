import Foundation
import OSLog

protocol SharedArrClient: Actor {
    var base: ArrAPIClient { get }
    var apiPath: String { get }
}

extension SharedArrClient {
    var apiPath: String { "/api/v3" }

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

    func getDiskSpace() async throws -> [ArrDiskSpace] { try await base.get("\(apiPath)/diskspace") }
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

    func getManualImport(
        folder: String,
        libraryItemId: Int? = nil,
        libraryItemIDQueryName: String,
        filterExistingFiles: Bool = true
    ) async throws -> [JSONValue] {
        var params = [
            URLQueryItem(name: "folder", value: folder),
            URLQueryItem(name: "filterExistingFiles", value: String(filterExistingFiles))
        ]
        if let libraryItemId {
            params.append(URLQueryItem(name: libraryItemIDQueryName, value: String(libraryItemId)))
        }
        return try await base.get("\(apiPath)/manualimport", queryItems: params)
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

    let baseURL: String
    private let apiKey: String
    private let session: URLSession
    private let trustPolicy: ServerTrustPolicy

    let apiKeyHeaderName: String

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false, apiKeyHeaderName: String = "X-Api-Key") {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.apiKey = apiKey
        self.apiKeyHeaderName = apiKeyHeaderName
        self.trustPolicy = ServerTrustPolicy(allowsUntrustedTLS: allowsUntrustedTLS)

        let config = URLSessionConfiguration.makeTrawlSecure()
        self.session = URLSession(configuration: config, delegate: trustPolicy, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Shared Endpoints

    func getSystemStatus() async throws -> ArrSystemStatus {
        try await get("/api/v3/system/status")
    }

    func getHealth() async throws -> [ArrHealthCheck] {
        try await get("/api/v3/health")
    }

    func getQualityProfiles() async throws -> [ArrQualityProfile] {
        try await get("/api/v3/qualityprofile")
    }

    func createQualityProfile(_ profile: ArrQualityProfile) async throws -> ArrQualityProfile {
        try await postCodable("/api/v3/qualityprofile", body: profile)
    }

    func updateQualityProfile(_ profile: ArrQualityProfile) async throws -> ArrQualityProfile {
        try await putCodable("/api/v3/qualityprofile/\(profile.id)", body: profile)
    }

    func deleteQualityProfile(id: Int) async throws {
        try await delete("/api/v3/qualityprofile/\(id)")
    }

    func getRootFolders() async throws -> [ArrRootFolder] {
        try await get("/api/v3/rootfolder")
    }

    func createRootFolder(path: String) async throws -> ArrRootFolder {
        try await postCodable("/api/v3/rootfolder", body: ["path": path])
    }

    func deleteRootFolder(id: Int) async throws {
        try await delete("/api/v3/rootfolder/\(id)")
    }

    func getFileSystem(path: String = "", includeFiles: Bool = false) async throws -> [ArrFileSystemEntry] {
        let response: ArrFileSystemResponse = try await get("/api/v3/filesystem", queryItems: Self.fileSystemQueryItems(path: path, includeFiles: includeFiles))
        return response.entries
    }

    nonisolated static func fileSystemQueryItems(path: String, includeFiles: Bool) -> [URLQueryItem] {
        [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "allowFoldersWithoutTrailingSlashes", value: "true"),
            URLQueryItem(name: "includeFiles", value: String(includeFiles))
        ]
    }

    func getTags() async throws -> [ArrTag] {
        try await get("/api/v3/tag")
    }

    func getNotifications() async throws -> [ArrNotification] {
        try await get("/api/v3/notification")
    }

    func createNotification(_ notification: ArrNotification) async throws -> ArrNotification {
        try await postCodable("/api/v3/notification", body: notification)
    }

    func updateNotification(_ notification: ArrNotification) async throws -> ArrNotification {
        guard let id = notification.id else { throw ArrError.invalidResponse }
        return try await putCodable("/api/v3/notification/\(id)", body: notification)
    }

    func getQueue(
        page: Int = 1,
        pageSize: Int = defaultPageSize,
        includeUnknownMovieItems: Bool = true
    ) async throws -> ArrQueuePage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "includeUnknownMovieItems", value: String(includeUnknownMovieItems)),
            URLQueryItem(name: "includeUnknownSeriesItems", value: "true")
        ]
        return try await get("/api/v3/queue", queryItems: params)
    }

    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        let params = [
            URLQueryItem(name: "removeFromClient", value: String(removeFromClient)),
            URLQueryItem(name: "blocklist", value: String(blocklist))
        ]
        try await delete("/api/v3/queue/\(id)", queryItems: params)
    }

    func getHistory(
        page: Int = 1,
        pageSize: Int = defaultPageSize,
        sortKey: String = "date",
        sortDirection: String = "descending"
    ) async throws -> ArrHistoryPage {
        let params = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "sortKey", value: sortKey),
            URLQueryItem(name: "sortDirection", value: sortDirection)
        ]
        return try await get("/api/v3/history", queryItems: params)
    }

    func getDiskSpace() async throws -> [ArrDiskSpace] {
        try await get("/api/v3/diskspace")
    }

    func getUpdates() async throws -> [ArrUpdateInfo] {
        try await get("/api/v3/update")
    }

    func getDownloadClients() async throws -> [ArrDownloadClient] {
        try await get("/api/v3/downloadclient")
    }

    func getDownloadClientSchema() async throws -> [ArrDownloadClient] {
        try await get("/api/v3/downloadclient/schema")
    }

    func createDownloadClient(_ client: ArrDownloadClient) async throws -> ArrDownloadClient {
        try await postCodable("/api/v3/downloadclient", body: client)
    }

    func updateDownloadClient(_ client: ArrDownloadClient) async throws -> ArrDownloadClient {
        try await putCodable("/api/v3/downloadclient/\(client.id)", body: client)
    }

    func deleteDownloadClient(id: Int) async throws {
        try await delete("/api/v3/downloadclient/\(id)")
    }

    func testDownloadClient(_ client: ArrDownloadClient) async throws {
        try await postVoidCodable("/api/v3/downloadclient/test", body: client)
    }

    func getRemotePathMappings() async throws -> [ArrRemotePathMapping] {
        try await get("/api/v3/remotepathmapping")
    }

    func createRemotePathMapping(_ mapping: ArrRemotePathMapping) async throws -> ArrRemotePathMapping {
        try await postCodable("/api/v3/remotepathmapping", body: mapping)
    }

    func updateRemotePathMapping(_ mapping: ArrRemotePathMapping) async throws -> ArrRemotePathMapping {
        try await putCodable("/api/v3/remotepathmapping/\(mapping.id)", body: mapping)
    }

    func deleteRemotePathMapping(id: Int) async throws {
        try await delete("/api/v3/remotepathmapping/\(id)")
    }

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

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> sending T {
        let request = try buildRequest(path: path, method: "GET", queryItems: queryItems)
        return try await perform(request)
    }

    func post<T: Decodable>(_ path: String, jsonBody: Any) async throws -> sending T {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await perform(request)
    }

    func postCodable<T: Decodable, B: Encodable>(_ path: String, body: sending B) async throws -> sending T {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    func putCodable<T: Decodable, B: Encodable>(_ path: String, body: sending B, queryItems: [URLQueryItem] = []) async throws -> sending T {
        var request = try buildRequest(path: path, method: "PUT", queryItems: queryItems)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    func delete(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try buildRequest(path: path, method: "DELETE", queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, path: path)
    }

    /// DELETE with a JSON body (e.g. bulk blocklist delete)
    func deleteWithBody(_ path: String, jsonBody: Any) async throws {
        var request = try buildRequest(path: path, method: "DELETE")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, path: path)
    }

    /// Fire-and-forget POST (for commands that return empty body)
    func postVoid(_ path: String, jsonBody: Any) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, path: path)
    }

    /// Fire-and-forget POST with query parameters.
    func postVoid(_ path: String, queryItems: [URLQueryItem]) async throws {
        let request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, path: path)
    }

    /// Fire-and-forget PATCH with query parameters.
    func patchVoid(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try buildRequest(path: path, method: "PATCH", queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, path: path)
    }

    /// Fire-and-forget POST with a Codable body (for commands that return empty body)
    func postVoidCodable<B: Encodable>(_ path: String, body: sending B) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, path: path)
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
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = formItems
        request.httpBody = components.query?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data, path: path)
    }

    // MARK: - Private

    private func buildRequest(path: String, method: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw ArrError.invalidURL
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw ArrError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: apiKeyHeaderName)
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> sending T {
        let data: Data
        let response: URLResponse
        let path = request.url?.path ?? "<unknown>"
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if isRequestCancellation(error) {
                throw CancellationError()
            }
            
            logReleaseDiagnostics(
                message: "Network error",
                path: path,
                request: request,
                responseData: nil,
                error: error
            )
            throw ArrError.networkError(error)
        }
        
        try validateResponse(response, data: data, path: path)
        
        do {
            return try Self.decodeResponse(T.self, from: data)
        } catch {
            logReleaseDiagnostics(
                message: "Decoding error",
                path: path,
                request: request,
                responseData: data,
                error: error
            )
            throw ArrError.decodingError(error)
        }
    }

    private nonisolated static func decodeResponse<T: Decodable>(_ type: sending T.Type, from data: Data) throws -> sending T {
        try JSONDecoder().decode(type, from: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ArrError.invalidResponse
        }

        if http.statusCode == 401 {
            throw ArrError.invalidAPIKey
        }

        guard (200..<400).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            Self.logger.error("Arr request failed for \(path, privacy: .public) with status \(http.statusCode)")
            
            Self.logger.debug("Arr request failure body for \(path, privacy: .public): \(body, privacy: .private)")
            
            logReleaseDiagnostics(
                message: "HTTP error \(http.statusCode)",
                path: path,
                request: nil,
                responseData: data,
                error: nil
            )
            throw ArrError.serverError(statusCode: http.statusCode, message: body)
        }
    }

    private func logReleaseDiagnostics(
        message: String,
        path: String,
        request: URLRequest?,
        responseData: Data?,
        error: Error?
    ) {
        guard path.contains("/api/v3/release") else { return }

        let urlString = request?.url?.absoluteString ?? "\(baseURL)\(path)"
        Self.logger.error("Interactive search diagnostic: \(message, privacy: .public)")
        Self.logger.error("Interactive search URL: \(urlString, privacy: .private)")

        if let error {
            Self.logger.error("Interactive search error: \(error.localizedDescription, privacy: .private)")
        }

        if let responseData,
           let body = String(data: responseData, encoding: .utf8),
           !body.isEmpty {
            Self.logger.error("Interactive search response body: \(body, privacy: .private)")
        }
    }
    
    private func isRequestCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
