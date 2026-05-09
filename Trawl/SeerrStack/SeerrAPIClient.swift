import Foundation

/// Core Seerr HTTP client for Trawl's admin features.
actor SeerrAPIClient {
    nonisolated let baseURL: String
    private let session: URLSession
    private var sessionCookie: String?
    private let trustPolicy: ServerTrustPolicy
    private var onCookieUpdate: (@Sendable (String) -> Void)?

    init(baseURL: String, sessionCookie: String? = nil, allowsUntrustedTLS: Bool = false) {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.sessionCookie = sessionCookie
        self.trustPolicy = ServerTrustPolicy(allowsUntrustedTLS: allowsUntrustedTLS)

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: trustPolicy, delegateQueue: nil)
    }

    /// Registers a handler invoked whenever Seerr issues a fresh `connect.sid` cookie
    /// on a response. The owner can persist the updated cookie so future launches use
    /// the latest value rather than the original one captured at sign-in.
    func setCookieUpdateHandler(_ handler: @escaping @Sendable (String) -> Void) {
        self.onCookieUpdate = handler
    }

    // MARK: - Auth

    func loginJellyfin(username: String, password: String) async throws -> SeerrUser {
        let body: [String: String] = ["username": username, "password": password]
        let (data, response) = try await postRaw("/api/v1/auth/jellyfin", jsonBody: body)

        captureRollingCookie(from: response)

        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw SeerrAPIError.unauthorized
            }
            throw SeerrAPIError.http(status: response.statusCode, body: bodyString(from: data))
        }

        return try decode(SeerrUser.self, from: data)
    }

    func getCurrentUser() async throws -> SeerrUser {
        try await get("/api/v1/auth/me")
    }

    func logout() async throws {
        _ = try? await postVoid("/api/v1/auth/logout", jsonBody: [:] as [String: String])
        sessionCookie = nil
    }

    func getSessionCookie() -> String? { sessionCookie }
    func setSessionCookie(_ cookie: String) { sessionCookie = cookie }

    // MARK: - Admin Endpoints (Users)

    func getUsers(take: Int = 20, skip: Int = 0) async throws -> SeerrUserListResponse {
        try await get("/api/v1/user", params: [
            "take": String(take),
            "skip": String(skip)
        ])
    }

    func updateUser(id: Int, permissions: Int) async throws -> SeerrUser {
        try await put("/api/v1/user/\(id)", body: SeerrUpdateUserBody(permissions: permissions))
    }

    func deleteUser(id: Int) async throws {
        try await deleteVoid("/api/v1/user/\(id)")
    }

    func importUsersFromJellyfin(jellyfinUserIds: [String]) async throws -> [SeerrUser] {
        try await post(
            "/api/v1/user/import-from-jellyfin",
            body: SeerrImportJellyfinUsersBody(jellyfinUserIds: jellyfinUserIds)
        )
    }

    func getJellyfinUsers() async throws -> [SeerrJellyfinUser] {
        try await get("/api/v1/settings/jellyfin/users")
    }

    // MARK: - Linked Applications (Sonarr / Radarr)

    func getDVRSettings(_ kind: SeerrDVRKind) async throws -> [SeerrDVRSettings] {
        try await get(kind.settingsPath)
    }

    func testDVRConnection(_ kind: SeerrDVRKind, body: SeerrDVRTestBody) async throws -> SeerrDVRTestResponse {
        try await post(kind.testPath, body: body)
    }

    func getDVRService(_ kind: SeerrDVRKind, id: Int) async throws -> SeerrDVRServiceResponse {
        try await get(kind.servicePath(id: id))
    }

    func createDVRSettings(_ kind: SeerrDVRKind, body: SeerrDVRSettings) async throws -> SeerrDVRSettings {
        try await post(kind.settingsPath, body: body)
    }

    func updateDVRSettings(_ kind: SeerrDVRKind, id: Int, body: SeerrDVRSettings) async throws -> SeerrDVRSettings {
        try await put(kind.settingsItemPath(id: id), body: body)
    }

    func deleteDVRSettings(_ kind: SeerrDVRKind, id: Int) async throws {
        try await deleteVoid(kind.settingsItemPath(id: id))
    }

    // MARK: - Admin Endpoints (Issues)

    func getIssues(take: Int = 20, skip: Int = 0, sort: String = "added", filter: String = "open") async throws -> SeerrIssueListResponse {
        try await get("/api/v1/issue", params: [
            "take": String(take),
            "skip": String(skip),
            "sort": sort,
            "filter": filter
        ])
    }

    func getIssue(id: Int) async throws -> SeerrIssue {
        try await get("/api/v1/issue/\(id)")
    }

    func getIssueComments(issueId: Int) async throws -> [SeerrIssueComment] {
        let issue: SeerrIssue = try await get("/api/v1/issue/\(issueId)")
        return issue.comments ?? []
    }

    func replyToIssue(issueId: Int, message: String) async throws -> SeerrIssue {
        try await post("/api/v1/issue/\(issueId)/comment", body: SeerrIssueCommentBody(message: message))
    }

    func resolveIssue(issueId: Int) async throws -> SeerrIssue {
        try await post("/api/v1/issue/\(issueId)/resolved", body: EmptyRequestBody())
    }

    func reopenIssue(issueId: Int) async throws -> SeerrIssue {
        try await post("/api/v1/issue/\(issueId)/open", body: EmptyRequestBody())
    }

    func getRequestCount() async throws -> SeerrRequestCount {
        try await get("/api/v1/request/count")
    }

    func getRequests(
        take: Int = 20,
        skip: Int = 0,
        filter: String = "pending",
        sort: String = "added",
        sortDirection: String = "desc",
        mediaType: String = "all"
    ) async throws -> SeerrRequestListResponse {
        try await get("/api/v1/request", params: [
            "take": String(take),
            "skip": String(skip),
            "filter": filter,
            "sort": sort,
            "sortDirection": sortDirection,
            "mediaType": mediaType
        ])
    }

    func approveRequest(id: Int) async throws -> SeerrMediaRequest {
        try await post("/api/v1/request/\(id)/approve", body: EmptyRequestBody())
    }

    func declineRequest(id: Int) async throws -> SeerrMediaRequest {
        try await post("/api/v1/request/\(id)/decline", body: EmptyRequestBody())
    }

    func deleteRequest(id: Int) async throws {
        try await deleteVoid("/api/v1/request/\(id)")
    }

    func getMediaSummary(tmdbId: Int, mediaType: String) async throws -> SeerrMediaSummary {
        let path = mediaType == "tv" ? "/api/v1/tv/\(tmdbId)" : "/api/v1/movie/\(tmdbId)"
        return try await get(path)
    }

    func getLogs(take: Int = 100, skip: Int = 0, filter: String = "debug", search: String? = nil) async throws -> [SeerrServerLogEntry] {
        var params = [
            "take": String(take),
            "skip": String(skip),
            "filter": filter
        ]
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["search"] = search
        }
        let response: SeerrPagedResponse<SeerrServerLogEntry> = try await get("/api/v1/settings/logs", params: params)
        return response.results
    }

    func getPublicSettings() async throws -> SeerrPublicSettings {
        try await get("/api/v1/settings/public")
    }

    // MARK: - HTTP Infrastructure

    private func get<T: Decodable>(_ path: String, params: [String: String] = [:]) async throws -> T {
        let request = try buildRequest(path: path, method: "GET", queryParams: params)
        return try await perform(request)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        var request = try buildRequest(path: path, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func postVoid<B: Encodable>(_ path: String, jsonBody: B) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(jsonBody)
        try await performVoid(request)
    }

    private func postRaw(_ path: String, jsonBody: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let (data, response) = try await sessionData(for: request)
        guard let http = response as? HTTPURLResponse else { throw SeerrAPIError.invalidResponse }
        return (data, http)
    }

    private func deleteVoid(_ path: String) async throws {
        let request = try buildRequest(path: path, method: "DELETE")
        try await performVoid(request)
    }

    private func buildRequest(path: String, method: String, queryParams: [String: String] = [:]) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw SeerrAPIError.badURL
        }
        if !queryParams.isEmpty {
            components.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw SeerrAPIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let cookie = sessionCookie {
            request.setValue("connect.sid=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func sessionData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            throw SeerrAPIError.transport(urlError)
        } catch {
            throw SeerrAPIError.transport(URLError(.unknown))
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await sessionData(for: request)

        guard let http = response as? HTTPURLResponse else { throw SeerrAPIError.invalidResponse }

        captureRollingCookie(from: http)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SeerrAPIError.unauthorized
        }

        guard (200..<400).contains(http.statusCode) else {
            throw SeerrAPIError.http(status: http.statusCode, body: bodyString(from: data))
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SeerrAPIError.decode(reason: String(describing: error))
        }
    }

    private func performVoid(_ request: URLRequest) async throws {
        let (data, response) = try await sessionData(for: request)

        guard let http = response as? HTTPURLResponse else { throw SeerrAPIError.invalidResponse }

        captureRollingCookie(from: http)

        if http.statusCode == 401 || http.statusCode == 403 {
            throw SeerrAPIError.unauthorized
        }

        guard (200..<400).contains(http.statusCode) else {
            throw SeerrAPIError.http(status: http.statusCode, body: bodyString(from: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SeerrAPIError.decode(reason: String(describing: error))
        }
    }

    private func bodyString(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Parse `Set-Cookie` headers using `HTTPCookie` so multi-cookie responses and
    /// header field name casing variations are handled correctly.
    private func extractSessionCookie(from response: HTTPURLResponse) -> String? {
        guard let url = response.url else { return nil }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        return cookies.first { $0.name == "connect.sid" }?.value
    }

    private func captureRollingCookie(from response: HTTPURLResponse) {
        guard
            let updated = extractSessionCookie(from: response),
            !updated.isEmpty,
            updated != sessionCookie
        else { return }
        sessionCookie = updated
        onCookieUpdate?(updated)
    }
}
