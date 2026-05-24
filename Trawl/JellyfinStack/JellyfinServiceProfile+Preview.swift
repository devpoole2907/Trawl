#if DEBUG
import Foundation

extension JellyfinServiceProfile {
    /// Returns a transient profile NOT inserted into any ModelContext.
    /// `@Model` types cannot have stored static lets — always a static func.
    static func preview(
        displayName: String = "My Jellyfin",
        hostURL: String = "http://192.168.1.50:8096",
        authMode: JellyfinAuthMode = .apiKey
    ) -> JellyfinServiceProfile {
        JellyfinServiceProfile(
            displayName: displayName,
            hostURL: hostURL,
            authMode: authMode
        )
    }
}
#endif
