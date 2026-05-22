import SwiftUI

struct TrawlSegmentBarItem<Selection: Hashable>: Identifiable {
    let value: Selection
    let title: String

    var id: Selection { value }

    init(_ title: String, value: Selection) {
        self.title = title
        self.value = value
    }
}

enum TrawlSegmentBarSearchPlacement {
    case leading
    case trailing
}

enum TrawlSegmentBarAlignment {
    case leading
    case center
}
