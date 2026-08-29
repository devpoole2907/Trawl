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
    case sabnzbd
    case sonarr
    case radarr
    case prowlarr
    case bazarr
    case seerr
    case jellyfin
    case cleanuparr

    nonisolated var displayName: String {
        switch self {
        case .qbittorrent: "qBittorrent"
        case .sabnzbd: "SABnzbd"
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        case .prowlarr: "Prowlarr"
        case .bazarr: "Bazarr"
        case .seerr: "Seerr"
        case .jellyfin: "Jellyfin"
        case .cleanuparr: "Cleanuparr"
        }
    }

    var brandColor: Color {
        switch self {
        case .qbittorrent: .blue
        case .sabnzbd: .orange
        case .sonarr: .purple
        case .radarr: .mint
        case .prowlarr: .yellow
        case .bazarr: .teal
        case .seerr: .pink
        case .jellyfin: .indigo
        case .cleanuparr: .green
        }
    }

    /// Filled glyph - use for rows, badges, and service-identity contexts.
    nonisolated var systemImage: String {
        switch self {
        case .qbittorrent: "arrow.down.circle.fill"
        case .sabnzbd: "tray.and.arrow.down.fill"
        case .sonarr: "tv.fill"
        case .radarr: "film.fill"
        case .prowlarr: "magnifyingglass.circle.fill"
        case .bazarr: "captions.bubble.fill"
        case .seerr: "eye.fill"
        case .jellyfin: "server.rack"
        case .cleanuparr: "sparkles.rectangle.stack.fill"
        }
    }

    /// Non-filled glyph - use for tab bar items and empty states.
    nonisolated var tabSystemImage: String {
        switch self {
        case .qbittorrent: "arrow.down.circle"
        case .sabnzbd: "tray.and.arrow.down"
        case .sonarr: "tv"
        case .radarr: "film"
        case .prowlarr: "magnifyingglass.circle"
        case .bazarr: "captions.bubble"
        case .seerr: "eye"
        case .jellyfin: "server.rack"
        case .cleanuparr: "sparkles.rectangle.stack"
        }
    }
}
