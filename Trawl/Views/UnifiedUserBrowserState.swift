import SwiftUI

/// Shared by the user list and detail columns of the root split view.
///
/// The view model lives here rather than in the list because each column builds
/// its own copy of the screen. Two models would mean two fetches of the same
/// accounts, and a rename made in the detail pane would leave the row beside it
/// still showing the old name.
@MainActor
@Observable
final class UnifiedUserBrowserState {
    var selectedUserID: String?
    var viewModel: UnifiedUserViewModel?
    /// Which Seerr client the model was built against, so pointing the app at a
    /// different Seerr rebuilds it rather than showing the previous server's users.
    var viewModelSeerrClientID: ObjectIdentifier?
}
