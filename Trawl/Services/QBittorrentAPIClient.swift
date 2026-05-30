import Foundation

actor QBittorrentAPIClient {
    let authService: AuthService
    private let session: URLSession
    private let trustPolicy: ServerTrustPolicy
    private let baseURL: String
    private let serverProfileID: UUID

    init(baseURL: String, authService: AuthService, allowsUntrustedTLS: Bool = false) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.authService = authService
        self.serverProfileID = authService.serverProfileID
        self.trustPolicy = ServerTrustPolicy(allowsUntrustedTLS: allowsUntrustedTLS)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: trustPolicy, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Auth

    func login(username: String, password: String) async throws {
        try await authService.login(hostURL: baseURL, username: username, password: password)
    }

    func logout() async throws {
        let request = try buildRequest(path: "/api/v2/auth/logout", method: "POST")
        _ = try? await performRequest(request)
        await authService.logout()
    }

    // MARK: - App

    func getAppVersion() async throws -> String {
        let request = try buildRequest(path: "/api/v2/app/version")
        let (data, _) = try await performRequest(request)
        guard let version = String(data: data, encoding: .utf8) else {
            throw QBError.invalidResponse
        }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func getPreferences() async throws -> AppPreferences {
        let request = try buildRequest(path: "/api/v2/app/preferences")
        let (data, _) = try await performRequest(request)
        return try decode(AppPreferences.self, from: data)
    }

    func setDefaultSavePath(_ savePath: String) async throws {
        let payload = ["save_path": savePath]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw QBError.invalidResponse
        }

        let request = try buildFormRequest(
            path: "/api/v2/app/setPreferences",
            params: ["json": jsonString]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to update default save location")
    }

    // MARK: - Torrents

    func getTorrents(filter: String? = nil, category: String? = nil, sort: String? = nil) async throws -> [Torrent] {
        var queryItems: [URLQueryItem] = []
        if let filter { queryItems.append(.init(name: "filter", value: filter)) }
        if let category { queryItems.append(.init(name: "category", value: category)) }
        if let sort { queryItems.append(.init(name: "sort", value: sort)) }

        let request = try buildRequest(path: "/api/v2/torrents/info", queryItems: queryItems)
        let (data, _) = try await performRequest(request)
        return try decode([Torrent].self, from: data)
    }

    /// Lightweight, fault-tolerant variant of `/api/v2/torrents/info` for consumers
    /// (e.g. widgets) that only need a few fields. Every field is optional so a
    /// server that omits a column never fails the whole decode — unlike the strict
    /// `Torrent` model, which the live app fills via `syncMainData` instead.
    func getTorrentSummaries(filter: String? = nil) async throws -> [TorrentInfoSummary] {
        var queryItems: [URLQueryItem] = []
        if let filter { queryItems.append(.init(name: "filter", value: filter)) }

        let request = try buildRequest(path: "/api/v2/torrents/info", queryItems: queryItems)
        let (data, _) = try await performRequest(request)
        return try decode([TorrentInfoSummary].self, from: data)
    }

    func addTorrentMagnet(
        magnetURL: String,
        savePath: String?,
        category: String?,
        paused: Bool,
        sequentialDownload: Bool,
        firstLastPiecePriority: Bool
    ) async throws {
        let boundary = UUID().uuidString
        var request = try buildRequest(path: "/api/v2/torrents/add", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipartField(boundary: boundary, name: "urls", value: magnetURL)
        if let savePath { body.appendMultipartField(boundary: boundary, name: "savepath", value: savePath) }
        if let category { body.appendMultipartField(boundary: boundary, name: "category", value: category) }
        if paused { body.appendMultipartField(boundary: boundary, name: "stopped", value: "true") }
        if sequentialDownload { body.appendMultipartField(boundary: boundary, name: "sequentialDownload", value: "true") }
        if firstLastPiecePriority { body.appendMultipartField(boundary: boundary, name: "firstLastPiecePrio", value: "true") }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (_, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw QBError.serverError(statusCode: response.statusCode, message: "Failed to add torrent")
        }
    }

    func addTorrentFile(
        fileData: Data,
        fileName: String,
        savePath: String?,
        category: String?,
        paused: Bool,
        sequentialDownload: Bool,
        firstLastPiecePriority: Bool
    ) async throws {
        let boundary = UUID().uuidString
        var request = try buildRequest(path: "/api/v2/torrents/add", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // File part
        body.appendMultipart(boundary: boundary, name: "torrents", filename: fileName, data: fileData)

        // Form fields
        if let savePath {
            body.appendMultipartField(boundary: boundary, name: "savepath", value: savePath)
        }
        if let category {
            body.appendMultipartField(boundary: boundary, name: "category", value: category)
        }
        if paused {
            body.appendMultipartField(boundary: boundary, name: "stopped", value: "true")
        }
        if sequentialDownload {
            body.appendMultipartField(boundary: boundary, name: "sequentialDownload", value: "true")
        }
        if firstLastPiecePriority {
            body.appendMultipartField(boundary: boundary, name: "firstLastPiecePrio", value: "true")
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (_, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw QBError.serverError(statusCode: response.statusCode, message: "Failed to add torrent file")
        }
    }

    func deleteTorrents(hashes: [String], deleteFiles: Bool) async throws {
        let params: [String: String] = [
            "hashes": hashes.qbittorrentJoined(),
            "deleteFiles": deleteFiles ? "true" : "false"
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/delete", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to delete torrents")
    }

    func pauseTorrents(hashes: [String]) async throws {
        let params = ["hashes": hashes.qbittorrentJoined()]
        // qBittorrent v5+ uses /stop; v4 used /pause
        let request = try buildFormRequest(path: "/api/v2/torrents/stop", params: params)
        let (_, response) = try await performRequest(request)
        if response.statusCode == 404 {
            // Fall back to v4 endpoint
            let fallback = try buildFormRequest(path: "/api/v2/torrents/pause", params: params)
            _ = try await performRequest(fallback)
        }
    }

    func resumeTorrents(hashes: [String]) async throws {
        let params = ["hashes": hashes.qbittorrentJoined()]
        // qBittorrent v5+ uses /start; v4 used /resume
        let request = try buildFormRequest(path: "/api/v2/torrents/start", params: params)
        let (_, response) = try await performRequest(request)
        if response.statusCode == 404 {
            // Fall back to v4 endpoint
            let fallback = try buildFormRequest(path: "/api/v2/torrents/resume", params: params)
            _ = try await performRequest(fallback)
        }
    }

    func recheckTorrents(hashes: [String]) async throws {
        let params = ["hashes": hashes.qbittorrentJoined()]
        let request = try buildFormRequest(path: "/api/v2/torrents/recheck", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to recheck torrents")
    }

    func getTorrentFiles(hash: String) async throws -> [TorrentFile] {
        let request = try buildRequest(path: "/api/v2/torrents/files", queryItems: [.init(name: "hash", value: hash)])
        let (data, _) = try await performRequest(request)
        let rawFiles = try decode([TorrentFile].self, from: data)
        // Assign array indices since the API doesn't return an index field
        return rawFiles.enumerated().map { index, file in file.withIndex(index) }
    }

    func setFilePriority(hash: String, fileIndices: [Int], priority: FilePriority) async throws {
        let params: [String: String] = [
            "hash": hash,
            "id": fileIndices.map(String.init).qbittorrentJoined(),
            "priority": String(priority.rawValue)
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/filePrio", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to update file priority")
    }

    func getTorrentProperties(hash: String) async throws -> TorrentProperties {
        let request = try buildRequest(path: "/api/v2/torrents/properties", queryItems: [.init(name: "hash", value: hash)])
        let (data, _) = try await performRequest(request)
        return try decode(TorrentProperties.self, from: data)
    }

    func setTorrentLocation(hashes: [String], location: String) async throws {
        let params: [String: String] = [
            "hashes": hashes.qbittorrentJoined(),
            "location": location
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/setLocation", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to update torrent location")
    }

    func setTorrentCategory(hashes: [String], category: String) async throws {
        let params: [String: String] = [
            "hashes": hashes.qbittorrentJoined(),
            "category": category
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/setCategory", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to update torrent category")
    }

    func renameTorrent(hash: String, name: String) async throws {
        let params: [String: String] = ["hash": hash, "name": name]
        let request = try buildFormRequest(path: "/api/v2/torrents/rename", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to rename torrent")
    }

    func getCategories() async throws -> [String: SyncCategory] {
        let request = try buildRequest(path: "/api/v2/torrents/categories")
        let (data, _) = try await performRequest(request)
        return try decode([String: SyncCategory].self, from: data)
    }

    func createCategory(name: String, savePath: String?) async throws {
        var params: [String: String] = ["category": name]
        if let savePath, !savePath.isEmpty {
            params["savePath"] = savePath
        }
        let request = try buildFormRequest(path: "/api/v2/torrents/createCategory", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to create category")
    }

    func removeCategories(names: [String]) async throws {
        let filteredNames = names.filter { !$0.isEmpty }
        guard !filteredNames.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/removeCategories",
            params: ["categories": filteredNames.joined(separator: "\n")]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to remove categories")
    }

    func getTags() async throws -> [String] {
        let request = try buildRequest(path: "/api/v2/torrents/tags")
        let (data, _) = try await performRequest(request)
        return try decode([String].self, from: data)
    }

    func createTags(tags: [String]) async throws {
        let filteredTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !filteredTags.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/createTags",
            params: ["tags": filteredTags.joined(separator: ",")]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to create tags")
    }

    func deleteTags(tags: [String]) async throws {
        let filteredTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !filteredTags.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/deleteTags",
            params: ["tags": filteredTags.joined(separator: ",")]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to delete tags")
    }

    func addTorrentTags(hashes: [String], tags: [String]) async throws {
        let filteredHashes = hashes.filter { !$0.isEmpty }
        let filteredTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !filteredHashes.isEmpty, !filteredTags.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/addTags",
            params: [
                "hashes": filteredHashes.qbittorrentJoined(),
                "tags": filteredTags.joined(separator: ",")
            ]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to add torrent tags")
    }

    func removeTorrentTags(hashes: [String], tags: [String]) async throws {
        let filteredHashes = hashes.filter { !$0.isEmpty }
        let filteredTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !filteredHashes.isEmpty, !filteredTags.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/removeTags",
            params: [
                "hashes": filteredHashes.qbittorrentJoined(),
                "tags": filteredTags.joined(separator: ",")
            ]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to remove torrent tags")
    }

    func getTrackers(hash: String) async throws -> [TorrentTracker] {
        let request = try buildRequest(path: "/api/v2/torrents/trackers", queryItems: [.init(name: "hash", value: hash)])
        let (data, _) = try await performRequest(request)
        return try decode([TorrentTracker].self, from: data)
    }

    func addTorrentTrackers(hash: String, urls: [String]) async throws {
        let sanitized = urls.trimmedNonEmpty()
        guard !sanitized.isEmpty else { return }
        // qBittorrent expects a newline-separated list as a single form value
        let params: [String: String] = [
            "hash": hash,
            "urls": sanitized.joined(separator: "\n")
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/addTrackers", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to add trackers")
    }

    func removeTorrentTrackers(hash: String, urls: [String]) async throws {
        let sanitized = urls.trimmedNonEmpty()
        guard !sanitized.isEmpty else { return }
        let params: [String: String] = [
            "hash": hash,
            "urls": sanitized.qbittorrentJoined()
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/removeTrackers", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to remove trackers")
    }

    func editTorrentTracker(hash: String, origURL: String, newURL: String) async throws {
        let params: [String: String] = [
            "hash": hash,
            "origUrl": origURL,
            "newUrl": newURL
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/editTracker", params: params)
        try await performSuccessfulMutation(request, failureMessage: "Failed to edit tracker")
    }

    // MARK: - Transfer

    func getTransferInfo() async throws -> TransferInfo {
        let request = try buildRequest(path: "/api/v2/transfer/info")
        let (data, _) = try await performRequest(request)
        return try decode(TransferInfo.self, from: data)
    }

    func getGlobalDownloadLimit() async throws -> Int64 {
        let request = try buildRequest(path: "/api/v2/transfer/downloadLimit")
        let (data, _) = try await performRequest(request)
        return try decodeNumericResponse(data)
    }

    func getGlobalUploadLimit() async throws -> Int64 {
        let request = try buildRequest(path: "/api/v2/transfer/uploadLimit")
        let (data, _) = try await performRequest(request)
        return try decodeNumericResponse(data)
    }

    func setGlobalDownloadLimit(limit: Int64) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/transfer/setDownloadLimit",
            params: ["limit": String(limit)]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to update download limit")
    }

    func setGlobalUploadLimit(limit: Int64) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/transfer/setUploadLimit",
            params: ["limit": String(limit)]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to update upload limit")
    }

    func isAlternativeSpeedEnabled() async throws -> Bool {
        let request = try buildRequest(path: "/api/v2/transfer/speedLimitsMode")
        let (data, _) = try await performRequest(request)
        return try decodeNumericResponse(data) == 1
    }

    func toggleAlternativeSpeed() async throws {
        let request = try buildRequest(path: "/api/v2/transfer/toggleSpeedLimitsMode", method: "POST")
        try await performSuccessfulMutation(request, failureMessage: "Failed to toggle alternative speed mode")
    }

    func setTorrentDownloadLimit(hashes: [String], limit: Int64) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/torrents/setDownloadLimit",
            params: [
                "hashes": hashes.qbittorrentJoined(),
                "limit": String(limit)
            ]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to update torrent download limit")
    }

    func setTorrentUploadLimit(hashes: [String], limit: Int64) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/torrents/setUploadLimit",
            params: [
                "hashes": hashes.qbittorrentJoined(),
                "limit": String(limit)
            ]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to update torrent upload limit")
    }

    func toggleSequentialDownload(hashes: [String]) async throws {
        let sanitized = hashes.trimmedNonEmpty()
        guard !sanitized.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/toggleSequentialDownload",
            params: ["hashes": sanitized.qbittorrentJoined()]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to toggle sequential download")
    }

    func toggleFirstLastPiecePriority(hashes: [String]) async throws {
        let sanitized = hashes.trimmedNonEmpty()
        guard !sanitized.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/toggleFirstLastPiecePrio",
            params: ["hashes": sanitized.qbittorrentJoined()]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to toggle first and last piece priority")
    }

    // MARK: - Sync

    func syncMainData(rid: Int) async throws -> SyncMainData {
        let request = try buildRequest(path: "/api/v2/sync/maindata", queryItems: [.init(name: "rid", value: String(rid))])
        let (data, _) = try await performRequest(request)
        return try decode(SyncMainData.self, from: data)
    }

    // MARK: - Request Infrastructure

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var mutableRequest = request
        await authService.authorize(&mutableRequest)

        do {
            let (data, response) = try await session.data(for: mutableRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw QBError.invalidResponse
            }

            if httpResponse.statusCode == 403 {
                // SID expired — attempt re-authentication
                try await reAuthenticate()
                await authService.authorize(&mutableRequest)
                let (retryData, retryResponse) = try await session.data(for: mutableRequest)
                guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                    throw QBError.invalidResponse
                }
                if retryHTTP.statusCode == 403 {
                    throw QBError.authFailed
                }
                return (retryData, retryHTTP)
            }

            return (data, httpResponse)
        } catch let error as QBError {
            throw error
        } catch {
            throw QBError.networkError(error.localizedDescription)
        }
    }

    // MARK: - RSS Feeds
    
    /// Get all RSS feeds and folders. Returns a dictionary where keys are folder names (or empty string for root) and values are feed URLs or nested folders.
    func getRSSItems(withData: Bool = false) async throws -> [String: JSONValue] {
        let request = try buildRequest(
            path: "/api/v2/rss/items",
            queryItems: [URLQueryItem(name: "withData", value: String(withData))]
        )
        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
    
    /// Add a new RSS feed or folder
    func addRSSFolder(path: String) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/rss/addFolder",
            params: ["path": path]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to add RSS folder")
    }
    
    func addRSSFeed(url: String, path: String? = nil) async throws {
        var params: [String: String] = ["url": url]
        if let path { params["path"] = path }
        let request = try buildFormRequest(
            path: "/api/v2/rss/addFeed",
            params: params
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to add RSS feed")
    }
    
    /// Remove an RSS feed or folder
    func removeRSSItem(path: String) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/rss/removeItem",
            params: ["path": path]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to remove RSS item")
    }
    
    /// Move an RSS feed or folder
    func moveRSSItem(itemPath: String, destPath: String) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/rss/moveItem",
            params: [
                "itemPath": itemPath,
                "destPath": destPath
            ]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to move RSS item")
    }
    
    /// Refresh an RSS feed
    func refreshRSSItem(itemPath: String) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/rss/refreshItem",
            params: ["itemPath": itemPath]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to refresh RSS item")
    }
    
    /// Set an auto-downloading rule
    func setRSSRule(ruleName: String, ruleDef: String) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/rss/setRule",
            params: [
                "ruleName": ruleName,
                "ruleDef": ruleDef // Expects JSON-encoded string of the rule object
            ]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to set RSS rule")
    }
    
    /// Get all auto-downloading rules keyed by rule name.
    func getRSSRules() async throws -> [String: QBittorrentRSSRule] {
        let request = try buildRequest(path: "/api/v2/rss/rules")
        let (data, _) = try await performRequest(request)
        return try decode([String: QBittorrentRSSRule].self, from: data)
    }
    
    // MARK: - Logs

    func getMainLog(normal: Bool = true, info: Bool = true, warning: Bool = true, critical: Bool = true, lastKnownId: Int = -1) async throws -> [QBittorrentLogEntry] {
        let queryItems: [URLQueryItem] = [
            .init(name: "normal", value: String(normal)),
            .init(name: "info", value: String(info)),
            .init(name: "warning", value: String(warning)),
            .init(name: "critical", value: String(critical)),
            .init(name: "last_known_id", value: String(lastKnownId)),
        ]
        let request = try buildRequest(path: "/api/v2/log/main", queryItems: queryItems)
        let (data, _) = try await performRequest(request)
        return try decode([QBittorrentLogEntry].self, from: data)
    }

    /// Remove an auto-downloading rule
    func removeRSSRule(ruleName: String) async throws {
        let request = try buildFormRequest(
            path: "/api/v2/rss/removeRule",
            params: ["ruleName": ruleName]
        )
        try await performSuccessfulMutation(request, failureMessage: "Failed to remove RSS rule")
    }

    private func reAuthenticate() async throws {
        let keychain = KeychainHelper.shared
        guard let username = try await keychain.read(key: "server_\(serverProfileID.uuidString)_username"),
              let password = try await keychain.read(key: "server_\(serverProfileID.uuidString)_password") else {
            throw QBError.authFailed
        }
        try await authService.login(hostURL: baseURL, username: username, password: password)
    }

    private func buildRequest(path: String, method: String = "GET", queryItems: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw QBError.invalidResponse
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw QBError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    private func buildFormRequest(path: String, params: [String: String]) throws -> URLRequest {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = params.map { "\($0.key)=\(URLEncoding.formEncode($0.value))" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    private func performSuccessfulMutation(
        _ request: URLRequest,
        successCodes: Set<Int> = [200],
        failureMessage: String
    ) async throws {
        let (_, response) = try await performRequest(request)
        guard successCodes.contains(response.statusCode) else {
            throw QBError.serverError(statusCode: response.statusCode, message: failureMessage)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw QBError.decodingError(error.localizedDescription)
        }
    }

    private func decodeNumericResponse(_ data: Data) throws -> Int64 {
        guard let stringValue = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int64(stringValue) else {
            throw QBError.invalidResponse
        }
        return value
    }
}
// MARK: - Helpers
extension Array where Element == String {
    nonisolated func qbittorrentJoined() -> String {
        joined(separator: "|")
    }

    nonisolated func trimmedNonEmpty() -> [String] {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#if DEBUG
extension QBittorrentAPIClient {
    static func preview() -> QBittorrentAPIClient {
        let authService = AuthService(serverProfileID: UUID())
        return QBittorrentAPIClient(
            baseURL: "http://preview.invalid",
            authService: authService
        )
    }
}
#endif
