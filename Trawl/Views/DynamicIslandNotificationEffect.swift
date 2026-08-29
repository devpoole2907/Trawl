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

        // Order matters: the glass goes down first and the mesh sits over it.
        // `glassEffect` paints a specular highlight along the shape's edge, and
        // with the mesh underneath that highlight lands on top as a light hairline
        // — invisible in light mode against white content, but an obvious white
        // line along the top of the Dynamic Island in dark mode. Measured at the
        // top edge: grey 61 with the mesh underneath, 0 with it on top. Layering
        // the mesh above lets its opaque top row cover the highlight while its
        // translucent lower rows still show the glass, which is the intended
        // "black fading to glass".
        ZStack {
            // Sized *before* `glassEffect`, not by the frame on the ZStack below.
            // Liquid Glass anchors its render surface to the bounds of the view the
            // modifier is attached to, so an unconstrained `Color.clear` leaves the
            // material at its expanded size while everything around it shrinks —
            // the bubble flashes full-width on dismissal instead of collapsing with
            // the rest. This is the safeguard the mesh-over-glass change dropped
            // when it moved the glass inside the stack.
            Color.clear
                .frame(width: width, height: height)
                .glassEffect(
                    .clear.tint(.black.opacity(1 - (0.95 * fadeProgress))),
                    in: shape
                )

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
            // Clipped at the animated size for the same reason: the capsule the
            // mesh is cut to has to be the capsule the glass is drawn in, on every
            // frame of the collapse.
            .frame(width: width, height: height)
            .clipShape(shape)

            content
                .compositingGroup()
                .blur(radius: reduceMotion ? 0 : 10 - (10 * fadeProgress))
                .opacity(reduceMotion && cappedProgress > 0 ? 1 : fadeProgress)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
    }
}

#endif
