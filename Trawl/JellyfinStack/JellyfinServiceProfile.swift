import Foundation
import SwiftData

public enum JellyfinAuthMode: String, Codable, CaseIterable, Sendable {
    case apiKey
    case userPass
}

@Model
public final class JellyfinServiceProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var hostURL: String
    private var allowsUntrustedTLSValue: Bool?
    public var isEnabled: Bool
    public var dateAdded: Date

    /// Raw value of `JellyfinAuthMode`. Stored as a `String` because SwiftData
    /// migrations between enum variants are fragile.
    public var authModeRaw: String

    /// Jellyfin user UUID returned by `AuthenticateByName`. Used in `/Users/{id}` paths
    /// for password resets and for resolving the signed-in admin in activity logs.
    /// `nil` for API-key profiles, which authenticate without a user binding.
    public var userID: String?

    /// Cached from `/System/Info` on connect so the settings screen can show
    /// version info without an extra round trip.
    public var serverName: String?
    public var serverVersion: String?

    public init(
        displayName: String,
        hostURL: String,
        authMode: JellyfinAuthMode,
        userID: String? = nil,
        allowsUntrustedTLS: Bool = false
    ) {
        self.id = UUID()
        self.displayName = displayName
        self.hostURL = hostURL
        self.allowsUntrustedTLSValue = allowsUntrustedTLS
        self.isEnabled = true
        self.dateAdded = .now
        self.authModeRaw = authMode.rawValue
        self.userID = userID
    }

    public var allowsUntrustedTLS: Bool {
        get { allowsUntrustedTLSValue ?? false }
        set { allowsUntrustedTLSValue = newValue }
    }

    public var authMode: JellyfinAuthMode {
        get { JellyfinAuthMode(rawValue: authModeRaw) ?? .apiKey }
        set { authModeRaw = newValue.rawValue }
    }

    /// Keychain key for the access token (user/pass mode) or API key (apiKey mode).
    /// Both share storage because Jellyfin treats them identically in the
    /// `Authorization` header — only the issuance flow differs.
    public var accessTokenKey: String { "jellyfin_\(id.uuidString)_token" }
}
