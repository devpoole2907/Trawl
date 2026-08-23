import Foundation
import SwiftData
import Testing
@testable import Trawl

/// Validation, seeding and persistence tests for `JellyfinSetupViewModel`.
///
/// Network-facing tests drive the real `JellyfinAPIClient` against a loopback
/// `JellyfinFixtureServer`; persistence uses an in-memory SwiftData
/// `ModelContainer` scoped to `JellyfinServiceProfile` only, following
/// `OnboardingViewModelTests`. Keychain writes go to the real Keychain under
/// `jellyfin_<fresh UUID>_token` keys created by this file or by the view model
/// itself, and every test deletes exactly those keys on both paths.
///
/// Deliberately not covered: the Keychain/save rollback branches in `persist`.
/// `@Attribute(.unique)` does not throw against an in-memory store, so a
/// "duplicate insert rolls back" test would silently run the success path and
/// prove nothing, and forcing a genuine `SecItemAdd` failure would mean
/// interfering with the real Keychain. Covering those needs an injectable
/// persistence or Keychain seam.
@Suite("Jellyfin setup view model", .serialized)
@MainActor
struct JellyfinSetupViewModelTests {

    // MARK: - canConnect

    @Test("canConnect requires a host plus the credentials the selected auth mode actually uses", arguments: JellyfinConnectCase.all)
    fileprivate func canConnectTruthTable(_ testCase: JellyfinConnectCase) {
        let viewModel = JellyfinSetupViewModel()
        viewModel.hostURL = testCase.hostURL
        viewModel.authMode = testCase.authMode
        viewModel.username = testCase.username
        viewModel.password = testCase.password
        viewModel.apiKey = testCase.apiKey
        viewModel.isAuthenticating = testCase.isAuthenticating

        #expect(viewModel.canConnect == testCase.expected, "\(testCase.label)")
    }

    // MARK: - seed(from:)

    @Test("seed copies the profile's settings but never rehydrates the secret fields")
    func seedCopiesProfileWithoutSecrets() {
        let profile = Self.makeProfile(hostURL: "http://jf.local:8096", authMode: .userPass)
        profile.displayName = "Basement"
        profile.allowsUntrustedTLS = true

        let viewModel = JellyfinSetupViewModel()
        viewModel.username = "left-over"
        viewModel.password = "left-over"
        viewModel.apiKey = "left-over"
        viewModel.error = "stale error"

        viewModel.seed(from: profile)

        #expect(viewModel.displayName == "Basement")
        #expect(viewModel.hostURL == "http://jf.local:8096")
        #expect(viewModel.authMode == .userPass)
        #expect(viewModel.allowsUntrustedTLS == true)
        #expect(viewModel.username.isEmpty)
        #expect(viewModel.password.isEmpty)
        #expect(viewModel.apiKey.isEmpty)
        #expect(viewModel.error == nil)
    }

    @Test("Re-seeding the same profile does not overwrite edits the user has made since")
    func seedIsIdempotentForTheSameProfile() {
        let profile = Self.makeProfile(hostURL: "http://jf.local:8096", authMode: .apiKey)
        let viewModel = JellyfinSetupViewModel()

        viewModel.seed(from: profile)
        viewModel.hostURL = "http://edited.local:9000"
        viewModel.apiKey = "typed-by-user"
        viewModel.seed(from: profile)

        #expect(viewModel.hostURL == "http://edited.local:9000")
        #expect(viewModel.apiKey == "typed-by-user")
    }

    @Test("Seeding a different profile re-seeds the form and blanks the secrets again")
    func seedRefreshesWhenTheProfileChanges() {
        let first = Self.makeProfile(hostURL: "http://first.local:8096", authMode: .apiKey)
        first.displayName = "First"
        let second = Self.makeProfile(hostURL: "http://second.local:8096", authMode: .userPass)
        second.displayName = "Second"

        let viewModel = JellyfinSetupViewModel()
        viewModel.seed(from: first)
        viewModel.apiKey = "typed-by-user"
        viewModel.seed(from: second)

        #expect(viewModel.displayName == "Second")
        #expect(viewModel.hostURL == "http://second.local:8096")
        #expect(viewModel.authMode == .userPass)
        #expect(viewModel.apiKey.isEmpty)
    }

