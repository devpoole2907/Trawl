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
        let healthyServer = try await RetryArrTestServer(label: "sonarr-healthy", statusCode: 200)
        let failingServer = try await RetryArrTestServer(label: "sonarr-failing", statusCode: 401)
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
private final class RetryArrTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let statusCode: Int
    private let lock = NSLock()
    private var recordedRequests: [RetryRequest] = []

    init(label: String, statusCode: Int) async throws {
        self.queue = DispatchQueue(label: "RetryArrTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.statusCode = statusCode
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

            let body: String
            if self.statusCode == 200 {
                switch request.path {
                case "/api/v3/system/status": body = "{}"
                case "/api/v3/qualityprofile", "/api/v3/rootfolder", "/api/v3/tag": body = "[]"
                case "/api/v3/command": body = "{}"
                default: body = "[]"
                }
            } else {
                body = #"{"message":"credentials rejected"}"#
            }
            connection.send(
                content: Self.httpResponse(statusCode: self.statusCode, body: body),
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
        let status = statusCode == 200 ? "200 OK" : "\(statusCode) Unauthorized"
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }
}
