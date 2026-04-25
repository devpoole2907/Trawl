import SwiftUI
#if os(iOS)
import LocalAuthentication
#endif

struct AppLockView: View {
    @Environment(AppLockController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 24) {
            if let uiImage = UIImage(named: "AppIcon") {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
            }

            VStack(spacing: 8) {
                Text("Trawl Is Locked")
                    .font(.title2.weight(.semibold))

                Text("Unlock to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await controller.authenticate() }
            } label: {
                Label(unlockButtonTitle, systemImage: unlockButtonIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .glassEffect(.regular.interactive(), in: Capsule())
            .disabled(controller.isAuthenticating)

            if let error = controller.lastError, error.code != .userCancel {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await controller.authenticate()
        }
    }

    private var unlockButtonTitle: String {
        switch controller.availability {
        case .faceID:
            "Unlock with Face ID"
        case .touchID:
            "Unlock with Touch ID"
        case .opticID:
            "Unlock with Optic ID"
        case .passcodeOnly, .unavailable:
            "Unlock"
        }
    }

    private var unlockButtonIcon: String {
        switch controller.availability {
        case .faceID:
            "faceid"
        case .touchID:
            "touchid"
        case .opticID:
            "opticid"
        case .passcodeOnly, .unavailable:
            "lock.open"
        }
    }
}
