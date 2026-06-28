import AppIntents
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

/// A Radarr movie — either a lookup result from a search or an item already in the library.
nonisolated struct ArrMovieEntity: AppEntity {
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

nonisolated struct ArrMovieEntityQuery: EntityQuery {
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
}
