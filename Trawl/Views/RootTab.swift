import SwiftUI

enum RootTab: Hashable, CaseIterable {
    case downloads
    case series
    case movies
    case search
    case more

    var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .series: "Series"
        case .movies: "Movies"
        case .search: "Search"
        case .more: "More"
        }
    }
}
