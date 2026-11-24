import Observation

/// Per-window state for root destinations whose views are replaced when the user
/// changes the selected sidebar row or switches between compact and regular chrome.
@MainActor
@Observable
final class RootNavigationSession {
    let downloads = DownloadsViewSession()
    let search = SearchViewSession()
    let series = ArrLibraryRootSession<SonarrViewModel>()
    let movies = ArrLibraryRootSession<RadarrViewModel>()
}
