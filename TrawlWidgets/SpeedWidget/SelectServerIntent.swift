import AppIntents
import SwiftData
import WidgetKit

// MARK: - App Entity

struct ServerAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static var defaultQuery = ServerAppEntityQuery()

    var id: String
    var displayRepresentation: DisplayRepresentation

    init(id: String, name: String) {
        self.id = id
        self.displayRepresentation = DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name)
        )
    }
}

// MARK: - Entity Query

struct ServerAppEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ServerAppEntity] {
        let all = try await allServers()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ServerAppEntity] {
        try await allServers()
    }

    private func allServers() async throws -> [ServerAppEntity] {
        let container = try WidgetDataFetcher.makeModelContainer()
        return try await MainActor.run {
            let context = ModelContext(container)
            let servers = try context.fetch(FetchDescriptor<ServerProfile>())
            return servers.map { ServerAppEntity(id: $0.id.uuidString, name: $0.displayName) }
        }
    }
}

// MARK: - Configuration Intent

struct SelectServerIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "qBittorrent Server"
    static var description = IntentDescription("Choose which server's speeds to display.")

    @Parameter(title: "Server") var server: ServerAppEntity?
}
