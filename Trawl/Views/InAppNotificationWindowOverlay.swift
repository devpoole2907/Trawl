#if os(iOS)
import SwiftUI
import UIKit

@MainActor
final class InAppNotificationWindowPresenter {
    private var window: UIWindow?

    func install(notificationCenter: InAppNotificationCenter) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }

        if window?.windowScene === scene {
            return
        }

        let hostingController = UIHostingController(
            rootView: InAppNotificationWindowOverlay(notificationCenter: notificationCenter)
                .environment(notificationCenter)
        )
        hostingController.view.backgroundColor = .clear

        let overlayWindow = PassthroughNotificationWindow(windowScene: scene)
        overlayWindow.notificationCenter = notificationCenter
        overlayWindow.backgroundColor = .clear
        overlayWindow.windowLevel = .statusBar + 1
        overlayWindow.rootViewController = hostingController
        overlayWindow.isHidden = false

        window = overlayWindow
    }
}

final class PassthroughNotificationWindow: UIWindow {
    weak var notificationCenter: InAppNotificationCenter?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only intercept touches inside the visible banner frame. Transparent
        // SwiftUI subviews would otherwise claim taps in empty areas — bannerFrame
        // is the source of truth for what should swallow input.
        guard let center = notificationCenter,
              center.currentBanner != nil,
              !center.bannerFrame.isEmpty,
              center.bannerFrame.contains(point) else {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

struct InAppNotificationWindowOverlay: View {
    let notificationCenter: InAppNotificationCenter

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .overlay(alignment: .top) {
                    if let banner = notificationCenter.currentBanner {
                        InAppNotificationBanner(item: banner) {
                            notificationCenter.dismissCurrentBanner()
                        } onTap: {
                            if notificationCenter.currentBannerHasAction {
                                notificationCenter.fireCurrentBannerAction()
                            } else {
                                notificationCenter.showRecentNotifications()
                                notificationCenter.dismissCurrentBanner()
                            }
                        }
                        .withActionAffordance(notificationCenter.currentBannerHasAction)
                        // Fresh view per banner so SwiftUI doesn't carry dragOffset
                        // @State from a previous swipe-dismiss mid-flight.
                        .id(banner.id)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { newFrame in
                            notificationCenter.bannerFrame = newFrame
                        }
                        .padding(.top, toolbarAwareTopPadding(safeAreaTop: geometry.safeAreaInsets.top))
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onDisappear {
                            notificationCenter.bannerFrame = .zero
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: notificationCenter.currentBanner)
    }

    private func toolbarAwareTopPadding(safeAreaTop: CGFloat) -> CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })

        let statusBarTop = scene?.statusBarManager?.statusBarFrame.height ?? 0
        let sheetNudge: CGFloat = isPresentingSheet(in: scene) ? 4 : 0

        return max(safeAreaTop, statusBarTop, 44) + 44 + 26 + sheetNudge
    }

    private func isPresentingSheet(in scene: UIWindowScene?) -> Bool {
        scene?.windows
            .filter { !($0 is PassthroughNotificationWindow) }
            .contains { $0.rootViewController?.presentedViewController != nil } ?? false
    }
}
#endif
