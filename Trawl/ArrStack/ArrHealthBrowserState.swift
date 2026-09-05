import SwiftUI

/// The Health list's selection, owned above the split view so the two native
/// columns share it.
///
/// Held as the check's id rather than the check itself: the list is rebuilt from
/// whatever the servers last reported, so a resolved warning has to be able to
/// drop out from under the pane.
@MainActor
@Observable
final class ArrHealthBrowserState {
    var selectedCheckID: String?
}
