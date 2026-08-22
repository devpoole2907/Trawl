#if os(iOS)
import SwiftUI

struct DynamicIslandNotificationToast: View {
    let notificationCenter: InAppNotificationCenter
    let safeAreaTop: CGFloat
    let presentationChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedBanner: InAppBannerItem?
    @State private var presentationProgress: CGFloat = 0
    @State private var expansionTask: Task<Void, Never>?
    @State private var clearBannerTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let expandedWidth = geometry.size.width - 20
            let expandedHeight: CGFloat = 90
            let collapsedWidth: CGFloat = 120
            let collapsedHeight: CGFloat = 36
            let cappedProgress = max(min(presentationProgress, 1), 0)
            let layoutProgress = reduceMotion ? (cappedProgress > 0 ? 1 : 0) : cappedProgress
            let width = collapsedWidth + ((expandedWidth - collapsedWidth) * layoutProgress)
            let height = collapsedHeight + ((expandedHeight - collapsedHeight) * layoutProgress)
            let scaleX = reduceMotion ? 1 : width / expandedWidth
            let scaleY = reduceMotion ? 1 : height / expandedHeight
            let topOffset = 11 + max(safeAreaTop - 59, 0)
            let isPresented = cappedProgress > 0

            ZStack {
                DynamicIslandNotificationEffect(
                    progress: cappedProgress,
                    width: width,
                    height: height
                ) {
                    if let displayedBanner {
                        DynamicIslandNotificationContent(
                            item: displayedBanner,
                            hasAction: displayedBanner.action != nil
                        )
                        .frame(width: expandedWidth, height: expandedHeight)
                        .scaleEffect(x: scaleX, y: scaleY)
                    }
                }
                .offset(y: topOffset)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.15) : .linear(duration: 0.02).delay(isPresented ? 0 : 0.26)
                ) { content in
                    content.opacity(isPresented ? 1 : 0)
                }
                .contentShape(.rect)
                .gesture(dismissGesture)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    notificationCenter.bannerFrame = isPresented ? frame : .zero
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .animation(
                reduceMotion
                    ? .linear(duration: 0)
                    : (isPresented ? .bouncy(duration: 0.3, extraBounce: 0) : .smooth(duration: 0.28)),
                value: presentationProgress
            )
        }
        .onChange(of: notificationCenter.currentBanner, initial: true) { _, newBanner in
            updatePresentation(with: newBanner)
        }
        .onDisappear {
            expansionTask?.cancel()
            clearBannerTask?.cancel()
            presentationChanged(false)
            notificationCenter.bannerFrame = .zero
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            activateNotification()
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture()
            .onEnded { value in
                if value.translation.height < 0 {
                    notificationCenter.dismissCurrentBanner()
                } else if abs(value.translation.height) < 8, abs(value.translation.width) < 8 {
                    activateNotification()
                }
            }
    }

    private func updatePresentation(with banner: InAppBannerItem?) {
        expansionTask?.cancel()
        clearBannerTask?.cancel()

        if let banner {
            displayedBanner = banner
            presentationChanged(true)
            if presentationProgress == 1 {
                return
            }

            expansionTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                presentationProgress = 1
            }
        } else {
            presentationProgress = 0
            notificationCenter.bannerFrame = .zero
            clearBannerTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(340))
                guard !Task.isCancelled else { return }
                displayedBanner = nil
                presentationChanged(false)
            }
        }
    }

    private func activateNotification() {
        guard notificationCenter.currentBanner != nil else { return }
        if notificationCenter.currentBannerHasAction {
            notificationCenter.fireCurrentBannerAction()
        } else {
            notificationCenter.showRecentNotifications()
            notificationCenter.dismissCurrentBanner()
        }
    }
}
#endif
