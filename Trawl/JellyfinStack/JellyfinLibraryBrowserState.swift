import SwiftUI

/// Shared by the library list and detail columns of the root split view.
///
/// The folders live here rather than in the list because each column builds its
/// own copy of the screen: held separately, a path added in the detail pane would
/// not reach the "2 paths" count on the row beside it, and a scan started from one
/// column would spin in only that column.
@MainActor
@Observable
final class JellyfinLibraryBrowserState {
    var selectedLibraryID: String?
    var folders: [JellyfinVirtualFolder] = []
    var isLoading = false
    var errorMessage: String?
    var scanningLibraryID: String?
}
