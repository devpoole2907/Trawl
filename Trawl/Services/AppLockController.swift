import Foundation
import Observation
import SwiftUI
#if os(iOS)
import LocalAuthentication
#endif

@MainActor
@Observable
final class AppLockController {
    @ObservationIgnored
    @AppStorage("appLock.enabled") private var storedEnabled: Bool = false

    private(set) var isEnabled = false
    private(set) var isLocked = false
    private(set) var availability: BiometryAvailability = .unavailable(nil)
    var isAuthenticating = false
    var lastError: LAError?
    var biometryName: String { availability.displayName }

    init() {
        refreshAvailability()
    }

    func bootstrap() {
        refreshAvailability()
        #if os(iOS)
        isEnabled = storedEnabled
        isLocked = storedEnabled
        #else
        storedEnabled = false
        isEnabled = false
        isLocked = false
        #endif
        lastError = nil
    }

    func handleScenePhase(_ new: ScenePhase, old: ScenePhase) {
        #if os(iOS)
        guard isEnabled else { return }
        guard old == .active || new == .background else { return }

        if new == .inactive || new == .background {
            isLocked = true
        }
        #endif
    }

    func authenticate() async {
        #if os(iOS)
        guard isEnabled else { return }
        guard !isAuthenticating else { return }
        refreshAvailability()
        guard availability.isUsable else { return }

        isAuthenticating = true
        defer { isAuthenticating = false }

        switch await BiometricAuthService.authenticate(reason: "Unlock Trawl to continue.") {
        case .success:
            isLocked = false
            lastError = nil
        case .failure(let error):
            isLocked = true
            lastError = error
        }
        #endif
    }

    func enable() async -> Bool {
        #if os(iOS)
        guard !isEnabled else { return true }
        refreshAvailability()
        guard availability.isUsable else { return false }

        switch await BiometricAuthService.authenticate(reason: "Enable app lock for Trawl.") {
        case .success:
            storedEnabled = true
            isEnabled = true
            isLocked = false
            lastError = nil
            return true
        case .failure(let error):
            storedEnabled = false
            isEnabled = false
            isLocked = false
            lastError = error
            return false
        }
        #else
        return false
        #endif
    }

    func disable() async -> Bool {
        #if os(iOS)
        guard isEnabled else { return true }
        refreshAvailability()
        guard availability.isUsable else { return false }

        switch await BiometricAuthService.authenticate(reason: "Disable app lock for Trawl.") {
        case .success:
            storedEnabled = false
            isEnabled = false
            isLocked = false
            lastError = nil
            return true
        case .failure(let error):
            lastError = error
            return false
        }
        #else
        return false
        #endif
    }

    private func refreshAvailability() {
        #if os(iOS)
        availability = BiometricAuthService.availability()
        #else
        availability = .unavailable(nil)
        #endif
    }
}
