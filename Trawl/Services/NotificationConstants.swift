import Foundation

enum NotificationConstants {
    static let apnsTokenKey = "APNSDeviceToken"
    static let workerURLKey = "NotificationWorkerURL"
    static let defaultWorkerURL = "https://trawl-apns-worker.james-5d8.workers.dev"
    static let apnsTokenReceivedNotification = Notification.Name("TrawlAPNSTokenReceived")
    static let apnsRegistrationDidCompleteNotification = Notification.Name("TrawlAPNSRegistrationDidComplete")
    /// Posted with the tapped push's `trawl://` URL as its object. ContentView routes it
    /// through the same handler as a real `onOpenURL`, so push taps and external links
    /// can't drift apart.
    static let pushDeepLinkNotification = Notification.Name("TrawlPushDeepLink")
}
