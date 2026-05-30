import SwiftUI
import LocalAuthentication

struct AppLockView: View {
    @Environment(AppLockController.self) private var controller
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.app.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .foregroundStyle(.tint)
                .shadow(color: .black.opacity(0.14), radius: 18, y: 8)

            VStack(spacing: 8) {
                Text("Trawl Is Locked")
                    .font(.title2.weight(.semibold))

                Text("Unlock to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
        .prominentBottomButton(LocalizedStringKey(unlockButtonTitle), systemImage: unlockButtonIcon, isDisabled: controller.isAuthenticating) {
            Task { await controller.authenticate() }
        }
        .task {
            await controller.authenticate()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await controller.authenticate() }
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

#if DEBUG
extension AppLockController {
    static func preview(
        isAuthenticating: Bool = false,
        lastError: LAError? = nil
    ) -> AppLockController {
        let controller = AppLockController()
        controller.isAuthenticating = isAuthenticating
        controller.lastError = lastError
        return controller
    }
}

#Preview("Locked") {
    AppLockView()
        .environment(AppLockController.preview())
}

#Preview("Authenticating") {
    AppLockView()
        .environment(AppLockController.preview(isAuthenticating: true))
}

#Preview("Error") {
    AppLockView()
        .environment(AppLockController.preview(lastError: LAError(.authenticationFailed)))
}
#endif
