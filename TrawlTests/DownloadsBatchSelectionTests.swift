//
//  DownloadsBatchSelectionTests.swift
//  TrawlTests
//
//  The Downloads tab shows one list built from four different kinds of row, and a
//  batch action has to work out, per row, which client it is actually talking to.
//  Getting that wrong is silent in both directions: a row that resolves to nothing
//  gets counted as acted on, or an *arr row resolves to the wrong client and the
//  action lands on someone else's download.
//
//  These pin the resolution and the toolbar state that reads from it. Both were
//  extracted out of `DownloadsView` precisely so they could be tested without
//  standing up a view.

import Foundation
import Testing
@testable import Trawl

/// `@MainActor` for the whole suite: this project defaults its models to main-actor
/// isolation, so `Torrent`'s `Decodable` conformance and `DownloadListItem`'s
/// members are only reachable from the main actor. Marking the suite is cleaner than
/// making the model `nonisolated` purely to suit a test.
@Suite("Downloads batch selection")
@MainActor
struct DownloadsBatchSelectionTests {
    private static let decoder = JSONDecoder()

    /// Decoded from a qBittorrent payload rather than constructed field by field:
    /// the wire shape is what the app actually sees, and a hand-built value drifts
    /// silently when the model gains a field.
    private static func torrent(hash: String, name: String = "Example") throws -> Torrent {
        let json = """
        {
          "hash": "\(hash)",
          "name": "\(name)",
          "size": 1000,
          "progress": 0.5,
          "dlspeed": 0,
          "upspeed": 0,
          "priority": 1,
          "num_seeds": 2,
          "num_leechs": 1,
          "ratio": 0.5,
          "eta": 600,
          "state": "downloading",
          "category": "",
          "tags": "",
          "added_on": 0,
          "completion_on": 0,
          "save_path": "/downloads",
          "dl_session": 0,
          "up_session": 0,
          "amount_left": 500,
          "total_size": 1000,
          "seq_dl": false,
          "f_l_piece_prio": false
        }
        """
        return try decoder.decode(Torrent.self, from: Data(json.utf8))
    }

    private static func sabJob(id: String = "SABnzbd_nzo_1") throws -> SABnzbdJob {
        let json = """
        {
          "nzo_id": "\(id)",
          "filename": "Example.Job",
          "status": "Downloading",
          "timeleft": "0:10:00",
          "percentage": "50",
          "size": "1 GB",
          "sizeleft": "500 MB",
          "mb": "1024",
          "mbleft": "512"
        }
        """
        return SABnzbdJob(queueSlot: try decoder.decode(SABnzbdQueueSlot.self, from: Data(json.utf8)))
    }

