import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class JellyfinServiceManager {
    private(set) var activeClient: JellyfinAPIClient?
    private(set) var activeProfileID: UUID?
    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var connectionError: String?
    private(set) var cachedUserCount: Int?
    private(set) var cachedSystemInfo: JellyfinSystemInfo?
    private(set) var requiresReauthentication: Bool = false
    private(set) var reauthenticationProfileID: UUID?
    let availability = JellyfinAvailabilityResolver()

    // MARK: Library scan and item refresh state
    //
    // A library scan is server-wide and an item refresh outlives the card that
    // asked for it, so both live here rather than in a card's `@State`: leaving
    // the detail screen used to drop the "scanning" state while Jellyfin kept
    // going, and coming back offered Rescan again as if nothing was running.

    /// True from the scan request until the watched titles show up or the
    /// re-checks run out.
    private(set) var isScanningLibraries = false
    /// Items sent for a metadata refresh on this connection.
    private(set) var refreshedItemIDs: Set<String> = []
    /// What the running scan is waiting to see. A card that asks while a scan is
    /// already running adds to this rather than starting another scan.
    private(set) var libraryScanWatches: [LibraryScanWatch] = []
    @ObservationIgnored private var libraryScanTask: Task<Void, Never>?
    /// Bumped by a reset, so a cancelled scan finishing late can't clear the
    /// state of the one that replaced it.
    @ObservationIgnored private var libraryScanGeneration = 0
    /// How often, and how many times, the scan re-queries. Roughly 30 seconds: a
    /// small library resolves on the first passes, a busy one still gets time.
    @ObservationIgnored var libraryScanRecheckInterval: Duration = .milliseconds(2500)
    @ObservationIgnored var libraryScanAttempts = 12

    // MARK: Backup work
    /// A Jellyfin backup can take minutes; held here so leaving Backups doesn't
    /// lose it.
    private(set) var isCreatingBackup = false
    /// Bumped when a backup finishes, so an open Backups list reloads.
    private(set) var backupRevision = 0
    @ObservationIgnored var backupSettleDelay: Duration = .seconds(3)
    /// Backups include every library's metadata, so they get far longer than
    /// the default request timeout.
    static let backupRequestTimeout: TimeInterval = 600

    func initialize(from profiles: [JellyfinServiceProfile]) async {
        guard let profile = profiles.first(where: { $0.isEnabled }) ?? profiles.first else {
            disconnect()
            return
        }

        await connectService(profile)
    }

    func connectService(_ profile: JellyfinServiceProfile) async {
        isConnecting = true
        connectionError = nil
        requiresReauthentication = false
        reauthenticationProfileID = nil
        availability.invalidateAll()
        resetLibraryWork()

        defer { isConnecting = false }

        do {
            guard let token = try await storedAccessToken(for: profile), !token.isEmpty else {
                clearActiveConnection()
                connectionError = missingTokenMessage(for: profile)
                return
            }

            let client = JellyfinAPIClient(
                baseURL: profile.hostURL,
                accessToken: token,
                allowsUntrustedTLS: profile.allowsUntrustedTLS
            )

            let systemInfo: JellyfinSystemInfo
            do {
                systemInfo = try await client.getSystemInfo()
            } catch JellyfinAPIError.unauthorized {
                clearActiveConnection()
                connectionError = expiredAuthorizationMessage(for: profile)
                if profile.authMode == .userPass {
                    requiresReauthentication = true
                    reauthenticationProfileID = profile.id
                }
                return
            }

            activeClient = client
            activeProfileID = profile.id
            isConnected = true
            cachedSystemInfo = systemInfo
            cacheSystemInfo(systemInfo, on: profile)

            await prefetchUserCount(using: client)
        } catch {
            connectionError = error.localizedDescription
            clearActiveConnection()
        }
    }

    func disconnect() {
        availability.invalidateAll()
        resetLibraryWork()
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        connectionError = nil
        isConnecting = false
        cachedUserCount = nil
        cachedSystemInfo = nil
        requiresReauthentication = false
        reauthenticationProfileID = nil
    }

    func updateCachedUserCount(_ count: Int) {
        cachedUserCount = count
    }

    func updateCachedSystemInfo(_ systemInfo: JellyfinSystemInfo?) {
        cachedSystemInfo = systemInfo
    }

    private func storedAccessToken(for profile: JellyfinServiceProfile) async throws -> String? {
        guard let value = try await KeychainHelper.shared.read(key: profile.accessTokenKey) else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func prefetchUserCount(using client: JellyfinAPIClient) async {
        do {
            let users = try await client.getUsers()
            cachedUserCount = users.count
        } catch {
            // Non-fatal: admin screens will report a detailed loading error on appear.
        }
    }

    private func cacheSystemInfo(_ systemInfo: JellyfinSystemInfo, on profile: JellyfinServiceProfile) {
        if let serverName = systemInfo.serverName, !serverName.isEmpty {
            profile.serverName = serverName
        }
        if let version = systemInfo.version, !version.isEmpty {
            profile.serverVersion = version
        }
    }

    private func clearActiveConnection() {
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        cachedUserCount = nil
        cachedSystemInfo = nil
    }

    private func missingTokenMessage(for profile: JellyfinServiceProfile) -> String {
        switch profile.authMode {
        case .apiKey:
            return "Jellyfin API key not found in Keychain. Add the server again from Settings."
        case .userPass:
            return "Jellyfin session token not found in Keychain. Sign in again from Settings."
        }
    }

    private func expiredAuthorizationMessage(for profile: JellyfinServiceProfile) -> String {
        switch profile.authMode {
        case .apiKey:
            return "Jellyfin API key is no longer valid. Update it in Settings."
        case .userPass:
            return "Jellyfin session expired. Sign in again from Settings."
        }
    }
}

// MARK: - Library scan and item refresh

extension JellyfinServiceManager {
    /// A title, or one episode of a series, that a library scan should turn up.
    struct LibraryScanWatch: Sendable {
        let media: JellyfinMediaAvailabilityCard.Media
        let episode: (season: Int, number: Int)?

        static func title(_ media: JellyfinMediaAvailabilityCard.Media) -> LibraryScanWatch {
            LibraryScanWatch(media: media, episode: nil)
        }

        static func episode(_ media: JellyfinMediaAvailabilityCard.Media, season: Int, number: Int) -> LibraryScanWatch {
            LibraryScanWatch(media: media, episode: (season, number))
        }

        var id: String {
            episode.map { "\(media.taskKey)-s\($0.season)e\($0.number)" } ?? media.taskKey
        }
    }

    /// Starts a Jellyfin library scan and re-checks the watched titles while the
    /// server's asynchronous scan catches up - the POST means "queued", not "the
    /// new file is already visible". While a scan runs, another call only adds
    /// its watch. Returns the running scan so a caller can await it.
    @discardableResult
    func scanLibraries(watching watch: LibraryScanWatch) -> Task<Void, Never>? {
        guard let client = activeClient, let profileID = activeProfileID else { return nil }
        if !libraryScanWatches.contains(where: { $0.id == watch.id }) {
            libraryScanWatches.append(watch)
        }
        if let libraryScanTask { return libraryScanTask }

        isScanningLibraries = true
        let generation = libraryScanGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLibraryScan(client: client, profileID: profileID, title: watch.media.title, generation: generation)
        }
        libraryScanTask = task
        return task
    }

    /// Sends one item for a metadata refresh, then drops the cached lookups that
    /// item feeds so every card showing it reloads.
    func refreshItem(_ item: JellyfinLibraryItem, for media: JellyfinMediaAvailabilityCard.Media) async {
        guard let client = activeClient, let profileID = activeProfileID else { return }
        do {
            try await client.refreshItem(id: item.id)
            refreshedItemIDs.insert(item.id)
            let key = JellyfinAvailabilityResolver.Key(profileID: profileID, mediaTaskKey: media.taskKey)
            let seriesItemIDs: [String] = if case .resolved(let items) = availability.state(for: key) { items.map(\.id) } else { [] }
            availability.invalidate(key)
            availability.ensureLoaded(key, media: media, client: client)
            for seriesItemID in seriesItemIDs {
                let episodesKey = JellyfinAvailabilityResolver.EpisodesKey(profileID: profileID, seriesItemID: seriesItemID)
                availability.invalidateEpisodes(episodesKey)
                availability.ensureEpisodesLoaded(episodesKey, client: client)
            }
            InAppNotificationCenter.shared.showSuccess(
                title: "Jellyfin Refresh Started",
                message: "\(item.name ?? media.title) was sent for metadata refresh.",
                source: .inApp
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Jellyfin Refresh Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }

    private func runLibraryScan(client: JellyfinAPIClient, profileID: UUID, title: String, generation: Int) async {
        defer {
            if generation == libraryScanGeneration { endLibraryScan() }
        }
        do {
            try await client.refreshAllLibraries()
            InAppNotificationCenter.shared.showSuccess(
                title: "Jellyfin Library Scan Started",
                message: "Jellyfin is rescanning your libraries for \(title).",
                source: .inApp
            )
            for attempt in 0..<libraryScanAttempts {
                if attempt > 0 {
                    try await Task.sleep(for: libraryScanRecheckInterval)
                }
                try Task.checkCancellation()
                // Snapshot, then drop only what was found: a watch added while
                // this pass awaited is checked on the next one.
                for watch in libraryScanWatches {
                    if try await isPresent(watch, client: client, profileID: profileID) {
                        libraryScanWatches.removeAll { $0.id == watch.id }
                    }
                }
                if libraryScanWatches.isEmpty { return }
            }
        } catch is CancellationError {
            return
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Jellyfin Scan Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }

    private func endLibraryScan() {
        isScanningLibraries = false
        libraryScanWatches = []
        libraryScanTask = nil
    }

    /// Re-queries a watched title (and its episodes, for an episode watch) and
    /// says whether Jellyfin has it now.
    private func isPresent(_ watch: LibraryScanWatch, client: JellyfinAPIClient, profileID: UUID) async throws -> Bool {
        let key = JellyfinAvailabilityResolver.Key(profileID: profileID, mediaTaskKey: watch.media.taskKey)
        availability.invalidate(key)
        availability.ensureLoaded(key, media: watch.media, client: client)
        try await waitForLookupToSettle(key)
        guard case .resolved(let items) = availability.state(for: key), !items.isEmpty else { return false }
        guard let episode = watch.episode else { return true }

        let episodesKeys = items.map { JellyfinAvailabilityResolver.EpisodesKey(profileID: profileID, seriesItemID: $0.id) }
        for episodesKey in episodesKeys {
            availability.invalidateEpisodes(episodesKey)
            availability.ensureEpisodesLoaded(episodesKey, client: client)
        }
        try await waitForEpisodeLookupsToSettle(episodesKeys)
        return JellyfinEpisodeAvailabilityAggregate.matchingEpisode(
            in: episodesKeys.map { availability.episodesState(for: $0) },
            seasonNumber: episode.season,
            episodeNumber: episode.number
        ) != nil
    }

    private func waitForLookupToSettle(_ key: JellyfinAvailabilityResolver.Key) async throws {
        for _ in 0..<250 {
            switch availability.state(for: key) {
            case .idle, .loading: try await Task.sleep(for: .milliseconds(20))
            case .resolved, .failed: return
            }
        }
    }

    private func waitForEpisodeLookupsToSettle(_ keys: [JellyfinAvailabilityResolver.EpisodesKey]) async throws {
        guard !keys.isEmpty else { return }
        for _ in 0..<250 {
            if !JellyfinEpisodeAvailabilityAggregate.isLoading(keys.map { availability.episodesState(for: $0) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A new connection or a disconnect ends any scan and forgets refreshes made
    /// against the old server.
    fileprivate func resetLibraryWork() {
        libraryScanGeneration += 1
        libraryScanTask?.cancel()
        endLibraryScan()
        refreshedItemIDs = []
    }
}

// MARK: - Backup work

extension JellyfinServiceManager {
    @discardableResult
    func createBackup(options: JellyfinBackupOptions) -> Task<Void, Never>? {
        guard !isCreatingBackup, let client = activeClient else { return nil }
        isCreatingBackup = true
        return Task { [weak self] in
            guard let self else { return }
            do {
                try await client.createBackup(options: options, requestTimeout: Self.backupRequestTimeout)
                try? await Task.sleep(for: backupSettleDelay)
            } catch {
                InAppNotificationCenter.shared.showError(title: "Backup Failed", message: error.localizedDescription)
            }
            isCreatingBackup = false
            backupRevision &+= 1
        }
    }
}

#if DEBUG
extension JellyfinServiceManager {
    enum PreviewState {
        case connected, connecting, error(String), notConfigured, requiresReauthentication
    }

    static func preview(_ state: PreviewState = .connected) -> JellyfinServiceManager {
        let mgr = JellyfinServiceManager()
        switch state {
        case .connected:
            mgr.activeClient = .preview()
            mgr.activeProfileID = UUID()
            mgr.isConnected = true
            mgr.cachedUserCount = 14
            mgr.cachedSystemInfo = JellyfinSystemInfo.preview
        case .connecting:
            mgr.isConnecting = true
        case .error(let msg):
            mgr.connectionError = msg
        case .notConfigured:
            break
        case .requiresReauthentication:
            mgr.connectionError = "Session expired. Please re-enter your password."
            mgr.requiresReauthentication = true
            mgr.reauthenticationProfileID = UUID()
        }
        return mgr
    }
}
#endif
