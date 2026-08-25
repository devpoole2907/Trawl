#if os(iOS)
import SwiftUI
import UIKit

/// Controls the interactive dismissal gestures SwiftUI installs for a zoom
/// navigation transition.
///
/// SwiftUI does not currently expose these controls. This modifier therefore
/// locates the installed UIKit recognizers by runtime class name. Keep its use
/// narrowly scoped to presentations where a zoom gesture conflicts with a
/// system presentation gesture.
struct AllowedNavigationDismissalGestures: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let swipeToGoBack = Self(rawValue: 1 << 0)
    static let zoomEdgePanToDismiss = Self(rawValue: 1 << 1)
    static let zoomSwipeDownToDismiss = Self(rawValue: 1 << 2)
    static let zoomPinchToDismiss = Self(rawValue: 1 << 3)

    static let all: Self = [
        .swipeToGoBack,
        .zoomEdgePanToDismiss,
        .zoomSwipeDownToDismiss,
        .zoomPinchToDismiss,
    ]
}

extension View {
    /// Limits which gestures may interactively dismiss a zoom navigation transition.
    func navigationAllowDismissalGestures(
        _ gestures: AllowedNavigationDismissalGestures = .all
    ) -> some View {
        modifier(NavigationAllowedDismissalGesturesModifier(allowedGestures: gestures))
    }
}

private struct NavigationAllowedDismissalGesturesModifier: ViewModifier {
    let allowedGestures: AllowedNavigationDismissalGestures

    func body(content: Content) -> some View {
        content.background {
            NavigationDismissalGestureUpdater(allowedGestures: allowedGestures)
                .frame(width: 0, height: 0)
        }
    }
}

private struct NavigationDismissalGestureUpdater: UIViewControllerRepresentable {
    let allowedGestures: AllowedNavigationDismissalGestures

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        context.coordinator.update(
            for: viewController,
            allowedGestures: allowedGestures
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIViewController(_ viewController: UIViewController, coordinator: Coordinator) {
        coordinator.restoreGestures(for: viewController)
    }

    @MainActor
    final class Coordinator {
        private var mountRetryCount = 0

        func update(
            for viewController: UIViewController,
            allowedGestures: AllowedNavigationDismissalGestures
        ) {
            guard
                let parentViewController = viewController.parent,
                let navigationController = parentViewController.navigationController
            else {
                retryUpdate(for: viewController, allowedGestures: allowedGestures)
                return
            }

            guard navigationController.topViewController == parentViewController else { return }

            navigationController.interactivePopGestureRecognizer?.isEnabled = allowedGestures.contains(.swipeToGoBack)

            for gesture in parentViewController.view.gestureRecognizers ?? [] {
                switch String(describing: type(of: gesture)) {
                case Constants.zoomEdgePanToDismissClassName:
                    gesture.isEnabled = allowedGestures.contains(.zoomEdgePanToDismiss)
                case Constants.zoomSwipeDownToDismissClassName:
                    gesture.isEnabled = allowedGestures.contains(.zoomSwipeDownToDismiss)
                case Constants.zoomPinchToDismissClassName:
                    gesture.isEnabled = allowedGestures.contains(.zoomPinchToDismiss)
                default:
                    continue
                }
            }
        }

        func restoreGestures(for viewController: UIViewController) {
            viewController.parent?.navigationController?.interactivePopGestureRecognizer?.isEnabled = true

            for gesture in viewController.parent?.view.gestureRecognizers ?? [] {
                if Constants.zoomGestureClassNames.contains(String(describing: type(of: gesture))) {
                    gesture.isEnabled = true
                }
            }
        }

        private func retryUpdate(
            for viewController: UIViewController,
            allowedGestures: AllowedNavigationDismissalGestures
        ) {
            guard mountRetryCount < Constants.maximumMountRetries else { return }
            mountRetryCount += 1

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak viewController] in
                guard let self, let viewController else { return }
                self.update(for: viewController, allowedGestures: allowedGestures)
            }
        }
    }

    private enum Constants {
        static let maximumMountRetries = 2
        static let zoomEdgePanToDismissClassName = "_UIParallaxTransitionPanGestureRecognizer"
        static let zoomSwipeDownToDismissClassName = "_UIContentSwipeDismissGestureRecognizer"
        static let zoomPinchToDismissClassName = "_UITransformGestureRecognizer"
        static let zoomGestureClassNames: Set<String> = [
            zoomEdgePanToDismissClassName,
            zoomSwipeDownToDismissClassName,
            zoomPinchToDismissClassName,
        ]
    }
}
#endif
