import SwiftUI

/// The top of a detail screen for something that is not media.
///
/// `ArrDetailHeaderView` covers the poster case - a series, a movie, a request -
/// where the artwork carries the identity. This covers the rest: a person, a
/// library, anything whose identity is a glyph, a name and a handful of badges.
/// It exists so those screens open with the thing they are about rather than with
/// a row of fields, and so they do it the same way as each other.
struct TrawlEntityHeader: View {
    enum Shape {
        /// People.
        case circle
        /// Everything else: libraries, folders, clients.
        case rounded
    }

    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    /// An avatar or icon fetched from the service, falling back to `systemImage`.
    var artworkURL: URL?
    var shape: Shape = .rounded
    var badges: [ArrDetailBadge] = []

    private var clipShape: AnyShape {
        switch shape {
        case .circle: AnyShape(Circle())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            artwork

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if !badges.isEmpty {
                // Centred under the name while the badges fit, which is the case
                // this header is usually in; a scroll only when they do not, so a
                // narrow pane truncates nothing. Wrapping to a second line was the
                // other option and it reads as the start of a new section.
                ViewThatFits(in: .horizontal) {
                    badgeRow
                        .frame(maxWidth: .infinity)

                    ScrollView(.horizontal) {
                        badgeRow.padding(.horizontal, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var badgeRow: some View {
        HStack(spacing: 8) {
            ForEach(badges) { badge in
                Label(badge.label, systemImage: badge.icon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(badge.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(badge.color)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        ArrArtworkView(url: artworkURL) {
            clipShape
                .fill(tint.opacity(0.15))
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(tint)
                }
        }
        .frame(width: 76, height: 76)
        .clipShape(clipShape)
    }
}
