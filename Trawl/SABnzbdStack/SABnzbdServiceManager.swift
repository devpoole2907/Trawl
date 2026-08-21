import Foundation
import Observation

@MainActor
@Observable
final class SABnzbdServiceManager {
    private(set) var activeClient: SABnzbdAPIClient?
    private(set) var activeProfileID: UUID?
    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var isRefreshing: Bool = false
    private(set) var connectionError: String?
    private(set) var queue: SABnzbdQueue?
    private(set) var history: SABnzbdHistory?

    private var pollingTask: Task<Void, Never>?
    var pollingInterval: TimeInterval = 4.0

    /// Queue jobs plus nonterminal history entries (repair/unpack/move), matching
    /// what SABnzbd itself considers still "in flight" past the download stage.
    var activeJobs: [SABnzbdJob] {
        let queueJobs = queue?.jobs ?? []
        let postProcessingJobs = (history?.jobs ?? []).filter(\.isPostProcessing)
        return queueJobs + postProcessingJobs
    }

    /// Terminal history entries only (`Completed` / `Failed`).
    var historyJobs: [SABnzbdJob] {
        (history?.jobs ?? []).filter { $0.normalizedStatus.isTerminal }
    }

    func initialize(from profiles: [SABnzbdServiceProfile]) async {
        guard let profile = profiles.first(where: { $0.isEnabled }) ?? profiles.first else {
            disconnect()
            return
        }

        await connectService(profile)
    }

    func connectService(_ profile: SABnzbdServiceProfile) async {
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        do {
            guard let apiKey = try await storedAPIKey(for: profile), !apiKey.isEmpty else {
                clearActiveConnection()
                connectionError = "SABnzbd API key not found in Keychain. Add the server again from Settings."
                return
            }

            let client = SABnzbdAPIClient(
                baseURL: profile.hostURL,
                apiKey: apiKey,
                allowsUntrustedTLS: profile.allowsUntrustedTLS
            )

            let version: String
            let fetchedQueue: SABnzbdQueue
            do {
                async let versionResult = client.getVersion()
                async let queueResult = client.getQueue(start: 0, limit: 200)
                (version, fetchedQueue) = try await (versionResult, queueResult)
            } catch SABnzbdAPIError.unauthorized {
                clearActiveConnection()
                connectionError = "SABnzbd rejected the API key. Update it in Settings."
                return
            } catch SABnzbdAPIError.insufficientAPIKey {
                clearActiveConnection()
                connectionError = "Trawl needs the full SABnzbd API key, not the add-only NZB key."
                return
            }

            activeClient = client
            activeProfileID = profile.id
            isConnected = true
            queue = fetchedQueue
            history = nil
            profile.serverVersion = version
            profile.lastSynced = .now

            await refresh()
        } catch {
            connectionError = error.localizedDescription
            clearActiveConnection()
        }
    }

    func disconnect() {
        stopPolling()
        clearActiveConnection()
        connectionError = nil
    }

    func refresh() async {
        guard let client = activeClient, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let queueResult = client.getQueue(start: 0, limit: 200)
            async let historyResult = client.getHistory(
                start: 0,
                limit: 200,
                lastHistoryUpdate: history?.lastHistoryUpdate
            )
            let (fetchedQueue, fetchedHistory) = try await (queueResult, historyResult)
            queue = fetchedQueue
            // A `nil` result means SABnzbd's `{ "history": false }` shape-changing
            // response — history hasn't changed since `lastHistoryUpdate`, so keep it.
            if let fetchedHistory {
                history = fetchedHistory
            }
            connectionError = nil
        } catch SABnzbdAPIError.unauthorized {
            connectionError = "SABnzbd rejected the API key. Update it in Settings."
            isConnected = false
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func startPolling() {
        guard pollingTask == nil, activeClient != nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.pollingInterval))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Global actions

    func pauseAll() async throws {
        guard let client = activeClient else { return }
        try await client.pauseQueue()
        await refresh()
    }

    func resumeAll() async throws {
        guard let client = activeClient else { return }
        try await client.resumeQueue()
        await refresh()
    }

    // MARK: - Job actions

    func pause(job: SABnzbdJob) async throws {
        guard let client = activeClient else { return }
        try await client.pauseJobs(ids: [job.id])
        await refresh()
    }

    func resume(job: SABnzbdJob) async throws {
        guard let client = activeClient else { return }
        try await client.resumeJobs(ids: [job.id])
        await refresh()
    }

    func retry(job: SABnzbdJob) async throws {
        guard let client = activeClient else { return }
        _ = try await client.retryHistoryJob(id: job.id)
        await refresh()
    }

    func delete(job: SABnzbdJob, deleteFiles: Bool = false) async throws {
        guard let client = activeClient else { return }
        try await client.deleteQueueJobs(ids: [job.id], deleteFiles: deleteFiles)
        await refresh()
    }

    func deleteHistory(job: SABnzbdJob, permanently: Bool = false, deleteFiles: Bool = false) async throws {
        guard let client = activeClient else { return }
        try await client.deleteHistoryJobs(ids: [job.id], permanently: permanently, deleteFiles: deleteFiles)
        await refresh()
    }

    /// `priority.apiValue` is `nil` for `.default`, which only makes sense at
    /// add time (it means "use the category default"). Callers should exclude
    /// it from post-add priority pickers.
    func setPriority(job: SABnzbdJob, priority: AddDownloadPriority) async throws {
        guard let client = activeClient, let value = priority.apiValue else { return }
        try await client.setPriority(id: job.id, priority: value)
        await refresh()
    }

