import SwiftUI

@MainActor
@Observable
final class ArrQualityProfileBrowserState {
    var selectedInstanceID: UUID?
    var selectedProfileID: ArrQualityProfile.ID?
}
