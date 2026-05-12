import SwiftUI

// MARK: - Badge section

struct ArrDetailBadgeSection: View {
    let badges: [ArrDetailBadge]

    var body: some View {
        if !badges.isEmpty {
            ArrDetailPillFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(badges) { badge in
                    pill(badge)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func pill(_ badge: ArrDetailBadge) -> some View {
        Label(badge.label, systemImage: badge.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(badge.color)
            .lineLimit(1)
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
        ArrDetailPillFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(genres.prefix(8).enumerated()), id: \.offset) { _, genre in
                pill(genre)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pill(_ genre: String) -> some View {
        Text(genre)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 220, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
    }
}

private struct ArrDetailPillFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(for: proposal, subviews: subviews)
        let measuredWidth = rows.map(\.width).max() ?? 0
        let width: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            width = proposedWidth
        } else {
            width = measuredWidth
        }

        let height = rows.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let placementProposal = ProposedViewSize(width: bounds.width, height: nil)
        let rows = rows(for: placementProposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX + max((bounds.width - row.width) / 2, 0)

            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(
                        x: x,
                        y: y + max((row.height - item.size.height) / 2, 0)
                    ),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + horizontalSpacing
            }

            y += row.height + verticalSpacing
        }
    }

    private func rows(for proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        guard !subviews.isEmpty else { return [] }

        let sizes = subviews.indices.map { subviews[$0].sizeThatFits(.unspecified) }
        let singleRowWidth = sizes.map(\.width).reduce(0, +) + horizontalSpacing * CGFloat(max(sizes.count - 1, 0))
        let availableWidth: CGFloat
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            availableWidth = max(proposedWidth, 0)
        } else {
            availableWidth = singleRowWidth
        }

        var rows: [Row] = []
        var currentRow = Row()

        for offset in sizes.indices {
            let size = sizes[offset]
            let nextWidth = currentRow.items.isEmpty
                ? size.width
                : currentRow.width + horizontalSpacing + size.width

            if !currentRow.items.isEmpty && nextWidth > availableWidth {
                rows.append(currentRow)
                currentRow = Row()
            }

            currentRow.add(index: offset, size: size, spacing: horizontalSpacing)
        }

        if !currentRow.items.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0

        mutating func add(index: Int, size: CGSize, spacing: CGFloat) {
            if !items.isEmpty {
                width += spacing
            }
            items.append((index: index, size: size))
            width += size.width
            height = max(height, size.height)
        }
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
