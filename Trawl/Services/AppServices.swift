import Foundation
import Observation

@Observable
final class AppServices {
    let authService: AuthService
    let apiClient: QBittorrentAPIClient
    let torrentService: TorrentService
    let syncService: SyncService

    init(authService: AuthService, apiClient: QBittorrentAPIClient, torrentService: TorrentService, syncService: SyncService) {
        self.authService = authService
        self.apiClient = apiClient
        self.torrentService = torrentService
        self.syncService = syncService
    }

    /// Creates a disconnected placeholder for use when no qBittorrent server is configured.
    /// All services exist but are idle — no networking is performed.
    static func disconnected() -> AppServices {
        let authService = AuthService(serverProfileID: UUID())
        let apiClient = QBittorrentAPIClient(baseURL: "http://localhost", authService: authService)
        return AppServices(
            authService: authService,
            apiClient: apiClient,
            torrentService: TorrentService(apiClient: apiClient),
            syncService: SyncService(apiClient: apiClient)
        )
    }

    /// Convenience factory that builds the full service graph from a ServerProfile and Keychain credentials.
    static func build(from server: ServerProfile, username: String, password: String) async throws -> AppServices {
        let authService = AuthService(serverProfileID: server.id, allowsUntrustedTLS: server.allowsUntrustedTLS)
        let apiClient = QBittorrentAPIClient(
            baseURL: server.hostURL,
            authService: authService,
            allowsUntrustedTLS: server.allowsUntrustedTLS
        )

        // Authenticate
        try await apiClient.login(username: username, password: password)

        let torrentService = TorrentService(apiClient: apiClient)
        let syncService = SyncService(apiClient: apiClient)

        // Fetch server default save path (best-effort — don't fail startup if this errors)
        if let prefs = try? await apiClient.getPreferences(), let path = prefs.savePath, !path.isEmpty {
            syncService.defaultSavePath = path
        }

        return AppServices(
            authService: authService,
            apiClient: apiClient,
            torrentService: torrentService,
            syncService: syncService
        )
    }
}
