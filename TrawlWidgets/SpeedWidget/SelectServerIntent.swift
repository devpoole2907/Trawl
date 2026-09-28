import AppIntents
import SwiftData
import WidgetKit

// MARK: - App Entity

struct ServerAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = ServerAppEntityQuery()

    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation

    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.displayRepresentation = DisplayRepresentation(
            title: "\(name)"
        )
    }

    /// Every qBittorrent server and every enabled SABnzbd profile, blended.
    static let allClients = ServerAppEntity(
        id: WidgetDownloadClientSelection.allClientsIdentifier,
        name: "All Clients"
    )
}

// MARK: - Entity Query

struct ServerAppEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ServerAppEntity] {
        let all = try await allServers()
        return identifiers.compactMap { identifier in
            if let exact = all.first(where: { $0.id == identifier }) { return exact }
            guard let legacy = all.first(where: { $0.id == "qb:\(identifier)" }) else { return nil }
            return ServerAppEntity(id: identifier, name: legacy.name)
        }
    }

    func suggestedEntities() async throws -> [ServerAppEntity] {
        try await allServers()
    }

    /// New widgets start blended, so torrents and usenet show side by side.
    func defaultResult() async -> ServerAppEntity? {
        .allClients
    }

    private func allServers() async throws -> [ServerAppEntity] {
        let container = try WidgetDataFetcher.makeModelContainer()
        return try await MainActor.run {
            let context = ModelContext(container)
            let torrents = try context.fetch(FetchDescriptor<ServerProfile>()).map {
                (id: "qb:\($0.id.uuidString)", name: "\($0.displayName) · qBittorrent")
            }
            let usenet = try context.fetch(FetchDescriptor<SABnzbdServiceProfile>())
                .filter(\.isEnabled)
                .map {
                    (id: "sab:\($0.id.uuidString)", name: "\($0.displayName) · SABnzbd")
                }
            let clients = (torrents + usenet).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }.map { ServerAppEntity(id: $0.id, name: $0.name) }
            return [.allClients] + clients
        }
    }
}

// MARK: - Configuration Intent

struct SelectServerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Download Client"
    static let description = IntentDescription("Choose All Clients to combine every qBittorrent and SABnzbd download, or pick one client.")

    @Parameter(title: "Client") var server: ServerAppEntity?
}
