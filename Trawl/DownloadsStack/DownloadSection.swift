import Foundation

enum DownloadSection: String, CaseIterable, Hashable, Identifiable {
    case active = "Active"
    case queue = "Queue"
    case completed = "Completed"
    case seeding = "Seeding"
    case history = "History"
    case issues = "Issues"

    var id: Self { self }
}

/// Which in-progress section a blended download row belongs in. Deliberately two
/// cases and no "neither": every queue row that is not an import issue has to
/// appear under Active or Queue, or it silently vanishes from the tab.
nonisolated enum DownloadRowActivity: Hashable, Sendable {
    case active
    case waiting
}
