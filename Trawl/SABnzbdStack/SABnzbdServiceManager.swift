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
    /// Whether a refresh has ever completed. `isRefreshing` flips true on every
    /// poll, so a first-load spinner keyed off it alone blinks the whole view
    /// once per cycle whenever the queue is empty.
    private(set) var hasRefreshedOnce: Bool = false
    private(set) var connectionError: String?
    private(set) var queue: SABnzbdQueue?
    private(set) var history: SABnzbdHistory?

    private var pollingTask: Task<Void, Never>?
    /// Whether a view has asked for polling, as distinct from whether polling is
    /// currently possible. `startPolling()` used to be a silent no-op when it ran
    /// before the client existed - which is exactly what a cold launch into the
    /// Downloads tab does - leaving the queue stale for the whole session with
    /// nothing to retry it. The request is remembered so the connection can start
    /// the poll the moment it is able to.
    private var pollingRequested = false
    private var pollingGeneration = 0
    /// Bumped whenever the manager commits to a different connection - a new
    /// `connectService` attempt, or an explicit `disconnect`. Every async
    /// operation stamps it on entry and re-checks it before touching shared
    /// state, so a slow response addressed to the previous server can never
    /// land under the newly selected profile.
    private var connectionGeneration = 0
    /// The connection generation whose refresh is currently in flight. Keyed by
    /// generation rather than by the plain `isRefreshing` flag: a newly connected
    /// profile's first refresh must not be swallowed because the *previous*
    /// profile's refresh is still waiting on a slow server.
    private var refreshingGeneration: Int?
    private let sessionConfiguration: URLSessionConfiguration
    private let waitForPollingInterval: @Sendable (TimeInterval) async -> Void
    private let didFinishRefresh: @MainActor @Sendable () -> Void
    private(set) var isPolling = false
    var pollingInterval: TimeInterval = 4.0

    init(
        sessionConfiguration: URLSessionConfiguration = .makeTrawlSecure(),
        waitForPollingInterval: @escaping @Sendable (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(for: .seconds(interval))
        },
        didFinishRefresh: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.waitForPollingInterval = waitForPollingInterval
        self.didFinishRefresh = didFinishRefresh
    }

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
        connectionGeneration += 1
        let generation = connectionGeneration
        isConnecting = true
        connectionError = nil
        // Only the newest attempt owns the spinner; an older one finishing late
        // must not declare the connection settled.
        defer {
            if connectionGeneration == generation { isConnecting = false }
        }

        do {
            let storedKey = try await storedAPIKey(for: profile)
            guard connectionGeneration == generation else { return }
            guard let apiKey = storedKey, !apiKey.isEmpty else {
                clearActiveConnection()
                connectionError = "SABnzbd API key not found in Keychain. Add the server again from Settings."
                return
            }

            let client = SABnzbdAPIClient(
                baseURL: profile.hostURL,
                apiKey: apiKey,
                allowsUntrustedTLS: profile.allowsUntrustedTLS,
                sessionConfiguration: sessionConfiguration
            )

            let version: String
            let fetchedQueue: SABnzbdQueue
            // Both still run concurrently, but their outcomes are kept apart on
            // purpose. SABnzbd issues two key tiers, and against a real 5.1.1 server
            // the add-only "NZB key" is *accepted* by `mode=version` and *rejected*
            // by `mode=queue`. Which of the two calls failed is therefore the only
            // signal that separates a wrong key from the right key of the wrong tier,
            // and `async let` with a combined `try await` throws away exactly that.
            let versionTask = Task { try await client.getVersion() }
            let queueTask = Task { try await client.getQueue(start: 0, limit: 200) }
            let versionOutcome = await versionTask.result
            let queueOutcome = await queueTask.result

            do {
                version = try versionOutcome.get()
                fetchedQueue = try queueOutcome.get()
            } catch SABnzbdAPIError.unauthorized {
                guard connectionGeneration == generation else { return }
                clearActiveConnection()
                let versionWasAccepted = (try? versionOutcome.get()) != nil
                connectionError = versionWasAccepted
                    ? "Trawl needs the full SABnzbd API key, not the add-only NZB key."
                    : "SABnzbd rejected the API key. Update it in Settings."
                return
            }

            // A newer connection (or a disconnect) happened while this server was
            // answering. Its client, queue, and version belong to a profile the
            // user has already navigated away from - drop the whole result.
            guard connectionGeneration == generation else { return }

            activeClient = client
            activeProfileID = profile.id
            isConnected = true
            queue = fetchedQueue
            history = nil
            profile.serverVersion = version
            profile.lastSynced = .now

            // A view may have asked for polling before this connection existed.
            startPollingIfPossible()

            await refresh()
        } catch {
            guard connectionGeneration == generation else { return }
            connectionError = error.localizedDescription
            clearActiveConnection()
        }
    }

    func disconnect() {
        // Retires any connect or refresh still in flight. `isConnecting` is
        // cleared here because the retired attempt's own `defer` deliberately
        // no longer owns it.
        connectionGeneration += 1
        // Polling becomes impossible here, not unwanted - a profile switch
        // disconnects and reconnects while the same view stays on screen, and that
        // view's request to poll outlives the connection it was made against.
        // Only the view's own disappearance withdraws the request.
        cancelPollingTask()
        clearActiveConnection()
        connectionError = nil
        isConnecting = false
    }

    func refresh() async {
        let generation = connectionGeneration
        guard let client = activeClient, refreshingGeneration != generation else { return }
        refreshingGeneration = generation
        isRefreshing = true
        let previousHistoryJobs = history?.jobs
        defer {
            // Only the refresh that still owns the flag may release it; a stale
            // one finishing late would otherwise clear the current profile's.
            if refreshingGeneration == generation {
                refreshingGeneration = nil
                isRefreshing = false
            }
            if connectionGeneration == generation {
                hasRefreshedOnce = true
            }
            didFinishRefresh()
        }

        do {
            async let queueResult = client.getQueue(start: 0, limit: 200)
            async let historyResult = client.getHistory(
                start: 0,
                limit: 200,
                lastHistoryUpdate: history?.lastHistoryUpdate
            )
            let (fetchedQueue, fetchedHistory) = try await (queueResult, historyResult)
            // This payload describes whichever server `client` points at. If the
            // manager has since moved on, publishing it would show the old
            // server's queue under the new profile and misattribute completions.
            guard isCurrentConnection(generation: generation, client: client) else { return }
            queue = fetchedQueue
            // A `nil` result means SABnzbd's `{ "history": false }` shape-changing
            // response - history hasn't changed since `lastHistoryUpdate`, so keep it.
            if let fetchedHistory {
                history = fetchedHistory
                announceCompletions(
                    Self.newlyCompletedJobs(
                        previous: previousHistoryJobs,
                        current: fetchedHistory.jobs
                    )
                )
            }
            connectionError = nil
        } catch SABnzbdAPIError.unauthorized {
            guard isCurrentConnection(generation: generation, client: client) else { return }
            cancelPollingTask()
            clearActiveConnection()
            connectionError = "SABnzbd rejected the API key. Update it in Settings."
        } catch {
            guard isCurrentConnection(generation: generation, client: client) else { return }
            connectionError = error.localizedDescription
        }
    }

    /// True only while `client` is still the manager's live client for the
    /// connection that `generation` was stamped from. The identity check covers
    /// the cases the counter cannot: a connection cleared in place by a 401, or
    /// by a failed reconnect.
    private func isCurrentConnection(generation: Int, client: SABnzbdAPIClient) -> Bool {
        connectionGeneration == generation && activeClient === client
    }

    /// The first history response establishes a baseline. Later responses only
    /// announce jobs that newly entered Completed, including jobs that were
    /// already present in history while repairing or unpacking.
    nonisolated static func newlyCompletedJobs(
        previous: [SABnzbdJob]?,
        current: [SABnzbdJob]
    ) -> [SABnzbdJob] {
        guard let previous else { return [] }
        let previouslyCompletedIDs = Set(
            previous
                .filter { $0.normalizedStatus == .completed }
                .map { $0.id.lowercased() }
        )
        return current.filter {
            $0.normalizedStatus == .completed
                && !previouslyCompletedIDs.contains($0.id.lowercased())
        }
    }

    private func announceCompletions(_ jobs: [SABnzbdJob]) {
        guard !jobs.isEmpty else { return }
        if jobs.count == 1, let job = jobs.first {
            InAppNotificationCenter.shared.showDownloadCompleted(name: job.name)
        } else {
            InAppNotificationCenter.shared.showSuccess(
                title: "Downloads Complete",
                message: "\(jobs.count) SABnzbd downloads completed."
            )
        }
    }

    func startPolling() {
        pollingRequested = true
        startPollingIfPossible()
    }

    /// Starts the poll loop when there is something to poll. Safe to call
    /// repeatedly: the caller does not have to know whether a client exists yet.
    private func startPollingIfPossible() {
        guard pollingRequested, pollingTask == nil, activeClient != nil else { return }
        pollingGeneration += 1
        let generation = pollingGeneration
        isPolling = true
        pollingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pollingGeneration == generation {
                    self.isPolling = false
                    self.pollingTask = nil
                }
            }
            while !Task.isCancelled {
                await self.waitForPollingInterval(self.pollingInterval)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    /// Stops polling and withdraws the request: the view that wanted it is gone,
    /// so a later reconnect must not silently resume it.
    func stopPolling() {
        pollingRequested = false
        cancelPollingTask()
    }

    /// Stops the loop but keeps the request standing, for when polling is
    /// impossible rather than unwanted - a rejected API key clears the client, and
    /// the view asking for the queue is still on screen. Reconnecting resumes it.
    private func cancelPollingTask() {
        pollingGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    // MARK: - Global actions

    func pauseAll() async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        try await client.pauseQueue()
        await refresh()
    }

    func resumeAll() async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        try await client.resumeQueue()
        await refresh()
    }

    // MARK: - Job actions

    func pause(job: SABnzbdJob) async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        try await client.pauseJobs(ids: [job.id])
        await refresh()
    }

    func resume(job: SABnzbdJob) async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        try await client.resumeJobs(ids: [job.id])
        await refresh()
    }

    func retry(job: SABnzbdJob) async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        _ = try await client.retryHistoryJob(id: job.id)
        await refresh()
    }

    func delete(job: SABnzbdJob, deleteFiles: Bool = false) async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        try await client.deleteQueueJobs(ids: [job.id], deleteFiles: deleteFiles)
        await refresh()
    }

    func deleteHistory(job: SABnzbdJob, permanently: Bool = false, deleteFiles: Bool = false) async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        try await client.deleteHistoryJobs(ids: [job.id], permanently: permanently, deleteFiles: deleteFiles)
        await refresh()
    }

    /// `priority.apiValue` is `nil` for `.default`, which only makes sense at
    /// add time (it means "use the category default"). Callers should exclude
    /// it from post-add priority pickers.
    func setPriority(job: SABnzbdJob, priority: AddDownloadPriority) async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        guard let value = priority.apiValue else { return }
        try await client.setPriority(id: job.id, priority: value)
        await refresh()
    }

    func setCategory(job: SABnzbdJob, category: String) async throws {
        guard let client = activeClient else { throw SABnzbdAPIError.invalidResponse }
        try await client.setCategory(id: job.id, category: category)
        await refresh()
    }

    // MARK: - Server configuration

    /// Fetched on demand by the add sheet rather than polled - categories and scripts
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
