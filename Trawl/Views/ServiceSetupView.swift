import SwiftUI

/// Missing configuration uses the centered presentation with a setup action.
struct ServiceSetupView: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle = "Open Settings"
    var onSetup: (() -> Void)? = nil
    @Environment(\.navigateToSettings) private var navigateToSettings

    var body: some View {
        ConnectionStatusCard(
            title: title,
            message: message,
            editTitle: actionTitle,
            presentation: .embedded,
            systemImage: systemImage,
            showsRetryCountdown: false,
            usesGlassEditButton: true,
            onEdit: onSetup ?? navigateToSettings
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
