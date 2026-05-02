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
