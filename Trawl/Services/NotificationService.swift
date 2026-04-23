import Foundation
import OSLog
import UserNotifications
#if os(iOS)
import UIKit
#endif

final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let logger = Logger(subsystem: "com.poole.james.Trawl", category: "NotificationService")

    #if os(iOS)
    @MainActor
    private var isRegisteringRemoteNotifications = false
    #endif

    /// Request notification permission from the user. Returns true if granted.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            
            #if os(iOS)
            if granted {
                await registerForRemoteNotifications(force: true)
            }
            #endif
            
            return granted
        } catch {
            return false
        }
    }
    
    #if os(iOS)
    /// Fetches the current APNs device token from secure storage.
    var deviceToken: String? {
        get async {
            try? await KeychainHelper.shared.read(key: NotificationConstants.apnsTokenKey)
        }
    }

    /// The URL of the Cloudflare Worker proxy.
    var workerURL: String {
        UserDefaults.standard.string(forKey: NotificationConstants.workerURLKey) ?? NotificationConstants.defaultWorkerURL
    }

    @MainActor
    func registerForRemoteNotificationsIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        guard await deviceToken == nil else { return }
        await registerForRemoteNotifications(force: false)
    }

    @MainActor
    private func registerForRemoteNotifications(force: Bool) async {
        guard force || !isRegisteringRemoteNotifications else { return }
        if isRegisteringRemoteNotifications { return }

        isRegisteringRemoteNotifications = true
        UIApplication.shared.registerForRemoteNotifications()

        // Prevent repeated same-turn registrations from multiple call sites.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.isRegisteringRemoteNotifications = false
        }
    }
    #endif
}
