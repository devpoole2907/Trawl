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

    private static func arrQueueItem(id: Int = 1, downloadID: String? = nil, status: String? = nil) throws -> ArrQueueItem {
        let statusField = status.map { ", \"status\": \"\($0)\"" } ?? ""
        let downloadField = downloadID.map { ", \"downloadId\": \"\($0)\"" } ?? ""
        let json = """
        { "id": \(id), "title": "Example", "size": 1000, "sizeleft": 500, "movieId": 7\(statusField)\(downloadField) }
        """
        return try decoder.decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    @Test("A season pack occupies one blended row per server, while missing IDs remain separate")
    func seasonPackRowsRepresentOnePhysicalJob() throws {
        let firstServer = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr", tier: .hd)
        let secondServer = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr 4K", tier: .uhd)
        let rows = try (1...8).map { episode in
            DownloadListItem.arrQueue(
                item: try Self.arrQueueItem(id: episode, downloadID: episode.isMultiple(of: 2) ? " PACK-ID " : "pack-id"),
                source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: firstServer
            )
        } + [
            .arrQueue(item: try Self.arrQueueItem(id: 9, downloadID: "pack-id"), source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: secondServer),
            .arrQueue(item: try Self.arrQueueItem(id: 10), source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: firstServer),
            .arrQueue(item: try Self.arrQueueItem(id: 11), source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: firstServer)
        ]

        #expect(DownloadsViewModel.oneRowPerDownload(rows).map(\.id) == [rows[0].id, rows[8].id, rows[9].id, rows[10].id])
    }

    /// An import-issue record. Every one carries a *different* status-message title -
    /// the per-file name Sonarr puts there - so this fixture pins the decision that
    /// `importIssueSignature` reads the messages and not the title. Were the title
    /// counted, every episode of one pack would look like a distinct failure and the
    /// collapse below would silently do nothing.
    private static func arrIssueQueueItem(
        id: Int = 1,
        downloadID: String? = nil,
        reasons: [String],
        trackedStatus: String = "warning",
        libraryID: String? = ", \"seriesId\": 3"
    ) throws -> ArrQueueItem {
        let downloadField = downloadID.map { ", \"downloadId\": \"\($0)\"" } ?? ""
        let messages = reasons.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        { "id": \(id), "title": "Example", "size": 1000, "sizeleft": 0\(libraryID ?? ""), "trackedDownloadStatus": "\(trackedStatus)", "trackedDownloadState": "importPending"\(downloadField), "statusMessages": [{ "title": "Example.S01E\(id).mkv", "messages": [\(messages)] }] }
        """
        return try decoder.decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    private static func arrIssueQueueItem(
        id: Int = 1,
        downloadID: String? = nil,
        reason: String,
        trackedStatus: String = "warning"
    ) throws -> ArrQueueItem {
        try arrIssueQueueItem(id: id, downloadID: downloadID, reasons: [reason], trackedStatus: trackedStatus)
    }

    /// An import issue on a record naming neither a series nor a movie - the one case
    /// that cannot be routed to a resolution UI.
    private static func arrIssueQueueItemWithoutLibraryID(reason: String) throws -> ArrQueueItem {
        try arrIssueQueueItem(id: 1, downloadID: "abc", reasons: [reason], libraryID: nil)
    }

    /// The reported bug: one stuck season pack listed the same failure once per
    /// episode - eight rows, all opening the same screen, behind an attention badge
    /// reading 8.
    ///
    /// The assertion is an exact row list rather than a count, because the fix has
    /// two halves and a count would pass with either half missing. Collapsing on the
    /// download ID alone would fold `distinct` away, which is the outcome Issues was
    /// deliberately left un-collapsed to avoid.
    @Test("A season pack's repeated import failure collapses to one row, while distinct failures survive")
    func seasonPackIssueRowsCollapsePerDistinctFailure() throws {
        let server = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr", tier: .hd)
        let other = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr 4K", tier: .uhd)
        let sharedReason = "One or more episodes expected in this release were not imported"

        func row(_ item: ArrQueueItem, on instance: ArrInstanceRef = server) -> DownloadListItem {
            .arrQueue(item: item, source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: instance)
        }

        // Six episodes of one pack reporting one failure between them.
        let repeats = try (1...6).map {
            try row(Self.arrIssueQueueItem(id: $0, downloadID: "pack-id", reason: sharedReason))
        }
        // Same pack, genuinely different failure - must stay visible.
        let distinct = try row(
            Self.arrIssueQueueItem(id: 7, downloadID: "pack-id", reason: "Episode file already exists")
        )
        // The same pack ID on the other server is a different physical download.
        let otherServer = try row(
            Self.arrIssueQueueItem(id: 8, downloadID: "pack-id", reason: sharedReason),
            on: other
        )
        // No download ID: nothing shows these to be repeats of anything, so both stay.
        let unidentified = try [9, 10].map { try row(Self.arrIssueQueueItem(id: $0, reason: sharedReason)) }

        let rows = repeats + [distinct, otherServer] + unidentified

        #expect(
            DownloadsViewModel.oneRowPerIssue(rows).map(\.id)
                == [repeats[0].id, distinct.id, otherServer.id, unidentified[0].id, unidentified[1].id]
        )
    }

    // MARK: - Which screen an import-issue row opens

    /// An import issue is resolved on the film or series - Edit, Resolve, Remove,
    /// Blocklist all live there - not on the download, whose detail screen offers
    /// nothing that helps. So the row routes to the media detail.
    ///
    /// The ordering is the whole test: **even when a torrent is still behind it**. A
    /// version that checked the torrent link first compiled, ran, and looked correct
    /// on every unlinked issue, while silently sending every linked one back to the
    /// dead end.
    @Test("An import-issue row opens the media detail even with a torrent behind it")
    func importIssueRowOpensMediaDetailOverItsTorrent() throws {
        let instance = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr", tier: .hd)
        let linked = try Self.torrent(hash: "still-seeding")
        let issue = try Self.arrIssueQueueItem(id: 1, downloadID: "pack-id", reason: "Not imported")

        let row = DownloadListItem.arrQueue(
            item: issue, source: .sonarr, linkedTorrent: linked, linkedSABJob: nil, instance: instance
        )

        #expect(
            row.detailDestination
                == .arrMedia(.series(id: 3, instanceID: instance.id, scrollToImportIssues: true))
        )
    }

    /// The same row on the other chrome. `DownloadsView` pushes `arrQueueRow`'s branch
    /// on iPhone and reads `detailDestination` beside a detail column, so a change to
    /// one and not the other makes a single row open two different screens depending
    /// on the device. Both are asserted against the *same* destination value.
    @Test("An unlinked import-issue row is still routable rather than inert")
    func unlinkedImportIssueRowIsRoutable() throws {
        let instance = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr", tier: .hd)
        let issue = try Self.arrIssueQueueItem(id: 1, downloadID: "pack-id", reason: "Not imported")

        let row = DownloadListItem.arrQueue(
            item: issue, source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: instance
        )

        // Before the route existed this resolved to nil, which made the row
        // `selectionDisabled` - inert in exactly the case Issues exists for.
        #expect(row.detailDestination != nil)
        #expect(
            row.detailDestination
                == .arrMedia(.series(id: 3, instanceID: instance.id, scrollToImportIssues: true))
        )
    }

    /// A healthy queue row is unaffected: it still pairs with its client's own row so
    /// selecting either leaves the detail column showing one thing.
    @Test("A healthy Arr queue row still opens the download it is a view of")
    func healthyQueueRowStillOpensItsDownload() throws {
        let linked = try Self.torrent(hash: "downloading")
        let healthy = try Self.arrQueueItem(id: 1, downloadID: "abc", status: "downloading")

        let row = DownloadListItem.arrQueue(
            item: healthy, source: .radarr, linkedTorrent: linked, linkedSABJob: nil, instance: nil
        )

        #expect(row.detailDestination == .torrent(hash: "downloading"))
    }

    /// An import issue that names no library item cannot be routed to a resolution UI,
    /// so it falls through to the client rather than resolving to a media destination
    /// for id `nil`.
    @Test("An import issue naming no library item falls back to its client")
    func importIssueWithoutLibraryItemFallsBackToClient() throws {
        let job = try Self.sabJob(id: "nzo-1")
        let issue = try Self.arrIssueQueueItemWithoutLibraryID(reason: "Not imported")

        let row = DownloadListItem.arrQueue(
            item: issue, source: .sonarr, linkedTorrent: nil, linkedSABJob: job, instance: nil
        )

        #expect(row.detailDestination == .sabJob(id: "nzo-1", name: job.name))
    }

    /// Radarr's queue records carry `movieId`, Sonarr's carry `seriesId`, and the
    /// destination has to be the matching case - a movie id routed to `.series` opens
    /// a different library's item with the same small integer.
    @Test("A Radarr import issue routes to the movie case")
    func radarrImportIssueRoutesToMovie() throws {
        let instance = ArrInstanceRef(id: UUID(), serviceType: .radarr, displayName: "Radarr", tier: .hd)
        let issue = try Self.arrQueueItem(id: 1, downloadID: "abc", status: "importPending")

        let row = DownloadListItem.arrQueue(
            item: issue, source: .radarr, linkedTorrent: nil, linkedSABJob: nil, instance: instance
        )

        // `arrQueueItem`'s fixture carries movieId 7 and no seriesId.
        #expect(
            row.detailDestination
                == .arrMedia(.movie(id: 7, instanceID: instance.id, scrollToImportIssues: true))
        )
    }

    // MARK: - What counts as the same import issue

    /// The signature decides which rows collapse. These pin the three decisions it
    /// encodes, because each is invisible in the rendered list until it is wrong.
    @Test("Two records of one failure share a signature regardless of their file titles")
    func identicalFailuresShareASignature() throws {
        let first = try Self.arrIssueQueueItem(id: 1, downloadID: "pack", reason: "Not imported")
        let second = try Self.arrIssueQueueItem(id: 2, downloadID: "pack", reason: "Not imported")

        // The fixture gives each a different per-file status title. Counting it would
        // make every episode of a pack distinct and the collapse a no-op.
        #expect(first.importIssueSignature == second.importIssueSignature)
    }

    @Test("Different failure text means different signatures")
    func differentFailuresDifferInSignature() throws {
        let missing = try Self.arrIssueQueueItem(id: 1, downloadID: "pack", reason: "Not imported")
        let exists = try Self.arrIssueQueueItem(id: 2, downloadID: "pack", reason: "File already exists")

        #expect(missing.importIssueSignature != exists.importIssueSignature)
    }

    /// Arr does not promise an order for `statusMessages`, and two polls of one stuck
    /// pack can return the same reasons in a different order. A signature that joined
    /// them as they arrived would make one issue look like two on alternate refreshes,
    /// which reads as the list flickering between 1 and 2 rows.
    @Test("Status message order does not change a signature")
    func signatureIsOrderIndependent() throws {
        let forwards = try Self.arrIssueQueueItem(id: 1, downloadID: "p", reasons: ["alpha", "beta"])
        let backwards = try Self.arrIssueQueueItem(id: 2, downloadID: "p", reasons: ["beta", "alpha"])

        #expect(forwards.importIssueSignature == backwards.importIssueSignature)
    }

    /// Two records with no status messages at all are still distinguished by how Arr
    /// described the failure, so a warning does not collapse onto an error.
    @Test("Tracked status separates a warning from an error")
    func signatureSeparatesWarningFromError() throws {
        let warning = try Self.arrIssueQueueItem(id: 1, downloadID: "p", reason: "same", trackedStatus: "warning")
        let error = try Self.arrIssueQueueItem(id: 2, downloadID: "p", reason: "same", trackedStatus: "error")

        #expect(warning.importIssueSignature != error.importIssueSignature)
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
