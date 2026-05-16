import Foundation

/// Direct HTTP client against a Jellyfin server's admin API.
///
/// Jellyfin's auth model: every request carries an `Authorization: MediaBrowser ...`
/// header (see `JellyfinAuthHeader`). After login the header includes a `Token=` field
/// containing either an access token (from `AuthenticateByName`) or a permanent API key
/// (from the Jellyfin dashboard). Both are stored under the same Keychain slot — they
/// are interchangeable on the wire.
actor JellyfinAPIClient {
    nonisolated var baseURL: String { transport.baseURL }
    private let transport: HTTPTransport

    init(baseURL: String, accessToken: String? = nil, allowsUntrustedTLS: Bool = false) {
        let mapper = HTTPErrorMapper(
            badURL: { JellyfinAPIError.badURL },
            transport: { error in
                if let urlError = error as? URLError { return JellyfinAPIError.transport(urlError) }
                return JellyfinAPIError.transport(URLError(.unknown))
            },
            unauthorized: { JellyfinAPIError.unauthorized },
            http: { code, body in JellyfinAPIError.http(status: code, body: body) },
            decode: { error in JellyfinAPIError.decode(reason: String(describing: error)) },
            invalidResponse: { JellyfinAPIError.invalidResponse },
            unauthorizedStatusCodes: [401, 403]
        )

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30

        self.transport = HTTPTransport(
            baseURL: baseURL,
            auth: .mutable(name: "Authorization", format: { token in
                JellyfinAuthHeader.value(token: token)
            }),
            initialMutableAuthValue: accessToken,
            allowsUntrustedTLS: allowsUntrustedTLS,
            sessionConfiguration: config,
            errorMapper: mapper
        )
    }

    func setAccessToken(_ token: String?) async { await transport.setMutableAuthValue(token) }
    func getAccessToken() async -> String? { await transport.currentMutableAuthValue() }

    // MARK: - Auth & System

    /// `POST /Users/AuthenticateByName`. On success, persists the returned access token
    /// inside this client so the caller can immediately make authenticated calls.
    /// The caller is still responsible for writing the token to Keychain.
    func authenticateByName(username: String, password: String) async throws -> JellyfinAuthResponse {
        let body = JellyfinAuthByNameBody(username: username, pw: password)
        let result: JellyfinAuthResponse = try await post("/Users/AuthenticateByName", body: body)
        await transport.setMutableAuthValue(result.accessToken)
        return result
    }

    func ping() async throws {
        try await getVoid("/System/Ping")
    }

    /// Reachable without authentication. Used during setup to validate URL correctness
    /// and surface server name/version before the user enters credentials.
    func getPublicSystemInfo() async throws -> JellyfinSystemPublicInfo {
        try await get("/System/Info/Public")
    }

    func getSystemInfo() async throws -> JellyfinSystemInfo {
        try await get("/System/Info")
    }

    func restartServer() async throws {
        try await postEmpty("/System/Restart")
    }

    func shutdownServer() async throws {
        try await postEmpty("/System/Shutdown")
    }

    // MARK: - Users

    func getUsers() async throws -> [JellyfinUser] {
        try await get("/Users")
    }

    func getUser(id: String) async throws -> JellyfinUser {
        try await get("/Users/\(id)")
    }

    func updateUserPolicy(id: String, policy: JellyfinUserPolicy) async throws {
        try await postVoid("/Users/\(id)/Policy", body: policy)
    }

    func updateUserConfiguration(id: String, configuration: JellyfinUserConfiguration) async throws {
        try await postVoid("/Users/\(id)/Configuration", body: configuration)
    }

    func updateUserPassword(
        id: String,
        currentPassword: String?,
        newPassword: String,
        resetPassword: Bool = false
    ) async throws {
        let body = JellyfinPasswordChangeBody(
            currentPw: currentPassword,
            newPw: newPassword,
            resetPassword: resetPassword
        )
        try await postVoid("/Users/\(id)/Password", body: body)
    }

    func deleteUser(id: String) async throws {
        try await deleteVoid("/Users/\(id)")
    }

    func createUser(name: String, password: String?) async throws -> JellyfinUser {
        let body = JellyfinCreateUserBody(name: name, password: password)
        return try await post("/Users/New", body: body)
    }

    // MARK: - Libraries

    func getVirtualFolders() async throws -> [JellyfinVirtualFolder] {
        try await get("/Library/VirtualFolders")
    }

    func getLibraryItems(
        includeItemTypes: [String],
        fields: [String] = ["ProviderIds", "Path", "DateCreated", "MediaSources"],
        recursive: Bool = true,
        startIndex: Int = 0,
        limit: Int = 500
    ) async throws -> JellyfinItemsResponse {
        var params = [
            "Recursive": String(recursive),
            "StartIndex": String(startIndex),
            "Limit": String(limit)
        ]
        if !includeItemTypes.isEmpty {
            params["IncludeItemTypes"] = includeItemTypes.joined(separator: ",")
        }
        if !fields.isEmpty {
            params["Fields"] = fields.joined(separator: ",")
        }
        return try await get("/Items", params: params)
    }

    func getAllLibraryItems(
        includeItemTypes: [String],
        fields: [String] = ["ProviderIds", "Path", "DateCreated", "MediaSources"],
        pageSize: Int = 500,
        maxItems: Int? = nil
    ) async throws -> [JellyfinLibraryItem] {
        var startIndex = 0
        var allItems: [JellyfinLibraryItem] = []

        while maxItems == nil || allItems.count < maxItems! {
            let requestLimit = if let maxItems {
                min(pageSize, maxItems - allItems.count)
            } else {
                pageSize
            }

            let response = try await getLibraryItems(
                includeItemTypes: includeItemTypes,
                fields: fields,
                startIndex: startIndex,
                limit: requestLimit
            )
            allItems.append(contentsOf: response.items)

            let loadedCount = startIndex + response.items.count
            guard
                !response.items.isEmpty,
                loadedCount < (response.totalRecordCount ?? loadedCount)
            else { break }
            startIndex = loadedCount
        }

        return allItems
    }

    func findItems(
        includeItemTypes: [String],
        anyProviderIdEquals: [(provider: String, id: String)],
        fields: [String] = ["ProviderIds", "Path", "DateCreated", "MediaSources"],
        limit: Int = 10
    ) async throws -> [JellyfinLibraryItem] {
        var params: [String: String] = [
            "Recursive": "true",
            "Limit": String(limit)
        ]
        if !includeItemTypes.isEmpty {
            params["IncludeItemTypes"] = includeItemTypes.joined(separator: ",")
        }
        if !fields.isEmpty {
            params["Fields"] = fields.joined(separator: ",")
        }
        if !anyProviderIdEquals.isEmpty {
            params["AnyProviderIdEquals"] = anyProviderIdEquals
                .map { "\($0.provider).\($0.id)" }
                .joined(separator: ",")
        }
        let response: JellyfinItemsResponse = try await get("/Items", params: params)
        return response.items
    }

    func searchItems(
        term: String,
        includeItemTypes: [String],
        limit: Int = 20
    ) async throws -> [JellyfinLibraryItem] {
        var params: [String: String] = [
            "SearchTerm": term,
            "Recursive": "true",
            "Limit": String(limit),
            "Fields": "ProviderIds,Path,DateCreated,MediaSources"
        ]
        if !includeItemTypes.isEmpty {
            params["IncludeItemTypes"] = includeItemTypes.joined(separator: ",")
        }
        let response: JellyfinItemsResponse = try await get("/Items", params: params)
        return response.items
    }

    func refreshAllLibraries() async throws {
        try await postEmpty("/Library/Refresh")
    }

    /// Trigger metadata refresh on a single library/item. Defaults match Jellyfin's
    /// "Scan Library" button: recursive, full metadata pass.
    func refreshItem(
        id: String,
        recursive: Bool = true,
        metadataRefreshMode: String = "FullRefresh",
        imageRefreshMode: String = "Default",
        replaceAllMetadata: Bool = false,
        replaceAllImages: Bool = false
    ) async throws {
        try await postEmpty("/Items/\(id)/Refresh", queryParams: [
            "Recursive": String(recursive),
            "MetadataRefreshMode": metadataRefreshMode,
            "ImageRefreshMode": imageRefreshMode,
            "ReplaceAllMetadata": String(replaceAllMetadata),
            "ReplaceAllImages": String(replaceAllImages)
        ])
    }

    // MARK: - Environment

    func getDrives() async throws -> [JellyfinFileSystemEntryInfo] {
        try await get("/Environment/Drives")
    }

    func getDirectoryContents(
        path: String,
        includeFiles: Bool = false,
        includeDirectories: Bool = true
    ) async throws -> [JellyfinFileSystemEntryInfo] {
        try await get("/Environment/DirectoryContents", params: Self.directoryContentsParams(
            path: path,
            includeFiles: includeFiles,
            includeDirectories: includeDirectories
        ))
    }

    func getParentPath(path: String) async throws -> String {
        try await get("/Environment/ParentPath", params: ["Path": path])
    }

    func validatePath(path: String) async throws -> Bool {
        try await get("/Environment/ValidatePath", params: ["Path": path])
    }

    nonisolated static func directoryContentsParams(
        path: String,
        includeFiles: Bool,
        includeDirectories: Bool
    ) -> [String: String] {
        [
            "Path": path,
            "IncludeFiles": String(includeFiles),
            "IncludeDirectories": String(includeDirectories)
        ]
    }

    // MARK: - Library Structure

    func addVirtualFolder(
        name: String,
        collectionType: String,
        paths: [String],
        refreshLibrary: Bool = true
    ) async throws {
        let body = JellyfinVirtualFolderBody(
            name: name,
            collectionType: collectionType,
            paths: paths,
            refreshLibrary: refreshLibrary
        )
        try await postVoid("/Library/VirtualFolders", body: body)
    }

    func removeVirtualFolder(name: String, refreshLibrary: Bool = true) async throws {
        try await deleteVoid("/Library/VirtualFolders", queryParams: [
            "name": name,
            "refreshLibrary": String(refreshLibrary)
        ])
    }

    func addMediaPath(libraryName: String, path: String, refreshLibrary: Bool = true) async throws {
        let body = JellyfinMediaPathBody(
            name: libraryName,
            pathInfo: JellyfinMediaPathInfo(path: path)
        )
        try await postVoid("/Library/VirtualFolders/Paths", body: body, queryParams: [
            "refreshLibrary": String(refreshLibrary)
        ])
    }

    func removeMediaPath(libraryName: String, path: String, refreshLibrary: Bool = true) async throws {
        try await deleteVoid("/Library/VirtualFolders/Paths", queryParams: [
            "name": libraryName,
            "path": path,
            "refreshLibrary": String(refreshLibrary)
        ])
    }

    func renameVirtualFolder(name: String, newName: String, refreshLibrary: Bool = true) async throws {
        try await postEmpty("/Library/VirtualFolders/Name", queryParams: [
            "name": name,
            "newName": newName,
            "refreshLibrary": String(refreshLibrary)
        ])
    }

    // MARK: - Sessions

    func getSessions() async throws -> [JellyfinSession] {
        try await get("/Sessions")
    }

    func sendMessage(sessionId: String, header: String, text: String, timeoutMs: Int? = 5000) async throws {
        let body = JellyfinSessionMessageBody(header: header, text: text, timeoutMs: timeoutMs)
        try await postVoid("/Sessions/\(sessionId)/Message", body: body)
    }

    func stopPlayback(sessionId: String) async throws {
        try await postEmpty("/Sessions/\(sessionId)/Playing/Stop")
    }

    // MARK: - Activity Log

    func getActivityLog(startIndex: Int = 0, limit: Int = 50, minDate: String? = nil) async throws -> JellyfinActivityResponse {
        var params = ["startIndex": String(startIndex), "limit": String(limit)]
        if let minDate { params["minDate"] = minDate }
        return try await get("/System/ActivityLog/Entries", params: params)
    }

    // MARK: - Scheduled Tasks

    func getScheduledTasks() async throws -> [JellyfinScheduledTask] {
        try await get("/ScheduledTasks")
    }

    func startScheduledTask(id: String) async throws {
        try await postEmpty("/ScheduledTasks/Running/\(id)")
    }

    func stopScheduledTask(id: String) async throws {
        try await deleteVoid("/ScheduledTasks/Running/\(id)")
    }

    // MARK: - Plugins

    func getPlugins() async throws -> [JellyfinPlugin] {
        try await get("/Plugins")
    }

    /// Pass `version` to delete a specific build; omit to remove the plugin entirely.
    func deletePlugin(id: String, version: String? = nil) async throws {
        let path = version.map { "/Plugins/\(id)/\($0)" } ?? "/Plugins/\(id)"
        try await deleteVoid(path)
    }

    // MARK: - HTTP Infrastructure

    private func get<T: Decodable>(_ path: String, params: [String: String] = [:]) async throws -> T {
        try await transport.get(path, queryItems: Self.queryItems(from: params))
    }

    private func getVoid(_ path: String, params: [String: String] = [:]) async throws {
        try await transport.getVoid(path, queryItems: Self.queryItems(from: params))
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: sending B) async throws -> T {
        try await transport.postCodable(path, body: body)
    }

    private func postVoid<B: Encodable>(_ path: String, body: sending B, queryParams: [String: String] = [:]) async throws {
        try await transport.postVoidCodable(path, body: body, queryItems: Self.queryItems(from: queryParams))
    }

    /// Body-less POST. Jellyfin uses these for command-style endpoints
    /// (`/System/Restart`, `/Library/Refresh`, `/ScheduledTasks/Running/{id}`).
    private func postEmpty(_ path: String, queryParams: [String: String] = [:]) async throws {
        try await transport.postVoid(path, queryItems: Self.queryItems(from: queryParams))
    }

    private func deleteVoid(_ path: String, queryParams: [String: String] = [:]) async throws {
        try await transport.delete(path, queryItems: Self.queryItems(from: queryParams))
    }

    private nonisolated static func queryItems(from params: [String: String]) -> [URLQueryItem] {
        guard !params.isEmpty else { return [] }
        return params.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}
