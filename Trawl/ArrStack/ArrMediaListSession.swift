import Observation

/// Durable interaction state for a Series or Movies library list.
@MainActor
@Observable
final class ArrMediaListSession {
    var scrollPosition: ArrMergeKey?
    var editMode: SelectionMode = .inactive
    var selectedIDs: Set<ArrMergeKey> = []
    var isFilterSearchExpanded = false
}
