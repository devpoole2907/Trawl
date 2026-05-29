import SwiftUI

struct InAppNotificationBanner: View {
    let item: InAppBannerItem
    let onDismiss: () -> Void
    let onTap: () -> Void
    var hasAction = false

    @State private var dragOffset: CGFloat = 0
    @State private var didDrag = false

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                if item.showsProgressView {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(item.tintColor)
                } else {
                    Image(systemName: item.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(item.tintColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(item.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if hasAction {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular.tint(item.tintColor.opacity(0.18)), in: RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if abs(value.translation.width) > 5 || abs(value.translation.height) > 5 {
                        didDrag = true
                    }
                    let translation = value.translation.height
                    if translation < 0 {
                        dragOffset = translation
                    } else {
                        dragOffset = rubberBand(translation)
                    }
                }
                .onEnded { value in
                    let wasDrag = didDrag
                    didDrag = false

                    if value.translation.height < -40 {
                        onDismiss()
                        return
                    }

                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                        dragOffset = 0
                    }

                    if !wasDrag {
                        onTap()
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

extension InAppNotificationBanner {
    func withActionAffordance(_ hasAction: Bool) -> InAppNotificationBanner {
        var copy = self
        copy.hasAction = hasAction
        return copy
    }
}

// UIKit-style rubber-band resistance: asymptotically approaches `dimension`
// so the user can tug the banner down slightly but never drag it indefinitely.
private func rubberBand(_ distance: CGFloat, dimension: CGFloat = 80) -> CGFloat {
    let d = max(distance, 0)
    return (1.0 - 1.0 / ((d * 0.55 / dimension) + 1.0)) * dimension
}

private extension InAppBannerItem {
    var tintColor: Color {
        switch style {
        case .success: .green
        case .error: .red
        case .progress: .blue
        }
    }
}
