import AppIntents
import CoreSpotlight
import Foundation
import OSLog

/// Adds Trawl's *arr App Entities to the Spotlight index so they become discoverable by
/// Apple Intelligence and Siri (the "semantic index" half of the Siri AI integration).
///
/// This is additive on top of the v1 `AppShortcutsProvider` phrases: indexing lets the system
/// surface configured services and library content even from vague queries, and lets Spotlight
/// launch Trawl onto the matching item.
///
/// All APIs used here (`IndexedEntity`, `CSSearchableIndex.indexAppEntities`) ship in the SDK
/// for Trawl's iOS 26.1 deployment target, so no availability gating is required; failures are
/// swallowed and logged so indexing can never disrupt the app or an intent.
enum ArrSpotlightIndexer {
    private static let logger = Logger(subsystem: "com.poole.james.Trawl", category: "ArrSpotlightIndexer")

    /// Stable, named indexes (Apple recommends named indexes over the default for shipping code).
    private static let servicesIndexName = "TrawlArrServices"
    private static let libraryIndexName = "TrawlArrLibrary"

    // MARK: - Services

    /// Indexes the configured Radarr/Sonarr/Prowlarr services. Cheap — reads SwiftData only —
    /// so it's safe to call on every launch.
    static func indexConfiguredServices() async {
        do {
            let services = try await ArrIntentSupport.loadServices(ofTypes: Set(ArrServiceType.allCases))
            let entities = services.map(ArrServiceEntity.init(snapshot:))
            guard !entities.isEmpty else { return }
            try await CSSearchableIndex(name: servicesIndexName).indexAppEntities(entities)
            logger.debug("Indexed \(entities.count, privacy: .public) services for Spotlight.")
        } catch {
            logger.error("Service indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Library content

    /// Opportunistically indexes movie entities (e.g. from a search result) so they're findable later.
    static func index(movies: [ArrMovieEntity]) async {
        guard !movies.isEmpty else { return }
        do {
            try await CSSearchableIndex(name: libraryIndexName).indexAppEntities(movies)
        } catch {
            logger.error("Movie indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opportunistically indexes series entities (e.g. from a search result).
    static func index(series: [ArrSeriesEntity]) async {
        guard !series.isEmpty else { return }
        do {
            try await CSSearchableIndex(name: libraryIndexName).indexAppEntities(series)
        } catch {
            logger.error("Series indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Indexes the full Radarr/Sonarr libraries. Network-heavy — call deliberately (e.g. from a
    /// pull-to-refresh or a manual "re-index" action), not on every launch.
    static func indexLibraries() async {
        let services = (try? await ArrIntentSupport.loadServices(ofTypes: [.radarr, .sonarr])) ?? []
        for service in services {
            do {
                switch service.serviceType {
                case .radarr:
                    let client = try await ArrIntentSupport.makeRadarrClient(service)
                    let movies = try await client.getMovies()
                    await index(movies: movies.map { ArrMovieEntity(serviceID: service.id.uuidString, movie: $0) })
                case .sonarr:
                    let client = try await ArrIntentSupport.makeSonarrClient(service)
                    let series = try await client.getSeries()
                    await index(series: series.map { ArrSeriesEntity(serviceID: service.id.uuidString, series: $0) })
                default:
                    break
                }
            } catch {
                logger.error("Library indexing failed for a service: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Full refresh: services plus the current libraries.
    static func refreshAll() async {
        await indexConfiguredServices()
        await indexLibraries()
    }
}
