import Observation
import SwiftUI

/// Search state shared by the tab and split-view presentations in one window.
@MainActor
@Observable
final class SearchViewSession {
    let viewModel: SearchViewModel
    var navigationPath = NavigationPath()

    init(viewModel: SearchViewModel = SearchViewModel()) {
        self.viewModel = viewModel
    }
}
