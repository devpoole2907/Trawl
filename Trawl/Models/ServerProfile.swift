import Foundation
import SwiftData

@Model
public final class ServerProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var hostURL: String
    private var allowsUntrustedTLSValue: Bool?
    public var isActive: Bool
    public var dateAdded: Date
    public var lastConnected: Date?
    public var defaultSavePath: String?

    public init(displayName: String, hostURL: String, allowsUntrustedTLS: Bool = false) {
        self.id = UUID()
        self.displayName = displayName
        self.hostURL = hostURL
        self.allowsUntrustedTLSValue = allowsUntrustedTLS
        self.isActive = true
        self.dateAdded = .now
    }

    public var allowsUntrustedTLS: Bool {
        get { allowsUntrustedTLSValue ?? false }
        set { allowsUntrustedTLSValue = newValue }
    }

    /// Keychain key for the username credential
    public var usernameKey: String { "server_\(id.uuidString)_username" }

    /// Keychain key for the password credential
    public var passwordKey: String { "server_\(id.uuidString)_password" }
}