    @Test("Seeding nil after a profile clears the error and re-arms seeding, but leaves the form's field values in place")
    func seedWithNilLeavesFieldValuesUntouched() {
        let profile = Self.makeProfile(hostURL: "http://jf.local:8096", authMode: .userPass)
        profile.displayName = "Basement"

        let viewModel = JellyfinSetupViewModel()
        viewModel.seed(from: profile)
        viewModel.error = "stale error"

        viewModel.seed(from: nil)

        // Pinning current behaviour: the nil branch returns before resetting the
        // form, so an "add a new server" pass after editing an existing one
        // still shows the previous server's host and display name.
        #expect(viewModel.hostURL == "http://jf.local:8096")
        #expect(viewModel.displayName == "Basement")
        #expect(viewModel.authMode == .userPass)
        #expect(viewModel.error == nil)

        // ...and the profile can be seeded again, because seededProfileID moved to nil.
        viewModel.hostURL = "edited"
        viewModel.seed(from: profile)
        #expect(viewModel.hostURL == "http://jf.local:8096")
    }

    // MARK: - Field validation (no request is ever made)

    @Test("Field validation rejects the form before any request, with an auth-mode specific message", arguments: JellyfinValidationCase.all)
    fileprivate func validationRejectsBeforeAnyRequest(_ testCase: JellyfinValidationCase) async throws {
        let server = try await JellyfinFixtureServer(label: "validation-\(testCase.label)") { _ in
            JellyfinFixtureResponse.json("{}")
        }
        defer { server.stop() }

        let context = try Self.makeInMemoryContext()
        let viewModel = JellyfinSetupViewModel()
        viewModel.hostURL = testCase.usesServerHost ? server.baseURL : testCase.hostURL
        viewModel.authMode = testCase.authMode
        viewModel.username = testCase.username
        viewModel.password = testCase.password
        viewModel.apiKey = testCase.apiKey

        let connected = await viewModel.connect(modelContext: context)

        #expect(connected == false, "\(testCase.label)")
        #expect(viewModel.error == testCase.expectedError, "\(testCase.label)")
        #expect(viewModel.isAuthenticating == false)
        #expect(server.requests.isEmpty, "\(testCase.label) should not have reached the network")
        let profiles = try context.fetch(FetchDescriptor<JellyfinServiceProfile>())
        #expect(profiles.isEmpty)
    }

    @Test("A malformed host URL is rejected by the URL validator before any request")
    func malformedHostURLIsRejectedBeforeAnyRequest() async throws {
        let context = try Self.makeInMemoryContext()
        let viewModel = JellyfinSetupViewModel()
        viewModel.authMode = .apiKey
        viewModel.hostURL = "ftp://jf.local:8096"
        viewModel.apiKey = "abc123"

        let connected = await viewModel.connect(modelContext: context)

        #expect(connected == false)
        #expect(viewModel.error == ServerURLValidationError.unsupportedScheme.localizedDescription)
        let profiles = try context.fetch(FetchDescriptor<JellyfinServiceProfile>())
        #expect(profiles.isEmpty)
    }

    // MARK: - Non-admin rejection

