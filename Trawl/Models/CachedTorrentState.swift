import Foundation
import SwiftData

@Model
final class CachedTorrentState {
    @Attribute(.unique) var hash: String
    var name: String
    var state: String
    var progress: Double
    var lastUpdated: Date

    init(hash: String, name: String, state: String, progress: Double) {
        self.hash = hash
        self.name = name
        self.state = state
        self.progress = progress
        self.lastUpdated = .now
    }
}
