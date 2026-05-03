import OSLog

#if os(iOS)
import UIKit

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
        let body = Self.enrichedNotificationBody(content.body, userInfo: content.userInfo)
        if !title.isEmpty || !body.isEmpty {
            let style = content.userInfo["style"] as? String
            // Normalize fallback values: ensure both title and body are non-empty
            let displayTitle = title.isEmpty ? (body.isEmpty ? "Notification" : body) : title
            let displayBody = body.isEmpty ? title : body
            Task { @MainActor in
                let isError = style == "error"
                if isError {
                    InAppNotificationCenter.shared.showError(title: displayTitle, message: displayBody, source: .system)
                } else {
                    InAppNotificationCenter.shared.showSuccess(title: displayTitle, message: displayBody, source: .system)
                }
            }
        }
        // Still update badge and list, but suppress the system banner/sound
        completionHandler([.list, .badge])
    }

    private static func enrichedNotificationBody(_ body: String, userInfo: [AnyHashable: Any]) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldAttachPayloadDetails(to: trimmedBody) else { return body }

        let details = notificationDetailValues(from: userInfo)
        guard !details.isEmpty else { return body }
        return ([trimmedBody] + details).joined(separator: "\n")
    }

    private static func shouldAttachPayloadDetails(to body: String) -> Bool {
        let normalized = body.lowercased()
        return normalized.contains("imported") || normalized.contains("grabbed") || normalized.contains("download")
    }

    private static func notificationDetailValues(from userInfo: [AnyHashable: Any]) -> [String] {
        let displaySafeKeys = [
            "sourceTitle", "releaseTitle", "downloadTitle", "seriesTitle", "movieTitle", "episodeTitle"
        ]
        var details: [String] = []
        for key in displaySafeKeys {
            if let value = nestedNotificationValue(for: key, in: userInfo) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !details.contains(trimmed), !isFilesystemPath(trimmed) {
                    details.append(trimmed)
                }
            }
        }
        return details.prefix(4).map { "• \($0)" }
    }

    private static func isFilesystemPath(_ value: String) -> Bool {
        if value.contains("/") || value.contains("\\") {
            return true
        }
        if value.hasPrefix("/") {
            return true
        }
        // Check for Windows drive letters (e.g., "C:\")
        if value.count >= 2, value[value.index(value.startIndex, offsetBy: 1)] == ":" {
            let firstChar = value[value.startIndex]
            if firstChar.isLetter {
                return true
            }
        }
        return false
    }

    private static func nestedNotificationValue(for key: String, in value: Any) -> String? {
        if let dictionary = value as? [AnyHashable: Any] {
            for (rawKey, nestedValue) in dictionary {
                if String(describing: rawKey).caseInsensitiveCompare(key) == .orderedSame {
                    return stringifyNotificationValue(nestedValue)
                }
                if let found = nestedNotificationValue(for: key, in: nestedValue) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = nestedNotificationValue(for: key, in: item) {
                    return found
                }
            }
        }
        return nil
    }

    private static func stringifyNotificationValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let dictionary = value as? [AnyHashable: Any] {
            for key in ["name", "title", "sourceTitle"] {
                if let value = nestedNotificationValue(for: key, in: dictionary) {
                    return value
                }
            }
        }
        return nil
    }
}
#endif
