import SwiftUI

struct ArrConnectingView: View {
    let profile: ArrServiceProfile?
    let editServer: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting...")
                .font(.headline)
            if let profile {
                VStack(spacing: 4) {
                    Text(profile.displayName)
                    Text(profile.hostURL)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
            }
            Button("Edit Server", systemImage: "server.rack", action: editServer)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
