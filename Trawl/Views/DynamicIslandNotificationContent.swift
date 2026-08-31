#if os(iOS)
import SwiftUI

struct DynamicIslandNotificationContent: View {
    let item: InAppBannerItem

    var body: some View {
        // Top-aligned, not centred: the text block grows downward for a long
        // message and the icon has to stay level with the title rather than drift
        // to the middle of a tall banner.
        HStack(alignment: .top, spacing: 10) {
            Group {
                if item.showsProgressView {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(tintColor)
                } else {
                    Image(systemName: item.systemImage)
                        .font(.title.weight(.semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, tintColor)
                }
            }
            .frame(width: 50)
            .padding(.top, Self.contentTopInset - 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout)
                    .bold()
                    .foregroundStyle(.white)

                Text(item.message)
                    // Was `.white.secondary`, which resolves dim enough on the
                    // island's black to be hard to read at caption size - the
                    // message is the part carrying the actual information.
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.caption)
                    // Grows downward instead of truncating. Capped so a runaway
                    // server message cannot take over the screen; past the cap it
                    // truncates as before, which is the right failure for text
                    // nobody could read at a glance anyway.
                    .lineLimit(Self.messageLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Self.contentTopInset)
            .padding(.bottom, Self.contentBottomInset)
        }
        .padding(.horizontal, 20)
        .compositingGroup()
    }

    /// Clears the physical island cutout, which the banner is drawn around rather
    /// than under. Previously achieved with a `Spacer` against a fixed 90pt frame -
    /// which is exactly what stopped the banner growing.
    static let contentTopInset: CGFloat = 34
    static let contentBottomInset: CGFloat = 14
    static let messageLineLimit = 4

    private var tintColor: Color {
        switch item.style {
        case .success: .green
        case .error: .red
        case .progress: .blue
        }
    }
}
#endif
