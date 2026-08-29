import SwiftUI

/// The monitored marker on a library row.
///
/// A merged row stands for every server's copy of a title, and those copies can
/// disagree: unmonitoring the 4K copy from its detail view leaves the HD one
/// monitored. Rendering that identically to "monitored on both" is a half-truth
/// the list has no other way to correct, so a partial state gets the hollow
/// bookmark and the filled one is reserved for "monitored everywhere".
struct ArrMonitorBadge: View {
    let monitoredCount: Int
    let totalCount: Int

    /// For the single-copy callers that have a plain Bool and no pair to describe.
    init(isMonitored: Bool) {
        self.monitoredCount = isMonitored ? 1 : 0
        self.totalCount = 1
    }

    init(monitoredCount: Int, totalCount: Int) {
        self.monitoredCount = monitoredCount
        self.totalCount = totalCount
    }

    private var isPartial: Bool {
        totalCount > 1 && monitoredCount > 0 && monitoredCount < totalCount
    }

    var body: some View {
        if monitoredCount > 0 {
            Image(systemName: isPartial ? "bookmark" : "bookmark.fill")
                .foregroundStyle(.blue)
                .accessibilityLabel(
                    isPartial
                        ? Text("Monitored on \(monitoredCount) of \(totalCount) servers")
                        : Text("Monitored")
                )
        }
    }
}
