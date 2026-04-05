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

    /// Convenience factory that builds the full service graph from a ServerProfile and Keychain credentials.
    static func build(from server: ServerProfile, username: String, password: String) async throws -> AppServices {
        let authService = AuthService(serverProfileID: server.id)
        let apiClient = QBittorrentAPIClient(baseURL: server.hostURL, authService: authService)

        // Authenticate
        try await apiClient.login(username: username, password: password)

        let torrentService = TorrentService(apiClient: apiClient)
        let syncService = SyncService(apiClient: apiClient)

        return AppServices(
            authService: authService,
            apiClient: apiClient,
            torrentService: torrentService,
            syncService: syncService
        )
    }
}
