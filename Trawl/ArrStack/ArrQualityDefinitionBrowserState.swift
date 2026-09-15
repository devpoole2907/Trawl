import Foundation
import Observation

/// Shared list/detail state for the native Quality Definitions sidebar destination.
@MainActor
@Observable
final class ArrQualityDefinitionBrowserState {
    var selectedInstanceID: UUID?
    var selectedService: ArrServiceType = .sonarr
    var selectedDefinitionID: ArrQualityDefinition.ID?
    var definitions: [ArrQualityDefinition] = []
    var isLoading = false
    var isSaving = false
    var isEditingDefinition = false
    var errorMessage: String?
}
