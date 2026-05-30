import SwiftUI

enum RootTab: Hashable, CaseIterable {
    case torrents
    case series
    case movies
    case search
    case more

    var displayName: String {
        switch self {
        case .torrents: "Torrents"
        case .series: "Series"
        case .movies: "Movies"
        case .search: "Search"
        case .more: "More"
        }
    }
}
