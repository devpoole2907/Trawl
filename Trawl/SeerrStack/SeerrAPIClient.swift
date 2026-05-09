import Foundation

/// Core Seerr HTTP client for Trawl's admin features.
actor SeerrAPIClient {
    let baseURL: String
    private let session: URLSession
    private var sessionCookie: String?

    init(baseURL: String, sessionCookie: String? = nil) {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.sessionCookie = sessionCookie

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth

    func loginJellyfin(username: String, password: String) async throws -> SeerrUser {
        let body: [String: String] = ["username": username, "password": password]
        let (data, response) = try await postRaw("/api/v1/auth/jellyfin", jsonBody: body)

        if let setCookie = response.value(forHTTPHeaderField: "Set-Cookie") {
            sessionCookie = extractSessionCookie(from: setCookie)
        }

        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw URLError(.userAuthenticationRequired)
            }
            throw URLError(.badServerResponse)
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

    func deleteUser(id: Int) async throws -> SeerrUser {
        try await delete("/api/v1/user/\(id)")
    }

    func importUsersFromJellyfin(jellyfinUserIds: [String]? = nil) async throws -> [SeerrUser] {
        if let jellyfinUserIds, !jellyfinUserIds.isEmpty {
            return try await post(
                "/api/v1/user/import-from-jellyfin",
                body: SeerrImportJellyfinUsersBody(jellyfinUserIds: jellyfinUserIds)
            )
        }
        return try await post("/api/v1/user/import-from-jellyfin", body: EmptyRequestBody())
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
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func postRaw(_ path: String, jsonBody: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        let request = try buildRequest(path: path, method: "DELETE")
        return try await perform(request)
    }

    private func buildRequest(path: String, method: String, queryParams: [String: String] = [:]) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }
        if !queryParams.isEmpty {
            components.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let cookie = sessionCookie {
            request.setValue("connect.sid=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw URLError(.cannotConnectToHost)
        }

        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw URLError(.userAuthenticationRequired)
        }

        guard (200..<400).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw URLError(.cannotDecodeRawData)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw URLError(.cannotDecodeRawData)
        }
    }

    private func extractSessionCookie(from header: String) -> String? {
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("connect.sid=") {
                return String(trimmed.dropFirst("connect.sid=".count))
            }
        }
        return nil
    }
}