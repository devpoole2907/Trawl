import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class InAppNotificationCenter {
    static let shared = InAppNotificationCenter()

    private(set) var currentBanner: InAppBannerItem?
    private(set) var recentNotifications: [NotificationLogEntry] = []
    var currentBannerHasAction: Bool { currentBanner?.action != nil }

    private var queuedBanners: [InAppBannerItem] = []
    private var dismissTask: Task<Void, Never>?

    #if os(iOS)
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let impactGenerator = UIImpactFeedbackGenerator(style: .medium)
    #endif

    func showDownloadCompleted(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        showSuccess(title: "Download Complete", message: trimmedName)
    }

    func showProgress(title: String, message: String, key: String? = nil, source: NotificationLogEntry.Source = .inApp) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }
        appendLog(title: trimmedTitle, message: trimmedMessage, style: .progress, source: source)

        presentImmediately(
            InAppBannerItem(
                title: trimmedTitle,
                message: trimmedMessage,
                systemImage: "arrow.triangle.2.circlepath",
                style: .progress,
                action: nil,
                key: key,
                showsProgressView: true,
                automaticallyDismisses: false
            ),
            requeueCurrent: true
        )
    }

    func showSuccess(title: String, message: String, action: InAppBannerAction? = nil, source: NotificationLogEntry.Source = .inApp) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }
        appendLog(title: trimmedTitle, message: trimmedMessage, style: .success, source: source)

        #if os(iOS)
        notificationGenerator.notificationOccurred(.success)
        #endif

        enqueue(InAppBannerItem(
            title: trimmedTitle,
            message: trimmedMessage,
            systemImage: "checkmark.circle.fill",
            style: .success,
            action: action,
            key: nil,
            showsProgressView: false,
            automaticallyDismisses: true
        ))
    }

    func replaceProgressWithSuccess(
        key: String,
        title: String,
        message: String,
        action: InAppBannerAction? = nil
    ) {
        removeQueuedBanner(matching: key)
        if currentBanner?.key == key {
            #if os(iOS)
                notificationGenerator.notificationOccurred(.success)
            #endif
            presentImmediately(makeBanner(title: title, message: message, style: .success, action: action), requeueCurrent: false)
            return
        }
        showSuccess(title: title, message: message, action: action)
    }

    func showError(title: String, message: String, source: NotificationLogEntry.Source = .inApp) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }
        appendLog(title: trimmedTitle, message: trimmedMessage, style: .error, source: source)

        #if os(iOS)
        notificationGenerator.notificationOccurred(.error)
        #endif

        enqueue(InAppBannerItem(
            title: trimmedTitle,
            message: trimmedMessage,
            systemImage: "exclamationmark.triangle.fill",
            style: .error,
            action: nil,
            key: nil,
            showsProgressView: false,
            automaticallyDismisses: true
        ))
    }

    func replaceProgressWithError(key: String, title: String, message: String) {
        removeQueuedBanner(matching: key)
        if currentBanner?.key == key {
            #if os(iOS)
                notificationGenerator.notificationOccurred(.error)
            #endif
            presentImmediately(makeBanner(title: title, message: message, style: .error, action: nil), requeueCurrent: false)
            return
        }
        showError(title: title, message: message)
    }

    func clearRecentNotifications() {
        recentNotifications.removeAll()
    }

    func dismissBanner(matching key: String) {
        removeQueuedBanner(matching: key)
        guard currentBanner?.key == key else { return }
        dismissCurrentBanner()
    }

    func triggerImpact() {
        #if os(iOS)
        impactGenerator.impactOccurred()
        #endif
    }

    func reportFailure(_ action: String, error: Error) {
        showError(title: "\(action) Failed", message: error.localizedDescription)
    }

    func reportFailure(_ action: String, message: String) {
        showError(title: "\(action) Failed", message: message)
    }

    func showMonitoringChanged(itemName: String, itemType: String, isMonitoring: Bool) {
        let trimmedName = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = itemType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedType.isEmpty else { return }

        if isMonitoring {
            showSuccess(title: "Monitoring Enabled", message: "\(trimmedName) added to \(trimmedType.lowercased()) monitoring.")
        } else {
            showSuccess(title: "Monitoring Disabled", message: "\(trimmedName) removed from \(trimmedType.lowercased()) monitoring.")
        }
    }

    func dismissCurrentBanner() {
        dismissTask?.cancel()
        dismissTask = nil
        currentBanner = nil

        // Brief delay before showing next banner to allow for dismissal animation
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.showNext()
        }
    }

    func fireCurrentBannerAction() {
        let action = currentBanner?.action
        dismissCurrentBanner()
        action?.handler()
    }

    private func enqueue(_ banner: InAppBannerItem) {
        queuedBanners.append(banner)

        if currentBanner == nil {
            showNext()
        }
    }

    private func removeQueuedBanner(matching key: String) {
        queuedBanners.removeAll { $0.key == key }
    }

    private func showNext() {
        guard currentBanner == nil, !queuedBanners.isEmpty else { return }
        present(queuedBanners.removeFirst())
    }

    private func presentImmediately(_ banner: InAppBannerItem, requeueCurrent: Bool) {
        if let key = banner.key {
            removeQueuedBanner(matching: key)
        }
        dismissTask?.cancel()
        dismissTask = nil

        if requeueCurrent, let currentBanner, currentBanner.key != banner.key {
            queuedBanners.insert(currentBanner, at: 0)
        }

        present(banner)
    }

    private func present(_ banner: InAppBannerItem) {
        currentBanner = banner
        dismissTask?.cancel()
        guard banner.automaticallyDismisses else {
            dismissTask = nil
            return
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.dismissCurrentBanner()
        }
    }


    private func makeBanner(title: String, message: String, style: InAppBannerStyle, action: InAppBannerAction?) -> InAppBannerItem {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemImage: String
        let dismisses: Bool
        let showsProgress: Bool

        switch style {
        case .success:
            systemImage = "checkmark.circle.fill"
            dismisses = true
            showsProgress = false
        case .error:
            systemImage = "exclamationmark.triangle.fill"
            dismisses = true
            showsProgress = false
        case .progress:
            systemImage = "arrow.triangle.2.circlepath"
            dismisses = false
            showsProgress = true
        }

        return InAppBannerItem(
            title: trimmedTitle,
            message: trimmedMessage,
            systemImage: systemImage,
            style: style,
            action: action,
            key: nil,
            showsProgressView: showsProgress,
            automaticallyDismisses: dismisses
        )
    }

    private func appendLog(title: String, message: String, style: InAppBannerStyle, source: NotificationLogEntry.Source) {
        let entry = NotificationLogEntry(title: title, message: message, style: style, source: source, timestamp: Date())
        recentNotifications.insert(entry, at: 0)
        if recentNotifications.count > 200 {
            recentNotifications.removeLast(recentNotifications.count - 200)
        }
    }
}

struct InAppBannerAction {
    let label: String
    let handler: () -> Void
}

enum InAppBannerStyle: Sendable {
    case success
    case error
    case progress
}

struct InAppBannerItem: Identifiable, @unchecked Sendable {
    let id = UUID()
    let title: String
    let message: String
    let systemImage: String
    let style: InAppBannerStyle
    let action: InAppBannerAction?
    let key: String?
    let showsProgressView: Bool
    let automaticallyDismisses: Bool
}

struct NotificationLogEntry: Identifiable, Sendable {
    enum Source: String, Sendable {
        case inApp = "In-App"
        case system = "System"
    }

    let id = UUID()
    let title: String
    let message: String
    let style: InAppBannerStyle
    let source: Source
    let timestamp: Date
}

extension InAppBannerItem: Equatable {
    static func == (lhs: InAppBannerItem, rhs: InAppBannerItem) -> Bool {
        lhs.id == rhs.id
    }
}
