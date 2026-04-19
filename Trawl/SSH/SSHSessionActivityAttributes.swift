import Foundation

#if os(iOS)
import ActivityKit

struct SSHSessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var subtitle: String
        var statusText: String
    }

    var profileID: String
    var hostDisplay: String
}
#endif
