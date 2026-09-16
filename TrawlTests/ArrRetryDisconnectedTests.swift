import Foundation
import Network
import Testing
@testable import Trawl

/// Regression coverage for M-01: `ArrServiceManager.retryDisconnected()` must decide
/// per profile, not per service type. With two Sonarr profiles where one is connected
/// and one is failing, the failing profile must still be retried on foreground return
/// even though the service *type* as a whole already has a healthy active instance.
///
/// Uses real loopback HTTP servers (`NWListener`) and drives the real
/// `ArrServiceManager.initialize(from:)` / `retryDisconnected()` - no stubbing of
/// `connectService` itself. Follows the pattern established by
/// `ArrClientLifecycleTests.swift`.
@Suite("Arr retry disconnected", .serialized)
@MainActor
struct ArrRetryDisconnectedTests {
    @Test("retryDisconnected reconnects a failed secondary Sonarr profile without touching the already-connected one")
    func retryDisconnectedRetriesOnlyFailedProfile() async throws {
        let healthyServer = try await RetryArrTestServer(label: "sonarr-healthy", mode: .healthy)
        let failingServer = try await RetryArrTestServer(label: "sonarr-failing", mode: .rejecting(401))
        defer { healthyServer.stop(); failingServer.stop() }

        let healthyProfile = ArrServiceProfile(displayName: "Sonarr Healthy", hostURL: healthyServer.baseURL, serviceType: .sonarr)
        let failingProfile = ArrServiceProfile(displayName: "Sonarr Failing", hostURL: failingServer.baseURL, serviceType: .sonarr)

        let manager = ArrServiceManager()

        try await withSavedAPIKey(for: healthyProfile) {
            try await withSavedAPIKey(for: failingProfile) {
                // `initialize(from:)` is the real production entry point that populates
                // `storedProfiles` and attempts to connect every enabled profile - the
                // same seam a real app launch or profile-list edit goes through.
                await manager.initialize(from: [healthyProfile, failingProfile])

                #expect(manager.isConnected(.sonarr, profileID: healthyProfile.id) == true)
                #expect(manager.isConnected(.sonarr, profileID: failingProfile.id) == false)

                // `initialize(from:)` ends by spawning a detached health/blocklist
                // prefetch against the connected client, so the healthy server's
                // total request list keeps growing on its own timeline. What the
                // retry must not do is re-run the connection handshake, and every
                // connect attempt starts with a system-status GET - so count those.
                let healthyStatusRequestsAfterInitialize = healthyServer.statusRequestCount
                let failingRequestsAfterInitialize = failingServer.requests
                #expect(!failingRequestsAfterInitialize.isEmpty)

                await manager.retryDisconnected()

                // The failed profile's server must have received a fresh connection
                // attempt from the retry. This is the assertion that fails against the
                // unfixed code: retryDisconnected() used to check
                // `isConnected(.sonarr)`, which reads the *active* instance only - and
                // the active instance (the healthy profile) was connected, so the whole
                // Sonarr type was skipped and the failing profile was never retried.
                // Exactly one more request: the retry's system-status call, which 401s
                // again. A `> count` assertion would also pass if the retry looped.
                #expect(failingServer.requests == failingRequestsAfterInitialize + [.init(method: "GET", path: "/api/v3/system/status")])

                // The already-connected profile must not be reconnected by the
                // retry - no redundant handshake, no needless client churn.
                #expect(healthyServer.statusRequestCount == healthyStatusRequestsAfterInitialize)

                #expect(manager.isConnected(.sonarr, profileID: healthyProfile.id) == true)
                #expect(manager.isConnected(.sonarr, profileID: failingProfile.id) == false)
            }
        }
    }

    /// A server that dies *after* connecting used to keep `isConnected == true`
    /// forever: `setError` is only reachable from `connectService`, so nothing
    /// downgraded a live instance. The "Sonarr Unreachable" screen therefore only
    /// ever appeared for a server that was already down at launch, and
    /// `retryDisconnected()` skipped the instance because it did not look
    /// disconnected - so the app sat on stale data until it was relaunched.
    @Test("A connected Sonarr that stops answering is marked unreachable, and the retry brings it back")
    func transportFailuresDisconnectAConnectedInstanceAndTheRetryRecoversIt() async throws {
        let server = try await RetryArrTestServer(label: "sonarr-flaky", mode: .healthy)
        defer { server.stop() }

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: server.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await withSavedAPIKey(for: profile) {
            await manager.initialize(from: [profile])
            #expect(manager.isConnected(.sonarr, profileID: profile.id) == true)

            server.setMode(.unreachable)

            // One short of the threshold is a blip, not an outage. It must not
            // disconnect anything: `pair(_:with:)` gates every fan-out on
            // `isConnected`, so flipping here would empty a library mid-scroll for
            // what may be a single dropped request during a Wi-Fi handover.
            for _ in 0..<(ArrServiceManager.unreachableFailureThreshold - 1) {
                await manager.refreshQueues()
            }
            #expect(manager.isConnected(.sonarr, profileID: profile.id) == true)

            await manager.refreshQueues()
            #expect(manager.isConnected(.sonarr, profileID: profile.id) == false)
            #expect(manager.connectionError(.sonarr) != nil)

            // Which is what puts it in front of the retry scheduler's sweep.
            server.setMode(.healthy)
            let statusRequestsBeforeRetry = server.statusRequestCount
            await manager.retryDisconnected()

            #expect(server.statusRequestCount > statusRequestsBeforeRetry)
            #expect(manager.isConnected(.sonarr, profileID: profile.id) == true)
            #expect(manager.connectionError(.sonarr) == nil)
        }
    }

