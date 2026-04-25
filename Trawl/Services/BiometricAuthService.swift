import Foundation
import LocalAuthentication

enum BiometryAvailability: Sendable {
    case faceID
    case touchID
    case opticID
    case passcodeOnly
    case unavailable(LAError?)

    var isUsable: Bool {
        switch self {
        case .faceID, .touchID, .opticID, .passcodeOnly:
            true
        case .unavailable:
            false
        }
    }

    var displayName: String {
        switch self {
        case .faceID:
            "Face ID"
        case .touchID:
            "Touch ID"
        case .opticID:
            "Optic ID"
        case .passcodeOnly:
            "device passcode"
        case .unavailable:
            "device authentication"
        }
    }
}

@MainActor
struct BiometricAuthService {
    static func availability() -> BiometryAvailability {
        let biometricContext = LAContext()
        var biometricError: NSError?

        if biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError) {
            switch biometricContext.biometryType {
            case .faceID:
                return .faceID
            case .touchID:
                return .touchID
            case .opticID:
                return .opticID
            case .none:
                break
            @unknown default:
                break
            }
        }

        let passcodeContext = LAContext()
        var passcodeError: NSError?
        if passcodeContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError) {
            return .passcodeOnly
        }

        return .unavailable(laError(from: biometricError ?? passcodeError))
    }

    static func authenticate(reason: String) async -> Result<Void, LAError> {
        let context = LAContext()
        var policyError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .failure(laError(from: policyError))
        }

        do {
            let success = try await evaluatePolicy(context: context, reason: reason)
            return success ? .success(()) : .failure(LAError(.authenticationFailed))
        } catch let error as LAError {
            return .failure(error)
        } catch {
            return .failure(laError(from: error as NSError))
        }
    }

    private static func evaluatePolicy(context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private static func laError(from error: NSError?) -> LAError {
        guard let error else {
            return LAError(.biometryNotAvailable)
        }
        return LAError(_nsError: error)
    }
}
