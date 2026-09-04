import SwiftUI

/// Shared by the indexer list and detail columns of the root split view.
@MainActor
@Observable
final class ProwlarrIndexerBrowserState {
    var selection: ProwlarrIndexerSelection?
    var prowlarrViewModel: ProwlarrViewModel?
    var directViewModel: ArrIndexerManagementViewModel?
    var applicationsViewModel: ProwlarrApplicationsViewModel?
}
