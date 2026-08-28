import AppIntents
import Foundation

/// A title Siri should pass through to Trawl's library check.
///
/// Unlike a catalog movie or series, this entity intentionally resolves every non-empty title:
/// an absent title is still a valid library question and must reach the intent so Trawl can say
/// that it is not present.
nonisolated struct ArrLibraryTitleEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Movie or Show")
    static let defaultQuery = ArrLibraryTitleEntityQuery()

    let title: String

    var id: String { title }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

nonisolated struct ArrLibraryTitleEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArrLibraryTitleEntity] {
        identifiers.compactMap(Self.entity(for:))
    }

    func suggestedEntities() async throws -> [ArrLibraryTitleEntity] { [] }

    func entities(matching string: String) async throws -> [ArrLibraryTitleEntity] {
        Self.entity(for: string).map { [$0] } ?? []
    }

    private static func entity(for value: String) -> ArrLibraryTitleEntity? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : ArrLibraryTitleEntity(title: title)
    }
}
