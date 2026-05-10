import SwiftUI

// MARK: - Badge section

struct ArrDetailBadgeSection: View {
    let badges: [ArrDetailBadge]

    var body: some View {
        if !badges.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(badges) { badge in pill(badge) }
                }
                VStack(spacing: 8) {
                    ForEach(badges) { badge in pill(badge) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func pill(_ badge: ArrDetailBadge) -> some View {
        Label(badge.label, systemImage: badge.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(badge.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Overview card

struct ArrDetailOverviewCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Overview", systemImage: "text.alignleft")
                .font(.headline)
                .foregroundStyle(.white)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Genre chips

struct ArrDetailGenreChips: View {
    let genres: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(genres.prefix(8).enumerated()), id: \.offset) { index, genre in pill(genre) }
            }
            VStack(spacing: 8) {
                ForEach(Array(genres.prefix(8).enumerated()), id: \.offset) { index, genre in pill(genre) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pill(_ genre: String) -> some View {
        Text(genre)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
    }
}

// MARK: - Alternate titles card

/// Displays a collapsible list of alternate titles.
/// Each entry is `(title, subtitle?)` — callers map service-specific types to this tuple.
struct ArrDetailAlternateTitlesCard: View {
    let titles: [(title: String, subtitle: String?)]
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alternative Titles")
                            .font(.subheadline.weight(.semibold))
                        Text("\(titles.count) titles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ForEach(Array(titles.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.subheadline)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if index < titles.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}
