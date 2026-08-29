import Foundation
import Testing
@testable import Trawl

@Suite("SABnzbd service-manager authorization", .serialized)
struct SABnzbdServiceManagerConcurrencyTests {
    @Test("An unauthorized poll drops the client and stops future polls")
    @MainActor
    func unauthorizedPollDisconnectsAndPreventsFurtherRequests() async throws {
        let clock = ManualSABnzbdPollClock()
        let refreshCompletion = SABnzbdRefreshCompletion()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedSABnzbdURLProtocol.self]
        let manager = SABnzbdServiceManager(
            sessionConfiguration: configuration,
            waitForPollingInterval: { _ in await clock.wait() },
            didFinishRefresh: { refreshCompletion.signal() }
        )
        defer { manager.stopPolling() }
        let profile = SABnzbdServiceProfile(
            displayName: "Controlled SABnzbd",
            hostURL: "https://sabnzbd.unauthorized.test"
        )

        await UnauthorizedSABnzbdRemote.shared.reset()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            #expect(manager.isConnected)
            #expect(manager.activeClient != nil)
            refreshCompletion.reset()

            manager.startPolling()
            await clock.waitUntilSleeping()
            await UnauthorizedSABnzbdRemote.shared.rejectNextPoll()

            let advancedFirstPoll = await clock.advance()
            #expect(advancedFirstPoll)
            await UnauthorizedSABnzbdRemote.shared.waitForUnauthorizedRequests()
            await UnauthorizedSABnzbdRemote.shared.releaseUnauthorizedResponses()
            await refreshCompletion.wait()

            #expect(!manager.isConnected)
            #expect(!manager.isPolling)
            #expect(manager.activeClient == nil)
            #expect(manager.connectionError == "SABnzbd rejected the API key. Update it in Settings.")

            do {
                try await manager.pauseAll()
                Issue.record("Expected mutations to fail after the active client was cleared")
            } catch let error as SABnzbdAPIError {
                if case .invalidResponse = error {
                    // Expected: clearing the active client blocks all mutations.
                } else {
                    Issue.record("Expected invalidResponse without an active client, received \(error)")
                }
            } catch {
                Issue.record("Expected SABnzbdAPIError.invalidResponse, received \(error)")
            }

            let requestCountAfterUnauthorizedPoll = await UnauthorizedSABnzbdRemote.shared.requestCount
            #expect(requestCountAfterUnauthorizedPoll == 6)
            let advancedAfterDisconnect = await clock.advance()
            #expect(!advancedAfterDisconnect)
            let requestCountAfterExtraTick = await UnauthorizedSABnzbdRemote.shared.requestCount
            #expect(requestCountAfterExtraTick == requestCountAfterUnauthorizedPoll)
        }
    }

    /// The Downloads tab asks for polling from its `.task`, which runs while the
    /// SABnzbd connection is still being established at launch. `startPolling()`
    /// used to require a client to already exist and silently returned when it
    /// didn't - so a cold launch straight into Downloads never polled at all, and
    /// nothing retried it: the queue stayed frozen for the whole session until a
    /// manual pull-to-refresh. The request now outlives the missing client.
    @Test("Polling asked for before the client exists starts once connected")
    @MainActor
    func pollingRequestedBeforeConnectStartsOnConnect() async throws {
        // The loop is never advanced here: this test is about whether it starts at
        // all. `unauthorizedPollDisconnectsAndPreventsFurtherRequests` above drives
        // it for real.
        let clock = ManualSABnzbdPollClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedSABnzbdURLProtocol.self]
        let manager = SABnzbdServiceManager(
            sessionConfiguration: configuration,
            waitForPollingInterval: { _ in await clock.wait() }
        )
        defer { manager.stopPolling() }
        let profile = SABnzbdServiceProfile(
            displayName: "Late SABnzbd",
            hostURL: "https://sabnzbd.unauthorized.test"
        )

        await UnauthorizedSABnzbdRemote.shared.reset()
        try await withSavedAPIKey(for: profile) {
            // The view appears first: there is no client to poll yet.
            manager.startPolling()
            #expect(!manager.isPolling)

            await manager.connectService(profile)

            #expect(manager.isConnected)
            #expect(
                manager.isPolling,
                "A polling request made before the connection existed should be honoured once it does."
            )
        }
    }

    /// The mirror of the above. `stopPolling()` means the view that wanted the
    /// queue is gone, so a later connection must not quietly start polling for a
    /// screen nobody is looking at.
    @Test("Polling stopped by the view does not resume on a later connection")
    @MainActor
    func pollingStoppedByViewDoesNotResumeOnConnect() async throws {
        let clock = ManualSABnzbdPollClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedSABnzbdURLProtocol.self]
        let manager = SABnzbdServiceManager(
            sessionConfiguration: configuration,
            waitForPollingInterval: { _ in await clock.wait() }
        )
        defer { manager.stopPolling() }
        let profile = SABnzbdServiceProfile(
            displayName: "Unwatched SABnzbd",
            hostURL: "https://sabnzbd.unauthorized.test"
        )

        await UnauthorizedSABnzbdRemote.shared.reset()
        try await withSavedAPIKey(for: profile) {
            manager.startPolling()
            manager.stopPolling()

            await manager.connectService(profile)

            #expect(manager.isConnected)
            #expect(
                !manager.isPolling,
                "Connecting must not resume polling the view already withdrew."
            )
        }
    }

    private func withSavedAPIKey(
        for profile: SABnzbdServiceProfile,
        operation: () async throws -> Void
    ) async throws {
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "test-api-key")
        do {
            try await operation()
        } catch {
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            throw error
        }
        try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
    }
}