    /// The counter must measure reachability, not displeasure. A server returning
    /// 500s is up, talking, and reachable - disconnecting it would drop it out of
    /// the blended library over an error its own screens are already reporting, and
    /// the retry loop would reconnect it moments later, forever. The same reasoning
    /// covers a rejected API key, which is the trap
    /// `SABnzbdServiceManager.didRejectCredentials` exists to document.
    @Test("A server answering with errors is never treated as unreachable")
    func serverErrorsDoNotDisconnectAConnectedInstance() async throws {
        let server = try await RetryArrTestServer(label: "sonarr-erroring", mode: .healthy)
        defer { server.stop() }

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: server.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await withSavedAPIKey(for: profile) {
            await manager.initialize(from: [profile])
            #expect(manager.isConnected(.sonarr, profileID: profile.id) == true)

            server.setMode(.rejecting(500))
            for _ in 0..<(ArrServiceManager.unreachableFailureThreshold + 2) {
                await manager.refreshQueues()
            }

            #expect(manager.isConnected(.sonarr, profileID: profile.id) == true)
            // The failure is still reported - it is just reported as what it is.
            #expect(manager.queueError != nil)
        }
    }

    @Test("Only a transport failure counts as evidence that a server is unreachable")
    func onlyTransportFailuresCountAsUnreachable() {
        #expect(ArrServiceManager.isTransportFailure(ArrError.networkError(URLError(.cannotConnectToHost))))
        #expect(ArrServiceManager.isTransportFailure(ArrError.networkError(URLError(.timedOut))))

        #expect(!ArrServiceManager.isTransportFailure(ArrError.serverError(statusCode: 500, message: nil)))
        #expect(!ArrServiceManager.isTransportFailure(ArrError.invalidAPIKey))
        #expect(!ArrServiceManager.isTransportFailure(ArrError.decodingError(URLError(.badServerResponse))))
        #expect(!ArrServiceManager.isTransportFailure(ArrError.invalidResponse))
        #expect(!ArrServiceManager.isTransportFailure(CancellationError()))
    }

    private func withSavedAPIKey(
        for profile: ArrServiceProfile,
        operation: () async throws -> Void
    ) async throws {
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "retry-disconnected-test-key")
        do {
            try await operation()
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        } catch {
            try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            throw error
        }
    }
}

private struct RetryRequest: Sendable, Equatable {
    let method: String
    let path: String
}

/// Minimal loopback Sonarr stand-in. Mirrors `LifecycleArrTestServer` in
/// `ArrClientLifecycleTests.swift`: a healthy server answers every *arr
/// bootstrap call (system status, quality profiles, root folders, tags) with
/// 200s; a failing server answers every call with the given non-200 status so
/// `connectService` throws right after the system-status call, exactly like a
/// rejected API key.
/// How the loopback server behaves for the next request.
///
/// `unreachable` accepts the connection and drops it without answering, which is
/// what URLSession reports as a transport failure. It is used in place of stopping
/// the listener because a stopped listener frees its port, and rebinding the same
/// port afterwards to simulate the server coming back is exactly the kind of thing
/// that fails once a week on a busy machine. Flipping a mode is instant and total.
private enum RetryArrServerMode: Sendable {
    case healthy
    case rejecting(Int)
    case unreachable
}

private final class RetryArrTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var currentMode: RetryArrServerMode
    private var recordedRequests: [RetryRequest] = []

    init(label: String, mode: RetryArrServerMode) async throws {
        self.queue = DispatchQueue(label: "RetryArrTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.currentMode = mode
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
        guard let port = listener.port else { fatalError("Retry test server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    /// Connection handshakes only. Every `connectService` attempt begins with
    /// this call, so it is the signal for "was this server reconnected".
    var statusRequestCount: Int {
        requests.filter { $0.method == "GET" && $0.path == "/api/v3/system/status" }.count
    }

    var requests: [RetryRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private var mode: RetryArrServerMode {
        lock.lock()
        defer { lock.unlock() }
        return currentMode
    }

    func setMode(_ mode: RetryArrServerMode) {
        lock.lock()
        currentMode = mode
        lock.unlock()
    }

    func stop() { listener.cancel() }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = Self.request(from: data)
            self.lock.lock()
            self.recordedRequests.append(request)
            self.lock.unlock()

            let statusCode: Int
            let body: String
            switch self.mode {
            case .unreachable:
                // Answer nothing at all. URLSession surfaces this as a URLError,
                // which is what `HTTPTransport` maps to `ArrError.networkError`.
                connection.cancel()
                return
            case .healthy:
                statusCode = 200
                switch request.path {
                case "/api/v3/system/status": body = "{}"
                case "/api/v3/qualityprofile", "/api/v3/rootfolder", "/api/v3/tag": body = "[]"
                case "/api/v3/command": body = "{}"
                // The queue poller decodes a paged envelope; a bare array would fail
                // to decode and register as the server answering badly rather than
                // answering well, which is a different branch of what is under test.
                case "/api/v3/queue", "/api/v3/history": body = #"{"records":[]}"#
                default: body = "[]"
                }
            case .rejecting(let code):
                statusCode = code
                body = #"{"message":"the server is unhappy"}"#
            }
            connection.send(
                content: Self.httpResponse(statusCode: statusCode, body: body),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func request(from data: Data) -> RetryRequest {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return .init(method: "", path: "")
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        return .init(method: method, path: String(rawPath.split(separator: "?", maxSplits: 1).first ?? ""))
    }

    private static func httpResponse(statusCode: Int, body: String) -> Data {
        let status = statusCode == 200 ? "200 OK" : "\(statusCode) Error"
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }
}
