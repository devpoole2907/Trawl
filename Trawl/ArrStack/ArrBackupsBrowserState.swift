import SwiftUI

/// The Backups list's selection and shared state, owned above the split view
/// so the two native columns share it.
@MainActor
@Observable
final class ArrBackupsBrowserState {
    var selectedSourceID: String?
    var selectedBackupID: String?
    var states: [UUID: ArrBackupViewState] = [:]
    var unavailable: Set<UUID> = []
    var jellyfinState = ArrJellyfinBackupState()
    var sortOrder: ArrBackupSortOrder = .newestFirst
}

struct ArrBackupViewState: Sendable {
    var backups: [ArrBackup] = []
    var isLoading = false
    var isCreating = false
    var isUploading = false
    var error: String?
}

struct ArrJellyfinBackupState: Sendable {
    var backups: [JellyfinBackupManifest] = []
    var isLoading = false
    var isCreating = false
    var error: String?
}

enum ArrBackupSortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst = "Newest First"
    case oldestFirst = "Oldest First"
    case nameAscending = "Name A-Z"
    case nameDescending = "Name Z-A"
    case largestFirst = "Largest First"
    case smallestFirst = "Smallest First"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .newestFirst: "clock.arrow.circlepath"
        case .oldestFirst: "clock"
        case .nameAscending: "textformat.abc"
        case .nameDescending: "textformat.abc.dottedunderline"
        case .largestFirst: "arrow.down.to.line.compact"
        case .smallestFirst: "arrow.up.to.line.compact"
        }
    }
}
