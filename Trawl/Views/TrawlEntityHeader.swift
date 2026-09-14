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
                    .trawlCentralHeaderTitle(title)
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
                ArrDetailBadgeLabel(badge: badge)
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

/// Only publishes threshold crossings, rather than every point of scrolling.
private struct CentralHeaderTitlePreference: PreferenceKey {
    static let defaultValue: [String: Bool] = [:]

    static func reduce(value: inout [String: Bool], nextValue: () -> [String: Bool]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct CentralHeaderTitleTracker: ViewModifier {
    let title: String
    @State private var hasScrolledPast = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { proxy in
                // A title below the viewport has not been scrolled past. Observe
                // the bottom edge so multiline titles finish leaving first.
                proxy.bounds(of: .scrollView(axis: .vertical)) != nil
                    && proxy.frame(in: .scrollView(axis: .vertical)).maxY <= 0
            } action: { hasScrolledPast = $0 }
            .preference(key: CentralHeaderTitlePreference.self, value: [title: hasScrolledPast])
    }
}

private struct CentralHeaderNavigationTitle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let subtitle: String?
    @State private var headerStates: [String: Bool] = [:]

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationSubtitle(headerStates[title] == nil ? (subtitle ?? "") : "")
            .onPreferenceChange(CentralHeaderTitlePreference.self) { states in
                // Form/List can recycle the header row off-screen. Keep its last
                // crossing instead of removing the principal item and exposing
                // the native title when the row's preference disappears.
                let updatedStates = headerStates.merging(states, uniquingKeysWith: { _, new in new })
                guard headerStates != updatedStates else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    headerStates = updatedStates
                }
            }
            .toolbar {
                if let hasScrolledPast = headerStates[title] {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                                .accessibilityIdentifier("central-header-navigation-title")
                            if let subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .accessibilityIdentifier("central-header-navigation-subtitle")
                            }
                        }
                        .opacity(hasScrolledPast ? 1 : 0)
                        // Toolbar contents are hosted separately from the Form.
                        // Animate at the opacity itself as well as at the state
                        // update so the host cannot drop the transaction.
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasScrolledPast)
                        .accessibilityHidden(!hasScrolledPast)
                    }
                }
            }
            #else
            .navigationSubtitle(subtitle ?? "")
            #endif
    }
}

extension View {
    func trawlCentralHeaderTitle(_ title: String) -> some View {
        modifier(CentralHeaderTitleTracker(title: title))
    }

    /// Retains native navigation identity/back labels, while handing the visible
    /// title over from a matching central header after it scrolls off the top.
    func trawlCentralHeaderNavigationTitle(_ title: String, subtitle: String? = nil) -> some View {
        modifier(CentralHeaderNavigationTitle(title: title, subtitle: subtitle))
    }
}
