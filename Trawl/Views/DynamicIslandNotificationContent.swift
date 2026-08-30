#if os(iOS)
import SwiftUI

struct DynamicIslandNotificationContent: View {
    let item: InAppBannerItem

    var body: some View {
        HStack(spacing: 10) {
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

            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)

                Text(item.title)
                    .font(.callout)
                    .bold()
                    .foregroundStyle(.white)

                Text(item.message)
                    .font(.caption)
                    .foregroundStyle(.white.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)

        }
        .padding(.horizontal, 20)
        .compositingGroup()
    }

    private var tintColor: Color {
        switch item.style {
        case .success: .green
        case .error: .red
        case .progress: .blue
        }
    }
}
#endif
