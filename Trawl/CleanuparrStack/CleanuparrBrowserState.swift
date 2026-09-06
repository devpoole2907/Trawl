import SwiftUI

/// The selectable items in Cleanuparr's 3-column split view layout.
enum CleanuparrDetailItem: Hashable, Sendable {
    /// High-level activity metrics, strikes, searches, and removals breakdown.
    case overview

    /// A specific scheduled maintenance job.
    case job(name: String)

    /// A specific monitored service health check (download client or Arr instance).
    case serviceHealth(id: String)

    /// Server connection status, readiness diagnostics, and profile settings.
    case server
}

/// The Cleanuparr dashboard's selection and filter state, owned above the
/// split view so the content and detail columns share it without duplicating queries.
@MainActor
@Observable
final class CleanuparrBrowserState {
    var selectedItem: CleanuparrDetailItem? = .overview
    var timeframeHours: Int = 168
    var includeDryRun: Bool = false
}
