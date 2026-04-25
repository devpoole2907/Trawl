import UIKit
import OSLog

#if os(iOS)
final class TrawlAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "com.poole.james.Trawl", category: "AppDelegate")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

        Task {
            let previousToken = try? await KeychainHelper.shared.read(key: NotificationConstants.apnsTokenKey)
            do {
                try await KeychainHelper.shared.save(key: NotificationConstants.apnsTokenKey, value: tokenString)
            } catch {
                self.logger.error("Failed to persist APNs device token to keychain: \(error.localizedDescription, privacy: .public)")
            }

            if previousToken == tokenString {
                self.logger.debug("Remote notification token unchanged.")
            } else {
                self.logger.info("Successfully registered for remote notifications. Token: \(tokenString, privacy: .private)")
            }
            
            // Post notification for observers (like SettingsViewModel)
            await MainActor.run {
                NotificationCenter.default.post(name: NotificationConstants.apnsTokenReceivedNotification, object: tokenString)
                NotificationCenter.default.post(name: NotificationConstants.apnsRegistrationDidCompleteNotification, object: nil)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: NotificationConstants.apnsRegistrationDidCompleteNotification, object: nil)
        logger.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
    }

    // Handle foreground notifications
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Absorb system banners when foregrounded — show via in-app banner instead
        let content = notification.request.content
        let title = content.title
        let body = content.body
        if !title.isEmpty || !body.isEmpty {
            let style = content.userInfo["style"] as? String
            Task { @MainActor in
                if style == "error" {
                    InAppNotificationCenter.shared.showError(title: title, message: body)
                } else {
                    InAppNotificationCenter.shared.showSuccess(title: title, message: body)
                }
            }
        }
        // Still update badge and list, but suppress the system banner/sound
        completionHandler([.list, .badge])
    }
}
#endif
