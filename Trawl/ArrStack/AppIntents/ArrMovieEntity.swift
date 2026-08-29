import AppIntents
import CoreSpotlight
import Foundation

/// Self-describing payload backing a movie or series entity. Encoded into the entity
/// identifier so the entity survives Shortcuts' cross-process hand-off without a live lookup.
nonisolated struct ArrMediaPayload: Codable, Sendable {
    var serviceID: String
    var tmdbId: Int?
    var tvdbId: Int?
    var libraryId: Int?     // local Radarr/Sonarr id when the item is already in the library
    var title: String
    var titleSlug: String?
    var year: Int?
    var overview: String?
    var monitored: Bool?
    var hasFile: Bool?
}

/// A Radarr movie - either a lookup result from a search or an item already in the library.
///
/// Conforms to `IndexedEntity` so it can be added to the app's Spotlight index and become
/// discoverable by Apple Intelligence / Siri (see `ArrSpotlightIndexer`).
nonisolated struct ArrMovieEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie")
    static let defaultQuery = ArrMovieEntityQuery()

    var payload: ArrMediaPayload

    /// Identifier is the encoded payload, making the entity fully reconstructable.
    var id: String { (try? ArrIDCodec.encode(payload)) ?? payload.title }

    var displayRepresentation: DisplayRepresentation {
        var detail: [String] = []
        if let year = payload.year { detail.append(String(year)) }
        if payload.hasFile == true { detail.append("Downloaded") }
        let subtitle = detail.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(payload.title)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)"
        )
    }

    /// Extra Spotlight metadata layered on top of the title/subtitle/image that the default
    /// implementation already derives from `displayRepresentation`.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = payload.overview
        attributes.keywords = ["movie", "Radarr", payload.title].filter { !$0.isEmpty }
        if let year = payload.year { attributes.comment = "Released \(year)" }
        return attributes
    }
}

extension ArrMovieEntity {
    /// Builds an entity from a Radarr lookup/library result. Lookup results carry a negative
    /// fallback `id`, so only a positive id is treated as a real library id.
    nonisolated init(serviceID: String, movie: RadarrMovie) {
        let libraryId = movie.id > 0 ? movie.id : nil
        self.init(payload: ArrMediaPayload(
            serviceID: serviceID,
            tmdbId: movie.tmdbId,
            tvdbId: nil,
            libraryId: libraryId,
            title: movie.title,
            titleSlug: movie.titleSlug,
            year: movie.year,
            overview: movie.overview,
            monitored: movie.monitored,
            hasFile: movie.hasFile
        ))
    }
}

nonisolated struct ArrMovieEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArrMovieEntity] {
        identifiers.compactMap { identifier in
            guard let payload = try? ArrIDCodec.decode(ArrMediaPayload.self, from: identifier) else {
                return nil
            }
            return ArrMovieEntity(payload: payload)
        }
    }

    /// Search-derived entities aren't suggested up front.
    func suggestedEntities() async throws -> [ArrMovieEntity] { [] }

    /// Resolves a naturally spoken movie title into real Radarr lookup entities. Siri uses this
    /// to fill the entity parameter in one-shot requests such as “Get Shrek 3 in Trawl.”
    func entities(matching string: String) async throws -> [ArrMovieEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let services = try await ArrIntentSupport.loadServices(ofTypes: [.radarr])
        var entities: [ArrMovieEntity] = []
        for service in services {
            do {
                let client = try await ArrIntentSupport.makeRadarrClient(service)
                let results = try await client.lookupMovie(term: query)
                entities.append(contentsOf: results.prefix(10).map {
                    ArrMovieEntity(serviceID: service.id.uuidString, movie: $0)
                })
            } catch {
                guard services.count == 1 else { continue }
                throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
            }
        }
        return entities
    }
}
