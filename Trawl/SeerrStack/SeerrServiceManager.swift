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
    private(set) var cachedUserCount: Int?

    func initialize(from profiles: [SeerrServiceProfile]) async {
        guard let profile = profiles.first(where: { $0.isEnabled }) ?? profiles.first else {
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
                cachedUserCount = nil
                connectionError = "Session cookie not found in Keychain."
                return
            }

            let client = SeerrAPIClient(baseURL: profile.hostURL, sessionCookie: cookie, allowsUntrustedTLS: profile.allowsUntrustedTLS)
            // Overseerr can issue a refreshed `connect.sid` on any response. Persist
            // updates so the cookie used at next launch is the latest, not the original
            // one captured at sign-in.
            let cookieKey = profile.sessionCookieKey
            await client.setCookieUpdateHandler { updated in
                Task.detached {
                    try? await KeychainHelper.shared.save(key: cookieKey, value: updated)
                }
            }
            _ = try await client.getCurrentUser()

            activeClient = client
            activeProfileID = profile.id
            isConnected = true

            // Eagerly fetch the user count so screens can show their subtitle
            // immediately on navigation, not after a round-trip.
            await prefetchUserCount(using: client)
        } catch {
            connectionError = error.localizedDescription
            activeClient = nil
            activeProfileID = nil
            isConnected = false
            cachedUserCount = nil
        }
    }

    func disconnect() {
        activeClient = nil
        activeProfileID = nil
        isConnected = false
        connectionError = nil
        isConnecting = false
        cachedUserCount = nil
    }

    func updateCachedUserCount(_ count: Int) {
        cachedUserCount = count
    }

    private func prefetchUserCount(using client: SeerrAPIClient) async {
        do {
            let response = try await client.getUsers(take: 1, skip: 0)
            cachedUserCount = response.pageInfo.results ?? response.results.count
        } catch {
            // Non-fatal — the user management screen will load fully on appear.
        }
    }
}
