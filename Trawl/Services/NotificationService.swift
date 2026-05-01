import Foundation
import OSLog
import UserNotifications
#if os(iOS)
import UIKit
#endif

final class NotificationService: Sendable {
    static let shared = NotificationService()
    private let logger = Logger(subsystem: "com.poole.james.Trawl", category: "NotificationService")
    nonisolated(unsafe) private var registrationObserver: NSObjectProtocol?

    private init() {
        #if os(iOS)
        registrationObserver = NotificationCenter.default.addObserver(
            forName: NotificationConstants.apnsRegistrationDidCompleteNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRegisteringRemoteNotifications = false
            }
        }
        #endif
    }

    deinit {
        if let registrationObserver {
            NotificationCenter.default.removeObserver(registrationObserver)
        }
    }

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
    
    /// The URL of the Cloudflare Worker proxy.
    var workerURL: String {
        UserDefaults.standard.string(forKey: NotificationConstants.workerURLKey) ?? NotificationConstants.defaultWorkerURL
    }

    #if os(iOS)
    /// Fetches the current APNs device token from secure storage.
    var deviceToken: String? {
        get async {
            do {
                return try await KeychainHelper.shared.read(key: NotificationConstants.apnsTokenKey)
            } catch {
                // A real keychain error (e.g. access-group mismatch after re-install) is
                // indistinguishable from "no token" if we use try?, causing silent re-registration
                // failures. Log it so it's diagnosable.
                logger.error("Failed to read APNs device token from keychain: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
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

        isRegisteringRemoteNotifications = true
        UIApplication.shared.registerForRemoteNotifications()
    }

    #endif
}
