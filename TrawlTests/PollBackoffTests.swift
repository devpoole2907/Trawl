import Foundation
import Testing
@testable import Trawl

@Suite("Poll backoff")
struct PollBackoffTests {
    @Test("A healthy poller stays at its base cadence")
    func healthyPollerKeepsBaseInterval() {
        var backoff = PollBackoff()
        #expect(backoff.interval(base: 2) == 2)

        backoff.recordSuccess()
        #expect(backoff.interval(base: 2) == 2)
    }

    @Test("Consecutive failures climb the ladder and stop at the ceiling")
    func failuresClimbAndSaturate() {
        var backoff = PollBackoff()
        var intervals: [TimeInterval] = []
        for _ in 0..<6 {
            backoff.recordFailure()
            intervals.append(backoff.interval(base: 2))
        }
        #expect(intervals == [5, 15, 30, 60, 60, 60])
    }

    @Test("One success returns the poller to base cadence immediately")
    func successResetsTheLadder() {
        var backoff = PollBackoff()
        backoff.recordFailure()
        backoff.recordFailure()
        backoff.recordFailure()
        #expect(backoff.interval(base: 2) == 30)

        backoff.recordSuccess()
        #expect(backoff.interval(base: 2) == 2)
        #expect(backoff.consecutiveFailures == 0)
    }

    /// The Arr queue poller's slow cadence is already a minute - the ladder's own
    /// ceiling - so a poller that is slower than a rung must not be *sped up* by
    /// failing. Without the `max`, a backgrounded Downloads tab would start polling
    /// twelve times more often the moment both servers went down.
    @Test("A poller slower than the ladder is never accelerated by failing")
    func slowPollerIsNeverAccelerated() {
        var backoff = PollBackoff()
        backoff.recordFailure()
        #expect(backoff.interval(base: 60) == 60)

        backoff.recordFailure()
        #expect(backoff.interval(base: 60) == 60)

        backoff.recordFailure()
        backoff.recordFailure()
        #expect(backoff.interval(base: 120) == 120)
    }

    @Test("Resetting clears the ladder without claiming a request succeeded")
    func resetClearsTheLadder() {
        var backoff = PollBackoff()
        backoff.recordFailure()
        backoff.recordFailure()
        #expect(backoff.consecutiveFailures == 2)

        backoff.reset()
        #expect(backoff.consecutiveFailures == 0)
        #expect(backoff.interval(base: 4) == 4)
    }
}
