import SwiftUI

/// Request failures share the same two presentations as connection failures.
/// A failed first load blocks the surface; a failed refresh leaves its content usable.
struct ServiceErrorView: View {
    var title = "Unable to Load"
    let message: String
    var identity: ServiceIdentity? = nil
    var hasContent = false
    var systemImage: String? = nil
    var onRetry: (() async -> Void)? = nil

    var body: some View {
        ConnectionStatusCard(
            identity: identity,
            title: title,
            message: message,
            retryTitle: "Retry",
            presentation: hasContent ? .card : .embedded,
            systemImage: systemImage ?? identity?.systemImage ?? "exclamationmark.triangle",
            showsRetryCountdown: false,
            onRetry: onRetry.map { retry in { Task { await retry() } } }
        )
        .frame(minHeight: hasContent ? nil : 360)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
