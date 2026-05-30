#if DEBUG
import Foundation

extension SeerrServiceProfile {
    /// Returns a transient profile NOT inserted into any ModelContext.
    /// `@Model` types cannot have stored static lets — always a static func.
    static func preview(
        displayName: String = "My Overseerr",
        hostURL: String = "http://192.168.1.50:5055"
    ) -> SeerrServiceProfile {
        SeerrServiceProfile(
            displayName: displayName,
            hostURL: hostURL
        )
    }
}
#endif
