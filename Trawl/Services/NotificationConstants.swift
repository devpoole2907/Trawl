import Foundation

enum NotificationConstants {
    static let apnsTokenKey = "APNSDeviceToken"
    static let workerURLKey = "NotificationWorkerURL"
    static let defaultWorkerURL = "https://trawl-apns-worker.james-5d8.workers.dev"
    static let apnsTokenReceivedNotification = Notification.Name("TrawlAPNSTokenReceived")
    static let apnsRegistrationDidCompleteNotification = Notification.Name("TrawlAPNSRegistrationDidComplete")
}
