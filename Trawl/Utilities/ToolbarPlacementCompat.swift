import SwiftUI

var platformTopBarLeadingPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .automatic
    #endif
}

var platformCancellationPlacement: ToolbarItemPlacement {
    #if os(iOS)
    .topBarLeading
    #else
    .cancellationAction
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
