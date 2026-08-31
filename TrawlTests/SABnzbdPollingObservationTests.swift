import Foundation
import Testing
@testable import Trawl

/// The SABnzbd poller runs every 4 seconds for as long as the app is open.
/// `@Observable` notifies on *assignment*, not on change, so republishing the same
/// queue every tick invalidated every view reading it whether or not SABnzbd had
/// said anything new.
///
/// This was measured rather than reasoned about. A Time Profiler trace of a Release
/// build on an iPhone 15 Pro Max, with nothing downloading, showed a ~48ms
/// main-thread spike every 4 seconds: a full SwiftUI graph update plus a
/// `UICollectionViewListCoordinatorBase.performUpdates` list diff, with
/// `DownloadsViewModel.match` re-running underneath. At 120Hz that is about six
/// dropped frames, on a metronome.
///
/// The second test is the one that matters. The cheap way to stop the
/// notifications is to stop refreshing, and a downloads list that goes stale is a
/// far worse bug than the one being fixed.
@Suite("SABnzbd polling observation", .serialized)
struct SABnzbdPollingObservationTests {

    /// `withObservationTracking`'s `onChange` is `@Sendable`, so the flag it sets
    /// cannot be a captured local.
    private final class ChangeFlag: @unchecked Sendable {
        var didChange = false
    }

