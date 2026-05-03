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
    public var serviceType: String          // "sonarr", "radarr", or "prowlarr"
    public var isEnabled: Bool
    public var dateAdded: Date
    public var lastSynced: Date?
    public var apiVersion: String?          // Populated from /api/v3/system/status
    public var importFolders: [String] = [] // Custom folders for manual importing

    public init(displayName: String, hostURL: String, serviceType: ArrServiceType, allowsUntrustedTLS: Bool = false) {
        self.id = UUID()
        self.displayName = displayName
        self.hostURL = hostURL
        self.allowsUntrustedTLSValue = allowsUntrustedTLS
        self.serviceType = serviceType.rawValue
        self.isEnabled = true
        self.dateAdded = .now
    }

    public var allowsUntrustedTLS: Bool {
        get { allowsUntrustedTLSValue ?? false }
        set { allowsUntrustedTLSValue = newValue }
    }

    /// Keychain key for the API key
    public var apiKeyKeychainKey: String { "arr_\(id.uuidString)_apikey" }

    public var resolvedServiceType: ArrServiceType? {
        ArrServiceType(rawValue: serviceType)
    }
}

public enum ArrServiceType: String, Codable, CaseIterable, Identifiable {
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
        case .sonarr: "tv"
        case .radarr: "film"
        case .prowlarr: "magnifyingglass.circle"
        case .bazarr: "captions.bubble"
        }
    }
}
