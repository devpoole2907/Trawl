import Foundation
import Testing
@testable import Trawl

/// Connection-lifecycle tests for `JellyfinServiceManager`.
///
/// These run against the real `KeychainHelper` (`TrawlTests` is hosted inside
/// `Trawl.app`, so it has the app's entitlements) and a real
/// `JellyfinAPIClient` talking to a loopback `JellyfinFixtureServer`. The only
/// fake is the remote server.
///
/// Every Keychain key used here is `JellyfinServiceProfile.accessTokenKey`,
/// which is derived from a freshly generated `UUID`, so it cannot collide with
/// a real saved credential. `withStoredToken` deletes what it wrote on both the
/// success and failure path.
@Suite("Jellyfin service manager connection lifecycle", .serialized)
@MainActor
struct JellyfinServiceManagerTests {

    // MARK: - Missing credentials

    @Test("A profile with no Keychain token reports the API-key message and never opens a connection")
    func missingTokenForAPIKeyProfile() async throws {
        let profile = Self.makeProfile(authMode: .apiKey, hostURL: "http://127.0.0.1:1")
        let manager = JellyfinServiceManager()

        await manager.connectService(profile)

        #expect(manager.connectionError == "Jellyfin API key not found in Keychain. Add the server again from Settings.")
        #expect(manager.isConnected == false)
        #expect(manager.activeClient == nil)
        #expect(manager.activeProfileID == nil)
        #expect(manager.isConnecting == false)
        #expect(manager.requiresReauthentication == false)
    }

    @Test("A user/password profile with no Keychain token reports the session-token message instead")
    func missingTokenForUserPassProfile() async throws {
        let profile = Self.makeProfile(authMode: .userPass, hostURL: "http://127.0.0.1:1")
        let manager = JellyfinServiceManager()

        await manager.connectService(profile)

        #expect(manager.connectionError == "Jellyfin session token not found in Keychain. Sign in again from Settings.")
        #expect(manager.isConnected == false)
        #expect(manager.activeClient == nil)
    }

