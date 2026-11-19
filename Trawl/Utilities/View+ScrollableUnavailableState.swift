import SwiftUI

extension View {
    /// Wraps a "not set up" / "not configured" / "no services" empty state (typically a
    /// `ContentUnavailableView`) in a `ScrollView` so it behaves like a configured screen:
    /// it scrolls with the usual pull-to-refresh bounce, and any gradient applied behind it
    /// shows through (a `ScrollView` is transparent).
    ///
    /// This is the canonical empty-state container - it mirrors the qBittorrent "Not Set Up"
    /// state in `ContentView` and the Subtitles hub empty state. Apply it to every bare
    /// no-service empty state so they all scroll consistently instead of sitting pinned and
    /// immovable.
    ///
    /// The state fills the scroll view's visible height, so it sits in the middle of the
    /// screen like a bare `ContentUnavailableView` does. It used to take a fixed 360pt
    /// slot at the top, which put these states in the upper third of an iPhone while
    /// Search's "No Results" sat in the middle.
    func scrollableUnavailableState() -> some View {
        ScrollView {
            self
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
                    max(length, EmptyStateLayout.minimumHeight)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Centres a list's only row - an empty, error or first-load state - in the list's
    /// visible height, so every list's empty state lines up with the others and with
    /// a bare `ContentUnavailableView`.
    ///
    /// The row is sized from the list's own visible height less the inset-grouped
    /// section margins, rather than a fixed height that left it in the top third.
    func centredInVisibleList() -> some View {
        containerRelativeFrame(.vertical, alignment: .center) { length, _ in
            max(length - EmptyStateLayout.listChromeReserve, EmptyStateLayout.minimumHeight)
        }
        .frame(maxWidth: .infinity)
    }
}

enum EmptyStateLayout {
    /// Below this an empty state's icon, title, message and button stop fitting.
    static let minimumHeight: CGFloat = 280
    /// An inset-grouped list puts a section margin above its first row and row insets
    /// around it. Without this allowance a full-height row overflows and the list
    /// scrolls by that much.
    static let listChromeReserve: CGFloat = 64
}
