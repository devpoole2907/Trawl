import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class JellyfinServiceManager {
    private(set) var activeClient: JellyfinAPIClient?
    private(set) var activeProfileID: UUID?
    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var connectionError: String?
    private(set) var cachedUserCount: Int?
    private(set) var cachedSystemInfo: JellyfinSystemInfo?
    private(set) var requiresReauthentication: Bool = false
    private(set) var reauthenticationProfileID: UUID?
    let availability = JellyfinAvailabilityResolver()

    func initialize(from profiles: [JellyfinServiceProfile]) async {
        guard let profile = profiles.first(where: { $0.isEnabled }) ?? profiles.first else {
            disconnect()
            return
        }

        await connectService(profile)
    }

    func connectService(_ profile: JellyfinServiceProfile) async {
        isConnecting = true
        connectionError = nil
        requiresReauthentication = false
        reauthenticationProfileID = nil
        availability.invalidateAll()

        defer { isConnecting = false }

        do {
            guard let token = try await storedAccessToken(for: profile), !token.isEmpty else {
                clearActiveConnection()
                connectionError = missingTokenMessage(for: profile)
                return
            }

            let client = JellyfinAPIClient(
                baseURL: profile.hostURL,
                accessToken: token,
                allowsUntrustedTLS: profile.allowsUntrustedTLS
            )

            let systemInfo: JellyfinSystemInfo
            do {
                systemInfo = try await client.getSystemInfo()
            } catch JellyfinAPIError.unauthorized {
                clearActiveConnection()
                connectionError = expiredAuthorizationMessage(for: profile)
                if profile.authMode == .userPass {
                    requiresReauthentication = true
                    reauthenticationProfileID = profile.id
                }
                return
            }

            activeClient = client
            activeProfileID = profile.id
            isConnected = true
            cachedSystemInfo = systemInfo
            cacheSystemInfo(systemInfo, on: profile)

            await prefetchUserCount(using: client)
        } catch {
            connectionError = error.localizedDescription
            clearActiveConnection()
        }
    }

    func disconnect() {
        availability.invalidateAll()
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        connectionError = nil
        isConnecting = false
        cachedUserCount = nil
        cachedSystemInfo = nil
        requiresReauthentication = false
        reauthenticationProfileID = nil
    }

    func updateCachedUserCount(_ count: Int) {
        cachedUserCount = count
    }

    func updateCachedSystemInfo(_ systemInfo: JellyfinSystemInfo?) {
        cachedSystemInfo = systemInfo
    }

    private func storedAccessToken(for profile: JellyfinServiceProfile) async throws -> String? {
        guard let value = try await KeychainHelper.shared.read(key: profile.accessTokenKey) else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func prefetchUserCount(using client: JellyfinAPIClient) async {
        do {
            let users = try await client.getUsers()
            cachedUserCount = users.count
        } catch {
            // Non-fatal: admin screens will report a detailed loading error on appear.
        }
    }

    private func cacheSystemInfo(_ systemInfo: JellyfinSystemInfo, on profile: JellyfinServiceProfile) {
        if let serverName = systemInfo.serverName, !serverName.isEmpty {
            profile.serverName = serverName
        }
        if let version = systemInfo.version, !version.isEmpty {
            profile.serverVersion = version
        }
    }

    private func clearActiveConnection() {
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        cachedUserCount = nil
        cachedSystemInfo = nil
    }

    private func missingTokenMessage(for profile: JellyfinServiceProfile) -> String {
        switch profile.authMode {
        case .apiKey:
            return "Jellyfin API key not found in Keychain. Add the server again from Settings."
        case .userPass:
            return "Jellyfin session token not found in Keychain. Sign in again from Settings."
        }
    }

    private func expiredAuthorizationMessage(for profile: JellyfinServiceProfile) -> String {
        switch profile.authMode {
        case .apiKey:
            return "Jellyfin API key is no longer valid. Update it in Settings."
        case .userPass:
            return "Jellyfin session expired. Sign in again from Settings."
        }
    }
}

#if DEBUG
extension JellyfinServiceManager {
    enum PreviewState {
        case connected, connecting, error(String), notConfigured, requiresReauthentication
    }

    static func preview(_ state: PreviewState = .connected) -> JellyfinServiceManager {
        let mgr = JellyfinServiceManager()
        switch state {
        case .connected:
            mgr.activeClient = .preview()
            mgr.activeProfileID = UUID()
            mgr.isConnected = true
            mgr.cachedUserCount = 14
            mgr.cachedSystemInfo = JellyfinSystemInfo.preview
        case .connecting:
            mgr.isConnecting = true
        case .error(let msg):
            mgr.connectionError = msg
        case .notConfigured:
            break
        case .requiresReauthentication:
            mgr.connectionError = "Session expired. Please re-enter your password."
            mgr.requiresReauthentication = true
            mgr.reauthenticationProfileID = UUID()
        }
        return mgr
    }
}
#endif
