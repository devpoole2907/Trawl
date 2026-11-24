import SwiftUI

/// Why a download needs fixing, read from what Sonarr or Radarr said about it.
///
/// The Issues list used to be one row per download: open each, read the service's
/// message, work out what it means, pick an action. Across a backlog those messages
/// fall into a handful of causes with one fix each, so Issues groups by cause and
/// offers that fix once per group. Ordered by how much one fix clears: a path
/// problem first, because a single setting usually causes every download below it.
nonisolated enum ImportIssueCause: String, CaseIterable, Identifiable, Sendable {
    case path
    case alreadyHave
    case badRelease
    case deadDownload
    case cantMatch
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .path: "Can’t reach the download folder"
        case .alreadyHave: "Already in your library"
        case .badRelease: "Bad release"
        case .deadDownload: "Download failed"
        case .cantMatch: "Couldn’t tell what this is"
        case .other: "Something else"
        }
    }

    /// One line on what happened and what the fix does.
    var explanation: String {
        switch self {
        case .path:
            "Sonarr or Radarr can’t find the files where the download client says it saved them. Usually a remote path mapping or a permission."
        case .alreadyHave:
            "Not an upgrade on what you already have. Removing deletes the download, not your library."
        case .badRelease:
            "Files are missing, or it holds only a sample or archive. Blocklisting stops the same release being grabbed again."
        case .deadDownload:
            "The download never finished. Blocklisting lets the next search pick a different release."
        case .cantMatch:
            "The file didn’t match a series or film. Pick the title for each in Manual Import."
        case .other:
            "Trawl doesn’t recognise these messages. Open each one to see what Sonarr or Radarr said."
        }
    }

    var systemImage: String {
        switch self {
        case .path: "folder.badge.questionmark"
        case .alreadyHave: "checkmark.circle"
        case .badRelease: "xmark.octagon"
        case .deadDownload: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        case .cantMatch: "questionmark.circle"
        case .other: "ellipsis.circle"
        }
    }

    var fix: ImportIssueFix {
        switch self {
        case .path: .checkAgain
        case .alreadyHave: .remove
        case .badRelease, .deadDownload: .blocklistAndSearch
        case .cantMatch, .other: .none
        }
    }

    /// Sorts the groups: lower first.
    var priority: Int {
        switch self {
        case .path: 0
        case .alreadyHave: 1
        case .badRelease: 2
        case .deadDownload: 3
        case .cantMatch: 4
        case .other: 5
        }
    }
}

nonisolated enum ImportIssueFix: Sendable, Equatable {
    /// Ask the services to look at their finished downloads again - after a path
    /// mapping or permission is fixed, the imports go through on their own.
    case checkAgain
    /// Remove from the queue and the download client.
    case remove
    /// Remove, blocklist the release, and search for another.
    case blocklistAndSearch
    case none

    /// Destructive fixes wait out an undo window before anything is sent.
    var isDestructive: Bool { self == .remove || self == .blocklistAndSearch }
}

nonisolated enum ImportIssueTriage {
    /// The cause behind a queue record's messages.
    ///
    /// Keyword matching rather than exact strings: Sonarr and Radarr word these
    /// differently and change the wording between versions. The phrases are taken
    /// from their source (Sonarr 4.0.16, Radarr develop, November 2026) and checked
    /// against a live Sonarr 4.0.20 and Radarr 7.0.3; anything unmatched falls to
    /// `.other`, which keeps the per-row view rather than guessing. Order matters:
    /// several messages say "failed" or "existing" about a problem that isn't
    /// a dead download or a duplicate.
    static func cause(messages: [String], trackedDownloadState: String?) -> ImportIssueCause {
        let text = messages.joined(separator: " ").lowercased()
        func mentions(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) } }

        // Waiting on something that clears by itself: not a cause with a fix.
        if mentions(["still being unpacked", "locked file", "recently aired", "thexem"]) {
            return .other
        }
        // "No files found are eligible for import in <path>" is what a live Sonarr
        // and Radarr report when they can't see the client's folder - the usual
        // Docker path mismatch - not just when a release holds no video. It reads
        // as a path problem so its fix is Check Again, never a blocklist.
        if mentions([
            "path does not exist", "not accessible", "not a valid local path", "remote path",
            "does not appear to exist inside the container", "no files found are eligible",
            "access to the path", "permission", "unauthorizedaccess", "directory does not exist",
            "root folder missing", "recycle bin"
        ]) {
            return .path
        }
        if mentions([
            "not an upgrade", "not a quality revision upgrade", "already imported", "already been imported",
            "same filesize", "same file size", "existing file", "file on disk contains more",
            "destination already exists", "not a custom format upgrade"
        ]) {
            return .alreadyHave
        }
        if mentions([
            "unknown series", "unknown movie", "unable to parse", "matched to series by id",
            "matched to movie by id", "automatic import is not possible", "manual import required",
            "manually import", "unable to identify", "unexpected considering", "title mismatch",
            "unable to find series", "unable to match movie", "found multiple", "not linked to any"
        ]) {
            return .cantMatch
        }
        if mentions([
            "sample", "no video files", "rar file", "rar archive", ".rar", "executable", "dangerous",
            "invalid video file", "no audio tracks", "not found in the grabbed release",
            "expected in this release", "missing episodes", "partial season", "split into multiple files",
            "multi-part"
        ]) {
            return .badRelease
        }
        let state = trackedDownloadState?.lowercased() ?? ""
        // Not bare "failed": "Failed to import episode" is an import problem.
        if state == "failedpending" || mentions([
            "download failed", "download has failed", "missing from download client", "stalled", "no connections"
        ]) {
            return .deadDownload
        }
        return .other
    }

    /// The messages only, not their titles: a title is usually the file being
    /// imported, and a release name like "…rarbg…" would read as a cause. The
    /// client's own error rides along: Sonarr and Radarr leave `statusMessages`
    /// empty for a stalled or errored download.
    static func messages(of item: ArrQueueItem) -> [String] {
        var result: [String] = []
        for statusMessage in item.statusMessages ?? [] {
            result.append(contentsOf: statusMessage.messages ?? [])
        }
        if let errorMessage = item.errorMessage { result.append(errorMessage) }
        return result
    }
}

