import Foundation
import Observation

@MainActor
@Observable
final class CleanuparrServiceManager {
    private(set) var activeClient: CleanuparrAPIClient?
    private(set) var activeProfileID: UUID?
    private(set) var stats: CleanuparrStats?
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isRefreshing = false
    private(set) var isReady: Bool?
    private(set) var connectionError: String?

    func initialize(from profiles: [CleanuparrServiceProfile]) async {
        guard let profile = profiles.first(where: { $0.isEnabled }) ?? profiles.first else {
            disconnect()
            return
        }
        await connectService(profile)
    }

    func connectService(_ profile: CleanuparrServiceProfile) async {
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        do {
            guard let apiKey = try await storedAPIKey(for: profile) else {
                clearConnection()
                connectionError = "Cleanuparr API key not found in Keychain. Add the server again from Settings."
                return
            }

            let client = CleanuparrAPIClient(
                baseURL: profile.hostURL,
                apiKey: apiKey,
                allowsUntrustedTLS: profile.allowsUntrustedTLS
            )
            let fetchedStats = try await client.getStats()
            let readiness = try? await client.isReady()

            activeClient = client
            activeProfileID = profile.id
            stats = fetchedStats
            isReady = readiness
            isConnected = true
            profile.lastSynced = .now
        } catch {
            clearConnection()
            connectionError = error.localizedDescription
        }
    }

    func refresh(hours: Int = 168, includeDryRun: Bool = false) async {
        guard let client = activeClient else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let fetchedStats = client.getStats(hours: hours, includeDryRun: includeDryRun)
            async let readiness = client.isReady()
            stats = try await fetchedStats
            isReady = try await readiness
            connectionError = nil
            isConnected = true
        } catch {
            connectionError = error.localizedDescription
            isConnected = false
        }
    }

    func disconnect() {
        clearConnection()
        connectionError = nil
        isConnecting = false
        isRefreshing = false
    }

    private func storedAPIKey(for profile: CleanuparrServiceProfile) async throws -> String? {
        guard let value = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clearConnection() {
        activeClient = nil
        activeProfileID = nil
        stats = nil
        isConnected = false
        isReady = nil
    }
}