@MainActor
private final class SABnzbdRefreshCompletion {
    private var hasFinished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func reset() {
        hasFinished = false
    }

    func signal() {
        hasFinished = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !hasFinished else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private actor ManualSABnzbdPollClock {
    private var waiter: CheckedContinuation<Void, Never>?
    private var sleepObserver: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            precondition(waiter == nil, "Only one SABnzbd polling wait should be pending.")
            waiter = continuation
            sleepObserver?.resume()
            sleepObserver = nil
        }
    }

    func waitUntilSleeping() async {
        guard waiter == nil else { return }
        await withCheckedContinuation { continuation in
            sleepObserver = continuation
        }
    }

    func advance() -> Bool {
        guard let waiter else { return false }
        self.waiter = nil
        waiter.resume()
        return true
    }
}

private actor UnauthorizedSABnzbdRemote {
    static let shared = UnauthorizedSABnzbdRemote()

    private var rejectingPoll = false
    private var requests: [String] = []
    private var unauthorizedRequestCount = 0
    private var unauthorizedRequestWaiter: CheckedContinuation<Void, Never>?
    private var unauthorizedResponseWaiters: [CheckedContinuation<UnauthorizedSABnzbdFixture, Never>] = []

    var requestCount: Int { requests.count }

    func reset() {
        rejectingPoll = false
        requests = []
        unauthorizedRequestCount = 0
        unauthorizedRequestWaiter = nil
        unauthorizedResponseWaiters = []
    }

    func rejectNextPoll() {
        rejectingPoll = true
        unauthorizedRequestCount = 0
    }

    func response(for request: URLRequest) async -> UnauthorizedSABnzbdFixture {
        let mode = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "mode" })?
            .value ?? ""
        requests.append(mode)

        if rejectingPoll {
            unauthorizedRequestCount += 1
            if unauthorizedRequestCount == 2 {
                unauthorizedRequestWaiter?.resume()
                unauthorizedRequestWaiter = nil
            }
            return await withCheckedContinuation { continuation in
                unauthorizedResponseWaiters.append(continuation)
            }
        }

        switch mode {
        case "version":
            return .init(statusCode: 200, body: Data("{\"version\":\"4.5.0\"}".utf8))
        case "queue":
            return .init(statusCode: 200, body: Data("{\"queue\":{\"slots\":[]}}".utf8))
        case "history":
            return .init(statusCode: 200, body: Data("{\"history\":{\"slots\":[]}}".utf8))
        default:
            return .init(statusCode: 500, body: Data())
        }
    }

    func waitForUnauthorizedRequests() async {
        guard unauthorizedRequestCount >= 2 else {
            await withCheckedContinuation { continuation in
                unauthorizedRequestWaiter = continuation
            }
            return
        }
    }

    func releaseUnauthorizedResponses() {
        let fixture = UnauthorizedSABnzbdFixture(
            statusCode: 401,
            body: Data("{\"error\":\"invalid API key\"}".utf8)
        )
        rejectingPoll = false
        let waiters = unauthorizedResponseWaiters
        unauthorizedResponseWaiters = []
        for waiter in waiters {
            waiter.resume(returning: fixture)
        }
    }

}

private struct UnauthorizedSABnzbdFixture: Sendable {
    let statusCode: Int
    let body: Data
}

private final class UnauthorizedSABnzbdURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sabnzbd.unauthorized.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let protocolInstance = self
        Task.detached { @Sendable in
            guard let url = request.url else { return }
            let fixture = await UnauthorizedSABnzbdRemote.shared.response(for: request)
            protocolInstance.complete(url: url, fixture: fixture)
        }
    }

    override func stopLoading() {}

    private func complete(url: URL, fixture: UnauthorizedSABnzbdFixture) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
