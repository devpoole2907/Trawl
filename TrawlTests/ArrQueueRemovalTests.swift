import Foundation
import Network
import SwiftData
import Testing
@testable import Trawl

/// What the queue screen *shows* after a removal, as opposed to what
/// `deleteQueueItem` puts on the wire - the contract for that lives in
/// `ArrAPIClientContractTests`' "Queue deletion" section.
///
/// The property under test is that the list cannot lie about what happened.
/// `ArrLibraryViewModel.removeQueueItem` drops the item from its local `queue` array
/// after the delete returns, so if a rejection were treated as success the row would
/// vanish from the screen while the download carried on in the client - the user is
/// then told something was removed that was not. That is the same failure shape as
/// N-03 (a rejected SABnzbd key silently emptying the Downloads tab), which is why it
/// is worth pinning here rather than trusting the happy path.
///
/// `queue` is `private(set)`, so these tests cannot install it: it is populated by
/// running the real `loadQueue()` against the fixture, which is the intended way round
/// - the removal is then exercised against state the production path produced.
@Suite("Arr queue removal", .serialized)
@MainActor
struct ArrQueueRemovalTests {

    @Test("A rejected removal keeps the item on screen and surfaces the failure")
    func rejectedRemovalKeepsTheItem() async throws {
        let server = try await ArrIndexerFixtureServer(label: "queue-remove-reject") { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v3/queue"):
                return .json(arrQueueRemovalPage)
            case ("DELETE", "/api/v3/queue/42"):
                return .failure(status: 500, message: "Download client unreachable")
            default:
                return arrIndexerDefaultResponse(for: request)
            }
        }
        defer { server.stop() }

        try await withConnectedArrInstances([
            ArrIndexerFixtureInstance(server, .sonarr, "Queue Fixture")
        ]) { manager, _ in
            let viewModel = SonarrViewModel(serviceManager: manager)
            await viewModel.loadQueue()
            #expect(viewModel.queue.map(\.id) == [42, 43])

            let removed = await viewModel.removeQueueItem(id: 42)

            #expect(removed == false)
            #expect(
                viewModel.queue.map(\.id) == [42, 43],
                "A rejected removal must leave the queue exactly as it was - dropping the row would tell the user a download was removed while it is still running in the client."
            )
            #expect(
                viewModel.error != nil,
                "The failure must be surfaced rather than swallowed."
            )
            #expect(server.requestCount(method: "DELETE", path: "/api/v3/queue/42") == 1)
        }
    }

    @Test("An accepted removal drops exactly that item and leaves the rest of the queue")
    func acceptedRemovalDropsOnlyThatItem() async throws {
        let server = try await ArrIndexerFixtureServer(label: "queue-remove-accept") { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v3/queue"):
                return .json(arrQueueRemovalPage)
            case ("DELETE", "/api/v3/queue/42"):
                return .json("{}")
            default:
                return arrIndexerDefaultResponse(for: request)
            }
        }
        defer { server.stop() }

        try await withConnectedArrInstances([
            ArrIndexerFixtureInstance(server, .sonarr, "Queue Fixture")
        ]) { manager, _ in
            let viewModel = SonarrViewModel(serviceManager: manager)
            await viewModel.loadQueue()
            #expect(viewModel.queue.map(\.id) == [42, 43])

            let removed = await viewModel.removeQueueItem(id: 42)

            #expect(removed == true)
            #expect(
                viewModel.queue.map(\.id) == [43],
                "Only the removed item should leave the queue - clearing more would blank rows whose downloads are untouched."
            )
            #expect(viewModel.error == nil)
        }
    }
}

/// Two records, so "the right one was removed" is distinguishable from "the queue was
/// cleared". Only `id` is required by `ArrQueueItem`; the rest is realistic filler
/// rather than anything under test.
///
/// File scope rather than a static on the suite: the suite is `@MainActor`, so a static
/// would inherit that isolation and could not be read from the fixture server's
/// `@Sendable` router closure.
private let arrQueueRemovalPage = """
{
  "page": 1,
  "pageSize": 250,
  "totalRecords": 2,
  "records": [
    {"id": 42, "title": "Some.Release.S01E01", "status": "downloading", "downloadId": "abc123"},
    {"id": 43, "title": "Another.Release.S01E02", "status": "downloading", "downloadId": "def456"}
  ]
}
"""

/// What a swipe or context-menu removal asks before it deletes the download.
@Suite("Queue removal confirmation wording")
struct QueueRemovalConfirmationTests {
    private func item(_ json: String) throws -> ArrQueueItem {
        try JSONDecoder().decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    @Test("A plain removal names the item, says the files go, and how far along it was")
    func plainRemovalSaysTheFilesGo() throws {
        let queued = try item(#"{"id":7,"title":"Some.Show.S01E01","size":1000,"sizeleft":130}"#)
        let copy = DownloadsViewModel.removalConfirmation(for: queued, source: .sonarr, blocklist: false, searchAgain: false)
        #expect(copy.title == "Remove “Some.Show.S01E01”?")
        #expect(copy.confirmLabel == "Remove")
        #expect(copy.message == "Sonarr removes it from the download client and deletes what's downloaded so far. It's 87% done. This can't be undone.")
    }

    @Test("Blocklisting and searching again say what else happens, each in its own words")
    func blocklistAndSearchAgainSayWhatElseHappens() throws {
        let untitled = try item(#"{"id":8}"#)
        let blocklisted = DownloadsViewModel.removalConfirmation(for: untitled, source: .radarr, blocklist: true, searchAgain: false)
        #expect(blocklisted.title == "Remove this download?")
        #expect(blocklisted.confirmLabel == "Blocklist & Remove")
        // No size reported, so no percentage is invented.
        #expect(blocklisted.message == "Radarr removes it from the download client and deletes what's downloaded so far. This release won't be grabbed again. This can't be undone.")

        let searched = DownloadsViewModel.removalConfirmation(for: untitled, source: .radarr, blocklist: true, searchAgain: true)
        #expect(searched.confirmLabel == "Blocklist & Search Again")
        #expect(searched.message.contains("This release won't be grabbed again, and Radarr looks for another."))
    }
}

