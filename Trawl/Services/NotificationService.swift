import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif
import SwiftData

final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let backgroundTaskIdentifier = "com.poole.james.Trawl.torrentCheck"

    /// Request notification permission from the user. Returns true if granted.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    /// Register the next background app refresh task (iOS only).
    func registerBackgroundTask() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule background task: \(error)")
        }
        #endif
    }

    /// Called from the background task handler. Fetches current torrent states,
    /// diffs against cached states, and fires local notifications for completions/errors.
    func handleBackgroundRefresh() async {
        do {
            // Build a fresh ModelContainer for background use
            let schema = Schema([
                ServerProfile.self,
                CachedTorrentState.self,
                RecentSavePath.self
            ])
            let config = ModelConfiguration(
                groupContainer: .identifier(AppGroup.identifier)
            )
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)

            // Load the active server profile
            let serverDescriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.isActive })
            guard let server = try context.fetch(serverDescriptor).first else { return }

            // Load credentials from Keychain
            guard let username = try await KeychainHelper.shared.read(key: server.usernameKey),
                  let password = try await KeychainHelper.shared.read(key: server.passwordKey) else { return }

            // Create a temporary API client and authenticate
            let authService = AuthService(serverProfileID: server.id)
            let apiClient = QBittorrentAPIClient(baseURL: server.hostURL, authService: authService)
            try await apiClient.login(username: username, password: password)

            // Fetch current torrent list
            let currentTorrents = try await apiClient.getTorrents()

            // Load cached states
            let cacheDescriptor = FetchDescriptor<CachedTorrentState>()
            let cachedStates = try context.fetch(cacheDescriptor)
            let cachedByHash = Dictionary(uniqueKeysWithValues: cachedStates.map { ($0.hash, $0) })

            // Diff and notify
            for torrent in currentTorrents {
                let currentStateRaw = torrent.state.rawValue

                if let cached = cachedByHash[torrent.hash] {
                    let previousState = TorrentState(rawValue: cached.state) ?? .unknown

                    // Notify on download completion
                    if !previousState.isCompleted && torrent.state.isCompleted {
                        await sendNotification(
                            title: "Download Complete",
                            body: torrent.name,
                            identifier: "complete-\(torrent.hash)"
                        )
                    }

                    // Notify on error
                    if previousState != .error && previousState != .missingFiles &&
                       (torrent.state == .error || torrent.state == .missingFiles) {
                        await sendNotification(
                            title: "Torrent Error",
                            body: "\(torrent.name) — \(torrent.state.displayName)",
                            identifier: "error-\(torrent.hash)"
                        )
                    }

                    // Update cached state
                    cached.state = currentStateRaw
                    cached.progress = torrent.progress
                    cached.name = torrent.name
                    cached.lastUpdated = .now
                } else {
                    // New torrent — cache it without notifying
                    let newCache = CachedTorrentState(
                        hash: torrent.hash,
                        name: torrent.name,
                        state: currentStateRaw,
                        progress: torrent.progress
                    )
                    context.insert(newCache)
                }
            }

            // Remove cached entries for torrents that no longer exist
            let currentHashes = Set(currentTorrents.map(\.hash))
            for cached in cachedStates where !currentHashes.contains(cached.hash) {
                context.delete(cached)
            }

            try context.save()

        } catch {
            print("Background refresh failed: \(error)")
        }

        // Schedule the next background refresh
        registerBackgroundTask()
    }

    // MARK: - Private

    private func sendNotification(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
