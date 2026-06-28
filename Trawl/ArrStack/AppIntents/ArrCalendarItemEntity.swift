import AppIntents
import Foundation

/// A read-only upcoming calendar entry (a movie release or an episode air date),
/// returned by `ShowArrCalendarIntent`.
nonisolated struct ArrCalendarItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Upcoming Release")
    static let defaultQuery = ArrCalendarItemEntityQuery()

    nonisolated struct Payload: Codable, Sendable {
        var serviceName: String
        var title: String           // movie title, or "Series — S01E02 Title"
        var dateISO: String?
    }

    var payload: Payload

    var id: String { (try? ArrIDCodec.encode(payload)) ?? "\(payload.serviceName)|\(payload.title)" }

    var displayRepresentation: DisplayRepresentation {
        var subtitle = payload.serviceName
        if let date = ArrIntentSupport.parseDate(payload.dateISO) {
            subtitle += " · " + date.formatted(date: .abbreviated, time: .omitted)
        }
        return DisplayRepresentation(
            title: "\(payload.title)",
            subtitle: "\(subtitle)"
        )
    }
}

nonisolated struct ArrCalendarItemEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ArrCalendarItemEntity] {
        identifiers.compactMap { identifier in
            guard let payload = try? ArrIDCodec.decode(ArrCalendarItemEntity.Payload.self, from: identifier) else {
                return nil
            }
            return ArrCalendarItemEntity(payload: payload)
        }
    }

    func suggestedEntities() async throws -> [ArrCalendarItemEntity] { [] }
}
