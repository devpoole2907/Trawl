import Foundation
import SwiftData

@Model
public final class SeerrServiceProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var hostURL: String
    private var allowsUntrustedTLSValue: Bool?
    public var isEnabled: Bool
    public var dateAdded: Date

    public init(displayName: String, hostURL: String, allowsUntrustedTLS: Bool = false) {
        self.id = UUID()
        self.displayName = displayName
        self.hostURL = hostURL
        self.allowsUntrustedTLSValue = allowsUntrustedTLS
        self.isEnabled = true
        self.dateAdded = .now
    }

    public var allowsUntrustedTLS: Bool {
        get { allowsUntrustedTLSValue ?? false }
        set { allowsUntrustedTLSValue = newValue }
    }

    public var sessionCookieKey: String { "seerr_\(id.uuidString)_session" }
}
