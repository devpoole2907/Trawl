import Observation

/// Browsing context that should survive replacing `DownloadsView`.
/// Confirmation dialogs and sheets remain view-local because returning to a tab
/// should not resurrect an interrupted destructive action.
@MainActor
@Observable
final class DownloadsViewSession {
    let viewModel = DownloadsViewModel()
    var selectedSection: DownloadSection
    var sortOrder: DownloadSortCriterion = .date
    var isSearchExpanded = false
    var managementRoute: DownloadsManagementRoute?
    var utilitySheetRoute: DownloadsManagementRoute?
    var titleDestination: DownloadsTitleDestination = .downloads
    var editMode: SelectionMode = .inactive
    var selectedRowIDs: Set<String> = []

    init(initialSection: DownloadSection = .active) {
        selectedSection = initialSection
    }
}
