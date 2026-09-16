import Foundation
import Testing
@testable import Trawl

@Suite("SyncService concurrency", .serialized)
struct SyncServiceConcurrencyTests {
    @Test("An older polling response cannot replace a newer refresh")
    @MainActor
    func stalePollingResponseIsDiscarded() async throws {
        let source = ControlledSyncDataSource()
        let service = SyncService(apiClient: source)
        service.pollingInterval = 0

        let notifications = InAppNotificationCenter.shared
        notifications.clearRecentNotifications()
        defer { notifications.clearRecentNotifications() }

        service.startPolling()
        let baselineRequest = await source.nextRequest()
        #expect(baselineRequest.rid == 0)
        await source.resolve(
            baselineRequest,
            with: try syncData(rid: 10, state: "downloading", downloadSpeed: 10)
        )

        let pollingRequest = await source.nextRequest()
        #expect(pollingRequest.rid == 10)

        let refreshTask = Task { @MainActor in
            await service.refreshNow()
        }
        let refreshRequest = await source.nextRequest()
        #expect(refreshRequest.rid == 10)

        await source.resolve(
            refreshRequest,
            with: try syncData(rid: 20, state: "uploading", downloadSpeed: 20)
        )
        await refreshTask.value

        await source.resolve(
            pollingRequest,
            with: try syncData(rid: 15, state: "downloading", downloadSpeed: 15)
        )
        let nextPollingRequest = await source.nextRequest()

        #expect(nextPollingRequest.rid == 20)
        #expect(service.serverState?.dlInfoSpeed == 20)
        #expect(service.torrents["example"]?.state == .uploading)
        #expect(
            notifications.recentNotifications.filter {
                $0.title == "Download Complete" && $0.message == "Example Download"
            }.count == 1
        )

        service.stopPolling()
        await source.resolve(
            nextPollingRequest,
            with: try syncData(rid: 21, state: "uploading", downloadSpeed: 21)
        )
        await Task.yield()
    }

    @Test("Stopping polling prevents a delayed response from applying")
    @MainActor
    func stoppedPollingDiscardsDelayedResponse() async throws {
        let source = ControlledSyncDataSource()
        let service = SyncService(apiClient: source)

        service.startPolling()
        let pendingRequest = await source.nextRequest()
        service.stopPolling()

        await source.resolve(
            pendingRequest,
            with: try syncData(rid: 20, state: "uploading", downloadSpeed: 20)
        )
        await Task.yield()

        #expect(service.torrents.isEmpty)
        #expect(service.serverState == nil)
        #expect(service.speedHistory.isEmpty)
        #expect(!service.isPolling)
    }

    /// The backoff is unit-covered in `PollBackoffTests`; what this pins is that the
    /// polling loop actually consults it, and that a success puts the cadence back.
    /// Asserted as the sequence of intervals the loop *asks* to wait, so nothing here
    /// sleeps - the loop is stepped by the controlled source holding each request.
    @Test("An unreachable server stretches the polling cadence, and recovery restores it")
    @MainActor
    func unreachableServerBacksOffAndRecovers() async throws {
        let source = ControlledSyncDataSource()
        let waits = RecordedWaits()
        let service = SyncService(
            apiClient: source,
            waitForPollingInterval: { interval in await waits.record(interval) }
        )
        service.pollingInterval = 2
        defer { service.stopPolling() }

        service.startPolling()

        for _ in 0..<4 {
            let request = await source.nextRequest()
            source.fail(request, with: URLError(.cannotConnectToHost))
        }

        let recovered = await source.nextRequest()
        source.resolve(recovered, with: try syncData(rid: 5, state: "downloading", downloadSpeed: 1))

        // Waited for rather than read directly: the fifth interval is only recorded
        // once the loop has applied the successful response and come back around.
        let recorded = await waits.first(5)
        #expect(recorded == [5, 15, 30, 60, 2])
        #expect(service.lastError == nil)
    }

    private func syncData(rid: Int, state: String, downloadSpeed: Int64) throws -> SyncMainData {
        let json = """
        {
          "rid": \(rid),
          "full_update": true,
          "torrents": {
            "example": {
              "name": "Example Download",
              "progress": \(state == "uploading" ? "1" : "0.5"),
              "state": "\(state)"
            }
          },
          "server_state": {
            "dl_info_speed": \(downloadSpeed)
          }
        }
        """
        return try JSONDecoder().decode(SyncMainData.self, from: Data(json.utf8))
    }
}

@MainActor
private final class ControlledSyncDataSource: SyncDataFetching {
    struct Request: Sendable {
        let id: Int
        let rid: Int
    }

    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<SyncMainData, Error>] = [:]
    private var queuedRequests: [Request] = []
    private var requestWaiter: CheckedContinuation<Request, Never>?

    func syncMainData(rid: Int) async throws -> SyncMainData {
        let request = Request(id: nextRequestID, rid: rid)
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            if let requestWaiter {
                self.requestWaiter = nil
                requestWaiter.resume(returning: request)
            } else {
                queuedRequests.append(request)
            }
        }
    }

    func nextRequest() async -> Request {
        if !queuedRequests.isEmpty {
            return queuedRequests.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    func resolve(_ request: Request, with data: SyncMainData) {
        let continuation = pending.removeValue(forKey: request.id)
        continuation?.resume(returning: data)
    }

    func fail(_ request: Request, with error: Error) {
        let continuation = pending.removeValue(forKey: request.id)
        continuation?.resume(throwing: error)
    }
}

/// Records the intervals the polling loop asks to wait for and lets a test await a
/// given number of them, so the assertion cannot run before the loop has produced them.
private actor RecordedWaits {
    private var intervals: [TimeInterval] = []
    private var waiter: (count: Int, continuation: CheckedContinuation<[TimeInterval], Never>)?

    func record(_ interval: TimeInterval) {
        intervals.append(interval)
        if let waiter, intervals.count >= waiter.count {
            self.waiter = nil
            waiter.continuation.resume(returning: intervals)
        }
    }

    func first(_ count: Int) async -> [TimeInterval] {
        if intervals.count >= count {
            return Array(intervals.prefix(count))
        }
        let all = await withCheckedContinuation { continuation in
            waiter = (count, continuation)
        }
        return Array(all.prefix(count))
    }
}
