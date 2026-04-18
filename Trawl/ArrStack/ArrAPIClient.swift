import Foundation

/// Base actor handling shared HTTP infrastructure for all *arr services.
/// Both SonarrAPIClient and RadarrAPIClient build on this.
actor ArrAPIClient {
    let baseURL: String
    private let apiKey: String
    private let session: URLSession

    init(baseURL: String, apiKey: String) {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
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

    func getRootFolders() async throws -> [ArrRootFolder] {
        try await get("/api/v3/rootfolder")
    }

    func getTags() async throws -> [ArrTag] {
        try await get("/api/v3/tag")
    }

    func getQueue(page: Int = 1, pageSize: Int = 20, includeUnknownMovieItems: Bool = true) async throws -> ArrQueuePage {
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

    func getHistory(page: Int = 1, pageSize: Int = 20, sortKey: String = "date", sortDirection: String = "descending") async throws -> ArrHistoryPage {
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

    func postCommand(name: String, additionalParams: [String: Any]? = nil) async throws -> ArrCommand {
        var body: [String: Any] = ["name": name]
        if let params = additionalParams {
            for (key, value) in params { body[key] = value }
        }
        return try await post("/api/v3/command", jsonBody: body)
    }

    // MARK: - HTTP Infrastructure

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let request = try buildRequest(path: path, method: "GET", queryItems: queryItems)
        return try await perform(request)
    }

    func post<T: Decodable>(_ path: String, jsonBody: Any) async throws -> T {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await perform(request)
    }

    func postCodable<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    func putCodable<T: Decodable, B: Encodable>(_ path: String, body: B, queryItems: [URLQueryItem] = []) async throws -> T {
        var request = try buildRequest(path: path, method: "PUT", queryItems: queryItems)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    func delete(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try buildRequest(path: path, method: "DELETE", queryItems: queryItems)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArrError.invalidResponse }
        if http.statusCode == 401 { throw ArrError.invalidAPIKey }
        guard (200..<400).contains(http.statusCode) else {
            throw ArrError.serverError(statusCode: http.statusCode, message: nil)
        }
    }

    /// Fire-and-forget POST (for commands that return empty body)
    func postVoid(_ path: String, jsonBody: Any) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArrError.invalidResponse }
        if http.statusCode == 401 { throw ArrError.invalidAPIKey }
        guard (200..<400).contains(http.statusCode) else {
            throw ArrError.serverError(statusCode: http.statusCode, message: nil)
        }
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
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ArrError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ArrError.invalidResponse
        }

        if http.statusCode == 401 { throw ArrError.invalidAPIKey }

        guard (200..<400).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw ArrError.serverError(statusCode: http.statusCode, message: body)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ArrError.decodingError(error)
        }
    }
}
