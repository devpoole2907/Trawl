import Foundation
import Network
import SwiftData
import Testing
@testable import Trawl

/// Coverage for `SeerrSetupViewModel.login(modelContext:)` - validation order,
/// admin/cookie rejection, and the exclusive-enable persistence rule. Previously
/// untested.
///
/// `SeerrSetupViewModel.login` builds its own `SeerrAPIClient` internally with no
/// `sessionConfiguration` parameter reaching the caller - the same situation
/// `SeerrServiceManagerTests` documents for `SeerrServiceManager.connectService(_:)`.
/// There is therefore no `URLProtocol` seam to hang off of for the network-reaching
/// paths, so those tests drive the real view model over a real loopback TCP server,
/// following the `ArrClientLifecycleTests.LifecycleArrTestServer` /
/// `OnboardingFakeQBServer` pattern (both `private` to their own files, so this
/// defines its own). The pure-validation paths (empty fields, bad URL) never reach
/// the network and need no server.
///
/// `TrawlTests` runs inside `Trawl.app` against the real Keychain. Every key this
/// suite touches belongs to a `SeerrServiceProfile` with a freshly, randomly
/// generated `UUID`, so none can collide with a real saved credential, and every
/// test deletes exactly the keys it created on both the success and failure paths.
@Suite("Seerr setup view model", .serialized)
@MainActor
struct SeerrSetupViewModelTests {

    // MARK: - Pre-flight validation: no request is ever made

    @Test("login returns false and makes no request when hostURL is empty")
    func loginEmptyHostMakesNoRequest() async throws {
        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = ""
        viewModel.username = "ada"
        viewModel.password = "hunter2"
        let context = try makeInMemoryContext()

        let result = await viewModel.login(modelContext: context)

        #expect(result == false)
        #expect(try context.fetch(FetchDescriptor<SeerrServiceProfile>()).isEmpty)
    }

    @Test("login returns false and makes no request when username is empty")
    func loginEmptyUsernameMakesNoRequest() async throws {
        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = "http://192.0.2.5"
        viewModel.username = ""
        viewModel.password = "hunter2"
        let context = try makeInMemoryContext()

        let result = await viewModel.login(modelContext: context)

        #expect(result == false)
        #expect(try context.fetch(FetchDescriptor<SeerrServiceProfile>()).isEmpty)
    }

    @Test("login returns false and makes no request when password is empty")
    func loginEmptyPasswordMakesNoRequest() async throws {
        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = "http://192.0.2.5"
        viewModel.username = "ada"
        viewModel.password = ""
        let context = try makeInMemoryContext()

        let result = await viewModel.login(modelContext: context)

        #expect(result == false)
        #expect(try context.fetch(FetchDescriptor<SeerrServiceProfile>()).isEmpty)
    }

    @Test("An invalid host URL is rejected by ServerURLValidator before any network call")
    func invalidHostURLIsRejectedBeforeNetworkCall() async throws {
        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = "ftp://example.com"
        viewModel.username = "ada"
        viewModel.password = "hunter2"
        let context = try makeInMemoryContext()

        let result = await viewModel.login(modelContext: context)

        #expect(result == false)
        #expect(viewModel.error == "Server URL must start with http:// or https://.")
        #expect(try context.fetch(FetchDescriptor<SeerrServiceProfile>()).isEmpty)
    }

    // MARK: - Rejected sign-in: nothing is persisted

