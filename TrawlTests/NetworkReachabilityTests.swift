import Foundation
import Testing
@testable import Trawl

/// Drives `NetworkReachability.apply(_:)` directly. The policy - what counts as a
/// change worth waking the app for - is the part with decisions in it, and it is
/// deliberately separable from `NWPathMonitor` so it can be pinned without a live
/// network or a fake path.
@Suite("Network reachability")
@MainActor
struct NetworkReachabilityTests {
    private func summary(
        satisfied: Bool,
        interfaces: Set<NetworkInterfaceKind> = [.wifi]
    ) -> NetworkPathSummary {
        NetworkPathSummary(isSatisfied: satisfied, interfaces: interfaces)
    }

    @Test("Assumes the network works until told otherwise")
    func startsOnline() {
        let reachability = NetworkReachability()
        #expect(reachability.isOffline == false)
        #expect(reachability.pathGeneration == 0)
    }

    /// The baseline still counts. Launching straight into flight mode has to be able
    /// to set the flag even though, as far as the app is concerned, nothing changed.
    @Test("The first path summary is applied even though nothing changed before it")
    func firstSummaryEstablishesTheBaseline() {
        let reachability = NetworkReachability()
        reachability.apply(summary(satisfied: false, interfaces: []))

        #expect(reachability.isOffline == true)
        #expect(reachability.pathGeneration == 1)
    }

    @Test("Losing and regaining a path moves the flag both ways")
    func offlineFlagTracksPathSatisfaction() {
        let reachability = NetworkReachability()

        reachability.apply(summary(satisfied: true))
        #expect(reachability.isOffline == false)

        reachability.apply(summary(satisfied: false, interfaces: []))
        #expect(reachability.isOffline == true)

        reachability.apply(summary(satisfied: true))
        #expect(reachability.isOffline == false)
        #expect(reachability.pathGeneration == 3)
    }

    /// The reason `pathGeneration` exists at all rather than watchers keying off
    /// `isOffline`. Handing over from cellular to Wi-Fi - or a VPN coming up - is
    /// satisfied on both sides, so the flag never moves, and yet it is exactly the
    /// moment a server that was unreachable a second ago becomes reachable.
    @Test("A route change while still online is a reason to retry")
    func interfaceChangeBumpsGenerationWithoutChangingTheFlag() {
        let reachability = NetworkReachability()
        reachability.apply(summary(satisfied: true, interfaces: [.cellular]))
        let generationOnCellular = reachability.pathGeneration
        #expect(reachability.isOffline == false)

        reachability.apply(summary(satisfied: true, interfaces: [.wifi]))

        #expect(reachability.pathGeneration > generationOnCellular)
        #expect(reachability.isOffline == false)
    }

    /// `NWPathMonitor` re-reports the same path readily. Every bump costs a fan-out
    /// of reconnect attempts across every configured service, so an unchanged path
    /// must be silent or the app hammers the user's servers for nothing.
    @Test("Repeating the same path changes nothing")
    func identicalSummaryIsIgnored() {
        let reachability = NetworkReachability()
        reachability.apply(summary(satisfied: true, interfaces: [.wifi]))
        let generation = reachability.pathGeneration

        reachability.apply(summary(satisfied: true, interfaces: [.wifi]))
        reachability.apply(summary(satisfied: true, interfaces: [.wifi]))

        #expect(reachability.pathGeneration == generation)
    }

    @Test("A path is the same only when both its status and its interfaces match")
    func summaryEquality() {
        #expect(summary(satisfied: true, interfaces: [.wifi]) == summary(satisfied: true, interfaces: [.wifi]))
        #expect(summary(satisfied: true, interfaces: [.wifi]) != summary(satisfied: true, interfaces: [.cellular]))
        #expect(summary(satisfied: true, interfaces: [.wifi]) != summary(satisfied: false, interfaces: [.wifi]))
        // Order and duplication are not distinctions a Set can make, which is the
        // point of holding interfaces as one.
        #expect(
            summary(satisfied: true, interfaces: [.wifi, .cellular])
                == summary(satisfied: true, interfaces: [.cellular, .wifi])
        )
    }
}
