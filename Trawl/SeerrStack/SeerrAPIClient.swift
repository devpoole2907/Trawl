import Foundation

/// Core Seerr HTTP client for Trawl's admin features.
actor SeerrAPIClient {
    nonisolated var baseURL: String { transport.baseURL }
    private let transport: HTTPTransport
    private var onCookieUpdate: (@Sendable (String) -> Void)?

    init(baseURL: String, sessionCookie: String? = nil, allowsUntrustedTLS: Bool = false) {
        let mapper = HTTPErrorMapper(
            badURL: { SeerrAPIError.badURL },
            transport: { error in
                if let urlError = error as? URLError { return SeerrAPIError.transport(urlError) }
                return SeerrAPIError.transport(URLError(.unknown))
            },
            unauthorized: { SeerrAPIError.unauthorized },
            http: { code, body in SeerrAPIError.http(status: code, body: body) },
            decode: { error in SeerrAPIError.decode(reason: String(describing: error)) },
            invalidResponse: { SeerrAPIError.invalidResponse },
            unauthorizedStatusCodes: [401, 403]
        )

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30

        self.transport = HTTPTransport(
            baseURL: baseURL,
            auth: .mutable(name: "Cookie", format: { value in
                guard let value, !value.isEmpty else { return nil }
                return "connect.sid=\(value)"
            }),
            initialMutableAuthValue: sessionCookie,
            allowsUntrustedTLS: allowsUntrustedTLS,
            sessionConfiguration: config,
            errorMapper: mapper
        )
    }

    /// Registers a handler invoked whenever Seerr issues a fresh `connect.sid` cookie
    /// on a response. The owner can persist the updated cookie so future launches use
    /// the latest value rather than the original one captured at sign-in.
    func setCookieUpdateHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        self.onCookieUpdate = handler
        // Capture rolling cookies via a transport response observer.
        // The closure does not retain `self` (it captures it weakly), which avoids
        // a retain cycle with the transport.
        let observerCallback: @Sendable (HTTPURLResponse) -> Void = { [weak self] response in
            guard let updated = Self.extractSessionCookie(from: response), !updated.isEmpty else { return }
            Task { [weak self] in
                await self?.handleRollingCookie(updated)
            }
        }
        await transport.setResponseObserver(observerCallback)
    }

    private func handleRollingCookie(_ updated: String) async {
        let current = await transport.currentMutableAuthValue()
        guard current != updated else { return }
        await transport.setMutableAuthValue(updated)
        onCookieUpdate?(updated)
    }

    // MARK: - Auth

    func loginJellyfin(username: String, password: String) async throws -> SeerrUser {
        let body: [String: String] = ["username": username, "password": password]
        let (data, response) = try await postRaw("/api/v1/auth/jellyfin", jsonBody: body)

        await captureRollingCookie(from: response)

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
        await transport.setMutableAuthValue(nil)
    }

    func getSessionCookie() async -> String? { await transport.currentMutableAuthValue() }
    func setSessionCookie(_ cookie: String) async { await transport.setMutableAuthValue(cookie) }

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

    func getJobs() async throws -> [SeerrJob] {
        try await get("/api/v1/settings/jobs")
    }

    func runJob(id: String) async throws {
        try await postVoid("/api/v1/settings/jobs/\(id)/run", jsonBody: [String: String]())
    }

    func cancelJob(id: String) async throws {
        try await postVoid("/api/v1/settings/jobs/\(id)/cancel", jsonBody: [String: String]())
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

    func getWebhookNotificationSettings() async throws -> SeerrWebhookNotificationSettings {
        try await get("/api/v1/settings/notifications/webhook")
    }

    func updateWebhookNotificationSettings(_ settings: SeerrWebhookNotificationSettings) async throws {
        try await postVoid("/api/v1/settings/notifications/webhook", jsonBody: settings)
    }

    func testWebhookNotificationSettings(_ settings: SeerrWebhookNotificationSettings) async throws {
        try await postVoid("/api/v1/settings/notifications/webhook/test", jsonBody: settings)
    }

    // MARK: - HTTP Infrastructure

    private func get<T: Decodable>(_ path: String, params: [String: String] = [:]) async throws -> T {
        try await transport.get(path, queryItems: Self.queryItems(from: params))
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: sending B) async throws -> T {
        try await transport.postCodable(path, body: body)
    }

    private func put<T: Decodable, B: Encodable>(_ path: String, body: sending B) async throws -> T {
        try await transport.putCodable(path, body: body)
    }

    private func postVoid<B: Encodable>(_ path: String, jsonBody: sending B) async throws {
        try await transport.postVoidCodable(path, body: jsonBody)
    }

    private func postRaw(_ path: String, jsonBody: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = try await transport.buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await transport.performRaw(request)
    }

    private func deleteVoid(_ path: String) async throws {
        try await transport.delete(path)
    }

    private func captureRollingCookie(from response: HTTPURLResponse) async {
        guard
            let updated = Self.extractSessionCookie(from: response),
            !updated.isEmpty
        else { return }
        await handleRollingCookie(updated)
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

    /// Parse every exposed `Set-Cookie` value so multi-cookie responses do not lose
    /// `connect.sid` before Foundation's cookie parser can inspect it.
    private nonisolated static func extractSessionCookie(from response: HTTPURLResponse) -> String? {
        guard let url = response.url else { return nil }

        for headerValue in setCookieHeaderValues(from: response) {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": headerValue], for: url)
            if let value = cookies.first(where: { $0.name == "connect.sid" })?.value {
                return value
            }
            if let value = sessionCookieValue(fromSetCookieHeader: headerValue) {
                return value
            }
        }
        return nil
    }

    private nonisolated static func setCookieHeaderValues(from response: HTTPURLResponse) -> [String] {
        var values: [String] = []
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String,
                  key.caseInsensitiveCompare("Set-Cookie") == .orderedSame
            else { continue }
            appendSetCookieHeaderValues(rawValue, to: &values)
        }

        if values.isEmpty, let fallback = response.value(forHTTPHeaderField: "Set-Cookie") {
            appendSetCookieHeader(fallback, to: &values)
        }
        return values
    }

    private nonisolated static func appendSetCookieHeaderValues(_ rawValue: Any, to values: inout [String]) {
        if let value = rawValue as? String {
            appendSetCookieHeader(value, to: &values)
        } else if let valueList = rawValue as? [String] {
            valueList.forEach { appendSetCookieHeader($0, to: &values) }
        } else if let valueList = rawValue as? NSArray {
            valueList.compactMap { $0 as? String }.forEach { appendSetCookieHeader($0, to: &values) }
        }
    }

    private nonisolated static func appendSetCookieHeader(_ value: String, to values: inout [String]) {
        let lines = value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                values.append(trimmedValue)
            }
        } else {
            values.append(contentsOf: lines)
        }
    }

    private nonisolated static func sessionCookieValue(fromSetCookieHeader header: String) -> String? {
        let marker = "connect.sid="
        var searchRange = header.startIndex..<header.endIndex
        while let markerRange = header.range(of: marker, options: [.caseInsensitive], range: searchRange) {
            if isCookieBoundary(before: markerRange.lowerBound, in: header) {
                let valueStart = markerRange.upperBound
                let valueEnd = header[valueStart...].firstIndex { character in
                    character == ";" || character == "," || character.isNewline
                } ?? header.endIndex
                let value = header[valueStart..<valueEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
            searchRange = markerRange.upperBound..<header.endIndex
        }
        return nil
    }

    private nonisolated static func isCookieBoundary(before index: String.Index, in header: String) -> Bool {
        guard index > header.startIndex else { return true }
        let previous = header[..<index].last { !$0.isWhitespace }
        return previous == ","
    }

    private nonisolated static func queryItems(from params: [String: String]) -> [URLQueryItem] {
        guard !params.isEmpty else { return [] }
        return params.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}

#if DEBUG
extension SeerrAPIClient {
    static func preview() -> SeerrAPIClient {
        SeerrAPIClient(baseURL: "http://preview.invalid", allowsUntrustedTLS: false)
    }
}
#endif
