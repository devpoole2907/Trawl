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
    var selectedFormatTarget: ArrNamingFormatEditorTarget?
    var isLoading = true
    var isSaving = false
    var errorMessage: String?
}
