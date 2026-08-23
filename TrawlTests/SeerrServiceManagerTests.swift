import Foundation
import Network
import Testing
@testable import Trawl

/// Coverage for `SeerrServiceManager` — connect/disconnect lifecycle, the pending
/// requests cache, and approve/decline. Previously untested.
///
/// `SeerrServiceManager.connectService(_:)` and the login path in
/// `SeerrSetupViewModel` both build their own internal `SeerrAPIClient` with no
/// `sessionConfiguration` parameter reaching the caller — unlike `SeerrAPIClient`
/// itself, which accepts one (see `SeerrContractTests`). There is therefore no
/// `URLProtocol` seam to hang off of here, exactly as `OnboardingViewModelTests`
/// documents for the analogous `OnboardingViewModel` case. These tests instead drive
/// the real manager over a real loopback TCP server, following the
/// `ArrClientLifecycleTests.LifecycleArrTestServer` / `OnboardingFakeQBServer`
/// pattern (both are `private` to their own files, so this defines its own).
///
/// `TrawlTests` runs inside `Trawl.app` against the real Keychain. Every key this
/// suite touches belongs to a `SeerrServiceProfile` with a freshly, randomly
/// generated `UUID`, so none can collide with a real saved credential, and every
/// test deletes exactly the keys it created on both the success and failure paths.
@Suite("Seerr service manager", .serialized)
@MainActor
struct SeerrServiceManagerTests {

    // MARK: - Missing / blank session cookie

    @Test("A missing Keychain session cookie sets connectionError and leaves the manager disconnected")
    func missingSessionCookieFailsToConnect() async throws {
        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: "https://seerr.invalid.test")
        let manager = SeerrServiceManager()

        await manager.connectService(profile)

