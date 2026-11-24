import Foundation
import Testing
@testable import Trawl

/// Issues are grouped by cause, read from Sonarr's and Radarr's own messages, so
/// each cause's one fix can be offered once. These pin the reading, the ordering,
/// and the undo window on the destructive fixes.
@Suite("Import issue triage")
@MainActor
struct ImportIssueTriageTests {
    private static func cause(_ message: String, state: String? = "importPending") -> ImportIssueCause {
        ImportIssueTriage.cause(messages: [message], trackedDownloadState: state)
    }

    @Test("Each family of Sonarr and Radarr messages reads as its cause")
    func messagesReadAsCauses() {
        #expect(Self.cause("Import failed, path does not exist or is not accessible by Sonarr: /downloads/tv") == .path)
        #expect(Self.cause("Download client qBittorrent places downloads in /data but this directory does not appear to exist inside the container. Review your remote path mappings") == .path)
        #expect(Self.cause("Not an upgrade for existing episode file(s). Existing quality: WEBDL-1080p") == .alreadyHave)
        #expect(Self.cause("Episode file already imported at 2026-11-20") == .alreadyHave)
        #expect(Self.cause("Has the same filesize as existing file") == .alreadyHave)
        #expect(Self.cause("Found matching series via grab history, but release was matched to series by ID. Automatic import is not possible.") == .cantMatch)
        #expect(Self.cause("Unknown Series") == .cantMatch)
        #expect(Self.cause("No files found are eligible for import in /downloads/x") == .path)
        #expect(Self.cause("Unable to determine if file is a sample") == .badRelease)
        #expect(Self.cause("One or more episodes expected in this release were not imported or missing") == .badRelease)
        #expect(Self.cause("The download is stalled with no connections", state: "downloading") == .deadDownload)
        #expect(Self.cause("", state: "failedPending") == .deadDownload)
        #expect(Self.cause("Something Trawl has never seen") == .other)
    }

    /// Sonarr's and Radarr's own wording, taken from their source. Each family
    /// lands in the cause whose fix suits it - in particular nothing that says
    /// "failed" or "existing" about a folder problem is offered a blocklist.
    @Test("Messages as Sonarr and Radarr word them read as the right cause", arguments: [
        ("[/data/tv/x] is not a valid local path. You may need a Remote Path Mapping.", ImportIssueCause.path),
        ("Failed to import episode, Root folder missing.", .path),
        ("Failed to import movie due to permission issues.", .path),
        ("Failed to import movie, unable to move existing file to the Recycle Bin.", .path),
        ("Not a quality revision upgrade for existing episode file(s)", .alreadyHave),
        ("Not an upgrade for existing movie file. Existing quality: Bluray-1080p. New Quality WEBDL-720p.", .alreadyHave),
        ("Movie has already been imported", .alreadyHave),
        ("Episode file on disk contains more episodes than this file contains", .alreadyHave),
        ("Failed to import episode, Destination already exists.", .alreadyHave),
        ("Episodes [3, 4] were unexpected considering the S01 folder name", .cantMatch),
        ("Movie title mismatch, automatic import is not possible. Manual Import required.", .cantMatch),
        ("Unable to import automatically, found multiple series: A, B", .cantMatch),
        ("Single episode file contains all episodes in seasons. Review file name or manually import", .cantMatch),
        ("File (x.mkv) is not linked to any episodes", .cantMatch),
        ("Unable to find series from title", .cantMatch),
        ("Episode 5 was not found in the grabbed release: Show.S01", .badRelease),
        ("RAR file detected, will require manual cleanup", .badRelease),
        ("Caution: Found executable file with extension: '.exe'", .badRelease),
        ("Invalid video file, filename starts with '._'", .badRelease),
        ("No audio tracks detected", .badRelease),
        ("Partial season packs are not supported", .badRelease),
        ("The download is stalled with no connections", .deadDownload),
        ("Failed to import episode", .other),
        ("File is still being unpacked", .other),
        ("Episode has a TBA title and recently aired", .other),
        ("qBittorrent is reporting an error", .other)
    ])
    func sourceWording(message: String, expected: ImportIssueCause) {
        #expect(Self.cause(message) == expected)
    }

