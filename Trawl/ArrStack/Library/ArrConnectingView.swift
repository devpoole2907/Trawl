import SwiftUI

struct ArrConnectingView: View {
    let profile: ArrServiceProfile?
    let editServer: () -> Void
    var retry: (() -> Void)?

    var body: some View {
        ConnectionStatusCard(
            identity: profile?.resolvedServiceType?.serviceIdentity,
            title: title,
            message: "Checking your configured service connection.",
            isConnecting: true,
            detailTitle: profile?.displayName,
            detailSubtitle: profile?.hostURL,
            retryTitle: "Retry Connection",
            editTitle: profile == nil ? "Edit Servers" : "Edit Server",
            presentation: .embedded,
            onRetry: retry,
            onEdit: editServer
        )
    }

    private var title: String {
        if let serviceType = profile?.resolvedServiceType {
            return "Connecting to \(serviceType.displayName)"
        }

        return "Connecting to Services"
    }
}
