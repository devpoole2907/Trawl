import Foundation
import Observation

@MainActor
@Observable
final class InAppNotificationCenter {
    static let shared = InAppNotificationCenter()

    private(set) var currentBanner: InAppBannerItem?

    private var queuedBanners: [InAppBannerItem] = []
    private var dismissTask: Task<Void, Never>?

    func showDownloadCompleted(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        showSuccess(title: "Download Complete", message: trimmedName)
    }

    func showSuccess(title: String, message: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }

        enqueue(
            InAppBannerItem(
                title: trimmedTitle,
                message: trimmedMessage,
                systemImage: "checkmark.circle.fill",
                style: .success
            )
        )
    }

    func showError(title: String, message: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedMessage.isEmpty else { return }

        enqueue(
            InAppBannerItem(
                title: trimmedTitle,
                message: trimmedMessage,
                systemImage: "exclamationmark.triangle.fill",
                style: .error
            )
        )
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

        guard !queuedBanners.isEmpty else { return }
        let nextBanner = queuedBanners.removeFirst()
        present(nextBanner)
    }

    private func enqueue(_ banner: InAppBannerItem) {
        queuedBanners.removeAll() // Clear any queued ones since we want immediate
        
        if currentBanner != nil {
            // Dismiss current one immediately
            dismissTask?.cancel()
            currentBanner = nil
            
            // Wait briefly for the exit animation to start, then present new
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self.present(banner)
            }
        } else {
            present(banner)
        }
    }

    private func present(_ banner: InAppBannerItem) {
        currentBanner = banner
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismissCurrentBanner()
        }
    }
}

enum InAppBannerStyle: Sendable {
    case success
    case error
}

struct InAppBannerItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let systemImage: String
    let style: InAppBannerStyle
}
