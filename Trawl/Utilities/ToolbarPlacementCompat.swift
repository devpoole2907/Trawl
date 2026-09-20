import SwiftUI

var platformTopBarLeadingPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .navigation
    #endif
}

var platformCancellationPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .cancellationAction
    #endif
}

/// Read-only sheets keep the existing iOS Done action while using Mac's
/// bottom-leading cancellation position and Close label.
var platformReadOnlySheetDismissPlacement: ToolbarItemPlacement {
    #if os(macOS)
    .cancellationAction
    #else
    .confirmationAction
    #endif
}

var platformReadOnlySheetDismissTitle: String {
    #if os(macOS)
    "Close"
    #else
    "Done"
    #endif
}

var platformTopBarTrailingPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .primaryAction
    #endif
}

/// macOS has no bottom bar; the item folds into the normal toolbar instead.
var platformBottomBarPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .bottomBar
    #else
    .automatic
    #endif
}
