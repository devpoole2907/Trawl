import Foundation

/// HTTP client for SABnzbd's query-based API.
actor SABnzbdAPIClient {
    nonisolated var baseURL: String { transport.baseURL }

    private let transport: HTTPTransport
    private let apiKey: String
    private nonisolated let apiPath: String

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false) {
        let mapper = HTTPErrorMapper(
            badURL: { SABnzbdAPIError.badURL },
            transport: { error in
                if let urlError = error as? URLError { return SABnzbdAPIError.transport(urlError) }
                return SABnzbdAPIError.transport(URLError(.unknown))
            },
            unauthorized: { SABnzbdAPIError.unauthorized },
            http: { code, body in SABnzbdAPIError.http(status: code, body: body) },
            decode: { error in SABnzbdAPIError.decode(reason: String(describing: error)) },
            invalidResponse: { SABnzbdAPIError.invalidResponse },
            unauthorizedStatusCodes: [401, 403]
        )

        let trimmedURL = Self.trimmedBaseURL(baseURL)
        self.apiKey = apiKey
        self.apiPath = Self.hasAPIPath(trimmedURL) ? "" : "/api"
        self.transport = HTTPTransport(
            baseURL: trimmedURL,
            auth: .none,
            allowsUntrustedTLS: allowsUntrustedTLS,
            errorMapper: mapper
        )
    }

    // MARK: - Connection and authentication

    func getVersion() async throws -> String {
        let envelope: SABnzbdVersionEnvelope = try await request(mode: "version")
        return envelope.version
    }

    func getAuthentication() async throws -> SABnzbdAuthentication {
        let envelope: SABnzbdAuthenticationEnvelope = try await request(
            mode: "auth",
            extra: [URLQueryItem(name: "key", value: apiKey)]
        )
        return envelope.authentication
    }

    // MARK: - Server configuration

    /// SABnzbd absolutely does list its categories — `mode=get_cats` — and its
    /// post-processing scripts alongside them. Deriving categories from whatever
    /// happened to be in the queue meant a fresh install offered none at all.
    func getCategories() async throws -> [String] {
        let envelope: SABnzbdCategoriesEnvelope = try await request(mode: "get_cats")
        return Self.withoutServerDefault(envelope.categories)
    }

    func getScripts() async throws -> [String] {
        let envelope: SABnzbdScriptsEnvelope = try await request(mode: "get_scripts")
        return Self.withoutServerDefault(envelope.scripts)
    }

    /// `value` is either a bare percentage of line speed (`"50"`, `"0"` for
    /// unlimited) or an absolute rate with a K/M suffix (`"1500K"`).
    func setSpeedLimit(_ value: String) async throws {
        try await performCommand(mode: "config", name: "speedlimit", extra: [URLQueryItem(name: "value", value: value)])
    }

    /// Pauses the whole queue for `minutes`; SABnzbd resumes it automatically.
    func setPauseDuration(minutes: Int) async throws {
        try await performCommand(mode: "config", name: "set_pause", extra: [URLQueryItem(name: "value", value: String(minutes))])
    }

    /// Clears every terminal (completed/failed) history entry.
    func clearHistory() async throws {
        try await performCommand(mode: "history", name: "delete", extra: [URLQueryItem(name: "value", value: "all")])
    }

    // MARK: - Category configuration

    /// The full settings behind each category. `get_cats` returns names only,
    /// which is all a picker needs but not enough to manage them.
    func getCategoryConfigs() async throws -> [SABnzbdCategory] {
        let envelope: SABnzbdCategoriesConfigEnvelope = try await request(
            mode: "get_config",
            extra: [URLQueryItem(name: "section", value: "categories")]
        )
        return envelope.config.categories ?? []
    }

    /// Same `keyword`/`name` rename handling as the news servers.
    func saveCategory(_ category: SABnzbdCategory, originalName: String?) async throws {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "section", value: "categories"),
            URLQueryItem(name: "keyword", value: originalName ?? category.name),
            URLQueryItem(name: "name", value: category.name)
        ]

        if let postProcessing = category.postProcessing {
            items.append(URLQueryItem(name: "pp", value: String(postProcessing)))
        }
        // Sent even when empty so clearing a script or folder actually clears it.
        items.append(URLQueryItem(name: "script", value: category.script ?? ""))
        items.append(URLQueryItem(name: "dir", value: category.directory ?? ""))
        if let priority = category.priority {
            items.append(URLQueryItem(name: "priority", value: String(priority)))
        }

        _ = try await transport.getData(apiPath, queryItems: queryItems(mode: "set_config", name: nil, extra: items))
    }

    func deleteCategory(name: String) async throws {
        try await performCommand(
            mode: "del_config",
            extra: [
                URLQueryItem(name: "section", value: "categories"),
                URLQueryItem(name: "keyword", value: name)
            ]
        )
    }

    // MARK: - News servers

    /// SABnzbd's news servers, as configured in its own settings. The response
    /// includes each server's password in plain text — it is the only way SABnzbd
    /// offers to read this section, so an editor that prefills has no alternative.
    func getNewsServers() async throws -> [SABnzbdNewsServer] {
        let envelope: SABnzbdServersEnvelope = try await request(
            mode: "get_config",
            extra: [URLQueryItem(name: "section", value: "servers")]
        )
        return envelope.config.servers ?? []
    }

    /// Creates or updates one news server.
    ///
    /// `originalName` is the name SABnzbd currently knows the server by; it goes
    /// out as `keyword`, which is how `set_config` addresses an existing entry,
    /// while `name` carries the (possibly new) name so a rename works. For a new
    /// server the two are the same. Booleans go out as 1/0 because that is what
    /// SABnzbd's config parser accepts on the way in, regardless of what shape it
    /// hands back on the way out.
    func saveNewsServer(_ server: SABnzbdNewsServer, originalName: String?) async throws {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "section", value: "servers"),
            URLQueryItem(name: "keyword", value: originalName ?? server.name),
            URLQueryItem(name: "name", value: server.name),
            URLQueryItem(name: "host", value: server.host),
            URLQueryItem(name: "port", value: String(server.port)),
            URLQueryItem(name: "connections", value: String(server.connections)),
            URLQueryItem(name: "ssl", value: server.ssl ? "1" : "0"),
            URLQueryItem(name: "enable", value: server.enabled ? "1" : "0"),
            URLQueryItem(name: "optional", value: server.optional ? "1" : "0")
        ]

        if let displayName = server.displayName {
            items.append(URLQueryItem(name: "displayname", value: displayName))
        }
        if let username = server.username {
            items.append(URLQueryItem(name: "username", value: username))
        }
        if let password = server.password {
            items.append(URLQueryItem(name: "password", value: password))
        }
        if let retention = server.retention {
            items.append(URLQueryItem(name: "retention", value: String(retention)))
        }
        if let timeout = server.timeout {
            items.append(URLQueryItem(name: "timeout", value: String(timeout)))
        }
        if let priority = server.priority {
            items.append(URLQueryItem(name: "priority", value: String(priority)))
        }
        if let sslVerify = server.sslVerify {
            items.append(URLQueryItem(name: "ssl_verify", value: String(sslVerify)))
        }
        if let notes = server.notes {
            items.append(URLQueryItem(name: "notes", value: notes))
        }

        // set_config echoes the saved section rather than a plain status envelope,
        // so a decode into the command shape would fail on a successful write.
        _ = try await transport.getData(apiPath, queryItems: queryItems(mode: "set_config", name: nil, extra: items))
    }

    /// Asks SABnzbd to open a real connection with these settings. Verified
    /// against 5.1.1: replies `{"value":{"result":Bool,"message":String}}` — a
    /// failed test is a successful request, so the message is returned rather
    /// than thrown.
    func testNewsServer(_ server: SABnzbdNewsServer) async throws -> (succeeded: Bool, message: String) {
        let envelope: SABnzbdServerTestEnvelope = try await request(
            mode: "config",
            name: "test_server",
            extra: [
                URLQueryItem(name: "host", value: server.host),
                URLQueryItem(name: "port", value: String(server.port)),
                URLQueryItem(name: "username", value: server.username ?? ""),
                URLQueryItem(name: "password", value: server.password ?? ""),
                URLQueryItem(name: "connections", value: String(server.connections)),
                URLQueryItem(name: "ssl", value: server.ssl ? "1" : "0")
            ]
        )
        return (
            envelope.value.result ?? false,
            envelope.value.message ?? "No response from SABnzbd."
        )
    }

    func deleteNewsServer(name: String) async throws {
        try await performCommand(
            mode: "del_config",
            extra: [
                URLQueryItem(name: "section", value: "servers"),
                URLQueryItem(name: "keyword", value: name)
            ]
        )
    }

    /// Drops SABnzbd's own "server default" sentinels; Trawl renders that choice itself.
    private nonisolated static func withoutServerDefault(_ values: [String]) -> [String] {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "*" && $0.caseInsensitiveCompare("Default") != .orderedSame && $0.caseInsensitiveCompare("None") != .orderedSame }
    }

    // MARK: - Queue and history

    func getQueue(
        start: Int = 0,
        limit: Int = 200,
        search: String? = nil,
        statuses: [String] = []
    ) async throws -> SABnzbdQueue {
        var extra = [
            URLQueryItem(name: "start", value: String(max(start, 0))),
            URLQueryItem(name: "limit", value: String(max(limit, 1)))
        ]
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            extra.append(URLQueryItem(name: "search", value: search))
        }
        if !statuses.isEmpty {
            extra.append(URLQueryItem(name: "status", value: statuses.joined(separator: ",")))
        }
        let envelope: SABnzbdQueueEnvelope = try await request(mode: "queue", extra: extra)
        return envelope.queue
    }

    /// Returns `nil` only when `lastHistoryUpdate` matched and SABnzbd replied
    /// with its shape-changing `{ "history": false }` polling response.
    func getHistory(
        start: Int = 0,
        limit: Int = 200,
        statuses: [String] = [],
        lastHistoryUpdate: Int? = nil
    ) async throws -> SABnzbdHistory? {
        var extra = [
            URLQueryItem(name: "start", value: String(max(start, 0))),
            URLQueryItem(name: "limit", value: String(max(limit, 1)))
        ]
        if !statuses.isEmpty {
            extra.append(URLQueryItem(name: "status", value: statuses.joined(separator: ",")))
        }
        if let lastHistoryUpdate {
            extra.append(URLQueryItem(name: "last_history_update", value: String(lastHistoryUpdate)))
        }
        let envelope: SABnzbdHistoryEnvelope = try await request(mode: "history", extra: extra)
        return envelope.history
    }

    // MARK: - Queue actions

    func pauseQueue() async throws {
        try await performCommand(mode: "pause")
    }

    func resumeQueue() async throws {
        try await performCommand(mode: "resume")
    }

    func pauseJobs(ids: [String]) async throws {
        try await performQueueCommand(name: "pause", ids: ids)
    }

    func resumeJobs(ids: [String]) async throws {
        try await performQueueCommand(name: "resume", ids: ids)
    }

    func deleteQueueJobs(ids: [String], deleteFiles: Bool = false) async throws {
        var extra = try jobIDsQuery(ids)
        if deleteFiles { extra.append(URLQueryItem(name: "del_files", value: "1")) }
        try await performCommand(mode: "queue", name: "delete", extra: extra)
    }

    /// A queued job's priority and category are otherwise fixed at add time;
    /// these let the user change them after the fact.
    func setPriority(id: String, priority: Int) async throws {
        try await performQueueCommand(name: "priority", id: id, value2: String(priority))
    }

    func setCategory(id: String, category: String) async throws {
        try await performQueueCommand(name: "change_cat", id: id, value2: category)
    }

    /// Moves a queued job to `position` (0-based) within the queue.
    func reorderJob(id: String, toPosition position: Int) async throws {
        try await performCommand(
            mode: "switch",
            extra: [
                URLQueryItem(name: "value", value: try validatedID(id)),
                URLQueryItem(name: "value2", value: String(position))
            ]
        )
    }

    // MARK: - History actions

    @discardableResult
    func retryHistoryJob(id: String, password: String? = nil) async throws -> String? {
        var extra = [URLQueryItem(name: "value", value: try validatedID(id))]
        if let password, !password.isEmpty {
            extra.append(URLQueryItem(name: "password", value: password))
        }
        let response = try await command(mode: "retry", extra: extra)
        return response.nzoID ?? response.nzoIDs.first
    }

    func deleteHistoryJobs(
        ids: [String],
        permanently: Bool = false,
        deleteFiles: Bool = false
    ) async throws {
        var extra = try jobIDsQuery(ids)
        if permanently { extra.append(URLQueryItem(name: "archive", value: "0")) }
        if deleteFiles { extra.append(URLQueryItem(name: "del_files", value: "1")) }
        try await performCommand(mode: "history", name: "delete", extra: extra)
    }

    // MARK: - Add NZB

    @discardableResult
    func addURL(_ url: URL, options: SABnzbdAddOptions = .init()) async throws -> [String] {
        var extra = [URLQueryItem(name: "name", value: url.absoluteString)]
        extra.append(contentsOf: Self.addOptionItems(options))
        let response = try await command(mode: "addurl", extra: extra)
        return response.nzoIDs
    }

    @discardableResult
    func addNZB(
        data: Data,
        filename: String,
        options: SABnzbdAddOptions = .init()
    ) async throws -> [String] {
        guard !data.isEmpty else { throw SABnzbdAPIError.invalidResponse }
        var fields = [URLQueryItem(name: "mode", value: "addfile")]
        fields.append(contentsOf: Self.addOptionItems(options))
        let response: SABnzbdCommandResponse = try await transport.postMultipart(
            apiPath,
            fileData: data,
            fieldName: "nzbfile",
            filename: filename,
            mimeType: "application/x-nzb",
            formItems: fields,
            queryItems: commonItems
        )
        return try validated(response).nzoIDs
    }

    // MARK: - Request helpers

    private var commonItems: [URLQueryItem] {
        [
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "apikey", value: apiKey)
        ]
    }

    private func request<T: Decodable>(
        mode: String,
        name: String? = nil,
        extra: [URLQueryItem] = []
    ) async throws -> T {
        let data = try await transport.getData(apiPath, queryItems: queryItems(mode: mode, name: name, extra: extra))
        if let apiError = try? JSONDecoder().decode(SABnzbdErrorResponse.self, from: data),
           apiError.status == false {
            throw SABnzbdAPIError.api(message: apiError.error ?? "The operation failed.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SABnzbdAPIError.decode(reason: String(describing: error))
        }
    }

    private func command(
        mode: String,
        name: String? = nil,
        extra: [URLQueryItem] = []
    ) async throws -> SABnzbdCommandResponse {
        let response: SABnzbdCommandResponse = try await request(mode: mode, name: name, extra: extra)
        return try validated(response)
    }

    private func performCommand(
        mode: String,
        name: String? = nil,
        extra: [URLQueryItem] = []
    ) async throws {
        _ = try await command(mode: mode, name: name, extra: extra)
    }

    private func performQueueCommand(name: String, ids: [String]) async throws {
        try await performCommand(mode: "queue", name: name, extra: jobIDsQuery(ids))
    }

    /// Same as `performQueueCommand(name:ids:)`, but for the `value`/`value2`
    /// shaped queue commands (priority, category, reorder) that act on one job.
    private func performQueueCommand(name: String, id: String, value2: String) async throws {
        try await performCommand(
            mode: "queue",
            name: name,
            extra: [
                URLQueryItem(name: "value", value: try validatedID(id)),
                URLQueryItem(name: "value2", value: value2)
            ]
        )
    }

    private func queryItems(
        mode: String,
        name: String?,
        extra: [URLQueryItem]
    ) -> [URLQueryItem] {
        var items = commonItems
        items.append(URLQueryItem(name: "mode", value: mode))
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        items.append(contentsOf: extra)
        return items
    }

    private func jobIDsQuery(_ ids: [String]) throws -> [URLQueryItem] {
        let clean = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { throw SABnzbdAPIError.invalidResponse }
        return [URLQueryItem(name: "value", value: clean.joined(separator: ","))]
    }

    private func validatedID(_ id: String) throws -> String {
        let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SABnzbdAPIError.invalidResponse }
        return clean
    }

    private func validated(_ response: SABnzbdCommandResponse) throws -> SABnzbdCommandResponse {
        if response.status == false {
            throw SABnzbdAPIError.api(message: response.error ?? "The operation failed.")
        }
        if let error = response.error, !error.isEmpty {
            throw SABnzbdAPIError.api(message: error)
        }
        return response
    }

    private nonisolated static func addOptionItems(_ options: SABnzbdAddOptions) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let name = options.name?.nilIfBlank { items.append(URLQueryItem(name: "nzbname", value: name)) }
        if let password = options.password?.nilIfBlank { items.append(URLQueryItem(name: "password", value: password)) }
        if let category = options.category?.nilIfBlank { items.append(URLQueryItem(name: "cat", value: category)) }
        if let script = options.script?.nilIfBlank { items.append(URLQueryItem(name: "script", value: script)) }
        if let priority = options.priority { items.append(URLQueryItem(name: "priority", value: String(priority))) }
        if let postProcessing = options.postProcessing { items.append(URLQueryItem(name: "pp", value: String(postProcessing))) }
        return items
    }

    private nonisolated static func trimmedBaseURL(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private nonisolated static func hasAPIPath(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last?.lowercased() == "api"
    }
}

private nonisolated extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
