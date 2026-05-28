import AppIntents
import SwiftData
import WidgetKit

// MARK: - App Entity

struct SeerrServerAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Seerr Server")
    static let defaultQuery = SeerrServerAppEntityQuery()

    var id: String
    var displayRepresentation: DisplayRepresentation

    init(id: String, name: String) {
        self.id = id
        self.displayRepresentation = DisplayRepresentation(title: "\(name)")
    }
}

// MARK: - Entity Query

struct SeerrServerAppEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SeerrServerAppEntity] {
        let all = try await allServers()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SeerrServerAppEntity] {
        try await allServers()
    }

    private func allServers() async throws -> [SeerrServerAppEntity] {
        let container = try WidgetDataFetcher.makeModelContainer()
        return try await MainActor.run {
            let context = ModelContext(container)
            let profiles = try context.fetch(FetchDescriptor<SeerrServiceProfile>())
            return profiles.map { SeerrServerAppEntity(id: $0.id.uuidString, name: $0.displayName) }
        }
    }
}

// MARK: - Configuration Intent

struct SelectSeerrServerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Seerr Server"
    static let description = IntentDescription("Choose one Seerr server, or leave blank to include all enabled servers.")

    @Parameter(title: "Server") var server: SeerrServerAppEntity?
}
