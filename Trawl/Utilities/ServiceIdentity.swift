import SwiftUI

extension ArrServiceType {
    nonisolated var serviceIdentity: ServiceIdentity {
        switch self {
        case .sonarr: .sonarr
        case .radarr: .radarr
        case .prowlarr: .prowlarr
        case .bazarr: .bazarr
        }
    }
}

enum ServiceIdentity: String, CaseIterable {
    case qbittorrent
    case sonarr
    case radarr
    case prowlarr
    case bazarr
    case seerr
    case jellyfin

    nonisolated var displayName: String {
        switch self {
        case .qbittorrent: "qBittorrent"
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        case .prowlarr: "Prowlarr"
        case .bazarr: "Bazarr"
        case .seerr: "Seerr"
        case .jellyfin: "Jellyfin"
        }
    }

    var brandColor: Color {
        switch self {
        case .qbittorrent: .blue
        case .sonarr: .purple
        case .radarr: .orange
        case .prowlarr: .yellow
        case .bazarr: .teal
        case .seerr: .indigo
        case .jellyfin: .indigo
        }
    }

    /// Filled glyph — use for rows, badges, and service-identity contexts.
    nonisolated var systemImage: String {
        switch self {
        case .qbittorrent: "arrow.down.circle.fill"
        case .sonarr: "tv.fill"
        case .radarr: "film.fill"
        case .prowlarr: "magnifyingglass.circle.fill"
        case .bazarr: "captions.bubble.fill"
        case .seerr: "eye.fill"
        case .jellyfin: "server.rack"
        }
    }

    /// Non-filled glyph — use for tab bar items and empty states.
    nonisolated var tabSystemImage: String {
        switch self {
        case .qbittorrent: "arrow.down.circle"
        case .sonarr: "tv"
        case .radarr: "film"
        case .prowlarr: "magnifyingglass.circle"
        case .bazarr: "captions.bubble"
        case .seerr: "eye"
        case .jellyfin: "server.rack"
        }
    }
}
