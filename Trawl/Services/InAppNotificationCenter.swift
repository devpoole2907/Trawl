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
                systemImage: "checkmark.circle.fill"
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
                systemImage: "exclamationmark.triangle.fill"
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
        if currentBanner == nil {
            present(banner)
        } else {
            queuedBanners.append(banner)
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

struct InAppBannerItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let systemImage: String
}