    private static func arrQueueItem() throws -> ArrQueueItem {
        let json = """
        { "id": 1, "title": "Example", "size": 1000, "sizeleft": 500, "movieId": 7 }
        """
        return try decoder.decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    // MARK: - Which client a row actually names

    @Test("A torrent row resolves to its torrent")
    func torrentRowResolvesToTorrent() throws {
        let t = try Self.torrent(hash: "abc")
        #expect(DownloadListItem.torrent(t).batchTarget == .torrent(t))
    }

    @Test("A SABnzbd row resolves to its job")
    func sabRowResolvesToJob() throws {
        let job = try Self.sabJob()
        #expect(DownloadListItem.sab(job).batchTarget == .sab(job))
    }

    /// The case the whole feature turns on: an *arr queue row is that service's
    /// view of a download running elsewhere, so pausing it has to pause the thing
    /// it is a view *of*.
    @Test("An Arr queue row resolves to the download it is a view of")
    func arrQueueRowResolvesToItsLink() throws {
        let t = try Self.torrent(hash: "linked")
        let job = try Self.sabJob(id: "linked-job")
        let item = try Self.arrQueueItem()

        let viaTorrent = DownloadListItem.arrQueue(
            item: item, source: .radarr, linkedTorrent: t, linkedSABJob: nil, instance: nil
        )
        #expect(viaTorrent.batchTarget == .torrent(t))

        let viaSAB = DownloadListItem.arrQueue(
            item: item, source: .radarr, linkedTorrent: nil, linkedSABJob: job, instance: nil
        )
        #expect(viaSAB.batchTarget == .sab(job))
    }

    /// An unlinked queue row names a download Trawl cannot reach - the client that
    /// holds it is not configured, or the link could not be made. Resolving it to
    /// *something* would send the action to the wrong client.
    @Test("An unlinked Arr queue row resolves to nothing")
    func unlinkedArrQueueRowResolvesToNil() throws {
        let item = try Self.arrQueueItem()
        let row = DownloadListItem.arrQueue(
            item: item, source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: nil
        )
        #expect(row.batchTarget == nil)
    }

    /// History is a record of a finished download, not a download. A batch that
    /// counted it as acted on would report more successes than it performed.
    @Test("A history row resolves to nothing")
    func historyRowResolvesToNil() throws {
        // `HistoryItem` wraps the wire record rather than being one, so the record
        // is decoded and the row built around it.
        let json = """
        { "id": 99, "sourceTitle": "Example", "eventType": "downloadFolderImported" }
        """
        let record = try Self.decoder.decode(ArrHistoryRecord.self, from: Data(json.utf8))
        let historyItem = HistoryItem(record: record, source: .radarr)
        #expect(DownloadListItem.arrHistory(historyItem).batchTarget == nil)
    }

    // MARK: - The toolbar the selection drives

    /// Every list publishes into one coordinator, so a stale value from the
    /// previous list is a button that acts on rows that are no longer on screen.
    @Test("Resetting clears every published capability and closure")
    func resetClearsEverything() {
        let chrome = DownloadsListChrome()
        chrome.canSelect = true
        chrome.isSelecting = true
        chrome.selectedCount = 3
        chrome.totalCount = 9
        chrome.supportsRecheck = true
        chrome.supportsPauseResume = true
        chrome.beginSelecting = {}
        chrome.pauseSelected = {}
        chrome.extraActions = [
            .init(id: "x", title: "X", systemImage: "x", perform: {})
        ]

        chrome.reset()

        #expect(!chrome.canSelect)
        #expect(!chrome.isSelecting)
        #expect(chrome.selectedCount == 0)
        #expect(chrome.totalCount == 0)
        #expect(!chrome.supportsRecheck)
        #expect(!chrome.supportsPauseResume)
        #expect(chrome.beginSelecting == nil)
        #expect(chrome.pauseSelected == nil)
        #expect(chrome.extraActions.isEmpty)
    }

    @Test("Select All flips to Deselect All only when everything is selected")
    func selectAllTitleReflectsWholeSelection() {
        let chrome = DownloadsListChrome()
        chrome.totalCount = 3

        chrome.selectedCount = 0
        #expect(chrome.selectAllTitle == "Select All")
        #expect(!chrome.hasSelection)

        chrome.selectedCount = 2
        #expect(chrome.selectAllTitle == "Select All")
        #expect(chrome.hasSelection)

        chrome.selectedCount = 3
        #expect(chrome.selectAllTitle == "Deselect All")
    }

    /// An empty list must not offer "Deselect All" just because zero equals zero.
    @Test("An empty list never offers Deselect All")
    func emptyListKeepsSelectAllTitle() {
        let chrome = DownloadsListChrome()
        chrome.totalCount = 0
        chrome.selectedCount = 0
        #expect(chrome.selectAllTitle == "Select All")
    }
}

// MARK: - Active / Queue classification

/// The blended list and the client-scoped lists have to agree about what a
/// download is doing. They didn't: a blended row backed by a download client was
/// filed by the *arr's import state, which stays "downloading" while the client
/// has the job paused, so the same paused download read as Active in the blended
/// list and Queue under the SABnzbd scope.
@Suite("Downloads active/queue classification")
@MainActor
struct DownloadsSectionClassificationTests {
    private static let decoder = JSONDecoder()

    private static func sabJob(status: String, id: String = "SABnzbd_nzo_1") throws -> SABnzbdJob {
        let json = """
        {
          "nzo_id": "\(id)",
          "filename": "Example.Job",
          "status": "\(status)",
          "timeleft": "0:10:00",
          "percentage": "50",
          "size": "1 GB",
          "sizeleft": "500 MB",
          "mb": "1024",
          "mbleft": "512"
        }
        """
        return SABnzbdJob(queueSlot: try decoder.decode(SABnzbdQueueSlot.self, from: Data(json.utf8)))
    }

    private static func torrent(state: String, hash: String = "abc") throws -> Torrent {
        let json = """
        {
          "hash": "\(hash)", "name": "Example", "size": 1000, "progress": 0.5,
          "dlspeed": 0, "upspeed": 0, "priority": 1, "num_seeds": 2, "num_leechs": 1,
          "ratio": 0.5, "eta": 600, "state": "\(state)", "category": "", "tags": "",
          "added_on": 0, "completion_on": 0, "save_path": "/downloads",
          "dl_session": 0, "up_session": 0, "amount_left": 500, "total_size": 1000,
          "seq_dl": false, "f_l_piece_prio": false
        }
        """
        return try decoder.decode(Torrent.self, from: Data(json.utf8))
    }

