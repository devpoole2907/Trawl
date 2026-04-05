import Foundation
import SwiftData

@Model
final class RecentSavePath {
    var path: String
    var lastUsed: Date
    var useCount: Int

    init(path: String) {
        self.path = path
        self.lastUsed = .now
        self.useCount = 1
    }
}
