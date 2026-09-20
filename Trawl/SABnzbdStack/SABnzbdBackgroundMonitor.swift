import Foundation
import OSLog
import Observation
import Synchronization
#if os(iOS)
import BackgroundTasks
#endif

nonisolated enum SABnzbdMonitorError: LocalizedError, Equatable {
    case unsupported
    case alreadyMonitoring
    case nothingToMonitor
    case notConnected

    var errorDescription: String? {
        switch self {
        case .unsupported: "Background monitoring needs iOS 26 or later."
        case .alreadyMonitoring: "Trawl is already monitoring a download."
        case .nothingToMonitor: "That download is no longer in the SABnzbd queue."
        case .notConnected: "Connect to SABnzbd before monitoring a download."
        }
    }
}

/// Keeps a SABnzbd download's progress on screen after the person leaves Trawl,
/// using `BGContinuedProcessingTask`.
///
/// The task does not *perform* the download - SABnzbd is doing that on the
/// person's own server - it polls the queue and reports what it finds into the
/// progress UI the system puts up. That is why it only ever runs from a
/// deliberate gesture on a row, and why it is scoped to SABnzbd: usenet jobs
/// have a known size and move monotonically, so the progress the system shows
/// is real. Torrents stall, reverse and seed indefinitely, which reads to the
/// system as a stuck task.
///
/// ## Cancelling is never destructive
///
/// `expirationHandler` fires both when the person taps Cancel in the system UI
/// *and* when iOS reclaims the task under resource pressure, and the API gives
/// no way to tell those apart - it is a bare `() -> Void`. So the handler stops
/// monitoring and nothing else. It never pauses or deletes on the server,
/// because a warm phone would then silently destroy somebody's download. The
/// task is titled "Monitoring …" so that Cancel reads as what it actually does.
@MainActor
@Observable
final class SABnzbdBackgroundMonitor {
    static let shared = SABnzbdBackgroundMonitor()

    /// Registered and submitted verbatim. Wildcard identifiers are documented
    /// but currently fail to match a registered handler, throwing "No launch
    /// handler registered for task with identifier" from `submit(_:)`.
    static let taskIdentifier = "com.poole.james.Trawl.sabnzbd-monitor"

    /// Gives up rather than holding a task open against a server that has gone
    /// away. Five failures at the polling interval is roughly half a minute.
    private static let maximumConsecutivePollFailures = 5

    /// Empty whenever no session is running, so a row can ask whether it is the
    /// one being monitored.
    private(set) var monitoredJobIDs: Set<String> = []

    var isMonitoring: Bool { !monitoredJobIDs.isEmpty }

    var isAvailable: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    @ObservationIgnored var pollingInterval: TimeInterval = 5
    @ObservationIgnored
    var waitForPollingInterval: @Sendable (TimeInterval) async -> Void = { interval in
        try? await Task.sleep(for: .seconds(interval))
    }

    @ObservationIgnored private let logger = Logger(
        subsystem: "com.poole.james.Trawl",
        category: "SABnzbdBackgroundMonitor"
    )
    @ObservationIgnored private var isRegistered = false
    /// Handed to the launch handler, which the scheduler calls back without any
    /// of the context the submitting gesture had.
    @ObservationIgnored private var pendingSession: Session?
    @ObservationIgnored private var activeSignal: ExpirationSignal?

    private struct Session {
        let plan: SABnzbdMonitorPlan
        let client: SABnzbdAPIClient
    }

    /// Call before the app finishes launching; the scheduler rejects a submit
    /// whose identifier has no handler registered.
    func register() {
        #if os(iOS)
        guard !isRegistered else { return }
        isRegistered = true

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // The scheduler calls this on its own queue and keeps the task alive
            // for the handler's lifetime; from here on only the monitor's main
            // actor touches it, so the hand-off is the only unchecked step.
            let box = TaskBox(task: continued)
            Task { @MainActor in
                await SABnzbdBackgroundMonitor.shared.run(box.task)
            }
        }

        if !registered {
            logger.error("BGTaskScheduler refused to register \(Self.taskIdentifier, privacy: .public).")
        }
        #endif
    }

    /// Starts a session for `jobs`. Must be called from the foreground, in
    /// response to a gesture - the system rejects anything else.
    func startMonitoring(jobs: [SABnzbdJob], client: SABnzbdAPIClient?) throws {
        guard isAvailable else { throw SABnzbdMonitorError.unsupported }
        guard !isMonitoring else { throw SABnzbdMonitorError.alreadyMonitoring }
        guard let client else { throw SABnzbdMonitorError.notConnected }
        guard let plan = SABnzbdMonitorPlan(jobs: jobs) else {
            throw SABnzbdMonitorError.nothingToMonitor
        }

        #if os(iOS)
        register()

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: plan.singleJobName.map { "Monitoring \($0)" }
                ?? "Monitoring \(plan.trackedIDs.count) SABnzbd downloads",
            subtitle: "Starting…"
        )
        // Queued rather than failed: a person who just asked for this would
        // rather wait a moment for a slot than be told no.
        request.strategy = .queue

        pendingSession = Session(plan: plan, client: client)
        monitoredJobIDs = Set(plan.trackedIDs)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            pendingSession = nil
            monitoredJobIDs = []
            throw error
        }
        #endif
    }

    /// Ends the session from inside the app. Like the system's Cancel, this
    /// stops watching and leaves the download alone.
    func stopMonitoring() {
        activeSignal?.signal()
        pendingSession = nil
        monitoredJobIDs = []
    }

    #if os(iOS)
    private func run(_ task: BGContinuedProcessingTask) async {
        guard let session = pendingSession else {
            task.setTaskCompleted(success: false)
            return
        }
        pendingSession = nil

        let signal = ExpirationSignal()
        activeSignal = signal
        task.expirationHandler = { signal.signal() }

        task.progress.totalUnitCount = session.plan.totalUnits
        var completedUnits: Int64 = 0
        var consecutiveFailures = 0
        var finishedNormally = false

        while !signal.isExpired {
            let queue = try? await session.client.getQueue(limit: 200)
            if queue == nil {
                consecutiveFailures += 1
                if consecutiveFailures >= Self.maximumConsecutivePollFailures { break }
            } else {
                consecutiveFailures = 0
            }

            let update = SABnzbdMonitorProgress.update(
                plan: session.plan,
                queue: queue,
                previousCompletedUnits: completedUnits
            )
            completedUnits = update.completedUnits
            task.progress.completedUnitCount = update.completedUnits
            task.updateTitle(update.title, subtitle: update.subtitle)

            if update.isFinished {
                finishedNormally = true
                break
            }

            await waitForPollingInterval(pollingInterval)
        }

        if finishedNormally {
            task.progress.completedUnitCount = session.plan.totalUnits
        }
        task.setTaskCompleted(success: finishedNormally)

        activeSignal = nil
        monitoredJobIDs = []
    }

    private struct TaskBox: @unchecked Sendable {
        let task: BGContinuedProcessingTask
    }
    #endif
}

/// Settable from whatever thread the expiration handler runs on, readable from
/// the polling loop.
private final class ExpirationSignal: Sendable {
    private let expired = Mutex(false)

    var isExpired: Bool { expired.withLock { $0 } }

    func signal() { expired.withLock { $0 = true } }
}