    func setCategory(job: SABnzbdJob, category: String) async throws {
        guard let client = activeClient else { return }
        try await client.setCategory(id: job.id, category: category)
        await refresh()
    }

    // MARK: - Server configuration

    /// Fetched on demand by the add sheet rather than polled — categories and scripts
    /// change when the user edits SABnzbd's config, not while downloads run.
    func categoriesAndScripts() async -> (categories: [String], scripts: [String]) {
        guard let client = activeClient else { return ([], []) }
        async let categories = try? client.getCategories()
        async let scripts = try? client.getScripts()
        return (await categories ?? [], await scripts ?? [])
    }

    // MARK: - Category configuration

    private(set) var categoryConfigs: [SABnzbdCategory] = []
    private(set) var scripts: [String] = []
    private(set) var isLoadingCategoryConfigs = false
    private(set) var categoryConfigsError: String?

    func refreshCategoryConfigs() async {
        guard let client = activeClient else {
            categoryConfigs = []
            return
        }

        isLoadingCategoryConfigs = true
        defer { isLoadingCategoryConfigs = false }

        do {
            async let categories = client.getCategoryConfigs()
            async let scriptList = try? client.getScripts()
            categoryConfigs = try await categories
            scripts = await scriptList ?? []
            categoryConfigsError = nil
        } catch {
            categoryConfigsError = error.localizedDescription
        }
    }

    func saveCategory(_ category: SABnzbdCategory, originalName: String?) async throws {
        guard let client = activeClient else { return }
        try await client.saveCategory(category, originalName: originalName)
        await refreshCategoryConfigs()
    }

    func deleteCategory(name: String) async throws {
        guard let client = activeClient else { return }
        try await client.deleteCategory(name: name)
        await refreshCategoryConfigs()
    }

    // MARK: - News servers

    /// Loaded on demand rather than polled: this changes when a human changes it,
    /// and the payload carries credentials worth not holding longer than needed.
    private(set) var newsServers: [SABnzbdNewsServer] = []
    private(set) var isLoadingNewsServers = false
    private(set) var newsServersError: String?

    func refreshNewsServers() async {
        guard let client = activeClient else {
            newsServers = []
            return
        }

        isLoadingNewsServers = true
        defer { isLoadingNewsServers = false }

        do {
            newsServers = try await client.getNewsServers()
            newsServersError = nil
        } catch {
            newsServersError = error.localizedDescription
        }
    }

    func saveNewsServer(_ server: SABnzbdNewsServer, originalName: String?) async throws {
        guard let client = activeClient else { return }
        try await client.saveNewsServer(server, originalName: originalName)
        await refreshNewsServers()
    }

    func testNewsServer(_ server: SABnzbdNewsServer) async throws -> (succeeded: Bool, message: String) {
        guard let client = activeClient else {
            return (false, "Not connected to SABnzbd.")
        }
        return try await client.testNewsServer(server)
    }

    func deleteNewsServer(name: String) async throws {
        guard let client = activeClient else { return }
        try await client.deleteNewsServer(name: name)
        await refreshNewsServers()
    }

    /// Drops the cached credentials once the editor is gone.
    func clearNewsServers() {
        newsServers = []
        newsServersError = nil
    }

    /// `value` is either a bare percentage of line speed (`"50"`, `"0"` for
    /// unlimited) or an absolute rate with a K/M suffix (`"1500K"`).
    func setSpeedLimit(_ value: String) async throws {
        guard let client = activeClient else { return }
        try await client.setSpeedLimit(value)
        await refresh()
    }

    /// Pauses the whole queue for `minutes`; SABnzbd resumes it automatically.
    func pauseForDuration(minutes: Int) async throws {
        guard let client = activeClient else { return }
        try await client.setPauseDuration(minutes: minutes)
        await refresh()
    }

    /// Clears every terminal (completed/failed) history entry.
    func clearHistory() async throws {
        guard let client = activeClient else { return }
        try await client.clearHistory()
        await refresh()
    }

    // MARK: - Add NZB

    @discardableResult
    func addURL(_ url: URL, options: SABnzbdAddOptions = .init()) async throws -> [String] {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        let ids = try await client.addURL(url, options: options)
        await refresh()
        return ids
    }

    @discardableResult
    func addNZB(data: Data, filename: String, options: SABnzbdAddOptions = .init()) async throws -> [String] {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        let ids = try await client.addNZB(data: data, filename: filename, options: options)
        await refresh()
        return ids
    }

    // MARK: - Helpers

    private func storedAPIKey(for profile: SABnzbdServiceProfile) async throws -> String? {
        guard let value = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey) else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clearActiveConnection() {
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        queue = nil
        history = nil
    }
}

#if DEBUG
extension SABnzbdServiceManager {
    enum PreviewState {
        case connected, populated, connecting, error(String), notConfigured
    }

    static func preview(_ state: PreviewState = .connected) -> SABnzbdServiceManager {
        let mgr = SABnzbdServiceManager()
        switch state {
        case .connected:
            mgr.activeProfileID = UUID()
            mgr.isConnected = true
        case .populated:
            mgr.activeProfileID = UUID()
            mgr.isConnected = true
            mgr.queue = .preview
            mgr.history = .preview
        case .connecting:
            mgr.isConnecting = true
        case .error(let message):
            mgr.connectionError = message
        case .notConfigured:
            break
        }
        return mgr
    }
}
#endif
