import SwiftUI

/// The full-width glass row behind every Automatic / Interactive search button on
/// the Sonarr and Radarr detail screens.
///
/// These rows are stacked vertically, one per action, rather than placed side by
/// side: two of them in a single row on an iPhone left each one about 150pt wide,
/// which hyphenated "Automatic" and "Interactive" mid-word and cut the subtitle
/// off. Episode detail always stacked them, and every other screen now does too.
struct ArrSearchActionRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    var isLoading: Bool = false
    var trailingSystemImage: String = "arrow.right"
    var accentColor: Color = .purple

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(accentColor)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview("Search actions") {
    VStack(spacing: 12) {
        ArrSearchActionRow(
            title: "Automatic Search",
            subtitle: "Search all monitored episodes",
            systemImage: "magnifyingglass",
            isLoading: true
        )
        ArrSearchActionRow(
            title: "Interactive Search",
            subtitle: "Pick a release",
            systemImage: "person.fill",
            trailingSystemImage: "arrow.up.forward.square",
            accentColor: .orange
        )
    }
    .padding()
    .background(.black)
}
