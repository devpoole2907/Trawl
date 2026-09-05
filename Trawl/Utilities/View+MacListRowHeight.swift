import SwiftUI

extension View {
    /// Stops a macOS `List` row from being drawn shorter than its content.
    ///
    /// AppKit measures a row once. A row measured before its column has settled
    /// keeps that height, and everything past it - a subtitle line, a badge's
    /// padding, a now-playing card - is clipped away until something forces a
    /// remeasure: a pull to refresh, or leaving the screen and coming back.
    ///
    /// `fixedSize` refuses the vertical compression, and the floor covers the case
    /// where the row is asked for its size before it has any content to measure.
    /// Both are no-ops once the row has a correct height, and nothing on iOS
    /// exhibits this, so it stays a Mac-only guard.
    func macListRowStableHeight(minHeight: CGFloat = 44) -> some View {
        #if os(macOS)
        self
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: minHeight)
        #else
        self
        #endif
    }
}
