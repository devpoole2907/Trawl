import SwiftUI

/// The visual mark that tells the user which server a thing came from.
///
/// The blended library deliberately has no per-instance screens, so this badge is
/// the *only* place server identity is visible. It appears wherever an item, a
/// queue row, a calendar entry, a health check or a command outcome belongs to
/// one specific server - and is suppressed entirely when only one instance of
/// that service is configured, because then it distinguishes nothing and is pure
/// noise on every row in the app.
struct ArrInstanceBadge: View {
    let label: String
    /// Configured position of the owning server. Keeps the colour stable per
    /// server rather than per row, so "the blue one" stays the same server.
    let ordinal: Int
    /// Whether this server actually holds a file, as opposed to merely having the
    /// title in its library.
    ///
    /// A filled badge means downloaded; a hollow one means the title is in that
    /// server's library with nothing on disk yet. Folding availability into the
    /// badge is what lets the row drop its separate availability pill: "Default,
    /// 4K" beside "Available Default & 4K" said the same thing twice in the common
    /// case, and differed only when a title was in a library but not downloaded -
    /// which is exactly what the fill now shows.
    var isDownloaded: Bool = true
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
                .background {
                    if isDownloaded {
                        RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.14))
                    } else {
                        // Outlined rather than tinted: fill is the signal, and a
                        // hollow badge has to be legible as "not yet" without it.
                        RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .opacity(isDownloaded ? 1 : 0.75)
                .lineLimit(1)
                .accessibilityLabel(accessibilityText)
        case .prominent:
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDownloaded ? .white : tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    if isDownloaded {
                        Capsule().fill(tint)
                    } else {
                        Capsule().strokeBorder(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .lineLimit(1)
                .accessibilityLabel(accessibilityText)
        }
    }

    /// The fill is the only visual difference, and fill alone is invisible to
    /// plenty of people, so the state is spelled out here rather than implied.
    private var accessibilityText: Text {
        isDownloaded ? Text("On \(label), downloaded") : Text("On \(label), not downloaded")
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
///
/// `downloadedTiers` marks which of those servers actually has a file; anything
/// else renders hollow. Passing nothing keeps every badge filled, which is right
/// for the places that describe membership only - a detail header, say - and have
/// no availability to express.
struct ArrInstanceBadgeRow: View {
    let refs: [ArrInstanceRef]
    var downloadedTiers: [ArrQualityTier]?
    var style: ArrInstanceBadge.Style = .compact

    var body: some View {
        if !refs.isEmpty {
            HStack(spacing: 4) {
                ForEach(refs) { ref in
                    ArrInstanceBadge(
                        label: ref.shortLabel,
                        ordinal: ref.ordinal,
                        isDownloaded: downloadedTiers.map { $0.contains(ref.tier) } ?? true,
                        style: style
                    )
                }
            }
        }
    }
}

#if DEBUG
#Preview("Badges") {
    let refs = ArrInstanceRef.previewPair(.radarr)
    return VStack(alignment: .leading, spacing: 16) {
        ArrInstanceBadgeRow(refs: refs)
        ArrInstanceBadgeRow(refs: refs, style: .prominent)
        ArrInstanceBadgeRow(refs: [refs[1]], style: .compact)
        // Downloaded on the first server only: the second reads as "in the library,
        // nothing on disk".
        ArrInstanceBadgeRow(refs: refs, downloadedTiers: [refs[0].tier])
        ArrInstanceBadgeRow(refs: refs, downloadedTiers: [refs[0].tier], style: .prominent)
        // Nothing downloaded anywhere - the case that still shows a status pill.
        ArrInstanceBadgeRow(refs: refs, downloadedTiers: [])
    }
    .padding()
}
#endif
