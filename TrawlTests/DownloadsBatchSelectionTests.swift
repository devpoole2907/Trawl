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
    private static func torrent(
        hash: String,
        name: String = "Example",
        state: String = "downloading"
    ) throws -> Torrent {
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
          "state": "\(state)",
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

    private static func sabJob(
        id: String = "SABnzbd_nzo_1",
        status: String = "Downloading"
    ) throws -> SABnzbdJob {
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

    private static func arrQueueItem(status: String? = nil) throws -> ArrQueueItem {
        let statusField = status.map { ", \"status\": \"\($0)\"" } ?? ""
        let json = """
        { "id": 1, "title": "Example", "size": 1000, "sizeleft": 500, "movieId": 7\(statusField) }
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

    // MARK: - Linking a detail screen's queue row to the live download

    /// The same resolution question the rows above ask, asked from a movie or series
    /// detail instead: `arrDetailLinkedTorrent` is what turns a static "Downloading"
    /// row into the live progress card. When it misses there is no error - the card
    /// simply never appears, and the screen looks like it has always looked.
    ///
    /// Casing is the whole risk. qBittorrent reports lowercase hashes and Arr stores
    /// whatever the grab handed it, so an exact dictionary hit is only the lucky path.
    @Test("A detail row finds its torrent whatever case the hash arrived in")
    func detailQueueRowLinksItsTorrentAcrossCasing() throws {
        let lower = try Self.torrent(hash: "abc123def", name: "Lowercase Hash")
        let upper = try Self.torrent(hash: "FFEE0011", name: "Uppercase Hash")
        let torrents = [lower.hash: lower, upper.hash: upper]

        // Exact, and the same hash in the other case.
        #expect(arrDetailLinkedTorrent(for: "abc123def", in: torrents)?.name == "Lowercase Hash")
        #expect(arrDetailLinkedTorrent(for: "ABC123DEF", in: torrents)?.name == "Lowercase Hash")
        #expect(arrDetailLinkedTorrent(for: "ffee0011", in: torrents)?.name == "Uppercase Hash")

        // A download this client has never heard of stays unlinked rather than
        // borrowing the first row in the dictionary.
        #expect(arrDetailLinkedTorrent(for: "not-a-hash", in: torrents) == nil)
        #expect(arrDetailLinkedTorrent(for: nil, in: torrents) == nil)
        #expect(arrDetailLinkedTorrent(for: "", in: torrents) == nil)
    }

    /// SABnzbd's counterpart. Arr keeps the `nzo_id` in `downloadId`, and a value
    /// that arrived with surrounding whitespace still names the same job.
    @Test("A detail row finds its SABnzbd job across casing and padding")
    func detailQueueRowLinksItsSABJob() throws {
        let job = try Self.sabJob(id: "SABnzbd_nzo_ax12")
        let other = try Self.sabJob(id: "SABnzbd_nzo_zz99")

        #expect(arrDetailLinkedSABJob(for: "SABnzbd_nzo_ax12", in: [job, other])?.id == job.id)
        #expect(arrDetailLinkedSABJob(for: "sabnzbd_nzo_AX12", in: [job, other])?.id == job.id)
        #expect(arrDetailLinkedSABJob(for: "  SABnzbd_nzo_ax12  ", in: [job, other])?.id == job.id)

        #expect(arrDetailLinkedSABJob(for: "SABnzbd_nzo_none", in: [job, other]) == nil)
        #expect(arrDetailLinkedSABJob(for: "   ", in: [job, other]) == nil)
        #expect(arrDetailLinkedSABJob(for: nil, in: [job, other]) == nil)
    }

    /// Whether the "Current Download" card appears on a movie or series at all.
    ///
    /// The row is Arr's *view* of a download running elsewhere, and Arr is the last to
    /// know: it still lists a grab as downloading while qBittorrent has it paused, and
    /// still lists one as importing while SABnzbd is unpacking. So the live client
    /// wins whenever there is one to ask, and Arr's own flag is the fallback. Getting
    /// it wrong is silent both ways - no progress card while a download runs, or a
    /// finished download that never stops claiming to be active.
    @Test("A linked torrent decides whether the download card is live, not the queue row")
    func activeQueueItemPrefersTheLinkedTorrentsState() throws {
        let item = try Self.arrQueueItem()

        for state in ["downloading", "stalledDL", "queuedDL", "metaDL"] {
            let torrent = try Self.torrent(hash: "abc", state: state)
            #expect(
                arrDetailIsActiveQueueItem(item, linkedTorrent: torrent),
                "\(state) is a downloading state; the card should be live."
            )
        }

        for state in ["pausedDL", "uploading", "error", "missingFiles"] {
            let torrent = try Self.torrent(hash: "abc", state: state)
            #expect(
                arrDetailIsActiveQueueItem(item, linkedTorrent: torrent) == false,
                "\(state) is not downloading; the card should not claim it is."
            )
        }
    }

    /// SABnzbd's side. A usenet grab that is queued, paused or post-processing is
    /// still *this* download's business - the comment on the production side says so
    /// explicitly, because a grab that fell out of both the download card and the
    /// import-issues card would vanish from the screen entirely.
    @Test("A SABnzbd job counts as live while it is queued, paused or post-processing")
    func activeQueueItemAcceptsEverySABnzbdWorkingState() throws {
        let item = try Self.arrQueueItem()

        for status in ["Queued", "Downloading", "Paused", "Repairing", "Extracting", "Verifying"] {
            let job = try Self.sabJob(status: status)
            #expect(
                arrDetailIsActiveQueueItem(item, linkedTorrent: nil, linkedSABJob: job),
                "\(status) is work in progress; the download card should stay."
            )
        }

        for status in ["Completed", "Failed"] {
            let job = try Self.sabJob(status: status)
            #expect(
                arrDetailIsActiveQueueItem(item, linkedTorrent: nil, linkedSABJob: job) == false,
                "\(status) is finished; it belongs to the import-issues card or to nothing."
            )
        }
    }

    /// With nothing linked - the window between Arr grabbing a release and the client
    /// poll catching up - Arr's own status is all there is to go on.
    @Test("With no live client to ask, the queue row's own status decides")
    func activeQueueItemFallsBackToTheQueueRow() throws {
        let downloading = try Self.arrQueueItem(status: "downloading")
        #expect(arrDetailIsActiveQueueItem(downloading, linkedTorrent: nil, linkedSABJob: nil))

        // Arr's other states are somebody else's card: an import that is pending or
        // has failed belongs to the import-issues section, not to a progress bar.
        for status in ["completed", "importPending", "failed", "warning"] {
            let item = try Self.arrQueueItem(status: status)
            #expect(
                arrDetailIsActiveQueueItem(item, linkedTorrent: nil, linkedSABJob: nil) == false,
                "\(status) is not a download in progress."
            )
        }

        // A linked torrent still wins over a job that matched the same id.
        let torrent = try Self.torrent(hash: "abc", state: "pausedDL")
        let job = try Self.sabJob(status: "Downloading")
        #expect(
            arrDetailIsActiveQueueItem(downloading, linkedTorrent: torrent, linkedSABJob: job) == false,
            "The torrent is the download; a job that happened to match its id must not overrule it."
        )
    }

    /// A torrent grab and a usenet grab can be in the queue at once, and the two
    /// lookups are given the same `downloadId` in turn. Neither may answer for the
    /// other's download: a torrent hash that happens to match an `nzo_id` would put
    /// someone else's progress bar on the card.
    @Test("The torrent and SABnzbd lookups never answer for each other")
    func theTwoLookupsStayInTheirOwnClient() throws {
        let shared = "COLLIDING-ID"
        let torrent = try Self.torrent(hash: shared, name: "Torrent Side")
        let job = try Self.sabJob(id: shared)

        #expect(arrDetailLinkedTorrent(for: shared, in: [torrent.hash: torrent])?.name == "Torrent Side")
        #expect(arrDetailLinkedTorrent(for: shared, in: [:]) == nil)
        #expect(arrDetailLinkedSABJob(for: shared, in: [job])?.id == shared)
        #expect(arrDetailLinkedSABJob(for: shared, in: []) == nil)
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