    @Test("A non-admin user is rejected without persisting a profile")
    func nonAdminUserIsRejected() async throws {
        let server = try await SeerrSetupLoopbackServer(label: "non-admin")
        defer { server.stop() }
        // permissions = 32 (.request) - the admin bit (2) is not set.
        server.route("POST /api/v1/auth/jellyfin", SeerrSetupFakeResponse(
            body: Data(#"{"id":5,"displayName":"Regular User","permissions":32}"#.utf8)
        ))

        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "regular"
        viewModel.password = "pw"
        let context = try makeInMemoryContext()

        let result = await viewModel.login(modelContext: context)

        #expect(result == false)
        #expect(viewModel.error == "You must be a Seerr admin to use Trawl.")
        #expect(try context.fetch(FetchDescriptor<SeerrServiceProfile>()).isEmpty)
        #expect(server.requests == ["POST /api/v1/auth/jellyfin"])
    }

    @Test("A missing session cookie is rejected with the cookie message")
    func missingSessionCookieIsRejected() async throws {
        let server = try await SeerrSetupLoopbackServer(label: "no-cookie")
        defer { server.stop() }
        // permissions = 2 (.admin), but the response carries no Set-Cookie header.
        server.route("POST /api/v1/auth/jellyfin", SeerrSetupFakeResponse(
            body: Data(#"{"id":1,"displayName":"Ada","permissions":2}"#.utf8)
        ))

        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "ada"
        viewModel.password = "hunter2"
        let context = try makeInMemoryContext()

        let result = await viewModel.login(modelContext: context)

        #expect(result == false)
        #expect(viewModel.error == "Session cookie not received from server.")
        #expect(try context.fetch(FetchDescriptor<SeerrServiceProfile>()).isEmpty)
    }

    // MARK: - Successful sign-in

    @Test("A successful login into an empty store creates one enabled profile and stores the session cookie")
    func successfulLoginIntoEmptyStoreCreatesEnabledProfile() async throws {
        let server = try await SeerrSetupLoopbackServer(label: "create")
        defer { server.stop() }
        server.route("POST /api/v1/auth/jellyfin", SeerrSetupFakeResponse(
            body: Data(#"{"id":1,"displayName":"Ada","permissions":2}"#.utf8),
            setCookie: "connect.sid=s%3Anew.session; Path=/; HttpOnly"
        ))

        let context = try makeInMemoryContext()
        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "ada"
        viewModel.password = "hunter2"

        let result = await viewModel.login(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<SeerrServiceProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(result == true)
            #expect(viewModel.error == nil)
            #expect(profiles.count == 1)

            let saved = try #require(profiles.first)
            #expect(saved.isEnabled == true)
            let expectedHostURL = try ServerURLValidator.normalizedURLString(from: server.baseURL)
            #expect(saved.hostURL == expectedHostURL)
            #expect(saved.displayName == "Seerr")

            let storedCookie = try await KeychainHelper.shared.read(key: saved.sessionCookieKey)
            #expect(storedCookie == "s%3Anew.session")
        }
    }

    /// Seerr is modelled as a single instance: `login` resolves the profile to write
    /// as `first(where: \.isEnabled) ?? first`, so signing in against a *different*
    /// Seerr server repoints the existing profile rather than adding a second one.
    /// This pins that behaviour - a second profile appearing here would mean the
    /// single-instance assumption the rest of the Seerr stack relies on had changed.
    @Test("Signing in against a different server repoints the existing profile instead of adding a second")
    func loginRepointsExistingProfileRatherThanAddingOne() async throws {
        let server = try await SeerrSetupLoopbackServer(label: "repoint")
        defer { server.stop() }
        server.route("POST /api/v1/auth/jellyfin", SeerrSetupFakeResponse(
            body: Data(#"{"id":1,"displayName":"Ada","permissions":2}"#.utf8),
            setCookie: "connect.sid=s%3Arepointed; Path=/; HttpOnly"
        ))

        let context = try makeInMemoryContext()
        let existing = SeerrServiceProfile(displayName: "Old Seerr", hostURL: "https://old.seerr.test")
        existing.isEnabled = true
        context.insert(existing)
        try context.save()
        let existingID = existing.id

        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "ada"
        viewModel.password = "hunter2"

        let result = await viewModel.login(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<SeerrServiceProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(result == true)
            #expect(profiles.count == 1)

            let saved = try #require(profiles.first)
            #expect(saved.id == existingID)
            #expect(saved.isEnabled == true)
            let expectedHostURL = try ServerURLValidator.normalizedURLString(from: server.baseURL)
            #expect(saved.hostURL == expectedHostURL)
            // The pre-existing display name is preserved, not reset to "Seerr".
            #expect(saved.displayName == "Old Seerr")

            let storedCookie = try await KeychainHelper.shared.read(key: saved.sessionCookieKey)
            #expect(storedCookie == "s%3Arepointed")
        }
    }

    @Test("Signing in leaves exactly one profile enabled even when the store starts with two enabled")
    func loginEnforcesExactlyOneEnabledProfile() async throws {
        let server = try await SeerrSetupLoopbackServer(label: "exclusive")
        defer { server.stop() }
        server.route("POST /api/v1/auth/jellyfin", SeerrSetupFakeResponse(
            body: Data(#"{"id":1,"displayName":"Ada","permissions":2}"#.utf8),
            setCookie: "connect.sid=s%3Aexclusive; Path=/; HttpOnly"
        ))

        let context = try makeInMemoryContext()
        // A legacy/corrupt store with two enabled profiles: the exclusive-enable
        // loop in `login` must collapse it back to one.
        for name in ["Seerr A", "Seerr B"] {
            let profile = SeerrServiceProfile(displayName: name, hostURL: "https://\(name).test")
            profile.isEnabled = true
            context.insert(profile)
        }
        try context.save()

        let viewModel = SeerrSetupViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "ada"
        viewModel.password = "hunter2"

        let result = await viewModel.login(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<SeerrServiceProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(result == true)
            #expect(profiles.count == 2)
            // Hoisted out of the macro: #require rewrites a `first(where:)` call
            // in its expansion and drops the `try`, which fails to compile.
            let enabledProfiles = profiles.filter(\.isEnabled)
            #expect(enabledProfiles.count == 1)

            let enabled = try #require(enabledProfiles.first)
            let expectedHostURL = try ServerURLValidator.normalizedURLString(from: server.baseURL)
            #expect(enabled.hostURL == expectedHostURL)
        }
    }

    // MARK: - Helpers

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([SeerrServiceProfile.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// Runs `body`, then deletes the Keychain session cookie for every profile in
    /// `profiles` on both the success and failure path - mirrors
    /// `OnboardingViewModelTests.cleaningUpKeychain`.
    private func cleaningUpKeychain(for profiles: [SeerrServiceProfile], body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            for profile in profiles { try? await KeychainHelper.shared.delete(key: profile.sessionCookieKey) }
            throw error
        }
        for profile in profiles { try? await KeychainHelper.shared.delete(key: profile.sessionCookieKey) }
    }
}

// MARK: - Fake response

private nonisolated struct SeerrSetupFakeResponse: Sendable {
    let statusCode: Int
    let reasonPhrase: String
    let body: Data
    let contentType: String
    let setCookie: String?

    init(statusCode: Int = 200, body: Data = Data(), contentType: String = "application/json", setCookie: String? = nil) {
        self.statusCode = statusCode
        self.reasonPhrase = Self.reasonPhrase(for: statusCode)
        self.body = body
        self.contentType = contentType
        self.setCookie = setCookie
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 401: return "Unauthorized"
        default: return "Error"
        }
    }
}

// MARK: - Loopback server

/// A minimal loopback HTTP server standing in for Seerr's Jellyfin-login endpoint.
/// `SeerrSetupViewModel.login` builds its own `SeerrAPIClient` internally with no
/// injectable seam reachable from outside - see this file's top doc comment - so
/// this drives the real view model over real loopback TCP, following the pattern
/// established by `ArrClientLifecycleTests.LifecycleArrTestServer` and
/// `OnboardingViewModelTests.OnboardingFakeQBServer` (both `private` to their own
/// files, and distinct from `SeerrServiceManagerTests.SeerrManagerLoopbackServer`).
private nonisolated final class SeerrSetupLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var routes: [String: SeerrSetupFakeResponse] = [:]
    private var recordedRequests: [String] = []

    init(label: String) async throws {
        self.queue = DispatchQueue(label: "SeerrSetupLoopbackServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.respond(to: connection)
        }
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else { fatalError("Seerr setup loopback server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func route(_ methodAndPath: String, _ response: SeerrSetupFakeResponse) {
        lock.lock()
        defer { lock.unlock() }
        routes[methodAndPath] = response
    }

    func stop() { listener.cancel() }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let key = Self.requestKey(from: data)

            self.lock.lock()
            self.recordedRequests.append(key)
            let response = self.routes[key] ?? SeerrSetupFakeResponse(statusCode: 404, body: Data())
            self.lock.unlock()

            connection.send(
                content: Self.httpResponse(response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func requestKey(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return ""
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")
        return "\(method) \(path)"
    }

    private static func httpResponse(_ response: SeerrSetupFakeResponse) -> Data {
        var head = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        if let setCookie = response.setCookie {
            head += "Set-Cookie: \(setCookie)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}