    // MARK: - Captured from live servers

    /// Recorded 24 November 2026 from Sonarr 4.0.20 and Radarr 7.0.3 importing from
    /// qBittorrent 5.3.0 into a folder the *arr couldn't see, plus a series it
    /// didn't know. The path problem never says "path": it says no files are
    /// eligible.
    @Test("Live import failures read as a path problem and a title it couldn't match")
    func liveImportFailures() throws {
        let noFiles = try Self.decode(#"{"id":1355986786,"title":"The.Office.US.S01E02.720p.WEB-DL.x264-TRAWLTEST","status":"completed","trackedDownloadStatus":"warning","trackedDownloadState":"importPending","statusMessages":[{"title":"The.Office.US.S01E02.720p.WEB-DL.x264-TRAWLTEST.mkv","messages":["No files found are eligible for import in /tmp/trawltest/The.Office.US.S01E02.720p.WEB-DL.x264-TRAWLTEST.mkv"]}],"downloadId":"47970DB1E2F4948C459BF7A9EDC36D58A8BF0A67","protocol":"torrent","downloadClient":"Trawl Import Test qB","outputPath":"/tmp/trawltest/The.Office.US.S01E02.720p.WEB-DL.x264-TRAWLTEST.mkv","seriesId":2,"episodeId":63,"seasonNumber":1}"#)
        let mismatch = try Self.decode(#"{"id":1173222917,"title":"Totally.Unknown.Show.S02E05.720p.HDTV-TRAWLTEST","status":"completed","trackedDownloadStatus":"warning","trackedDownloadState":"importBlocked","statusMessages":[{"title":"Totally.Unknown.Show.S02E05.720p.HDTV-TRAWLTEST.mkv","messages":["Series title mismatch; automatic import is not possible. Check the download troubleshooting entry on the wiki for common causes."]}],"downloadId":"9B1C0347BB5DB2A3215E5533DF91E92FFA8D300D","protocol":"torrent","downloadClient":"Trawl Import Test qB","outputPath":"/tmp/trawltest/Totally.Unknown.Show.S02E05.720p.HDTV-TRAWLTEST.mkv"}"#)

        #expect(noFiles.isImportIssueQueueItem)
        #expect(mismatch.isImportIssueQueueItem, "importBlocked is an issue too.")
        #expect(ImportIssueGroup.cause(of: Self.row(noFiles)) == .path)
        #expect(ImportIssueGroup.cause(of: Self.row(mismatch)) == .cantMatch)
    }

    /// The same capture while qBittorrent couldn't write its folder: the problem
    /// is only in `status` and `errorMessage`, with `trackedDownloadStatus` "ok".
    @Test("A download the client errored on carries its message and reaches Issues unless it's still moving")
    func liveClientError() throws {
        let errored = try Self.decode(#"{"id":339486936,"title":"The.Matrix.1999.1080p.BluRay.x264-TRAWLTEST.mkv","status":"warning","trackedDownloadStatus":"ok","trackedDownloadState":"downloading","statusMessages":[],"errorMessage":"qBittorrent is reporting an error","downloadId":"F77DC2AA247A305B62B114CA985AB157B79748CA","protocol":"torrent","downloadClient":"Trawl Import Test qB","movieId":3}"#)

        #expect(!errored.isImportIssueQueueItem)
        #expect(errored.reportsDownloadClientProblem)
        #expect(errored.primaryStatusMessage == "qBittorrent is reporting an error")
        #expect(ImportIssueTriage.messages(of: errored) == ["qBittorrent is reporting an error"])

        let erroredTorrent = try Self.torrent(state: "error")
        let stalledTorrent = try Self.torrent(state: "stalledDL")
        #expect(DownloadsViewModel.needsAttention(errored, linkedTorrent: erroredTorrent, linkedSABJob: nil))
        #expect(!DownloadsViewModel.needsAttention(errored, linkedTorrent: stalledTorrent, linkedSABJob: nil),
                "A torrent stalled for a moment stays in Active rather than flickering into Issues.")
        #expect(DownloadsViewModel.needsAttention(errored, linkedTorrent: nil, linkedSABJob: nil),
                "With no client to ask, the *arr's word stands.")
    }

    @Test("A release name in the message's title doesn't read as a cause")
    func titlesAreIgnored() throws {
        let item = try Self.queueItem(id: 1, title: "Show.S01E01.1080p-RARBG.mkv", message: "Something Trawl has never seen")
        #expect(ImportIssueGroup.cause(of: item) == .other)
    }

    @Test("Groups run path first, then by cause, larger first within a cause rank")
    func groupOrder() throws {
        let items = [
            try Self.queueItem(id: 1, message: "Not an upgrade for existing episode file(s)"),
            try Self.queueItem(id: 2, message: "Unknown Series"),
            try Self.queueItem(id: 3, message: "Not an upgrade for existing episode file(s)"),
            try Self.queueItem(id: 4, message: "Import failed, path does not exist or is not accessible by Sonarr: /x")
        ]
        let groups = ImportIssueGroup.groups(items)
        #expect(groups.map(\.cause) == [.path, .alreadyHave, .cantMatch])
        #expect(groups[1].items.count == 2)
        #expect(groups[1].fixableQueueItems.count == 2)
    }

    @Test("A destructive fix waits for Undo, and an undone fix never runs")
    func destructiveFixWaitsForUndo() async throws {
        let model = DownloadsViewModel()
        let manager = ArrServiceManager()
        let group = ImportIssueGroup(cause: .alreadyHave, items: [try Self.queueItem(id: 7, message: "Not an upgrade")])

        model.issueFixUndoWindow = .seconds(3_600)
        var finished = false
        let held = model.applyFix(to: group, serviceManager: manager) { _, _ in finished = true }
        #expect(model.scheduledIssueFix == ScheduledImportIssueFix(cause: .alreadyHave, count: 1))
        model.undoIssueFix()
        await held?.value
        #expect(model.scheduledIssueFix == nil)
        #expect(!finished, "An undone fix must not run.")

        // With no Sonarr connected the removal reports why rather than claiming success.
        model.issueFixUndoWindow = .zero
        var outcome: (Int, String?)?
        let sent = model.applyFix(to: group, serviceManager: manager) { outcome = ($0, $1) }
        await sent?.value
        #expect(outcome?.0 == 0)
        #expect(outcome?.1 != nil)
        #expect(model.workingIssueCauses.isEmpty)
    }

    private static func decode(_ json: String) throws -> ArrQueueItem {
        try JSONDecoder().decode(ArrQueueItem.self, from: Data(json.utf8))
    }

    private static func row(_ item: ArrQueueItem) -> DownloadListItem {
        .arrQueue(item: item, source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: nil)
    }

    private static func torrent(state: String) throws -> Torrent {
        let json = """
        {
          "hash": "f77dc2aa247a305b62b114ca985ab157b79748ca", "name": "The.Matrix", "size": 1000, "progress": 1,
          "dlspeed": 0, "upspeed": 0, "priority": 1, "num_seeds": 0, "num_leechs": 0,
          "ratio": 0, "eta": 0, "state": "\(state)", "category": "radarr", "tags": "",
          "added_on": 0, "completion_on": 0, "save_path": "/downloads",
          "downloaded_session": 0, "uploaded_session": 0, "amount_left": 0, "total_size": 1000,
          "seq_dl": false, "f_l_piece_prio": false
        }
        """
        return try JSONDecoder().decode(Torrent.self, from: Data(json.utf8))
    }

    private static func queueItem(id: Int, title: String? = nil, message: String) throws -> DownloadListItem {
        var status: [String: Any] = ["messages": [message]]
        if let title { status["title"] = title }
        let object: [String: Any] = [
            "id": id, "title": "Release \(id)", "status": "completed",
            "trackedDownloadStatus": "warning", "trackedDownloadState": "importPending",
            "statusMessages": [status], "downloadId": "hash\(id)", "seriesId": 1, "episodeId": id
        ]
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: JSONSerialization.data(withJSONObject: object))
        return .arrQueue(item: item, source: .sonarr, linkedTorrent: nil, linkedSABJob: nil, instance: nil)
    }
}
