import Foundation
import SwiftData

/// A configured SABnzbd instance. The API key is stored in Keychain rather than
/// SwiftData so the profile can safely participate in the shared model schema.
@Model
public final class SABnzbdServiceProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var hostURL: String
    private var allowsUntrustedTLSValue: Bool?
    public var isEnabled: Bool
    public var dateAdded: Date
    public var lastSynced: Date?
    public var serverVersion: String?

    public init(
        displayName: String,
        hostURL: String,
        allowsUntrustedTLS: Bool = false
    ) {
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

    /// Keychain account used for this profile's full-access SABnzbd API key.
    public var apiKeyKeychainKey: String { "sabnzbd_\(id.uuidString)_apikey" }
}
