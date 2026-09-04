import SwiftUI

struct NavigationMenuRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // The whole row is the target, not just the icon and the two lines of text.
        //
        // The `HStack` hugs its content, and most of these rows are the label of a
        // `Button(...).buttonStyle(.plain)`, which hit-tests the shape of what it
        // draws. On an iPhone the row is narrow enough that its centre lands on the
        // text; on an iPad it is over a thousand points wide and everything to the
        // right of the subtitle was dead - so a perfectly ordinary tap in the middle
        // of a row did nothing at all. The width has to come first: `.contentShape`
        // on its own has no width to shape.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
