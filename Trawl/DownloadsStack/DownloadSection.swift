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