    /// `mbleft` is carried at the queue level as well as per slot - `SABnzbdQueue`
    /// decodes its own `mbleft`, and a slot-only value leaves it at 0.
    private static func queueJSON(mbLeft: Int) -> String {
        #"""
        {"queue":{"mb":100,"mbleft":\#(mbLeft),"slots":[{"nzo_id":"nzo_1","filename":"Fixture Job","status":"Downloading","mb":100,"mbleft":\#(mbLeft),"percentage":50,"size":"100 MB","sizeleft":"\#(mbLeft) MB"}]}}
        """#
    }

    private static let historyJSON = #"{"history":{"last_history_update":42,"slots":[]}}"#

    @MainActor
    private func connectedManager() async throws -> (SABnzbdServiceManager, SABnzbdServiceProfile) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PollingObservationURLProtocol.self]
        // `connectService` starts the poll loop. Left to its own clock it would
        // refresh behind the test and fire the very notification being measured, so
        // the interval never elapses here - every refresh in these tests is one the
        // test asked for.
        let manager = SABnzbdServiceManager(
            sessionConfiguration: configuration,
            waitForPollingInterval: { _ in
                try? await Task.sleep(for: .seconds(3600))
            }
        )
        let profile = SABnzbdServiceProfile(
            displayName: "Observation SABnzbd",
            hostURL: "https://sabnzbd.observation.test"
        )
        return (manager, profile)
    }

    @Test("A poll that brings no new data notifies nobody")
    @MainActor
    func unchangedPollDoesNotNotifyObservers() async throws {
        PollingObservationRemote.shared.reset()
        PollingObservationRemote.shared.setQueue(Self.queueJSON(mbLeft: 25))
        PollingObservationRemote.shared.setHistory(Self.historyJSON)

        let (manager, profile) = try await connectedManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            await manager.refresh()
            #expect(manager.queue?.slots.count == 1)

            let flag = ChangeFlag()
            withObservationTracking {
                _ = manager.queue
            } onChange: {
                flag.didChange = true
            }

            // Byte-identical payload: the idle-server case that used to rebuild the
            // whole downloads list every four seconds.
            await manager.refresh()

            #expect(
                flag.didChange == false,
                "An identical queue must not notify observers - the frame it would produce is the frame already on screen."
            )
            #expect(manager.queue?.slots.count == 1, "Suppressing the notification must not drop the data.")
        }
    }

    @Test("A poll that brings new data still notifies, and the new data lands")
    @MainActor
    func changedPollStillNotifiesObservers() async throws {
        PollingObservationRemote.shared.reset()
        PollingObservationRemote.shared.setQueue(Self.queueJSON(mbLeft: 25))
        PollingObservationRemote.shared.setHistory(Self.historyJSON)

        let (manager, profile) = try await connectedManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            await manager.refresh()
            #expect(manager.queue?.megabytesLeft == 25)

            let flag = ChangeFlag()
            withObservationTracking {
                _ = manager.queue
            } onChange: {
                flag.didChange = true
            }

            // The download progressed, which is the entire point of polling.
            PollingObservationRemote.shared.setQueue(Self.queueJSON(mbLeft: 10))
            await manager.refresh()

            #expect(
                flag.didChange,
                "Real progress must still notify observers - a downloads list that stops updating is worse than the bug being fixed."
            )
            #expect(manager.queue?.megabytesLeft == 10)
        }
    }

    /// A rejected key is not a retryable failure.
    ///
    /// Clearing the connection flips `isConnected` to false, which is also the
    /// signal `ContentView.retryDisconnectedConnections()` used to decide whether
    /// to reconnect - so after a 401 the app immediately reconnected to the server
    /// that had just turned it away, issuing a `version` handshake and a `queue`
    /// poll against someone else's machine. A wrong key does not fix itself on a
    /// timer, and retrying silently contradicts the error the user is shown.
    ///
    /// `SABnzbdUnauthorizedJourneyUITests` caught this only once its polling
    /// assertion was made *stricter*: the previous version sampled every 0.5s
    /// against a 4s poll cadence and broke out on the first two quiet samples, so
    /// it could settle mid-interval and miss the reconnect entirely. Relaxing a
    /// timing-sensitive assertion because it goes red is how this stayed hidden.
    @Test("A rejected key is not retried automatically, but a deliberate reconnect clears that")
    @MainActor
    func rejectedCredentialsAreNotRetriedAutomatically() async throws {
        PollingObservationRemote.shared.reset()
        PollingObservationRemote.shared.setQueue(Self.queueJSON(mbLeft: 25))
        PollingObservationRemote.shared.setHistory(Self.historyJSON)

        let (manager, profile) = try await connectedManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            #expect(manager.didRejectCredentials == false)

            PollingObservationRemote.shared.setUnauthorized(true)
            await manager.refresh()

            #expect(manager.isConnected == false)
            #expect(
                manager.didRejectCredentials,
                "A 401 has to be distinguishable from being unreachable, or the automatic retry cannot tell them apart."
            )

            // The user corrects the key in Settings, which connects directly rather
            // than waiting for the retry loop. That must not be blocked.
            PollingObservationRemote.shared.setUnauthorized(false)
            await manager.connectService(profile)
            #expect(
                manager.didRejectCredentials == false,
                "A deliberate reconnect supersedes the rejection - otherwise fixing the key would never take effect."
            )
        }
    }

    /// The regression the full plan caught, pinned.
    ///
    /// `queueRevision` was originally bumped inside `refresh()` only. An
    /// unauthorized response clears the connection through a different path -
    /// `clearActiveConnection()` nils `queue` and `history` directly - so the
    /// revision did not move, and `DownloadsViewModel.items`, which memoises on it,
    /// kept serving the disconnected server's jobs. On screen that was a stale
    /// download row surviving a lost connection, which is exactly what
    /// `SABnzbdUnauthorizedJourneyUITests` exists to prevent.
    ///
    /// The lesson is in the assertion: it is not enough for a cache key to move on
    /// the paths its author remembered. This checks the property, not the poll.
    @Test("Clearing the connection moves the cache key, so nothing can serve stale jobs")
    @MainActor
    func clearingTheConnectionMovesTheRevision() async throws {
        PollingObservationRemote.shared.reset()
        PollingObservationRemote.shared.setQueue(Self.queueJSON(mbLeft: 25))
        PollingObservationRemote.shared.setHistory(Self.historyJSON)

        let (manager, profile) = try await connectedManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            await manager.refresh()
            #expect(manager.queue?.slots.count == 1)
            let revisionWhileConnected = manager.queueRevision

            // SABnzbd starts rejecting the key, which drops the client and the
            // cached queue with it.
            PollingObservationRemote.shared.setUnauthorized(true)
            await manager.refresh()

            #expect(manager.queue == nil, "An unauthorized response must clear the cached queue.")
            #expect(
                manager.queueRevision != revisionWhileConnected,
                "Clearing the queue has to move the revision. A consumer memoising on it would otherwise keep rendering jobs from a server it is no longer connected to."
            )
        }
    }
}

extension SABnzbdPollingObservationTests {
    /// Local copy of the same helper `SABnzbdServiceManagerConcurrencyTests` uses -
    /// it is private there, and the keychain round-trip is the point rather than
    /// something worth sharing a type over.
    fileprivate func withSavedAPIKey(
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

// MARK: - Controllable remote

/// Lock-protected rather than an actor so `startLoading` can answer synchronously.
/// Hopping to an actor would force the URLProtocol to capture itself into a `Task`,
/// which does not compile under strict concurrency and is not needed here.
private final class PollingObservationRemote: @unchecked Sendable {
    static let shared = PollingObservationRemote()
    private let lock = NSLock()
    private var queueBody = #"{"queue":{"slots":[]}}"#
    private var historyBody = #"{"history":{"last_history_update":0,"slots":[]}}"#

    func reset() {
        lock.lock(); defer { lock.unlock() }
        queueBody = #"{"queue":{"slots":[]}}"#
        historyBody = #"{"history":{"last_history_update":0,"slots":[]}}"#
        unauthorized = false
    }
    private var unauthorized = false
    func setUnauthorized(_ value: Bool) { lock.lock(); unauthorized = value; lock.unlock() }
    var isUnauthorized: Bool { lock.lock(); defer { lock.unlock() }; return unauthorized }
    func setQueue(_ body: String) { lock.lock(); queueBody = body; lock.unlock() }
    func setHistory(_ body: String) { lock.lock(); historyBody = body; lock.unlock() }
    func body(for mode: String) -> String {
        lock.lock(); defer { lock.unlock() }
        switch mode {
        case "history": return historyBody
        case "queue": return queueBody
        default: return #"{"status":true,"version":"4.5.0"}"#
        }
    }
}

private final class PollingObservationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "mode" }?.value ?? ""
        let body = PollingObservationRemote.shared.body(for: mode)
        let status = PollingObservationRemote.shared.isUnauthorized ? 401 : 200
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
