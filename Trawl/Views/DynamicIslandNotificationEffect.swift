#if os(iOS)
import SwiftUI

struct DynamicIslandNotificationEffect<Content: View>: View {
    let progress: CGFloat
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cappedProgress = max(min(progress, 1), 0)
        let fadeProgress = min(max((cappedProgress - 0.3) / 0.7, 0), 1)
        let topRow = Array(repeating: Color.black, count: 3)
        let middleRow = Array(repeating: Color.black.opacity(0.9), count: 3)
        let bottomRow = Array(repeating: Color.black.opacity(0.3), count: 3)
        let shape = Capsule(style: .continuous)

        ZStack {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5, 0.5], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ],
                colors: topRow + middleRow + bottomRow
            )

            content
                .compositingGroup()
                .blur(radius: reduceMotion ? 0 : 10 - (10 * fadeProgress))
                .opacity(reduceMotion && cappedProgress > 0 ? 1 : fadeProgress)
        }
        // Size the render surface before clipping and applying glass. Applying
        // the frame outside glass leaves the material at its expanded size
        // during dismissal, which appears as a frozen full-width capsule.
        .frame(width: width, height: height)
        .clipShape(shape)
        .glassEffect(
            .clear.tint(.black.opacity(1 - (0.95 * fadeProgress))),
            in: shape
        )
        .environment(\.colorScheme, .dark)
    }
}
#endif
