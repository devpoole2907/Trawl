import Foundation

/// The blended pause state of every configured download client.
///
/// The Control Center control acts on the same qBittorrent + SABnzbd union the two
/// download widgets already aggregate, so "are downloads running?" cannot be read
/// off one client. This type holds the raw counts each client reports and answers
/// that question in one place, free of WidgetKit and SwiftData so it is testable.
nonisolated struct DownloadControlState: Sendable, Equatable {
    /// qBittorrent torrents still working - downloading, seeding, checking, moving.
    let runningTorrentCount: Int
    /// qBittorrent torrents explicitly stopped or paused by the user.
    let stoppedTorrentCount: Int
    /// The `paused` flag from every SABnzbd queue that answered.
    let sabQueuePausedFlags: [Bool]
    /// How many clients answered at all. Zero means none is configured or reachable.
    let reachableClientCount: Int

    init(
        runningTorrentCount: Int = 0,
        stoppedTorrentCount: Int = 0,
        sabQueuePausedFlags: [Bool] = [],
        reachableClientCount: Int = 0
    ) {
        self.runningTorrentCount = runningTorrentCount
        self.stoppedTorrentCount = stoppedTorrentCount
        self.sabQueuePausedFlags = sabQueuePausedFlags
        self.reachableClientCount = reachableClientCount
    }

    static let unavailable = DownloadControlState()

    /// False when nothing answered, which the control renders as a disabled tile
    /// rather than as a confident "paused".
    var isAvailable: Bool { reachableClientCount > 0 }

    /// Downloads count as running when any client can still make progress.
    ///
    /// A SABnzbd queue that is not paused is running whether or not it holds jobs,
    /// because it will start the next one. qBittorrent has no global switch, so it
    /// is read from its torrents. When nothing is running *and* nothing is stopped -
    /// an empty qBittorrent with no SABnzbd queue - the stack is idle, not paused,
    /// so the control shows the toggle on rather than inviting a pointless resume.
    var isRunning: Bool {
        guard isAvailable else { return false }
        if sabQueuePausedFlags.contains(false) { return true }
        if runningTorrentCount > 0 { return true }
        return stoppedTorrentCount == 0 && sabQueuePausedFlags.isEmpty
    }

    /// Short status word for the control's subtitle.
    var statusLabel: String {
        guard isAvailable else { return "No Client" }
        return isRunning ? "Downloading" : "Paused"
    }

    // MARK: - Toggle decision

    /// What a Control Center toggle should do for a requested switch position.
    enum Action: Sendable, Equatable {
        case pause
        case resume
        /// Nothing is configured or reachable, so the toggle must not claim success.
        case unavailable
    }

    /// The requested position is applied as asked rather than diffed against
    /// `isRunning`: the cached state may be a few minutes old, and a user who taps
    /// pause means pause even if Trawl last saw the stack as already paused.
    static func action(requestedRunning: Bool, state: DownloadControlState) -> Action {
        guard state.isAvailable else { return .unavailable }
        return requestedRunning ? .resume : .pause
    }

    // MARK: - qBittorrent state classification

    /// Raw qBittorrent states that mean the torrent is still being worked on.
    static let runningTorrentStates: Set<String> = [
        "downloading", "forcedDL", "metaDL", "stalledDL", "queuedDL", "checkingDL",
        "allocating", "moving",
        "uploading", "forcedUP", "stalledUP", "queuedUP", "checkingUP", "checkingResumeData"
    ]

    /// Raw qBittorrent states that mean the user stopped the torrent. qBittorrent 5
    /// renamed `paused*` to `stopped*`; both spellings are accepted because the
    /// widget talks to whichever version the user runs.
    static let stoppedTorrentStates: Set<String> = [
        "pausedDL", "pausedUP", "stoppedDL", "stoppedUP"
    ]

    /// `error`, `missingFiles` and any unrecognised state are neither: they are not
    /// progressing and they are not something a resume would fix.
    static func isRunningTorrentState(_ rawState: String) -> Bool {
        runningTorrentStates.contains(rawState)
    }

    static func isStoppedTorrentState(_ rawState: String) -> Bool {
        stoppedTorrentStates.contains(rawState)
    }
}
