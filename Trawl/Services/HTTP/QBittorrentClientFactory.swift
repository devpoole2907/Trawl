import Foundation

struct QBittorrentClientFactory {
    static func makeAndLogin(
        baseURL: String,
        serverProfileID: UUID,
        allowsUntrustedTLS: Bool,
        username: String,
        password: String
    ) async throws -> QBittorrentAPIClient {
        let authService = AuthService(serverProfileID: serverProfileID, allowsUntrustedTLS: allowsUntrustedTLS)
        let apiClient = QBittorrentAPIClient(
            baseURL: baseURL,
            authService: authService,
            allowsUntrustedTLS: allowsUntrustedTLS
        )
        try await apiClient.login(username: username, password: password)
        return apiClient
    }
}
