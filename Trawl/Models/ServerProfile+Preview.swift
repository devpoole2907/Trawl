#if DEBUG
import Foundation

extension ServerProfile {
    /// Returns a transient profile NOT inserted into any ModelContext.
    static func preview(
        displayName: String = "My qBittorrent",
        hostURL: String = "http://192.168.1.50:8080"
    ) -> ServerProfile {
        ServerProfile(displayName: displayName, hostURL: hostURL)
    }
}
#endif
