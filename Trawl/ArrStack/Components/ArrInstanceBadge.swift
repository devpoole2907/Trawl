import SwiftUI

/// The visual mark that tells the user which server a thing came from.
///
/// The blended library deliberately has no per-instance screens, so this badge is
/// the *only* place server identity is visible. It appears wherever an item, a
/// queue row, a calendar entry, a health check or a command outcome belongs to
/// one specific server — and is suppressed entirely when only one instance of
/// that service is configured, because then it distinguishes nothing and is pure
/// noise on every row in the app.
struct ArrInstanceBadge: View {
    let label: String
    /// Configured position of the owning server. Keeps the colour stable per
    /// server rather than per row, so "the blue one" stays the same server.
    let ordinal: Int
    var style: Style = .compact

    enum Style {
        /// Bare tinted text. For dense rows where a filled capsule on every line
        /// would out-shout the titles.
        case compact
        /// Filled capsule. For headers and detail cards, where the badge is
        /// carrying real weight rather than annotating a list.
        case prominent
    }

    var body: some View {
        switch style {
        case .compact:
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                .lineLimit(1)
                .accessibilityLabel(Text("On \(label)"))
        case .prominent:
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tint, in: Capsule())
                .lineLimit(1)
                .accessibilityLabel(Text("On \(label)"))
        }
    }

    private var tint: Color {
        ArrInstanceBadge.tint(forOrdinal: ordinal)
    }

    /// Two servers, two colours. The palette is indexed rather than hashed so the
    /// first-configured server is always the same colour across every surface.
    static func tint(forOrdinal ordinal: Int) -> Color {
        let palette: [Color] = [.blue, .purple]
        guard ordinal >= 0 else { return palette[0] }
        return palette[ordinal % palette.count]
    }
}

/// A row of badges for a merged library entry, one per server holding the title.
struct ArrInstanceBadgeRow: View {
    let refs: [ArrInstanceRef]
    var style: ArrInstanceBadge.Style = .compact

    var body: some View {
        if !refs.isEmpty {
            HStack(spacing: 4) {
                ForEach(refs) { ref in
                    ArrInstanceBadge(label: ref.shortLabel, ordinal: ref.ordinal, style: style)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Badges") {
    let refs = ArrInstanceRef.make(
        from: [
            (id: UUID(), displayName: "Radarr HD"),
            (id: UUID(), displayName: "4K Radarr")
        ],
        serviceType: .radarr
    )
    return VStack(alignment: .leading, spacing: 16) {
        ArrInstanceBadgeRow(refs: refs)
        ArrInstanceBadgeRow(refs: refs, style: .prominent)
        ArrInstanceBadgeRow(refs: [refs[1]], style: .compact)
    }
    .padding()
}
#endif