    @Test("A whitespace-only stored token is treated as missing, not sent as a credential")
    func blankStoredTokenIsTreatedAsMissing() async throws {
        let profile = Self.makeProfile(authMode: .apiKey, hostURL: "http://127.0.0.1:1")
        try await Self.withStoredToken("   \n\t  ", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)

            #expect(manager.connectionError == "Jellyfin API key not found in Keychain. Add the server again from Settings.")
            #expect(manager.isConnected == false)
        }
    }

    // MARK: - Expired authorization

    @Test(
        "A 401/403 from /System/Info never asks an API-key profile to re-authenticate",
        arguments: [401, 403]
    )
    func unauthorizedAPIKeyProfileDoesNotRequestReauthentication(_ status: Int) async throws {
        let server = try await JellyfinFixtureServer(label: "unauthorized-apikey-\(status)") { _ in
            JellyfinFixtureResponse.json(#"{"Message":"Invalid token."}"#, status: status)
        }
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        try await Self.withStoredToken("stale-api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)

            #expect(manager.connectionError == "Jellyfin API key is no longer valid. Update it in Settings.")
            #expect(manager.requiresReauthentication == false)
            #expect(manager.reauthenticationProfileID == nil)
            #expect(manager.isConnected == false)
            #expect(manager.activeClient == nil)
        }

        #expect(server.requests.map(\.path) == ["/System/Info"])
    }

    @Test(
        "A 401/403 from /System/Info flags a user/password profile for re-authentication, tagged with its own id",
        arguments: [401, 403]
    )
    func unauthorizedUserPassProfileRequestsReauthentication(_ status: Int) async throws {
        let server = try await JellyfinFixtureServer(label: "unauthorized-userpass-\(status)") { _ in
            JellyfinFixtureResponse.json(#"{"Message":"Invalid token."}"#, status: status)
        }
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .userPass, hostURL: server.baseURL)
        try await Self.withStoredToken("expired-session", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)

            #expect(manager.connectionError == "Jellyfin session expired. Sign in again from Settings.")
            #expect(manager.requiresReauthentication == true)
            #expect(manager.reauthenticationProfileID == profile.id)
            #expect(manager.isConnected == false)
            #expect(manager.activeClient == nil)
        }
    }

    @Test("An unreachable host surfaces the transport error and leaves no active connection")
    func unreachableHostSurfacesTransportError() async throws {
        let profile = Self.makeProfile(authMode: .apiKey, hostURL: "http://127.0.0.1:1")
        try await Self.withStoredToken("api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)

            #expect(manager.isConnected == false)
            #expect(manager.activeClient == nil)
            #expect(manager.connectionError?.hasPrefix("Couldn't reach Jellyfin:") == true)
        }
    }

    // MARK: - Successful connection

    @Test("A successful connect caches system info on the profile, marks the connection live, and prefetches the user count")
    func successfulConnectCachesServerIdentityAndUserCount() async throws {
        let server = try await JellyfinFixtureServer(label: "connect-success") { request in
            switch request.path {
            case "/System/Info":
                return .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7","OperatingSystem":"Linux"}"#)
            case "/Users":
                return .json(#"[{"Id":"u1","Name":"sam"},{"Id":"u2","Name":"kim"},{"Id":"u3","Name":"lee"}]"#)
            default:
                return .json(#"{}"#, status: 404)
            }
        }
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        try await Self.withStoredToken("good-api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)

            #expect(manager.isConnected == true)
            #expect(manager.isConnecting == false)
            #expect(manager.connectionError == nil)
            #expect(manager.activeProfileID == profile.id)
            #expect(manager.activeClient != nil)
            #expect(manager.cachedSystemInfo?.serverName == "Basement")
            #expect(manager.cachedSystemInfo?.version == "10.10.7")
            #expect(manager.cachedUserCount == 3)
            // The identity is written back onto the passed profile object.
            #expect(profile.serverName == "Basement")
            #expect(profile.serverVersion == "10.10.7")
        }

        #expect(server.requests.map(\.path) == ["/System/Info", "/Users"])
        // The stored token really was used to authenticate both calls.
        #expect(server.requests.allSatisfy { $0.authorization?.contains(#"Token="good-api-key""#) == true })
    }

    @Test("An empty ServerName or Version from the server does not blank the profile's cached identity")
    func blankServerIdentityDoesNotOverwriteCachedValues() async throws {
        let server = try await JellyfinFixtureServer(label: "connect-blank-identity") { request in
            request.path == "/System/Info"
                ? .json(#"{"Id":"srv","ServerName":"","Version":""}"#)
                : .json("[]")
        }
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        profile.serverName = "Previously Known"
        profile.serverVersion = "10.9.0"

        try await Self.withStoredToken("good-api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)

            #expect(manager.isConnected == true)
            #expect(profile.serverName == "Previously Known")
            #expect(profile.serverVersion == "10.9.0")
        }
    }

    @Test("A failing /Users prefetch is non-fatal: the connection stays live and the cached count stays nil")
    func failingUserPrefetchIsNonFatal() async throws {
        let server = try await JellyfinFixtureServer(label: "connect-users-fail") { request in
            request.path == "/System/Info"
                ? .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
                : .json(#"{"Message":"Nope."}"#, status: 500)
        }
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        try await Self.withStoredToken("good-api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)

            #expect(manager.isConnected == true)
            #expect(manager.connectionError == nil)
            #expect(manager.cachedUserCount == nil)
            #expect(manager.cachedSystemInfo?.serverName == "Basement")
        }

        #expect(server.requests.map(\.path) == ["/System/Info", "/Users"])
    }

    // MARK: - Availability invalidation on reconnect

    @Test("Reconnecting drops the availability cache, so a previously resolved key goes back to idle")
    func reconnectInvalidatesResolvedAvailability() async throws {
        let server = try await JellyfinFixtureServer(label: "reconnect-invalidates") { request in
            switch request.path {
            case "/System/Info":
                return .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
            case "/Users":
                return .json(#"[{"Id":"u1","Name":"sam"}]"#)
            default:
                return .json(#"{"Items":[{"Id":"cached","Name":"Cached","Type":"Movie","ProviderIds":{"Tmdb":"12"}}],"TotalRecordCount":1}"#)
            }
        }
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        try await Self.withStoredToken("good-api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)
            let client = try #require(manager.activeClient)

            let media = JellyfinMediaAvailabilityCard.Media.movie(title: "Cached", year: nil, tmdbId: 12, imdbId: nil)
            let key = JellyfinAvailabilityResolver.Key(profileID: profile.id, mediaTaskKey: media.taskKey)

            manager.availability.ensureLoaded(key, media: media, client: client)
            await server.waitForServedResponses(3)
            let items = try await jellyfinSettledItems(manager.availability, key: key)
            #expect(items.map(\.id) == ["cached"])

            await manager.connectService(profile)

            if case .idle = manager.availability.state(for: key) {} else {
                Issue.record("Expected the availability cache to be dropped on reconnect.")
            }
        }
    }

    // MARK: - initialize(from:)

    @Test("initialize picks the enabled profile, not merely the first one in the list")
    func initializePicksEnabledProfile() async throws {
        let server = try await Self.makeHappyServer(label: "initialize-enabled")
        defer { server.stop() }

        let disabled = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        disabled.isEnabled = false
        let enabled = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        enabled.isEnabled = true

        try await Self.withStoredToken("token-a", for: disabled) {
            try await Self.withStoredToken("token-b", for: enabled) {
                let manager = JellyfinServiceManager()
                await manager.initialize(from: [disabled, enabled])

                #expect(manager.activeProfileID == enabled.id)
                #expect(manager.isConnected == true)
            }
        }

        #expect(server.requests.first?.authorization?.contains(#"Token="token-b""#) == true)
    }

    @Test("initialize falls back to the first profile when none is enabled")
    func initializeFallsBackToFirstProfile() async throws {
        let server = try await Self.makeHappyServer(label: "initialize-fallback")
        defer { server.stop() }

        let first = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        first.isEnabled = false
        let second = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        second.isEnabled = false

        try await Self.withStoredToken("token-a", for: first) {
            try await Self.withStoredToken("token-b", for: second) {
                let manager = JellyfinServiceManager()
                await manager.initialize(from: [first, second])

                #expect(manager.activeProfileID == first.id)
                #expect(manager.isConnected == true)
            }
        }
    }

    @Test("initialize with an empty profile list disconnects an existing connection")
    func initializeWithNoProfilesDisconnects() async throws {
        let server = try await Self.makeHappyServer(label: "initialize-empty")
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        try await Self.withStoredToken("good-api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)
            #expect(manager.isConnected == true)

            await manager.initialize(from: [])

            #expect(manager.isConnected == false)
            #expect(manager.activeClient == nil)
            #expect(manager.activeProfileID == nil)
            #expect(manager.cachedSystemInfo == nil)
            #expect(manager.cachedUserCount == nil)
        }
    }

    // MARK: - disconnect

    @Test("disconnect clears every published property, including a pending re-authentication flag")
    func disconnectClearsEveryPublishedProperty() async throws {
        let server = try await Self.makeHappyServer(label: "disconnect")
        defer { server.stop() }

        let profile = Self.makeProfile(authMode: .apiKey, hostURL: server.baseURL)
        try await Self.withStoredToken("good-api-key", for: profile) {
            let manager = JellyfinServiceManager()
            await manager.connectService(profile)
            manager.updateCachedUserCount(9)
            #expect(manager.isConnected == true)

            manager.disconnect()

            #expect(manager.activeClient == nil)
            #expect(manager.activeProfileID == nil)
            #expect(manager.isConnected == false)
            #expect(manager.isConnecting == false)
            #expect(manager.connectionError == nil)
            #expect(manager.cachedUserCount == nil)
            #expect(manager.cachedSystemInfo == nil)
            #expect(manager.requiresReauthentication == false)
            #expect(manager.reauthenticationProfileID == nil)
        }
    }

    @Test("A second connect attempt clears the re-authentication flag left by the first")
    func reconnectClearsStaleReauthenticationFlag() async throws {
        let unauthorized = try await JellyfinFixtureServer(label: "reauth-then-ok-401") { _ in
            JellyfinFixtureResponse.json(#"{"Message":"Invalid token."}"#, status: 401)
        }
        defer { unauthorized.stop() }
        let healthy = try await Self.makeHappyServer(label: "reauth-then-ok-200")
        defer { healthy.stop() }

        let failing = Self.makeProfile(authMode: .userPass, hostURL: unauthorized.baseURL)
        let working = Self.makeProfile(authMode: .userPass, hostURL: healthy.baseURL)

        try await Self.withStoredToken("expired", for: failing) {
            try await Self.withStoredToken("fresh", for: working) {
                let manager = JellyfinServiceManager()
                await manager.connectService(failing)
                #expect(manager.requiresReauthentication == true)

                await manager.connectService(working)

                #expect(manager.requiresReauthentication == false)
                #expect(manager.reauthenticationProfileID == nil)
                #expect(manager.isConnected == true)
                #expect(manager.activeProfileID == working.id)
            }
        }
    }

    // MARK: - Helpers

    private static func makeProfile(authMode: JellyfinAuthMode, hostURL: String) -> JellyfinServiceProfile {
        JellyfinServiceProfile(
            displayName: "Test Jellyfin",
            hostURL: hostURL,
            authMode: authMode
        )
    }

    private static func makeHappyServer(label: String) async throws -> JellyfinFixtureServer {
        try await JellyfinFixtureServer(label: label) { request in
            request.path == "/System/Info"
                ? .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
                : .json(#"[{"Id":"u1","Name":"sam"}]"#)
        }
    }

    /// Writes `token` under the profile's real Keychain key for the duration of
    /// `body`, then deletes it on both the success and failure path. The key is
    /// `jellyfin_<fresh UUID>_token`, so it can never collide with a real
    /// credential.
    private static func withStoredToken(
        _ token: String,
        for profile: JellyfinServiceProfile,
        body: () async throws -> Void
    ) async throws {
        try await KeychainHelper.shared.save(key: profile.accessTokenKey, value: token)
        do {
            try await body()
            try? await KeychainHelper.shared.delete(key: profile.accessTokenKey)
        } catch {
            try? await KeychainHelper.shared.delete(key: profile.accessTokenKey)
            throw error
        }
    }
}
