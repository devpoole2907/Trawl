import Foundation
import OSLog
import UserNotifications
#if os(iOS)
import UIKit
#endif

final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let logger = Logger(subsystem: "com.poole.james.Trawl", category: "NotificationService")

    /// Request notification permission from the user. Returns true if granted.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            
            #if os(iOS)
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            #endif
            
            return granted
        } catch {
            return false
        }
    }
    
    #if os(iOS)
    /// Fetches the current APNs device token from storage.
    var deviceToken: String? {
        UserDefaults.standard.string(forKey: "APNSDeviceToken")
    }

    /// The URL of the Cloudflare Worker proxy.
    var workerURL: String {
        UserDefaults.standard.string(forKey: "NotificationWorkerURL") ?? "https://trawl-apns-worker.james-5d8.workers.dev"
    }
    #endif
}
