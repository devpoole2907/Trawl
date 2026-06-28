import AppIntents
import Foundation

/// Shows the current Radarr/Sonarr download queue: a total count plus the top few items
/// with title, progress and status. Read-only.
struct ShowArrQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Download Queue"
    static let description = IntentDescription(
        "Show what Radarr and Sonarr are currently downloading.",
        categoryName: "Status"
    )

    @Parameter(title: "Service", default: .all)
    var scope: ArrServiceScope

    static var parameterSummary: some ParameterSummary {
        Summary("Show the \(\.$scope) download queue")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ArrQueueItemEntity]> & ProvidesDialog {
        let services = try await ArrIntentSupport.loadServices(ofTypes: scope.serviceTypes)
        guard !services.isEmpty else {
            throw ArrIntentError.noServiceConfigured(ArrIntentSupport.serviceTypeDescription(for: scope.serviceTypes))
        }

        var entities: [ArrQueueItemEntity] = []
        for service in services {
            let records = await queueRecords(for: service)
            for item in records {
                entities.append(ArrQueueItemEntity(payload: .init(
                    serviceName: service.displayName,
                    title: item.title ?? "Unknown",
                    status: item.status,
                    progress: ArrIntentSupport.progressText(size: item.size, sizeleft: item.sizeleft),
                    timeLeft: item.timeleft
                )))
            }
        }

        guard !entities.isEmpty else {
            return .result(value: [], dialog: "Nothing is downloading right now.")
        }

        let top = entities.prefix(3).map { entity -> String in
            var parts = [entity.payload.title]
            if let progress = entity.payload.progress { parts.append("at \(progress)") }
            return parts.joined(separator: " ")
        }
        let summary = "\(entities.count) item\(entities.count == 1 ? "" : "s") downloading. Top: \(top.joined(separator: "; "))."
        return .result(value: entities, dialog: IntentDialog(stringLiteral: summary))
    }

    /// Fetches the queue for one service, returning an empty list on failure so one offline
    /// service never breaks the whole summary.
    private func queueRecords(for service: ArrServiceSnapshot) async -> [ArrQueueItem] {
        do {
            switch service.serviceType {
            case .radarr:
                let client = try await ArrIntentSupport.makeRadarrClient(service)
                return try await client.getQueue(pageSize: 50).records ?? []
            case .sonarr:
                let client = try await ArrIntentSupport.makeSonarrClient(service)
                return try await client.getQueue(pageSize: 50).records ?? []
            default:
                return []
            }
        } catch {
            return []
        }
    }
}
