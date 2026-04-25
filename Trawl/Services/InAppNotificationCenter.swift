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

    func showSuccess(title: String, message: String, action: InAppBannerAction? = nil) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }

        #if os(iOS)
        notificationGenerator.notificationOccurred(.success)
        #endif

        enqueue(InAppBannerItem(
            title: trimmedTitle,
            message: trimmedMessage,
            systemImage: "checkmark.circle.fill",
            style: .success,
            action: action
        ))
    }

    func showError(title: String, message: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }

        #if os(iOS)
        notificationGenerator.notificationOccurred(.error)
        #endif

        enqueue(InAppBannerItem(
            title: trimmedTitle,
            message: trimmedMessage,
            systemImage: "exclamationmark.triangle.fill",
            style: .error,
            action: nil
        ))
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

    private func showNext() {
        guard currentBanner == nil, !queuedBanners.isEmpty else { return }
        present(queuedBanners.removeFirst())
    }

    private func present(_ banner: InAppBannerItem) {
        currentBanner = banner
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.dismissCurrentBanner()
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
}

struct InAppBannerItem: Identifiable, @unchecked Sendable {
    let id = UUID()
    let title: String
    let message: String
    let systemImage: String
    let style: InAppBannerStyle
    let action: InAppBannerAction?
}

extension InAppBannerItem: Equatable {
    static func == (lhs: InAppBannerItem, rhs: InAppBannerItem) -> Bool {
        lhs.id == rhs.id
    }
}
