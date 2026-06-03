import SwiftUI

/// A poster + title + year row used to present a Sonarr/Radarr catalog or library
/// match. Shared by the Manual Import identify sheet and the Library Import match
/// sheet so the two stay visually identical. The optional trailing `badge` drives
/// a Select/Selected capsule for sheets that keep a persistent selection; pass
/// `nil` for tap-to-pick sheets that dismiss on selection.
struct ArrCatalogMediaRow: View {
    let title: String
    let year: Int?
    let posterURL: URL?
    var badge: String? = nil
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: posterURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    Image(systemName: "photo")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.green : Color.blue, in: Capsule())
                    .animation(.snappy, value: isSelected)
            }
        }
        .padding(.vertical, 4)
    }
}
