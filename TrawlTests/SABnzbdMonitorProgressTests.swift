//
//  SABnzbdMonitorProgressTests.swift
//  TrawlTests
//
//  The background monitor reports a SABnzbd download's progress into a progress
//  UI the system owns, and the system reads that progress back: a bar that
//  stalls or reverses is what it treats as a stuck task worth prompting the
//  person to cancel, and a bar that reaches the end ends the session.
//
//  So the arithmetic here is not cosmetic. Two failure modes in particular are
//  silent and wrong: a poll that fails looking like an empty queue (which would
//  report a still-running download as finished at 100%), and a denominator that
//  grows mid-session (which drags the bar backwards). Both are pinned below.
//
//  `SABnzbdMonitorProgress` was split out of the task driver precisely so these
//  can run against fixture queues without standing up `BackgroundTasks`.

import Foundation
import Testing
@testable import Trawl

struct SABnzbdMonitorProgressTests {
    private static let decoder = JSONDecoder()

    // MARK: - Fixtures

    private struct SlotSpec {
        var id: String
        var name: String = "Show.S03E04.1080p"
        var megabytes: Double = 1000
        var megabytesLeft: Double = 1000
        var status: String = "Downloading"
        var timeLeft: String = "0:04:32"
        /// SABnzbd reports a percentage even for a job it has not sized, which
        /// is then the only thing the bar can be driven by.
        var percentageOverride: Double?

        var percentage: Double {
            if let percentageOverride { return percentageOverride }
            guard megabytes > 0 else { return 0 }
            return max(0, (megabytes - megabytesLeft) / megabytes) * 100
        }
    }

    private static func job(_ spec: SlotSpec) throws -> SABnzbdJob {
        SABnzbdJob(queueSlot: try decoder.decode(
            SABnzbdQueueSlot.self,
            from: Data(slotJSON(spec).utf8)
        ))
    }

    private static func queue(pausedAll: Bool = false, _ specs: [SlotSpec]) throws -> SABnzbdQueue {
        let json = """
        {
          "paused_all": \(pausedAll),
          "slots": [\(specs.map(slotJSON).joined(separator: ","))]
        }
        """
        return try decoder.decode(SABnzbdQueue.self, from: Data(json.utf8))
    }

    private static func slotJSON(_ spec: SlotSpec) -> String {
        """
        {
          "nzo_id": "\(spec.id)",
          "filename": "\(spec.name)",
          "status": "\(spec.status)",
          "mb": \(spec.megabytes),
          "mbleft": \(spec.megabytesLeft),
          "percentage": \(spec.percentage),
          "timeleft": "\(spec.timeLeft)"
        }
        """
    }

    private static func megabytes(_ value: Double) -> Int64 {
        Int64((value * 1_048_576).rounded())
    }

    // MARK: - The denominator is frozen at the start of the session

    @Test("An NZB queued mid-session does not move the bar this session reports")
    func denominatorIsFrozenWhenTheSessionStarts() throws {
        let tracked = try Self.job(SlotSpec(id: "a"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [tracked]))

        // SABnzbd picks up a second, larger NZB while the session runs. Summing
        // the live queue would triple the denominator and drag 50% back to 16%.
        let live = try Self.queue([
            SlotSpec(id: "a", megabytesLeft: 500),
            SlotSpec(id: "b", megabytes: 2000, megabytesLeft: 2000)
        ])

        let update = SABnzbdMonitorProgress.update(plan: plan, queue: live, previousCompletedUnits: 0)

        #expect(plan.totalUnits == Self.megabytes(1000))
        #expect(update.completedUnits == Self.megabytes(500))
        #expect(update.subtitle.hasPrefix("50%"))
        #expect(update.isFinished == false)
    }

    @Test("A tracked job that leaves the queue counts whole rather than vanishing")
    func departedJobsStayInTheNumerator() throws {
        let first = try Self.job(SlotSpec(id: "a"))
        let second = try Self.job(SlotSpec(id: "b"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [first, second]))

        // "a" finished downloading and moved to history; only "b" is still here.
        let live = try Self.queue([SlotSpec(id: "b", megabytesLeft: 1000)])
        let update = SABnzbdMonitorProgress.update(plan: plan, queue: live, previousCompletedUnits: 0)

        #expect(plan.totalUnits == Self.megabytes(2000))
        #expect(update.completedUnits == Self.megabytes(1000))
        #expect(update.isFinished == false)
    }

