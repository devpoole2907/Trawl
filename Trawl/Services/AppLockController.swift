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
    private var storedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "appLock.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "appLock.enabled") }
    }

    private(set) var isEnabled = false
    private(set) var isLocked = false
    private(set) var availability: BiometryAvailability = .unavailable(nil)
    var isAuthenticating = false
    var lastError: LAError?
    var biometryName: String { availability.displayName }

    init() {
        refreshAvailability()
        #if os(iOS)
        isEnabled = storedEnabled
        isLocked = storedEnabled
        #else
        isEnabled = false
        isLocked = false
        #endif
        lastError = nil
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
        if new != .active {
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
        guard !isAuthenticating else { return false }
        refreshAvailability()
        guard availability.isUsable else { return false }

        isAuthenticating = true
        defer { isAuthenticating = false }

        switch await BiometricAuthService.authenticate(reason: "Enable app lock for Trawl.") {
        case .success:
            storedEnabled = true
            isEnabled = true
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

    func disable() async -> Bool {
        #if os(iOS)
        guard isEnabled else { return true }
        guard !isAuthenticating else { return false }
        refreshAvailability()
        guard availability.isUsable else { return false }

        isAuthenticating = true
        defer { isAuthenticating = false }

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