/// One cause and the downloads it covers.
struct ImportIssueGroup: Identifiable {
    let cause: ImportIssueCause
    let items: [DownloadListItem]

    var id: String { cause.rawValue }

    /// The *arr queue rows the group's fix can act on. Errored torrents and failed
    /// SABnzbd jobs with no *arr record have nothing to blocklist or re-check, so
    /// they stay as rows to open.
    var fixableQueueItems: [(item: ArrQueueItem, source: ArrServiceType, instance: ArrInstanceRef?)] {
        items.compactMap {
            guard case .arrQueue(let item, let source, _, _, let instance) = $0 else { return nil }
            return (item, source, instance)
        }
    }

    static func cause(of item: DownloadListItem) -> ImportIssueCause {
        switch item {
        case .arrQueue(let queueItem, _, _, _, _):
            ImportIssueTriage.cause(
                messages: ImportIssueTriage.messages(of: queueItem),
                trackedDownloadState: queueItem.trackedDownloadState
            )
        case .torrent, .sab:
            .deadDownload
        case .arrHistory:
            .other
        }
    }

    /// Issues grouped by cause, the cause clearing most first.
    static func groups(_ items: [DownloadListItem]) -> [ImportIssueGroup] {
        Dictionary(grouping: items, by: cause(of:))
            .map { ImportIssueGroup(cause: $0.key, items: $0.value) }
            .sorted {
                $0.cause.priority != $1.cause.priority
                    ? $0.cause.priority < $1.cause.priority
                    : $0.items.count > $1.items.count
            }
    }
}

/// A fix the user asked for, waiting out its undo window.
struct ScheduledImportIssueFix: Equatable {
    let cause: ImportIssueCause
    let count: Int
}

/// The card heading each cause in Issues: what happened, how many downloads, and
/// the fix as one button. While a destructive fix waits, the button becomes Undo.
struct ImportIssueGroupHeader: View {
    let group: ImportIssueGroup
    let scheduled: ScheduledImportIssueFix?
    let isWorking: Bool
    let onFix: () -> Void
    let onUndo: () -> Void
    let onOpenPathMappings: () -> Void

    private var tint: Color {
        switch group.cause {
        case .path: .red
        case .alreadyHave: .green
        case .badRelease: .orange
        case .deadDownload: .pink
        case .cantMatch: .purple
        case .other: .secondary
        }
    }

    private var fixTitle: String? {
        let count = group.fixableQueueItems.count
        guard count > 0 else { return nil }
        switch group.cause.fix {
        case .checkAgain: return "Check Again"
        case .remove: return count == 1 ? "Remove" : "Remove All \(count)"
        case .blocklistAndSearch: return count == 1 ? "Blocklist & Search" : "Blocklist & Search All \(count)"
        case .none: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: group.cause.systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.cause.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text("\(group.items.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(scheduledText ?? group.cause.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }

            HStack(spacing: 8) {
                if scheduled != nil {
                    Button("Undo", action: onUndo)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("issue-fix-undo-\(group.cause.rawValue)")
                } else if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    if let fixTitle {
                        Button(fixTitle, action: onFix)
                            .buttonStyle(.borderedProminent)
                            .tint(group.cause == .alreadyHave ? .green : .accentColor)
                            .accessibilityIdentifier("issue-fix-\(group.cause.rawValue)")
                    }
                    if group.cause == .path {
                        Button("Path Mappings", action: onOpenPathMappings)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("issue-path-mappings")
                    }
                }
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: scheduled)
        .animation(.snappy, value: isWorking)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("issue-group-\(group.cause.rawValue)")
    }

    private var scheduledText: String? {
        guard let scheduled else { return nil }
        let noun = scheduled.count == 1 ? "download" : "downloads"
        switch group.cause.fix {
        case .remove: return "Removing \(scheduled.count) \(noun)…"
        case .blocklistAndSearch: return "Blocklisting \(scheduled.count) \(noun) and searching again…"
        default: return nil
        }
    }
}
