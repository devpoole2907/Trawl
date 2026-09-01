import Foundation

/// The single route from Arr operations to user-facing banners.
///
/// View models still own their `error` state, while this type owns presentation.
/// Keeping those responsibilities distinct lets a coordinating view suppress
/// per-request banners and announce one aggregate result instead.
@MainActor
enum ArrOperationFeedback {
    static func showFailure(title: String, message: String) {
        InAppNotificationCenter.shared.showError(title: title, message: message)
    }

    static func showSuccess(title: String, message: String) {
        InAppNotificationCenter.shared.showSuccess(title: title, message: message)
    }
}
