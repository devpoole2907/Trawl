import Foundation
import Observation

/// Shared form/detail state for the native Naming sidebar destination.
@MainActor
@Observable
final class ArrNamingBrowserState {
    var selectedInstanceID: UUID?
    var selectedService: ArrServiceType = .sonarr
    var sonarrConfig: SonarrNamingConfig?
    var radarrConfig: RadarrNamingConfig?
    /// The server `sonarrConfig`/`radarrConfig` were read from. A response for any
    /// other server is stale and must not replace them.
    var loadedInstanceID: UUID?
    var selectedFormatTarget: ArrNamingFormatEditorTarget?
    var isLoading = true
    var isSaving = false
    var errorMessage: String?

    /// Drafts for this session, keyed by server *and* format, so a column rebuild or
    /// a trip to another sidebar destination returns to the same edits.
    private(set) var editorSessions: [ArrNamingEditorScope: ArrNamingEditorSession] = [:]

    func editorSession(for scope: ArrNamingEditorScope) -> ArrNamingEditorSession? {
        editorSessions[scope]
    }

    /// The session to open for `scope`. An untouched existing draft follows the
    /// server's current value; one with edits is returned as it is.
    @discardableResult
    func openEditorSession(for scope: ArrNamingEditorScope, serverName: String, serverFormat: String) -> ArrNamingEditorSession {
        if let existing = editorSessions[scope] {
            existing.refreshBaseline(serverFormat)
            return existing
        }
        let session = ArrNamingEditorSession(scope: scope, serverName: serverName, serverFormat: serverFormat)
        editorSessions[scope] = session
        return session
    }

    /// The draft with unsaved edits on `instanceID`, if any.
    func dirtySession(on instanceID: UUID?) -> ArrNamingEditorSession? {
        editorSessions.values.first { $0.scope.instanceID == instanceID && $0.isDirty }
    }
}
