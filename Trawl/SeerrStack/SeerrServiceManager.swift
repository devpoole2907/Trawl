import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SeerrServiceManager {
    private(set) var activeClient: SeerrAPIClient?
    private(set) var activeProfileID: UUID?
    private(set) var isConnected: Bool = false
    private(set) var isConnecting: Bool = false
    private(set) var connectionError: String?

    func initialize(from profiles: [SeerrServiceProfile]) async {
        guard let profile = profiles.first(where: { $0.isEnabled }) else {
            disconnect()
            return
        }

        await connectService(profile)
    }

    func connectService(_ profile: SeerrServiceProfile) async {
        isConnecting = true
        connectionError = nil
        
        defer { isConnecting = false }

        do {
            guard let cookie = try await KeychainHelper.shared.read(key: profile.sessionCookieKey), !cookie.isEmpty else {
                activeClient = nil
                activeProfileID = nil
                isConnected = false
                connectionError = "Session cookie not found in Keychain."
                return
            }

            let client = SeerrAPIClient(baseURL: profile.hostURL, sessionCookie: cookie, allowsUntrustedTLS: profile.allowsUntrustedTLS)
            _ = try await client.getCurrentUser()

            activeClient = client
            activeProfileID = profile.id
            isConnected = true
        } catch {
            connectionError = error.localizedDescription
            activeClient = nil
            activeProfileID = nil
            isConnected = false
        }
    }

    func disconnect() {
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        connectionError = nil
        isConnecting = false
    }
}
