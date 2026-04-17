import Foundation

actor QBittorrentAPIClient {
    private let authService: AuthService
    private let session: URLSession
    private let baseURL: String
    private let serverProfileID: UUID

    init(baseURL: String, authService: AuthService) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.authService = authService
        self.serverProfileID = authService.serverProfileID
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
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

    func addTorrentMagnet(magnetURL: String, savePath: String?, category: String?, paused: Bool, sequentialDownload: Bool) async throws {
        let boundary = UUID().uuidString
        var request = try buildRequest(path: "/api/v2/torrents/add", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipartField(boundary: boundary, name: "urls", value: magnetURL)
        if let savePath { body.appendMultipartField(boundary: boundary, name: "savepath", value: savePath) }
        if let category { body.appendMultipartField(boundary: boundary, name: "category", value: category) }
        if paused { body.appendMultipartField(boundary: boundary, name: "stopped", value: "true") }
        if sequentialDownload { body.appendMultipartField(boundary: boundary, name: "sequentialDownload", value: "true") }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (_, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw QBError.serverError(statusCode: response.statusCode, message: "Failed to add torrent")
        }
    }

    func addTorrentFile(fileData: Data, fileName: String, savePath: String?, category: String?, paused: Bool, sequentialDownload: Bool) async throws {
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

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (_, response) = try await performRequest(request)
        guard response.statusCode == 200 else {
            throw QBError.serverError(statusCode: response.statusCode, message: "Failed to add torrent file")
        }
    }

    func deleteTorrents(hashes: [String], deleteFiles: Bool) async throws {
        let params: [String: String] = [
            "hashes": hashes.joined(separator: "|"),
            "deleteFiles": deleteFiles ? "true" : "false"
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/delete", params: params)
        _ = try await performRequest(request)
    }

    func pauseTorrents(hashes: [String]) async throws {
        let params = ["hashes": hashes.joined(separator: "|")]
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
        let params = ["hashes": hashes.joined(separator: "|")]
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
        let params = ["hashes": hashes.joined(separator: "|")]
        let request = try buildFormRequest(path: "/api/v2/torrents/recheck", params: params)
        _ = try await performRequest(request)
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
            "id": fileIndices.map(String.init).joined(separator: "|"),
            "priority": String(priority.rawValue)
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/filePrio", params: params)
        _ = try await performRequest(request)
    }

    func getTorrentProperties(hash: String) async throws -> TorrentProperties {
        let request = try buildRequest(path: "/api/v2/torrents/properties", queryItems: [.init(name: "hash", value: hash)])
        let (data, _) = try await performRequest(request)
        return try decode(TorrentProperties.self, from: data)
    }

    func setTorrentLocation(hashes: [String], location: String) async throws {
        let params: [String: String] = [
            "hashes": hashes.joined(separator: "|"),
            "location": location
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/setLocation", params: params)
        _ = try await performRequest(request)
    }

    func setTorrentCategory(hashes: [String], category: String) async throws {
        let params: [String: String] = [
            "hashes": hashes.joined(separator: "|"),
            "category": category
        ]
        let request = try buildFormRequest(path: "/api/v2/torrents/setCategory", params: params)
        _ = try await performRequest(request)
    }

    func renameTorrent(hash: String, name: String) async throws {
        let params: [String: String] = ["hash": hash, "name": name]
        let request = try buildFormRequest(path: "/api/v2/torrents/rename", params: params)
        _ = try await performRequest(request)
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
        _ = try await performRequest(request)
    }

    func removeCategories(names: [String]) async throws {
        let filteredNames = names.filter { !$0.isEmpty }
        guard !filteredNames.isEmpty else { return }
        let request = try buildFormRequest(
            path: "/api/v2/torrents/removeCategories",
            params: ["categories": filteredNames.joined(separator: "\n")]
        )
        _ = try await performRequest(request)
    }

    func getTrackers(hash: String) async throws -> [TorrentTracker] {
        let request = try buildRequest(path: "/api/v2/torrents/trackers", queryItems: [.init(name: "hash", value: hash)])
        let (data, _) = try await performRequest(request)
        return try decode([TorrentTracker].self, from: data)
    }

    // MARK: - Transfer

    func getTransferInfo() async throws -> TransferInfo {
        let request = try buildRequest(path: "/api/v2/transfer/info")
        let (data, _) = try await performRequest(request)
        return try decode(TransferInfo.self, from: data)
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
            throw QBError.networkError(error)
        }
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
        let body = params.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove("+")
        allowed.remove("&")
        allowed.remove("=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw QBError.decodingError(error)
        }
    }
}

// MARK: - Multipart Data Helpers

private extension Data {
    nonisolated mutating func appendMultipart(boundary: String, name: String, filename: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    nonisolated mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
