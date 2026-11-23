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
        #expect(Self.cause("No files found are eligible for import in /downloads/x") == .badRelease)
        #expect(Self.cause("Unable to determine if file is a sample") == .badRelease)
        #expect(Self.cause("One or more episodes expected in this release were not imported or missing") == .badRelease)
        #expect(Self.cause("The download is stalled with no connections", state: "downloading") == .deadDownload)
        #expect(Self.cause("", state: "failedPending") == .deadDownload)
        #expect(Self.cause("Something Trawl has never seen") == .other)
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
