import SwiftUI

/// The Root Folders list's selection and shared state, owned above the
/// split view so the two native columns share it.
@MainActor
@Observable
final class ArrRootFolderBrowserState {
    var selectedInstanceID: UUID?
}
