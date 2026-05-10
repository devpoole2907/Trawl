import Foundation

/// Builds the `Authorization` header value Jellyfin requires on every request.
///
/// Format:
/// ```
/// MediaBrowser Client="Trawl", Device="<name>", DeviceId="<uuid>", Version="<x.y.z>", Token="<token>"
/// ```
/// `Token` is omitted when no access token / API key is available (e.g. during
/// `POST /Users/AuthenticateByName` or the unauthenticated `/System/Info/Public` probe).
///
/// Implementation note: every static here uses only `Foundation`-level APIs
/// (`ProcessInfo`, `Bundle`, `UserDefaults`) so it can be called from any actor.
/// `UIDevice.current.name` is `@MainActor` in Swift 6, and on iOS 16+ it returns
/// a generic value ("iPhone") without the user-assigned-device-name entitlement
/// anyway, so the loss is negligible.
enum JellyfinAuthHeader {
    nonisolated static let clientName = "Trawl"

    /// Builds the full header value. Pass `token` when authenticated; pass `nil` for
    /// the public probe (`/System/Info/Public`) and for `AuthenticateByName` itself.
    nonisolated static func value(token: String?) -> String {
        var components = [
            field("Client", clientName),
            field("Device", deviceName),
            field("DeviceId", deviceId),
            field("Version", appVersion)
        ]
        if let token, !token.isEmpty {
            components.append(field("Token", token))
        }
        return "MediaBrowser " + components.joined(separator: ", ")
    }

    // MARK: - Components

    /// Stable per-install device identifier persisted in `UserDefaults`.
    /// Generated once and reused so Jellyfin can recognise this client across launches
    /// (sessions, devices list, activity log all key on this).
    nonisolated static let deviceId: String = {
        let key = "jellyfinDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    nonisolated static let deviceName: String = {
        let host = ProcessInfo.processInfo.hostName
        if !host.isEmpty { return host }
        return "Trawl"
    }()

    nonisolated static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        case let (nil, b?): return b
        default: return "1.0"
        }
    }()

    // MARK: - Helpers

    nonisolated private static func field(_ name: String, _ value: String) -> String {
        // Percent-encode to defend against quotes, commas, or non-ASCII in the value.
        let escaped = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
        return "\(name)=\"\(escaped)\""
    }
}
