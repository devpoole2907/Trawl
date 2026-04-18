import Foundation
import SwiftData

/// Represents a configured *arr service instance (Sonarr or Radarr).
/// API key is stored in Keychain, not here.
@Model
final class ArrServiceProfile {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var hostURL: String              // e.g. "http://192.168.1.100:8989"
    var serviceType: String          // "sonarr" or "radarr"
    var isEnabled: Bool
    var dateAdded: Date
    var lastSynced: Date?
    var apiVersion: String?          // Populated from /api/v3/system/status

    init(displayName: String, hostURL: String, serviceType: ArrServiceType) {
        self.id = UUID()
        self.displayName = displayName
        self.hostURL = hostURL
        self.serviceType = serviceType.rawValue
        self.isEnabled = true
        self.dateAdded = .now
    }

    /// Keychain key for the API key
    var apiKeyKeychainKey: String { "arr_\(id.uuidString)_apikey" }

    var resolvedServiceType: ArrServiceType {
        ArrServiceType(rawValue: serviceType) ?? .sonarr
    }
}

enum ArrServiceType: String, Codable, CaseIterable, Identifiable {
    case sonarr
    case radarr
    case prowlarr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        case .prowlarr: "Prowlarr"
        }
    }

    var defaultPort: Int {
        switch self {
        case .sonarr: 8989
        case .radarr: 7878
        case .prowlarr: 9696
        }
    }

    var systemImage: String {
        switch self {
        case .sonarr: "tv"
        case .radarr: "film"
        case .prowlarr: "magnifyingglass.circle"
        }
    }
}
