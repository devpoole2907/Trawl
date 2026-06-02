import SwiftUI

extension View {
    /// Wraps a "not set up" / "not configured" / "no services" empty state (typically a
    /// `ContentUnavailableView`) in a `ScrollView` so it behaves like a configured screen:
    /// it scrolls with the usual pull-to-refresh bounce, and any gradient applied behind it
    /// shows through (a `ScrollView` is transparent).
    ///
    /// This is the canonical empty-state container — it mirrors the qBittorrent "Not Set Up"
    /// state in `ContentView` and the Subtitles hub empty state. Apply it to every bare
    /// no-service empty state so they all scroll consistently instead of sitting pinned and
    /// immovable.
    func scrollableUnavailableState() -> some View {
        ScrollView {
            self
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