    /// The *arr keeps reporting "downloading" because that is its import stage,
    /// not the client's transfer state.
    private static func downloadingQueueItem() throws -> ArrQueueItem {
        let json = """
        { "id": 1, "title": "Example", "size": 1000, "sizeleft": 500, "movieId": 7,
          "status": "downloading", "trackedDownloadState": "downloading" }
        """
        return try decoder.decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    private static func importingQueueItem() throws -> ArrQueueItem {
        let json = """
        { "id": 2, "title": "Example", "size": 1000, "sizeleft": 0, "movieId": 7,
          "status": "completed", "trackedDownloadState": "importing" }
        """
        return try decoder.decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    @Test("A paused SABnzbd job is waiting, whatever the Arr still calls it")
    func pausedSABJobIsWaiting() throws {
        let activity = DownloadsViewModel.activity(
            of: try Self.downloadingQueueItem(),
            linkedTorrent: nil,
            linkedSABJob: try Self.sabJob(status: "Paused")
        )
        #expect(activity == .waiting)
    }

    /// The bug in one assertion: the blended row and the SABnzbd-scoped row are
    /// the same download, so they must land in the same section.
    @Test("The blended row and the SABnzbd-scoped row agree about a paused job")
    func blendedAndScopedAgree() throws {
        let job = try Self.sabJob(status: "Paused")
        let blended = DownloadsViewModel.activity(
            of: try Self.downloadingQueueItem(),
            linkedTorrent: nil,
            linkedSABJob: job
        )
        #expect(blended == .waiting)
        #expect(DownloadsViewModel.isWaiting(job))
        #expect(!DownloadsViewModel.isActive(job))
    }

    @Test("A downloading SABnzbd job is active")
    func downloadingSABJobIsActive() throws {
        let activity = DownloadsViewModel.activity(
            of: try Self.downloadingQueueItem(),
            linkedTorrent: nil,
            linkedSABJob: try Self.sabJob(status: "Downloading")
        )
        #expect(activity == .active)
    }

    @Test("A paused torrent is waiting and a downloading one is active")
    func torrentStateDecides() throws {
        let item = try Self.downloadingQueueItem()
        #expect(
            DownloadsViewModel.activity(of: item, linkedTorrent: try Self.torrent(state: "pausedDL"), linkedSABJob: nil) == .waiting
        )
        #expect(
            DownloadsViewModel.activity(of: item, linkedTorrent: try Self.torrent(state: "downloading"), linkedSABJob: nil) == .active
        )
    }

    /// A finished client job still in the Arr's queue is being imported, and the
    /// import is the work left - so the Arr decides rather than the row falling
    /// out of both sections.
    @Test("A completed client job falls back to the Arr's own state")
    func completedClientJobFallsBackToArr() throws {
        #expect(
            DownloadsViewModel.activity(
                of: try Self.importingQueueItem(),
                linkedTorrent: nil,
                linkedSABJob: try Self.sabJob(status: "Completed")
            ) == .active
        )
        #expect(
            DownloadsViewModel.activity(
                of: try Self.importingQueueItem(),
                linkedTorrent: try Self.torrent(state: "uploading"),
                linkedSABJob: nil
            ) == .active
        )
    }

    @Test("An unlinked row is classified by the Arr alone")
    func unlinkedRowUsesArrState() throws {
        #expect(
            DownloadsViewModel.activity(of: try Self.downloadingQueueItem(), linkedTorrent: nil, linkedSABJob: nil) == .active
        )
        #expect(
            DownloadsViewModel.activity(of: try Self.queuedQueueItem(), linkedTorrent: nil, linkedSABJob: nil) == .waiting
        )
    }

    private static func queuedQueueItem() throws -> ArrQueueItem {
        let json = """
        { "id": 3, "title": "Example", "size": 1000, "sizeleft": 1000, "movieId": 7,
          "status": "queued", "trackedDownloadState": "queued" }
        """
        return try decoder.decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    /// Totality: whatever the pair of states, a row is always in exactly one of the
    /// two sections. Losing that would drop downloads off the tab entirely.
    @Test("Every combination lands in exactly one section")
    func classificationIsTotal() throws {
        let statuses = ["Downloading", "Paused", "Queued", "Completed", "Failed", "Extracting", "Repairing"]
        let items = [try Self.downloadingQueueItem(), try Self.importingQueueItem(), try Self.queuedQueueItem()]
        for item in items {
            for status in statuses {
                let activity = DownloadsViewModel.activity(
                    of: item,
                    linkedTorrent: nil,
                    linkedSABJob: try Self.sabJob(status: status)
                )
                #expect(activity == .active || activity == .waiting)
            }
        }
    }
}
