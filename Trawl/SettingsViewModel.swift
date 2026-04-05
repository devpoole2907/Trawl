import Foundation
import Observation
import SwiftData
import UserNotifications

@Observable
final class SettingsViewModel {
    var pollingInterval: Double = 2.0
    var notificationsEnabled: Bool = false
    var notificationPermissionGranted: Bool = false
    var serverProfile: ServerProfile?
    var appVersion: String?
    var qbVersion: String?

    private var torrentService: TorrentService?
    private var syncService: SyncService?

    func configure(torrentService: TorrentService, syncService: SyncService) {
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

        // Fetch qBittorrent version
        if let service = torrentService {
            qbVersion = try? await service.getAppVersion()
        }

        // App version
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    func updatePollingInterval() {
        syncService?.pollingInterval = pollingInterval
    }

    func toggleNotifications() async {
        if notificationsEnabled {
            let granted = await NotificationService.shared.requestPermission()
            notificationPermissionGranted = granted
            if granted {
                NotificationService.shared.registerBackgroundTask()
            } else {
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
}
