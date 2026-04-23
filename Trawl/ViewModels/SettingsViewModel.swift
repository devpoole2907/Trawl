import Foundation
import Observation
import SwiftData
import UserNotifications
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class SettingsViewModel {
    var pollingInterval: Double = 2.0
    var notificationsEnabled: Bool = false
    var notificationPermissionGranted: Bool = false
    var serverProfile: ServerProfile?
    var appVersion: String?
    var qbVersion: String?
    var artworkCacheSizeDescription = "Empty"
    var isClearingArtworkCache = false
    var deviceToken: String?

    private var torrentService: TorrentService?
    private var syncService: SyncService?
    @ObservationIgnored
    nonisolated(unsafe) private var tokenObserver: NSObjectProtocol?

    init() {
        tokenObserver = NotificationCenter.default.addObserver(
            forName: NotificationConstants.apnsTokenReceivedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let token = notification.object as? String {
                Task { @MainActor [weak self] in
                    self?.deviceToken = token
                }
            }
        }
    }

    // Note: deinit is non-isolated. Removing an observer via NotificationCenter is thread-safe.
    deinit {
        if let observer = tokenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(torrentService: TorrentService, syncService: SyncService, arrServiceManager: ArrServiceManager? = nil) {
        self.torrentService = torrentService
        self.syncService = syncService
        self.pollingInterval = syncService.pollingInterval
    }

    func loadSettings(modelContext: ModelContext) async {
        // Load active server profile
        let descriptor = FetchDescriptor<ServerProfile>(predicate: #Predicate { $0.isActive })
        serverProfile = try? modelContext.fetch(descriptor).first

        // Check notification permission
        await checkNotificationPermission()
        
        #if os(iOS)
        // Register only when authorized and no token is currently available.
        if notificationPermissionGranted {
            await NotificationService.shared.registerForRemoteNotificationsIfNeeded()
        }
        #endif

        // Load device token
        #if os(iOS)
        deviceToken = await NotificationService.shared.deviceToken
        #endif

        // Fetch qBittorrent version
        if let service = torrentService {
            qbVersion = try? await service.getAppVersion()
        }

        // App version
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        await refreshArtworkCacheUsage()
    }

    func updatePollingInterval() {
        syncService?.pollingInterval = pollingInterval
    }

    func toggleNotifications() async {
        if notificationsEnabled {
            let granted = await NotificationService.shared.requestPermission()
            notificationPermissionGranted = granted
            if !granted {
                notificationsEnabled = false
            }
        }
    }

    func checkNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationPermissionGranted = settings.authorizationStatus == .authorized
        notificationsEnabled = notificationPermissionGranted
    }

    func refreshArtworkCacheUsage() async {
        let bytes = await ArtworkCache.shared.cacheSizeInBytes()
        artworkCacheSizeDescription = bytes > 0 ? ByteFormatter.format(bytes: bytes) : "Empty"
    }

    func clearArtworkCache() async {
        isClearingArtworkCache = true
        await ArtworkCache.shared.clear()
        await refreshArtworkCacheUsage()
        isClearingArtworkCache = false
    }

}
