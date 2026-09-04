import SwiftUI

/// Selection shared by the content and detail roots of one sidebar destination.
@MainActor
@Observable
final class TrawlColumnSelection<Value: Hashable> {
    var selection: Value?

    var binding: Binding<Value?> {
        @Bindable var state = self
        return $state.selection
    }
}
