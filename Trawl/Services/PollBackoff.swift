import Foundation

/// The wait an automatic poller puts between cycles, stretched while the server
/// it polls is failing.
///
/// A poller that keeps its base cadence against a server that has gone away
/// spends the entire outage waking the radio for a request it already knows the
/// answer to. qBittorrent's loop is the worst of them at a request every two
/// seconds, for as long as the app is foregrounded - a server that is off for an
/// afternoon is several thousand pointless requests. Escalating the wait leaves a
/// healthy server exactly as current as it was while making a dead one nearly free.
///
/// The ladder is in absolute seconds rather than multiples of the caller's base
/// interval, so every poller converges on the same one-minute floor during an
/// outage instead of each stretching in proportion to a cadence it chose for
/// reasons that have nothing to do with failure. `interval(base:)` never returns
/// less than the base, so a poller that is already slower than a rung is not
/// *sped up* by its first failure.
///
/// Only the automatic cadence backs off. A refresh the user asked for - pull to
/// refresh, a Retry button - does not consult this at all, so it is never made to
/// wait out a backoff it was invoked to escape.
///
/// One known limitation: resetting does not shorten a sleep already in progress.
/// A manual refresh that succeeds mid-outage returns the loop to base cadence
/// from its *next* cycle, which may be up to `ladder.last` away. The user has the
/// fresh data in hand either way, so waking the loop early would buy nothing worth
/// the machinery.
nonisolated struct PollBackoff: Sendable, Equatable {
    /// Successive waits applied after 1, 2, 3, and 4-or-more consecutive failures.
    static let ladder: [TimeInterval] = [5, 15, 30, 60]

    private(set) var consecutiveFailures = 0

    init() {}

    /// The server answered. Whether the payload was useful is a separate question -
    /// a response that turns out to be stale still proves the server is reachable,
    /// which is the only thing this measures.
    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordFailure() {
        consecutiveFailures += 1
    }

    /// Returns the loop to base cadence without claiming a request succeeded.
    /// For callers with outside knowledge that the situation has changed - the app
    /// returning to the foreground, the network path coming back - where recording
    /// a success would be a lie.
    mutating func reset() {
        consecutiveFailures = 0
    }

    func interval(base: TimeInterval) -> TimeInterval {
        guard consecutiveFailures > 0 else { return base }
        let rung = Self.ladder[min(consecutiveFailures, Self.ladder.count) - 1]
        return max(base, rung)
    }
}
