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
            try? await KeychainHelper.shared.save(key: NotificationConstants.apnsTokenKey, value: tokenString)

            if previousToken == tokenString {
                self.logger.debug("Remote notification token unchanged.")
            } else {
                self.logger.info("Successfully registered for remote notifications. Token: \(tokenString, privacy: .private)")
            }
            
            // Post notification for observers (like SettingsViewModel)
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("TrawlAPNSTokenReceived"), object: tokenString)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        logger.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
    }

    // Handle foreground notifications
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound, .badge])
    }
}
#endif
