#if os(iOS)
import SwiftUI

struct DynamicIslandNotificationToast: View {
    let notificationCenter: InAppNotificationCenter
    let safeAreaTop: CGFloat
    let presentationChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedBanner: InAppBannerItem?
    /// The banner's natural height at full width, measured from a hidden copy of
    /// the content. Measuring a *separate* instance is what keeps this from
    /// feeding back on itself: the copy is laid out with a free vertical axis, so
    /// its height never depends on the height being computed from it.
    @State private var measuredContentHeight: CGFloat = Self.minimumExpandedHeight
    @State private var presentationProgress: CGFloat = 0
    @State private var expansionTask: Task<Void, Never>?
    @State private var clearBannerTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let expandedWidth = geometry.size.width - 20
            // Was a flat 90, which is why a long message could only truncate. The
            // floor keeps a one-line banner pixel-identical to before.
            let expandedHeight = min(
                max(measuredContentHeight, Self.minimumExpandedHeight),
                Self.maximumExpandedHeight
            )
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
                        // No action affordance: every notification is tappable now,
                        // so a chevron on only some of them advertised a difference
                        // that no longer exists.
                        DynamicIslandNotificationContent(item: displayedBanner)
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
            // A background never influences its parent's size, so the measuring
            // copy can be laid out at full width without disturbing the layout it
            // is measuring for.
            .background(alignment: .topLeading) {
                if let displayedBanner {
                    DynamicIslandNotificationContent(item: displayedBanner)
                        .frame(width: expandedWidth)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            measuredContentHeight = height
                        }
                }
            }
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

    /// A one-line banner keeps the height it has always had.
    static let minimumExpandedHeight: CGFloat = 90
    /// Past this the message truncates rather than the banner swallowing the
    /// screen - four lines of caption plus the title and insets.
    static let maximumExpandedHeight: CGFloat = 190

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
        notificationCenter.activateCurrentBanner()
    }
}
#endif
