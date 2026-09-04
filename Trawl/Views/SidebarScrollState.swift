import SwiftUI

/// Retains the tapped row's position when changing the native split-view shape.
/// Geometry is bookkeeping, not view state: scrolling must not redraw the app root.
@MainActor
final class SidebarScrollState {
    var rowFrames: [RootTab: CGRect] = [:]
    var viewportFrame: CGRect = .zero
    private var restoration: (row: RootTab, anchor: UnitPoint, detailColumn: Bool)?

    func capture(_ row: RootTab, replacingColumns: Bool) {
        guard replacingColumns, let frame = rowFrames[row], viewportFrame.height > frame.height else {
            restoration = nil
            return
        }
        let fraction = min(1, max(0, (frame.minY - viewportFrame.minY) / (viewportFrame.height - frame.height)))
        restoration = (row, UnitPoint(x: 0, y: fraction), row.wantsDetailColumn)
    }

    /// Wait for the target row in the new list to lay out. `onAppear` runs before
    /// List has registered its scroll targets, so a scroll request there is lost.
    func takeRestoration(for row: RootTab, detailColumn: Bool) -> UnitPoint? {
        guard let restoration, restoration.row == row,
              restoration.detailColumn == detailColumn else { return nil }
        self.restoration = nil
        return restoration.anchor
    }
}
