import Foundation
import Network
import Testing
@testable import Trawl

/// The queue poller runs every 5 seconds for as long as a queue-facing view is on
/// screen. `@Observable` notifies on *assignment*, not on change, so assigning the
/// same queue back every poll invalidated every observing view whether or not the
/// servers had said anything new.
///
/// That is not merely wasteful. A detail screen rebuilds its toolbar `Menu` when its
/// body re-evaluates, and UIKit tears down a presented menu when its element tree is
/// replaced - so an open submenu closed itself every few seconds, on a metronome,
/// with nothing downloading.
///
/// Both directions are pinned here, and the second test matters more than the first:
/// the cheap way to stop the notifications is to stop refreshing, and that would be
/// a far worse bug than the one being fixed.
@Suite("Arr queue polling observation")
@MainActor
struct ArrQueuePollingObservationTests {

    /// `withObservationTracking`'s `onChange` is `@Sendable`, so the flag it sets
    /// cannot be a captured local. Access is confined to the MainActor either way.
    private final class ChangeFlag: @unchecked Sendable {
        var didChange = false
    }

    private static func queueJSON(ids: [Int]) -> String {
        let records = ids.map {
            #"{"id":\#($0),"title":"Fixture \#($0)","status":"downloading","size":100.0,"sizeleft":50.0}"#
        }
        return #"{"page":1,"pageSize":100,"totalRecords":\#(ids.count),"records":[\#(records.joined(separator: ","))]}"#
    }

    private func connected(
        to server: DualInstanceRadarrServer,
        run: (ArrServiceManager) async throws -> Void
    ) async throws {
        let manager = ArrServiceManager()
        let profile = ArrServiceProfile(
            displayName: "Radarr",
            hostURL: server.baseURL,
            serviceType: .radarr,
            qualityTier: .hd
        )
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "queue-poll-key")
        defer { Task { try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey) } }
        await manager.connectService(profile)
        try await run(manager)
    }

    @Test("A poll that brings no new data notifies nobody")
    func unchangedPollDoesNotNotifyObservers() async throws {
        let server = try await DualInstanceRadarrServer(label: "queue-same", movies: "[]")
        defer { server.stop() }
        server.queueBody = Self.queueJSON(ids: [1, 2])

        try await connected(to: server) { manager in
            // First refresh establishes the baseline and clears the first-load flags.
            await manager.refreshQueues()
            #expect(manager.radarrQueue.count == 2)
            #expect(manager.hasLoadedQueueOnce)

            let flag = ChangeFlag()
            withObservationTracking {
                _ = manager.radarrQueue
            } onChange: {
                flag.didChange = true
            }

            // Same payload, deliberately: this is the idle-server case that used to
            // invalidate every observer twice per poll.
            await manager.refreshQueues()

            #expect(
                flag.didChange == false,
                "An identical queue must not notify observers - the frame it would produce is the frame already on screen."
            )
            #expect(manager.radarrQueue.count == 2, "Suppressing the notification must not drop the data.")
        }
    }

    @Test("A poll that brings new data still notifies, and the new data lands")
    func changedPollStillNotifiesObservers() async throws {
        let server = try await DualInstanceRadarrServer(label: "queue-diff", movies: "[]")
        defer { server.stop() }
        server.queueBody = Self.queueJSON(ids: [1, 2])

        try await connected(to: server) { manager in
            await manager.refreshQueues()
            #expect(manager.radarrQueue.count == 2)

            let flag = ChangeFlag()
            withObservationTracking {
                _ = manager.radarrQueue
            } onChange: {
                flag.didChange = true
            }

            // A third download appears, which is exactly what the poller exists for.
            server.queueBody = Self.queueJSON(ids: [1, 2, 3])
            await manager.refreshQueues()

            #expect(
                flag.didChange,
                "Real new data must still notify observers - a view that stops updating is a worse bug than the one being fixed."
            )
            #expect(manager.radarrQueue.count == 3)
        }
    }

    @Test("The loading flag is a first-load affordance, not a per-poll flicker")
    func loadingFlagSettlesAfterTheFirstRefresh() async throws {
        let server = try await DualInstanceRadarrServer(label: "queue-flag", movies: "[]")
        defer { server.stop() }
        server.queueBody = Self.queueJSON(ids: [1])

        try await connected(to: server) { manager in
            await manager.refreshQueues()
            #expect(manager.hasLoadedQueueOnce)
            #expect(manager.isLoadingQueue == false)

            let flag = ChangeFlag()
            withObservationTracking {
                _ = manager.isLoadingQueue
            } onChange: {
                flag.didChange = true
            }

            // Changing the data guarantees the refresh does real work, so this is
            // not passing merely because nothing happened.
            server.queueBody = Self.queueJSON(ids: [1, 2])
            await manager.refreshQueues()

            #expect(
                flag.didChange == false,
                "isLoadingQueue used to flip true/false on every poll, which is two observer notifications per cycle on its own."
            )
            #expect(manager.radarrQueue.count == 2)
        }
    }
}
