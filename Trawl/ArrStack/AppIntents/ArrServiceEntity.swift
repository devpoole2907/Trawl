import AppIntents
import CoreSpotlight
import Foundation

/// A configured Radarr / Sonarr / Prowlarr service the user can pick in an intent.
///
/// One shared entity type is used for all *arr services; each intent validates the chosen
/// service against the types it supports via `ArrIntentSupport.resolveService`.
///
/// Conforms to `IndexedEntity` so configured services are added to the Spotlight index and
/// become discoverable by Apple Intelligence / Siri (see `ArrSpotlightIndexer`).
// TODO (post-v1): split into per-type entities so parameter suggestions only show the
// relevant service kind, and adopt Apple Intelligence assistant schemas if/when a
// media-management domain becomes available (none exists today).
nonisolated struct ArrServiceEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "arr Service")
    static let defaultQuery = ArrServiceEntityQuery()

    var id: String          // ArrServiceProfile UUID string
    var name: String
    var serviceType: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(serviceType.capitalized)"
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.contentDescription = "\(serviceType.capitalized) service"
        attributes.keywords = [serviceType, "Trawl", name].filter { !$0.isEmpty }
        return attributes
    }
}

extension ArrServiceEntity {
    nonisolated init(snapshot: ArrServiceSnapshot) {
        self.init(
            id: snapshot.id.uuidString,
            name: snapshot.displayName,
            serviceType: snapshot.serviceType.rawValue
        )
    }
}

nonisolated struct ArrServiceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ArrServiceEntity] {
        let services = try await ArrIntentSupport.loadServices(ofTypes: Set(ArrServiceType.allCases))
        return services
            .filter { identifiers.contains($0.id.uuidString) }
            .map(ArrServiceEntity.init(snapshot:))
    }

    func suggestedEntities() async throws -> [ArrServiceEntity] {
        let services = try await ArrIntentSupport.loadServices(ofTypes: [.radarr, .sonarr, .prowlarr])
        return services.map(ArrServiceEntity.init(snapshot:))
    }
}

/// Scope selector for cross-service read intents (queue, calendar, status).
nonisolated enum ArrServiceScope: String, AppEnum {
    case all
    case radarr
    case sonarr

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Service")
    static let caseDisplayRepresentations: [ArrServiceScope: DisplayRepresentation] = [
        .all: "Radarr & Sonarr",
        .radarr: "Radarr",
        .sonarr: "Sonarr"
    ]

    var serviceTypes: Set<ArrServiceType> {
        switch self {
        case .all: [.radarr, .sonarr]
        case .radarr: [.radarr]
        case .sonarr: [.sonarr]
        }
    }
}

/// Media kind selector for the "search for an existing item" intent.
nonisolated enum ArrMediaKind: String, AppEnum {
    case movie
    case series

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media Type")
    static let caseDisplayRepresentations: [ArrMediaKind: DisplayRepresentation] = [
        .movie: "Movie",
        .series: "TV Series"
    ]
}
