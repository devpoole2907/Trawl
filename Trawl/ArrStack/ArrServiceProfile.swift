import Foundation
import SwiftData

/// Represents a configured *arr service instance (Sonarr or Radarr).
/// API key is stored in Keychain, not here.
@Model
public final class ArrServiceProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String
    public var hostURL: String              // e.g. "http://192.168.1.100:8989"
    private var allowsUntrustedTLSValue: Bool?
    /// Optional-backed so an existing store migrates lightly, exactly like
    /// `allowsUntrustedTLSValue`. `nil` reads as HD.
    private var qualityTierValue: String?
    public var serviceType: String          // "sonarr", "radarr", or "prowlarr"
    public var isEnabled: Bool
    public var dateAdded: Date
    public var lastSynced: Date?
    public var apiVersion: String?          // Populated from /api/v3/system/status
    public var importFolders: [String] = [] // Custom folders for manual importing

    public init(
        displayName: String,
        hostURL: String,
        serviceType: ArrServiceType,
        allowsUntrustedTLS: Bool = false,
        qualityTier: ArrQualityTier = .hd
    ) {
        self.id = UUID()
        self.displayName = displayName
        self.hostURL = hostURL
        self.allowsUntrustedTLSValue = allowsUntrustedTLS
        self.qualityTierValue = qualityTier.rawValue
        self.serviceType = serviceType.rawValue
        self.isEnabled = true
        self.dateAdded = .now
    }

    public var allowsUntrustedTLS: Bool {
        get { allowsUntrustedTLSValue ?? false }
        set { allowsUntrustedTLSValue = newValue }
    }

    /// Whether this server holds the HD or the 4K copy of the library.
    ///
    /// This is the whole shape of multi-instance support in Trawl, and it is
    /// declared rather than guessed. An earlier pass derived "HD" and "4K" from
    /// whatever the user had named the server, which worked for "4K Radarr" and
    /// silently produced nonsense for "Radarr (big box)". Seerr models the same
    /// setup the same way, with the 4K server named explicitly.
    ///
    /// Defaults to HD, so an existing single-server install keeps working and
    /// reads as the HD library it always was.
    public var qualityTier: ArrQualityTier {
        get { qualityTierValue.flatMap(ArrQualityTier.init(rawValue:)) ?? .hd }
        set { qualityTierValue = newValue.rawValue }
    }

    /// Keychain key for the API key
    public var apiKeyKeychainKey: String { "arr_\(id.uuidString)_apikey" }

    public var resolvedServiceType: ArrServiceType? {
        ArrServiceType(rawValue: serviceType)
    }
}

/// Which copy of the library a server holds.
///
/// Trawl supports one of each per service — a default Sonarr and a 4K Sonarr, a
/// default Radarr and a 4K Radarr — presented as one blended library. The naming
/// follows Seerr, which pairs the same servers as a default and a 4K one. That is also where
/// the two-instance cap comes from: there are two tiers, so there are two slots,
/// and the limit needs no separate rule.
nonisolated public enum ArrQualityTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case hd
    case uhd

    public var id: String { rawValue }

    /// The badge text. Short by design — it sits on every row of the library.
    ///
    /// "Default" rather than "HD" to match Seerr, which is the other admin surface
    /// for the same pair of servers and calls them the default server and the 4K
    /// server. Two names for one box — "HD" here, "Default" in Linked Applications
    /// — made them read as different things. The `hd` case keeps its raw value:
    /// it is persisted on every profile, and renaming it would orphan them.
    public var label: String {
        switch self {
        case .hd: "Default"
        case .uhd: "4K"
        }
    }

    /// Spelled out for pickers and confirmations, where the extra words earn
    /// their place.
    public var longLabel: String {
        switch self {
        case .hd: "Default (non-4K)"
        case .uhd: "4K (2160p)"
        }
    }
}

nonisolated public enum ArrServiceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case sonarr
    case radarr
    case prowlarr
    case bazarr

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        case .prowlarr: "Prowlarr"
        case .bazarr: "Bazarr"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sonarr: 8989
        case .radarr: 7878
        case .prowlarr: 9696
        case .bazarr: 6767
        }
    }

    public var systemImage: String {
        switch self {
        case .sonarr: "tv.fill"
        case .radarr: "film.fill"
        case .prowlarr: "magnifyingglass.circle.fill"
        case .bazarr: "captions.bubble.fill"
        }
    }
}
