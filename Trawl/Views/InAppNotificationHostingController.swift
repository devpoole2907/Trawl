#if os(iOS)
import SwiftUI

final class InAppNotificationHostingController: UIHostingController<InAppNotificationWindowOverlay> {
    var hidesStatusBar = false {
        didSet {
            guard oldValue != hidesStatusBar else { return }
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    override var prefersStatusBarHidden: Bool {
        hidesStatusBar
    }
}
#endif