    // MARK: - A failed poll is not an empty queue

    @Test("A failed poll holds the last figure instead of reporting the session finished")
    func failedPollDoesNotReadAsCompletion() throws {
        let tracked = try Self.job(SlotSpec(id: "a"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [tracked]))
        let halfway = Self.megabytes(500)

        // The server went away mid-download. Treating the absent queue like an
        // empty one would count every tracked job as departed, report 100% and
        // end the session while the download was still running.
        let update = SABnzbdMonitorProgress.update(
            plan: plan,
            queue: nil,
            previousCompletedUnits: halfway
        )

        #expect(update.completedUnits == halfway)
        #expect(update.isFinished == false)
        #expect(update.subtitle == "Reconnecting…")
    }

    @Test("An empty queue, successfully polled, does finish the session")
    func emptyQueueFinishesTheSession() throws {
        let tracked = try Self.job(SlotSpec(id: "a"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [tracked]))

        let update = SABnzbdMonitorProgress.update(
            plan: plan,
            queue: try Self.queue([]),
            previousCompletedUnits: 0
        )

        #expect(update.isFinished)
        #expect(update.completedUnits == plan.totalUnits)
        // Not "Complete": the bytes have landed, but SABnzbd may still be
        // repairing or unpacking, which this session stops watching for.
        #expect(update.subtitle == "Download finished")
    }

    // MARK: - Progress never reverses

    @Test("A mid-download size revision cannot push the bar backwards")
    func progressIsMonotonic() throws {
        let tracked = try Self.job(SlotSpec(id: "a"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [tracked]))

        // SABnzbd revised the job upward, so the freshly computed figure is
        // lower than what was already reported.
        let live = try Self.queue([SlotSpec(id: "a", megabytesLeft: 600)])
        let previous = Self.megabytes(500)
        let update = SABnzbdMonitorProgress.update(
            plan: plan,
            queue: live,
            previousCompletedUnits: previous
        )

        #expect(Self.megabytes(400) < previous, "fixture must recompute lower to be meaningful")
        #expect(update.completedUnits == previous)
    }

    @Test("A stale previous figure cannot exceed the frozen total")
    func previousFigureIsClampedToTheTotal() throws {
        let tracked = try Self.job(SlotSpec(id: "a"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [tracked]))

        let update = SABnzbdMonitorProgress.update(
            plan: plan,
            queue: try Self.queue([SlotSpec(id: "a", megabytesLeft: 1000)]),
            previousCompletedUnits: Self.megabytes(99_999)
        )

        #expect(update.completedUnits == plan.totalUnits)
    }

    // MARK: - Wording

    @Test("A paused job says so rather than showing a stalled percentage alone")
    func pausedJobsAreLabelled() throws {
        let tracked = try Self.job(SlotSpec(id: "a"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [tracked]))

        let perJob = SABnzbdMonitorProgress.update(
            plan: plan,
            queue: try Self.queue([SlotSpec(id: "a", megabytesLeft: 500, status: "Paused")]),
            previousCompletedUnits: 0
        )
        #expect(perJob.subtitle == "Paused · 50%")

        // SABnzbd's global pause leaves each slot reporting "Downloading".
        let wholeQueue = SABnzbdMonitorProgress.update(
            plan: plan,
            queue: try Self.queue(pausedAll: true, [SlotSpec(id: "a", megabytesLeft: 500)]),
            previousCompletedUnits: 0
        )
        #expect(wholeQueue.subtitle == "Paused · 50%")
    }

