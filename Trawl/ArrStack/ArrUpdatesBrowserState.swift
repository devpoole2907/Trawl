import SwiftUI

/// The Updates list's selection and live model, owned above the split view so
/// the two native columns share it.
@MainActor
@Observable
final class ArrUpdatesBrowserState {
    var selectedInstanceID: UUID?
    var selectedVersion: String?
    let viewModel = ArrUpdatesViewModel()
}
