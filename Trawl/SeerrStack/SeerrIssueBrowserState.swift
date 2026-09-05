import SwiftUI

@MainActor
@Observable
final class SeerrIssueBrowserState {
    var selectedIssueID: Int?
    var viewModel: SeerrIssueListViewModel?
    var viewModelSeerrClientID: ObjectIdentifier?
}
