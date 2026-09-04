import SwiftUI

@MainActor
@Observable
final class SeerrRequestBrowserState {
    var selectedRequestID: Int?
    var viewModel: SeerrRequestManagementViewModel?
}
