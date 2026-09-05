import SwiftUI

/// The Library Import list's selection, owned above the split view so the two
/// native columns share it.
///
/// The selected location is a path rather than an index: the list is rebuilt
/// whenever the scope bar changes server, and the roots of an HD/4K pair have
/// nothing to do with each other.
@MainActor
@Observable
final class ArrImportLocationBrowserState {
    var selectedInstanceID: UUID?
    var selectedPath: String?
}
