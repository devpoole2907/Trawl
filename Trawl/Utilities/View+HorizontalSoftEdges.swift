import SwiftUI

private struct HorizontalSoftEdgesModifier: ViewModifier {
    var edgeWidth: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: edgeWidth)

                Rectangle()
                    .fill(.black)

                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: edgeWidth)
            }
        }
    }
}

extension View {
    func horizontalSoftEdges(edgeWidth: CGFloat = 18) -> some View {
        modifier(HorizontalSoftEdgesModifier(edgeWidth: edgeWidth))
    }
}
