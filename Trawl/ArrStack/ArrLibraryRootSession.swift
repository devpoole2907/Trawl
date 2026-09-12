import Observation

/// Retains one library root's model and browsing context while its sidebar branch
/// is not being rendered.
@MainActor
@Observable
final class ArrLibraryRootSession<Model> {
    var viewModel: Model?
    var lifecycleKey: String?
    let list = ArrMediaListSession()

    init(viewModel: Model? = nil, lifecycleKey: String? = nil) {
        self.viewModel = viewModel
        self.lifecycleKey = lifecycleKey
    }
}