    @Test("A user/password login by a non-administrator is rejected before /System/Info is ever requested")
    func nonAdministratorLoginIsRejected() async throws {
        let server = try await JellyfinFixtureServer(label: "non-admin") { request in
            switch request.path {
            case "/System/Info/Public":
                return .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
            case "/Users/AuthenticateByName":
                return .json(#"{"User":{"Id":"u1","Name":"guest","Policy":{"IsAdministrator":false}},"AccessToken":"guest-token"}"#)
            default:
                return .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
            }
        }
        defer { server.stop() }

        let context = try Self.makeInMemoryContext()
        let viewModel = JellyfinSetupViewModel()
        viewModel.authMode = .userPass
        viewModel.hostURL = server.baseURL
        viewModel.username = "guest"
        viewModel.password = "hunter2"

        let connected = await viewModel.connect(modelContext: context)

        #expect(connected == false)
        #expect(viewModel.error == JellyfinAPIError.notAdmin.localizedDescription)
        #expect(server.requests.map(\.path) == ["/System/Info/Public", "/Users/AuthenticateByName"])
        let profiles = try context.fetch(FetchDescriptor<JellyfinServiceProfile>())
        #expect(profiles.isEmpty)
    }

    @Test("A user/password login with no Policy object at all is treated as non-administrator")
    func loginWithoutPolicyIsRejected() async throws {
        let server = try await JellyfinFixtureServer(label: "no-policy") { request in
            request.path == "/Users/AuthenticateByName"
                ? .json(#"{"User":{"Id":"u1","Name":"guest"},"AccessToken":"guest-token"}"#)
                : .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
        }
        defer { server.stop() }

        let context = try Self.makeInMemoryContext()
        let viewModel = JellyfinSetupViewModel()
        viewModel.authMode = .userPass
        viewModel.hostURL = server.baseURL
        viewModel.username = "guest"
        viewModel.password = "hunter2"

        let connected = await viewModel.connect(modelContext: context)

        #expect(connected == false)
        #expect(viewModel.error == JellyfinAPIError.notAdmin.localizedDescription)
    }

    // MARK: - Persistence

    @Test("An API-key connect against an empty store creates one enabled profile and stores the key in the Keychain")
    func apiKeyConnectCreatesEnabledProfile() async throws {
        let server = try await Self.makeAdminServer(label: "persist-new")
        defer { server.stop() }

        let context = try Self.makeInMemoryContext()
        let viewModel = JellyfinSetupViewModel()
        viewModel.authMode = .apiKey
        viewModel.hostURL = server.baseURL
        viewModel.apiKey = "  abc123  "
        viewModel.displayName = "My Server"
        viewModel.allowsUntrustedTLS = true

        try await Self.cleaningUpKeychain(in: context) {
            let connected = await viewModel.connect(modelContext: context)
            #expect(connected == true)
            #expect(viewModel.error == nil)
            #expect(viewModel.isAuthenticating == false)

            let profiles = try context.fetch(FetchDescriptor<JellyfinServiceProfile>())
            #expect(profiles.count == 1)
            let saved = try #require(profiles.first)
            #expect(saved.isEnabled == true)
            #expect(saved.displayName == "My Server")
            #expect(saved.hostURL == server.baseURL)
            #expect(saved.authMode == .apiKey)
            #expect(saved.userID == nil)
            #expect(saved.allowsUntrustedTLS == true)
            #expect(saved.serverName == "Basement")
            #expect(saved.serverVersion == "10.10.7")

            // The trimmed key is what is stored and what was sent on the wire.
            let stored = try await KeychainHelper.shared.read(key: saved.accessTokenKey)
            #expect(stored == "abc123")
            #expect(server.requests.map(\.path) == ["/System/Info/Public", "/System/Info", "/Users"])
            #expect(server.requests[0].authorization?.contains("Token=") == false)
            #expect(server.requests[1].authorization?.contains(#"Token="abc123""#) == true)
        }
    }

    @Test("A user/password connect stores the returned access token and the Jellyfin user id")
    func userPassConnectStoresAccessTokenAndUserID() async throws {
        let server = try await JellyfinFixtureServer(label: "persist-userpass") { request in
            switch request.path {
            case "/System/Info/Public":
                return .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
            case "/Users/AuthenticateByName":
                return .json(#"{"User":{"Id":"admin-uuid","Name":"sam","Policy":{"IsAdministrator":true}},"AccessToken":"session-token"}"#)
            default:
                return .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
            }
        }
        defer { server.stop() }

        let context = try Self.makeInMemoryContext()
        let viewModel = JellyfinSetupViewModel()
        viewModel.authMode = .userPass
        viewModel.hostURL = server.baseURL
        viewModel.username = "  sam  "
        viewModel.password = "hunter2"
        viewModel.displayName = "Basement"

        try await Self.cleaningUpKeychain(in: context) {
            let connected = await viewModel.connect(modelContext: context)
            #expect(connected == true)

            let profiles = try context.fetch(FetchDescriptor<JellyfinServiceProfile>())
            let saved = try #require(profiles.first)
            #expect(saved.authMode == .userPass)
            #expect(saved.userID == "admin-uuid")
            let stored = try await KeychainHelper.shared.read(key: saved.accessTokenKey)
            #expect(stored == "session-token")

            // The username is trimmed before it is posted; the password is not.
            let login = try #require(server.requests.first(where: { $0.path == "/Users/AuthenticateByName" }))
            let body = try #require(login.jsonDictionary())
            #expect(body["Username"] as? String == "sam")
            #expect(body["Pw"] as? String == "hunter2")
            #expect(server.requests.map(\.path) == ["/System/Info/Public", "/Users/AuthenticateByName", "/System/Info"])
        }
    }

    @Test("Connecting enables the seeded profile and disables every other saved profile")
    func connectingEnablesExactlyOneProfile() async throws {
        let server = try await Self.makeAdminServer(label: "exclusive-enable")
        defer { server.stop() }

        let context = try Self.makeInMemoryContext()
        let target = Self.makeProfile(hostURL: server.baseURL, authMode: .apiKey)
        target.displayName = "Target"
        let other = Self.makeProfile(hostURL: "http://other.local:8096", authMode: .apiKey)
        other.displayName = "Other"
        other.isEnabled = true
        context.insert(target)
        context.insert(other)
        try context.save()

        let viewModel = JellyfinSetupViewModel()
        // Seeding pins which existing profile `persist` will reuse.
        viewModel.seed(from: target)
        viewModel.apiKey = "abc123"
        viewModel.hostURL = server.baseURL

        try await Self.cleaningUpKeychain(in: context) {
            let connected = await viewModel.connect(modelContext: context)
            #expect(connected == true)

            let profiles = try context.fetch(FetchDescriptor<JellyfinServiceProfile>())
            #expect(profiles.count == 2, "No new profile should have been created.")
            let savedTarget = profiles.first(where: { $0.id == target.id })
            let savedOther = profiles.first(where: { $0.id == other.id })
            #expect(savedTarget?.isEnabled == true)
            #expect(savedOther?.isEnabled == false)
            #expect(target.serverName == "Basement")
        }
    }

    @Test("The saved display name falls back from the typed name to system info, then public info, then \"Jellyfin\"", arguments: JellyfinDisplayNameCase.all)
    fileprivate func displayNameFallbackChain(_ testCase: JellyfinDisplayNameCase) async throws {
        let systemInfo = testCase.systemInfoJSON
        let publicInfo = testCase.publicInfoJSON
        let server = try await JellyfinFixtureServer(label: "display-name-\(testCase.label)") { request in
            switch request.path {
            case "/System/Info/Public": return .json(publicInfo)
            case "/System/Info": return .json(systemInfo)
            default: return .json("[]")
            }
        }
        defer { server.stop() }

        let context = try Self.makeInMemoryContext()
        let viewModel = JellyfinSetupViewModel()
        viewModel.authMode = .apiKey
        viewModel.hostURL = server.baseURL
        viewModel.apiKey = "abc123"
        viewModel.displayName = testCase.typedDisplayName

        try await Self.cleaningUpKeychain(in: context) {
            let connected = await viewModel.connect(modelContext: context)
            #expect(connected == true, "\(testCase.label)")

            let savedProfiles = try context.fetch(FetchDescriptor<JellyfinServiceProfile>())
            let saved = try #require(savedProfiles.first)
            #expect(saved.displayName == testCase.expected, "\(testCase.label)")
        }
    }

    // MARK: - Helpers

    private static func makeProfile(hostURL: String, authMode: JellyfinAuthMode) -> JellyfinServiceProfile {
        JellyfinServiceProfile(displayName: "Jellyfin", hostURL: hostURL, authMode: authMode)
    }

    private static func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([JellyfinServiceProfile.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    /// A server that satisfies the whole API-key setup flow: public probe,
    /// authenticated system info, and the admin `/Users` check.
    private static func makeAdminServer(label: String) async throws -> JellyfinFixtureServer {
        try await JellyfinFixtureServer(label: label) { request in
            switch request.path {
            case "/System/Info/Public", "/System/Info":
                return .json(#"{"Id":"srv","ServerName":"Basement","Version":"10.10.7"}"#)
            default:
                return .json(#"[{"Id":"u1","Name":"sam"}]"#)
            }
        }
    }

    /// Runs `body`, then deletes the Keychain token for every profile present in
    /// `context` afterwards, on both the success and failure path. Each key is
    /// `jellyfin_<UUID>_token` for a UUID minted by this file or by the view
    /// model under test, so none can be a real saved credential.
    private static func cleaningUpKeychain(in context: ModelContext, body: () async throws -> Void) async throws {
        do {
            try await body()
            await purgeTokens(in: context)
        } catch {
            await purgeTokens(in: context)
            throw error
        }
    }

    private static func purgeTokens(in context: ModelContext) async {
        let profiles = (try? context.fetch(FetchDescriptor<JellyfinServiceProfile>())) ?? []
        for profile in profiles {
            try? await KeychainHelper.shared.delete(key: profile.accessTokenKey)
        }
    }
}

// MARK: - canConnect cases

private nonisolated struct JellyfinConnectCase: Sendable, CustomStringConvertible {
    let label: String
    var hostURL: String = "http://jf.local:8096"
    var authMode: JellyfinAuthMode = .apiKey
    var username: String = ""
    var password: String = ""
    var apiKey: String = ""
    var isAuthenticating: Bool = false
    let expected: Bool

    var description: String { label }

    static let all: [JellyfinConnectCase] = [
        JellyfinConnectCase(label: "apiKey/complete", apiKey: "abc", expected: true),
        JellyfinConnectCase(label: "apiKey/blank-key", apiKey: "", expected: false),
        JellyfinConnectCase(label: "apiKey/whitespace-key", apiKey: "   \n ", expected: false),
        JellyfinConnectCase(label: "apiKey/whitespace-host", hostURL: "  ", apiKey: "abc", expected: false),
        JellyfinConnectCase(label: "apiKey/empty-host", hostURL: "", apiKey: "abc", expected: false),
        JellyfinConnectCase(
            label: "apiKey/ignores-username-and-password",
            authMode: .apiKey,
            username: "sam",
            password: "hunter2",
            apiKey: "",
            expected: false
        ),
        JellyfinConnectCase(
            label: "apiKey/while-authenticating",
            apiKey: "abc",
            isAuthenticating: true,
            expected: false
        ),
        JellyfinConnectCase(
            label: "userPass/complete",
            authMode: .userPass,
            username: "sam",
            password: "hunter2",
            expected: true
        ),
        JellyfinConnectCase(
            label: "userPass/whitespace-username",
            authMode: .userPass,
            username: "   ",
            password: "hunter2",
            expected: false
        ),
        JellyfinConnectCase(
            label: "userPass/empty-password",
            authMode: .userPass,
            username: "sam",
            password: "",
            expected: false
        ),
        JellyfinConnectCase(
            label: "userPass/whitespace-only-password-is-accepted",
            authMode: .userPass,
            username: "sam",
            // The password is deliberately not trimmed — spaces are legal in a
            // Jellyfin password, so only emptiness disqualifies it.
            password: "   ",
            expected: true
        ),
        JellyfinConnectCase(
            label: "userPass/ignores-api-key",
            authMode: .userPass,
            username: "",
            password: "",
            apiKey: "abc",
            expected: false
        ),
        JellyfinConnectCase(
            label: "userPass/while-authenticating",
            authMode: .userPass,
            username: "sam",
            password: "hunter2",
            isAuthenticating: true,
            expected: false
        )
    ]
}

// MARK: - Validation cases

private nonisolated struct JellyfinValidationCase: Sendable, CustomStringConvertible {
    let label: String
    var hostURL: String = ""
    var usesServerHost: Bool = false
    var authMode: JellyfinAuthMode = .apiKey
    var username: String = ""
    var password: String = ""
    var apiKey: String = ""
    let expectedError: String

    var description: String { label }

    static let all: [JellyfinValidationCase] = [
        JellyfinValidationCase(
            label: "empty-host",
            hostURL: "",
            apiKey: "abc",
            expectedError: "Jellyfin URL is required."
        ),
        JellyfinValidationCase(
            label: "whitespace-host",
            hostURL: "   \n",
            apiKey: "abc",
            expectedError: "Jellyfin URL is required."
        ),
        JellyfinValidationCase(
            label: "apiKey-missing",
            usesServerHost: true,
            authMode: .apiKey,
            apiKey: "   ",
            expectedError: "API key is required."
        ),
        JellyfinValidationCase(
            label: "username-missing",
            usesServerHost: true,
            authMode: .userPass,
            username: "  ",
            password: "hunter2",
            expectedError: "Username and password are required."
        ),
        JellyfinValidationCase(
            label: "password-missing",
            usesServerHost: true,
            authMode: .userPass,
            username: "sam",
            password: "",
            expectedError: "Username and password are required."
        )
    ]
}

// MARK: - Display-name fallback cases

private nonisolated struct JellyfinDisplayNameCase: Sendable, CustomStringConvertible {
    let label: String
    let typedDisplayName: String
    let systemInfoJSON: String
    let publicInfoJSON: String
    let expected: String

    var description: String { label }

    static let all: [JellyfinDisplayNameCase] = [
        JellyfinDisplayNameCase(
            label: "typed-name-wins-and-is-trimmed",
            typedDisplayName: "   Custom Name   ",
            systemInfoJSON: #"{"Id":"srv","ServerName":"SysName","Version":"10.10.7"}"#,
            publicInfoJSON: #"{"Id":"srv","ServerName":"PubName","Version":"10.10.7"}"#,
            expected: "Custom Name"
        ),
        JellyfinDisplayNameCase(
            label: "falls-back-to-system-info-server-name",
            typedDisplayName: "   ",
            systemInfoJSON: #"{"Id":"srv","ServerName":"SysName","Version":"10.10.7"}"#,
            publicInfoJSON: #"{"Id":"srv","ServerName":"PubName","Version":"10.10.7"}"#,
            expected: "SysName"
        ),
        JellyfinDisplayNameCase(
            label: "falls-back-to-public-info-server-name",
            typedDisplayName: "",
            systemInfoJSON: #"{"Id":"srv","Version":"10.10.7"}"#,
            publicInfoJSON: #"{"Id":"srv","ServerName":"PubName","Version":"10.10.7"}"#,
            expected: "PubName"
        ),
        JellyfinDisplayNameCase(
            label: "falls-back-to-literal-jellyfin",
            typedDisplayName: "",
            systemInfoJSON: #"{"Id":"srv","Version":"10.10.7"}"#,
            publicInfoJSON: #"{"Id":"srv","Version":"10.10.7"}"#,
            expected: "Jellyfin"
        )
    ]
}
