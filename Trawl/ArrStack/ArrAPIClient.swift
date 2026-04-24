import Foundation
import OSLog

protocol SharedArrClient: Actor {
    var base: ArrAPIClient { get }
}
nonisolated enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(String.self) {
            self = .string(x)
        } else if let x = try? container.decode(Double.self) {
            self = .number(x)
        } else if let x = try? container.decode(Bool.self) {
            self = .bool(x)
        } else if let x = try? container.decode([String: JSONValue].self) {
            self = .object(x)
        } else if let x = try? container.decode([JSONValue].self) {
            self = .array(x)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONValue"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let x): try container.encode(x)
        case .number(let x): try container.encode(x)
        case .bool(let x): try container.encode(x)
        case .object(let x): try container.encode(x)
        case .array(let x): try container.encode(x)
        case .null: try container.encodeNil()
        }
    }
    
    nonisolated var rawValue: Any {
        switch self {
        case .string(let x): return x
        case .number(let x): return x
        case .bool(let x): return x
        case .object(let x): return x.mapValues { $0.rawValue }
        case .array(let x): return x.map { $0.rawValue }
        case .null: return NSNull()
        }
    }
}

extension SharedArrClient {
    func getSystemStatus() async throws -> ArrSystemStatus { try await base.getSystemStatus() }
    func getHealth() async throws -> [ArrHealthCheck] { try await base.getHealth() }
    func getQualityProfiles() async throws -> [ArrQualityProfile] { try await base.getQualityProfiles() }
    func createQualityProfile(_ profile: ArrQualityProfile) async throws -> ArrQualityProfile { try await base.createQualityProfile(profile) }
    func updateQualityProfile(_ profile: ArrQualityProfile) async throws -> ArrQualityProfile { try await base.updateQualityProfile(profile) }
    func deleteQualityProfile(id: Int) async throws { try await base.deleteQualityProfile(id: id) }
    func getRootFolders() async throws -> [ArrRootFolder] { try await base.getRootFolders() }
    func getTags() async throws -> [ArrTag] { try await base.getTags() }
    func getNotifications() async throws -> [ArrNotification] { try await base.getNotifications() }
    func createNotification(_ notification: ArrNotification) async throws -> ArrNotification { try await base.createNotification(notification) }
    func updateNotification(_ notification: ArrNotification) async throws -> ArrNotification { try await base.updateNotification(notification) }

    func getQueue(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize,
        includeUnknownMovieItems: Bool = true
    ) async throws -> ArrQueuePage {
        try await base.getQueue(
            page: page,
            pageSize: pageSize,
            includeUnknownMovieItems: includeUnknownMovieItems
        )
    }

    func deleteQueueItem(id: Int, removeFromClient: Bool = true, blocklist: Bool = false) async throws {
        try await base.deleteQueueItem(
            id: id,
            removeFromClient: removeFromClient,
            blocklist: blocklist
        )
    }

    func getHistory(
        page: Int = 1,
        pageSize: Int = ArrAPIClient.defaultPageSize
    ) async throws -> ArrHistoryPage {
        try await base.getHistory(page: page, pageSize: pageSize)
    }

    func getDiskSpace() async throws -> [ArrDiskSpace] { try await base.getDiskSpace() }
    func getUpdates() async throws -> [ArrUpdateInfo] { try await base.getUpdates() }
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

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false) {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.apiKey = apiKey
        self.trustPolicy = ServerTrustPolicy(allowsUntrustedTLS: allowsUntrustedTLS)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
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

    /// Fire-and-forget POST with a Codable body (for commands that return empty body)
    func postVoidCodable<B: Encodable>(_ path: String, body: B) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
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
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
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
            return try JSONDecoder().decode(T.self, from: data)
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

