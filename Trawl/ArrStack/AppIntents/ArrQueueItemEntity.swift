import AppIntents
import Foundation

/// A read-only snapshot of one Radarr/Sonarr download queue item, returned by `ShowArrQueueIntent`.
nonisolated struct ArrQueueItemEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Queue Item")
    static let defaultQuery = ArrQueueItemEntityQuery()

    nonisolated struct Payload: Codable, Sendable {
        var serviceName: String
        var title: String
        var status: String?
        var progress: String?
        var timeLeft: String?
    }

    var payload: Payload

    var id: String { (try? ArrIDCodec.encode(payload)) ?? "\(payload.serviceName)|\(payload.title)" }

    var displayRepresentation: DisplayRepresentation {
        var detail: [String] = [payload.serviceName]
        if let progress = payload.progress { detail.append(progress) }
        if let status = payload.status { detail.append(status.capitalized) }
        return DisplayRepresentation(
            title: "\(payload.title)",
            subtitle: "\(detail.joined(separator: " · "))"
        )
    }
}

nonisolated struct ArrQueueItemEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ArrQueueItemEntity] {
        identifiers.compactMap { identifier in
            guard let payload = try? ArrIDCodec.decode(ArrQueueItemEntity.Payload.self, from: identifier) else {
                return nil
            }
            return ArrQueueItemEntity(payload: payload)
        }
    }

    func suggestedEntities() async throws -> [ArrQueueItemEntity] { [] }
}