        #expect(manager.isConnected == false)
        #expect(manager.activeClient == nil)
        #expect(manager.activeProfileID == nil)
        #expect(manager.connectionError == "Session cookie not found in Keychain.")
    }

    @Test("A blank Keychain session cookie sets connectionError and leaves the manager disconnected")
    func blankSessionCookieFailsToConnect() async throws {
        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: "https://seerr.invalid.test")
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "") {
            await manager.connectService(profile)

            #expect(manager.isConnected == false)
            #expect(manager.connectionError == "Session cookie not found in Keychain.")
        }
    }

    // MARK: - Successful connect

    @Test("A successful connect sets isConnected, activeProfileID, and prefetches the user count")
    func successfulConnectSetsStateAndPrefetchesUserCount() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "connect-success")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(body: Data(#"{"id":1,"displayName":"Ada"}"#.utf8)))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":1,"results":8,"page":1},"results":[{"id":1}]}"#.utf8)
        ))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "test-session") {
            await manager.connectService(profile)

            #expect(manager.isConnected == true)
            #expect(manager.activeProfileID == profile.id)
            #expect(manager.activeClient != nil)
            #expect(manager.cachedUserCount == 8)
            #expect(manager.connectionError == nil)
            #expect(server.requests.contains("GET /api/v1/auth/me"))
            #expect(server.requests.contains("GET /api/v1/user"))
        }
    }

    @Test("A failing user-count prefetch is non-fatal and leaves the manager connected")
    func failingPrefetchIsNonFatal() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "prefetch-fails")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(body: Data(#"{"id":1}"#.utf8)))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8)))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "test-session") {
            await manager.connectService(profile)

            #expect(manager.isConnected == true)
            #expect(manager.cachedUserCount == nil)
            #expect(manager.connectionError == nil)
        }
    }

    // MARK: - Pending requests cache

    @Test("A failed refreshPendingRequests leaves the previously loaded list in place")
    func failedRefreshLeavesPreviousListInPlace() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "refresh-then-fail")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(body: Data(#"{"id":1}"#.utf8)))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":1,"results":1,"page":1},"results":[{"id":1}]}"#.utf8)
        ))
        server.route("GET /api/v1/request", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":20,"results":2,"page":1},"results":[{"id":1},{"id":2}]}"#.utf8)
        ))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "test-session") {
            await manager.connectService(profile)
            await manager.refreshPendingRequests()
            #expect(manager.pendingRequests.map(\.id) == [1, 2])

            server.route("GET /api/v1/request", SeerrManagerFakeResponse(statusCode: 500, body: Data(#"{"message":"down"}"#.utf8)))
            await manager.refreshPendingRequests()

            // A failed refresh must not blank a list the user may be acting on.
            #expect(manager.pendingRequests.map(\.id) == [1, 2])
        }
    }

    @Test("refreshPendingRequests clears the list when there's no active client")
    func refreshPendingRequestsClearsListWithNoActiveClient() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "refresh-no-client")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(body: Data(#"{"id":1}"#.utf8)))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":1,"results":1,"page":1},"results":[{"id":1}]}"#.utf8)
        ))
        server.route("GET /api/v1/request", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":20,"results":1,"page":1},"results":[{"id":9}]}"#.utf8)
        ))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "test-session") {
            await manager.connectService(profile)
            await manager.refreshPendingRequests()
            #expect(manager.pendingRequests.map(\.id) == [9])

            // Delete the cookie so the next connectService(_:) call takes the
            // "missing cookie" early-return branch in production code. NOTE (see
            // report): that branch does not itself reset pendingRequests, unlike the
            // later catch-all failure branch which does — so immediately after this
            // call pendingRequests is still stale. This test is specifically about
            // refreshPendingRequests()'s own no-client guard, not connectService's.
            try await KeychainHelper.shared.delete(key: profile.sessionCookieKey)
            await manager.connectService(profile)
            #expect(manager.activeClient == nil)
            #expect(manager.pendingRequests.map(\.id) == [9])

            await manager.refreshPendingRequests()

            #expect(manager.pendingRequests.isEmpty)
        }
    }

    // MARK: - Approve / decline

    @Test("approveRequest removes the approved id from pendingRequests")
    func approveRequestRemovesId() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "approve")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(body: Data(#"{"id":1}"#.utf8)))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":1,"results":1,"page":1},"results":[{"id":1}]}"#.utf8)
        ))
        server.route("GET /api/v1/request", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":20,"results":2,"page":1},"results":[{"id":1},{"id":2}]}"#.utf8)
        ))
        server.route("POST /api/v1/request/1/approve", SeerrManagerFakeResponse(body: Data(#"{"id":1}"#.utf8)))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "test-session") {
            await manager.connectService(profile)
            await manager.refreshPendingRequests()

            try await manager.approveRequest(id: 1)

            #expect(manager.pendingRequests.map(\.id) == [2])
        }
    }

    @Test("declineRequest removes the declined id from pendingRequests")
    func declineRequestRemovesId() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "decline")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(body: Data(#"{"id":1}"#.utf8)))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":1,"results":1,"page":1},"results":[{"id":1}]}"#.utf8)
        ))
        server.route("GET /api/v1/request", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":20,"results":2,"page":1},"results":[{"id":1},{"id":2}]}"#.utf8)
        ))
        server.route("POST /api/v1/request/2/decline", SeerrManagerFakeResponse(body: Data(#"{"id":2}"#.utf8)))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "test-session") {
            await manager.connectService(profile)
            await manager.refreshPendingRequests()

            try await manager.declineRequest(id: 2)

            #expect(manager.pendingRequests.map(\.id) == [1])
        }
    }

    @Test("approveRequest and declineRequest are no-ops when there is no active client")
    func approveAndDeclineAreNoOpsWithoutClient() async throws {
        let manager = SeerrServiceManager()

        try await manager.approveRequest(id: 1)
        try await manager.declineRequest(id: 2)

        #expect(manager.pendingRequests.isEmpty)
    }

    // MARK: - disconnect

    @Test("disconnect clears every published property including pendingRequests")
    func disconnectClearsEveryPublishedProperty() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "disconnect")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(body: Data(#"{"id":1}"#.utf8)))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":1,"results":4,"page":1},"results":[{"id":1}]}"#.utf8)
        ))
        server.route("GET /api/v1/request", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":20,"results":1,"page":1},"results":[{"id":9}]}"#.utf8)
        ))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "test-session") {
            await manager.connectService(profile)
            await manager.refreshPendingRequests()
            #expect(manager.isConnected == true)
            #expect(manager.pendingRequests.isEmpty == false)

            manager.disconnect()

            #expect(manager.activeClient == nil)
            #expect(manager.activeProfileID == nil)
            #expect(manager.isConnected == false)
            #expect(manager.isConnecting == false)
            #expect(manager.connectionError == nil)
            #expect(manager.cachedUserCount == nil)
            #expect(manager.pendingRequests.isEmpty)
        }
    }

    // MARK: - Cookie update handler

    @Test("A refreshed connect.sid returned during connect is persisted to the Keychain")
    func refreshedCookieDuringConnectIsPersistedToKeychain() async throws {
        let server = try await SeerrManagerLoopbackServer(label: "cookie-refresh")
        defer { server.stop() }
        server.route("GET /api/v1/auth/me", SeerrManagerFakeResponse(
            body: Data(#"{"id":1}"#.utf8),
            setCookie: "connect.sid=s%3Arolled.session; Path=/; HttpOnly"
        ))
        server.route("GET /api/v1/user", SeerrManagerFakeResponse(
            body: Data(#"{"pageInfo":{"pages":1,"pageSize":1,"results":1,"page":1},"results":[{"id":1}]}"#.utf8)
        ))

        let profile = SeerrServiceProfile(displayName: "Test Seerr", hostURL: server.baseURL)
        let manager = SeerrServiceManager()

        try await withSavedSessionCookie(for: profile, cookie: "original-session") {
            await manager.connectService(profile)
            #expect(manager.isConnected == true)

            // The Keychain persist happens inside a Task.detached fired from the
            // client's cookie-update handler — there is no handle to await
            // directly. Poll the real Keychain value with bounded cooperative
            // yields rather than sleeping on the clock.
            let persisted = await awaitCondition {
                (try? await KeychainHelper.shared.read(key: profile.sessionCookieKey)) == "s%3Arolled.session"
            }
            #expect(persisted == true)
        }
    }

    // MARK: - Helpers

    /// Polls a real async condition with bounded cooperative yields instead of a
    /// wall-clock sleep. Used only where production code fires an unstructured,
    /// unawaited `Task`/`Task.detached` with no seam to await directly — mirrors
    /// `OnboardingViewModelTests.awaitCondition`, built for the identical problem.
    private func awaitCondition(maxYields: Int = 5_000, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    /// Saves `cookie` to `profile.sessionCookieKey`, runs `body`, then deletes that
    /// exact key on both the success and failure paths — mirrors
    /// `OnboardingViewModelTests.cleaningUpKeychain` / `KeychainAppGroupTests.withTestKey`.
    private func withSavedSessionCookie(
        for profile: SeerrServiceProfile,
        cookie: String,
        body: () async throws -> Void
    ) async throws {
        try await KeychainHelper.shared.save(key: profile.sessionCookieKey, value: cookie)
        do {
            try await body()
        } catch {
            try? await KeychainHelper.shared.delete(key: profile.sessionCookieKey)
            throw error
        }
        try? await KeychainHelper.shared.delete(key: profile.sessionCookieKey)
    }
}

// MARK: - Fake response

private nonisolated struct SeerrManagerFakeResponse: Sendable {
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
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}

// MARK: - Loopback server

/// A minimal loopback HTTP server standing in for Seerr's admin API.
/// `SeerrServiceManager` builds its own `SeerrAPIClient` (and that client its own
/// ephemeral `URLSession`) internally, with no injectable seam reachable from
/// outside — see this file's top doc comment — so this drives the real manager over
/// real loopback TCP, following the pattern established by
/// `ArrClientLifecycleTests.LifecycleArrTestServer` and
/// `OnboardingViewModelTests.OnboardingFakeQBServer` (both `private` to their own
/// files).
private nonisolated final class SeerrManagerLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var routes: [String: SeerrManagerFakeResponse] = [:]
    private var recordedRequests: [String] = []

    init(label: String) async throws {
        self.queue = DispatchQueue(label: "SeerrManagerLoopbackServer.\(label)")
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
        guard let port = listener.port else { fatalError("Seerr manager loopback server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func route(_ methodAndPath: String, _ response: SeerrManagerFakeResponse) {
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
            let response = self.routes[key] ?? SeerrManagerFakeResponse(statusCode: 404, body: Data())
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

    private static func httpResponse(_ response: SeerrManagerFakeResponse) -> Data {
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
