import Foundation

/// Failures the widget data layer can surface to a timeline provider.
///
/// This lives outside `WidgetDataFetcher` so the pure mapping from a failure to the
/// short string a widget shows can be compiled and tested without dragging SwiftData,
/// UIKit and the Keychain into the test target. `WidgetDataFetcher.WidgetError` remains
/// a valid spelling for every existing call site.
enum WidgetFetchError: LocalizedError, Equatable {
    case noServerConfigured
    case noArrServicesConfigured
    case noSeerrServicesConfigured
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .noServerConfigured: "No qBittorrent server configured."
        case .noArrServicesConfigured: "No Sonarr or Radarr services configured."
        case .noSeerrServicesConfigured: "No Seerr server configured."
        case .missingCredentials: "Server credentials not found in keychain."
        }
    }
}
