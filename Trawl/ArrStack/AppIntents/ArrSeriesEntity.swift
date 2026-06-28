import AppIntents
import CoreSpotlight
import Foundation

/// A Sonarr series — either a lookup result from a search or an item already in the library.
/// Shares `ArrMediaPayload` with `ArrMovieEntity`. Conforms to `IndexedEntity` for Spotlight /
/// Apple Intelligence discovery (see `ArrSpotlightIndexer`).
nonisolated struct ArrSeriesEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "TV Series")
    static let defaultQuery = ArrSeriesEntityQuery()

    var payload: ArrMediaPayload

    var id: String { (try? ArrIDCodec.encode(payload)) ?? payload.title }

    var displayRepresentation: DisplayRepresentation {
        var detail: [String] = []
        if let year = payload.year { detail.append(String(year)) }
        let subtitle = detail.joined(separator: " · ")
        return DisplayRepresentation(
            title: "\(payload.title)",
            subtitle: subtitle.isEmpty ? nil : "\(subtitle)"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = payload.overview
        attributes.keywords = ["tv", "series", "Sonarr", payload.title].filter { !$0.isEmpty }
        if let year = payload.year { attributes.comment = "First aired \(year)" }
        return attributes
    }
}

extension ArrSeriesEntity {
    nonisolated init(serviceID: String, series: SonarrSeries) {
        let libraryId = series.id > 0 ? series.id : nil
        self.init(payload: ArrMediaPayload(
            serviceID: serviceID,
            tmdbId: nil,
            tvdbId: series.tvdbId,
            libraryId: libraryId,
            title: series.title,
            titleSlug: series.titleSlug,
            year: series.year,
            overview: series.overview,
            monitored: series.monitored,
            hasFile: nil
        ))
    }
}

nonisolated struct ArrSeriesEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ArrSeriesEntity] {
        identifiers.compactMap { identifier in
            guard let payload = try? ArrIDCodec.decode(ArrMediaPayload.self, from: identifier) else {
                return nil
            }
            return ArrSeriesEntity(payload: payload)
        }
    }

    func suggestedEntities() async throws -> [ArrSeriesEntity] { [] }
}
