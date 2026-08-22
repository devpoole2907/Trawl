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
}
