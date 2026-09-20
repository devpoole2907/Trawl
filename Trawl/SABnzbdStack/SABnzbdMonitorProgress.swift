import Foundation

/// What a background monitor session is tracking, frozen at the moment the
/// person started it.
///
/// The denominator is deliberately fixed rather than re-summed from the live
/// queue on every poll. A live sum grows whenever SABnzbd picks up another NZB
/// mid-session, which drags the completed fraction backwards - and a progress
/// bar that goes backwards is precisely what iOS reads as a stuck task worth
/// suggesting the person cancel. Anything the person queues after starting a
/// session belongs to the next session, not this one.
nonisolated struct SABnzbdMonitorPlan: Sendable, Hashable {
    /// Stand-in weight for a job SABnzbd has not sized yet, so a session made
    /// entirely of unsized jobs still has a denominator to divide by.
    static let unsizedJobUnits: Int64 = 1_000_000

    /// Tracked jobs, deduplicated, in the order the person saw them.
    let trackedIDs: [String]
    /// The one job's name, used as the task title. Nil for a multi-job session,
    /// which is titled by count instead.
    let singleJobName: String?
    /// Frozen per-job denominator contribution, keyed by `nzo_id`.
    let weights: [String: Int64]

    var totalUnits: Int64 {
        max(1, trackedIDs.reduce(into: Int64(0)) { $0 += weights[$1] ?? 0 })
    }

    /// Nil when there is nothing monitorable, which is the signal not to submit
    /// a task at all rather than to show an empty one.
    init?(jobs: [SABnzbdJob]) {
        var seen: Set<String> = []
        let usable = jobs.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard !usable.isEmpty else { return nil }

        trackedIDs = usable.map(\.id)
        singleJobName = usable.count == 1 ? usable[0].name : nil
        weights = Dictionary(
            uniqueKeysWithValues: usable.map { ($0.id, Self.weight(for: $0)) }
        )
    }

    private static func weight(for job: SABnzbdJob) -> Int64 {
        guard let total = job.totalBytes, total > 0 else { return unsizedJobUnits }
        return total
    }
}

/// One poll's worth of state for the system's task UI.
nonisolated struct SABnzbdMonitorUpdate: Sendable, Hashable {
    let completedUnits: Int64
    let title: String
    let subtitle: String
    let isFinished: Bool
}

/// The whole of the monitor's arithmetic and wording, kept free of
/// `BackgroundTasks` so it can be exercised against fixture queues.
nonisolated enum SABnzbdMonitorProgress {
    static func update(
        plan: SABnzbdMonitorPlan,
        queue: SABnzbdQueue?,
        previousCompletedUnits: Int64
    ) -> SABnzbdMonitorUpdate {
        let title = plan.singleJobName.map { "Monitoring \($0)" }
            ?? "Monitoring \(plan.trackedIDs.count) SABnzbd downloads"

        // A failed poll is not an empty queue. Conflating the two would read
        // every tracked job as gone the moment the server became unreachable,
        // and report the session finished at 100% while the download was still
        // running - the one outcome a progress UI must never produce.
        guard let queue else {
            return SABnzbdMonitorUpdate(
                completedUnits: previousCompletedUnits,
                title: title,
                subtitle: "Reconnecting…",
                isFinished: false
            )
        }

        let live = Dictionary(
            queue.jobs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var completedUnits: Int64 = 0
        var remainingBytes: Int64 = 0
        var everyPresentJobIsSized = true
        var present: [SABnzbdJob] = []

        for id in plan.trackedIDs {
            let weight = plan.weights[id] ?? SABnzbdMonitorPlan.unsizedJobUnits
            guard let job = live[id] else {
                // Gone from the queue: finished downloading, or the person
                // removed it. Either way there is nothing left of it to wait on,
                // so it counts whole rather than vanishing from the numerator.
                completedUnits += weight
                continue
            }
            present.append(job)
            let done = downloadedUnits(for: job, weight: weight)
            completedUnits += done
            remainingBytes += weight - done
            if (job.totalBytes ?? 0) <= 0 { everyPresentJobIsSized = false }
        }

        // Monotonic by construction. SABnzbd revises a job's size mid-download
        // often enough that a raw sum can dip by a few MB between polls, and the
        // system reads a dip as a task making no progress.
        completedUnits = min(
            plan.totalUnits,
            max(completedUnits, min(previousCompletedUnits, plan.totalUnits))
        )

        let isFinished = present.isEmpty
        let isPaused = !present.isEmpty
            && (queue.pausedAll || present.allSatisfy { $0.normalizedStatus == .paused })

        return SABnzbdMonitorUpdate(
            completedUnits: completedUnits,
            title: title,
            subtitle: subtitle(
                completedUnits: completedUnits,
                totalUnits: plan.totalUnits,
                remainingBytes: everyPresentJobIsSized ? remainingBytes : nil,
                secondsRemaining: secondsRemaining(across: present),
                isFinished: isFinished,
                isPaused: isPaused
            ),
            isFinished: isFinished
        )
    }

    /// Prefers SABnzbd's byte counts and falls back to its percentage, clamped
    /// to the frozen weight so a revised size cannot push one job past its own
    /// share of the bar.
    static func downloadedUnits(for job: SABnzbdJob, weight: Int64) -> Int64 {
        if let downloaded = job.downloadedBytes, let total = job.totalBytes, total > 0 {
            return min(max(downloaded, 0), weight)
        }
        let fraction = min(max(job.progress, 0), 1)
        return Int64((Double(weight) * fraction).rounded())
    }

    /// SABnzbd reports `timeleft` per job as `H:MM:SS`. The session is only done
    /// when its slowest job is, so the estimate is the longest one.
    static func secondsRemaining(across jobs: [SABnzbdJob]) -> Int? {
        jobs.compactMap { secondsRemaining($0.timeRemaining) }.max()
    }

    static func secondsRemaining(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let components = text.split(separator: ":").map { Int($0) }
        guard !components.isEmpty, !components.contains(nil) else { return nil }
        let seconds = components.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? seconds : nil
    }

    static func subtitle(
        completedUnits: Int64,
        totalUnits: Int64,
        remainingBytes: Int64?,
        secondsRemaining: Int?,
        isFinished: Bool,
        isPaused: Bool
    ) -> String {
        // Deliberately not "Complete": the bytes have landed, but SABnzbd may
        // still be repairing, unpacking or moving on the server, and the monitor
        // stops watching at the end of the download.
        if isFinished { return "Download finished" }

        let fraction = Double(completedUnits) / Double(max(totalUnits, 1))
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))

        if isPaused { return "Paused · \(percent)%" }

        var parts = ["\(percent)%"]
        if let remainingBytes, remainingBytes > 0 {
            parts.append("\(remainingBytes.formatted(.byteCount(style: .file))) left")
        }
        if let secondsRemaining {
            parts.append(formattedTimeRemaining(secondsRemaining))
        }
        return parts.joined(separator: " · ")
    }

    /// Bare, with no trailing "left": the size clause before it already carries
    /// that word, and "1.2 GB left · 4 min left" reads badly in a one-line
    /// subtitle.
    static func formattedTimeRemaining(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "under a minute" }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
    }
}
