#if DEBUG
import Foundation

extension ArrServiceProfile {
    /// Returns a transient profile NOT inserted into any ModelContext.
    /// `@Model` types cannot have stored static lets — always a static func.
    static func preview(
        _ serviceType: ArrServiceType = .sonarr,
        displayName: String? = nil,
        hostURL: String = "http://192.168.1.50:8989"
    ) -> ArrServiceProfile {
        ArrServiceProfile(
            displayName: displayName ?? serviceType.displayName,
            hostURL: hostURL,
            serviceType: serviceType
        )
    }
}
#endif