    @Test("The title says monitoring, because the system's Cancel only ends the monitoring")
    func titleNamesTheMonitoringNotTheDownload() throws {
        let one = try #require(SABnzbdMonitorPlan(jobs: [try Self.job(SlotSpec(id: "a", name: "Show.S03E04"))]))
        let two = try #require(SABnzbdMonitorPlan(jobs: [
            try Self.job(SlotSpec(id: "a")),
            try Self.job(SlotSpec(id: "b"))
        ]))

        let single = SABnzbdMonitorProgress.update(plan: one, queue: nil, previousCompletedUnits: 0)
        let multiple = SABnzbdMonitorProgress.update(plan: two, queue: nil, previousCompletedUnits: 0)

        #expect(single.title == "Monitoring Show.S03E04")
        #expect(multiple.title == "Monitoring 2 SABnzbd downloads")
    }

    @Test("A running job's subtitle carries size and time remaining")
    func runningSubtitleCarriesSizeAndTime() throws {
        let tracked = try Self.job(SlotSpec(id: "a"))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [tracked]))

        let update = SABnzbdMonitorProgress.update(
            plan: plan,
            queue: try Self.queue([SlotSpec(id: "a", megabytesLeft: 500, timeLeft: "0:04:32")]),
            previousCompletedUnits: 0
        )

        #expect(update.subtitle.hasPrefix("50% · "))
        #expect(update.subtitle.contains("left"))
    }

    // MARK: - SABnzbd's own field shapes

    @Test("timeleft parses as H:MM:SS and rejects what it cannot read")
    func timeRemainingParsing() {
        #expect(SABnzbdMonitorProgress.secondsRemaining("0:04:32") == 272)
        #expect(SABnzbdMonitorProgress.secondsRemaining("1:00:00") == 3600)
        #expect(SABnzbdMonitorProgress.secondsRemaining("12:30") == 750)
        // SABnzbd's own default for "no estimate".
        #expect(SABnzbdMonitorProgress.secondsRemaining("0:00:00") == nil)
        #expect(SABnzbdMonitorProgress.secondsRemaining("") == nil)
        #expect(SABnzbdMonitorProgress.secondsRemaining("unknown") == nil)
        #expect(SABnzbdMonitorProgress.secondsRemaining(nil) == nil)
    }

    @Test("A job SABnzbd has not sized yet still has a denominator to divide by")
    func unsizedJobsFallBackToNominalUnits() throws {
        let unsized = try Self.job(SlotSpec(id: "a", megabytes: 0, megabytesLeft: 0))
        let plan = try #require(SABnzbdMonitorPlan(jobs: [unsized]))

        #expect(plan.totalUnits == SABnzbdMonitorPlan.unsizedJobUnits)

        // With no byte counts to work from, SABnzbd's percentage drives the bar,
        // and the subtitle omits the size it would otherwise be inventing.
        let live = try Self.queue([
            SlotSpec(id: "a", megabytes: 0, megabytesLeft: 0, percentageOverride: 40)
        ])
        let update = SABnzbdMonitorProgress.update(plan: plan, queue: live, previousCompletedUnits: 0)

        #expect(update.completedUnits == 400_000)
        #expect(update.subtitle.hasPrefix("40%"))
        #expect(update.subtitle.contains("MB") == false)
        #expect(update.subtitle.contains("GB") == false)
    }

    @Test("A plan needs something to track, and tracks each job once")
    func planRejectsNothingAndDeduplicates() throws {
        #expect(SABnzbdMonitorPlan(jobs: []) == nil)

        let duplicated = try [Self.job(SlotSpec(id: "a")), Self.job(SlotSpec(id: "a"))]
        let plan = try #require(SABnzbdMonitorPlan(jobs: duplicated))

        #expect(plan.trackedIDs == ["a"])
        #expect(plan.totalUnits == Self.megabytes(1000))
        // One tracked job, so the title can name it rather than count it.
        #expect(plan.singleJobName != nil)
    }
}

/// The driver's refusals, which are the only paths that can be exercised without
/// actually submitting a task to the scheduler.
@MainActor
struct SABnzbdBackgroundMonitorGuardTests {
    @Test("Monitoring refuses when SABnzbd is not connected")
    func requiresAConnectedClient() {
        let monitor = SABnzbdBackgroundMonitor()

        #expect(throws: SABnzbdMonitorError.notConnected) {
            try monitor.startMonitoring(jobs: [], client: nil)
        }
        #expect(monitor.isMonitoring == false)
    }

    @Test("Monitoring refuses when there is nothing left in the queue to track")
    func requiresSomethingToTrack() {
        let monitor = SABnzbdBackgroundMonitor()
        let client = SABnzbdAPIClient(baseURL: "http://localhost:8080", apiKey: "k")

        #expect(throws: SABnzbdMonitorError.nothingToMonitor) {
            try monitor.startMonitoring(jobs: [], client: client)
        }
        #expect(monitor.isMonitoring == false)
    }

    @Test("Stopping clears the session without reaching the server")
    func stoppingIsLocalOnly() {
        let monitor = SABnzbdBackgroundMonitor()
        monitor.stopMonitoring()
        #expect(monitor.monitoredJobIDs.isEmpty)
    }
}
