import Foundation
import SwiftData

/// A configured Cleanuparr instance. The API key lives in Keychain so the
/// shared SwiftData profile contains no authentication secrets.
@Model
public final class CleanuparrServiceProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var hostURL: String
    private var allowsUntrustedTLSValue: Bool?
    public var isEnabled: Bool
    public var dateAdded: Date
    public var lastSynced: Date?

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

    public var apiKeyKeychainKey: String { "cleanuparr_\(id.uuidString)_apikey" }
}
