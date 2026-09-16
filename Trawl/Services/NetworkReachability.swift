import Foundation
import Network
import Observation

/// The kinds of interface Trawl distinguishes. Mapped off `NWInterface.InterfaceType`
/// rather than used directly so the summary below stays trivially `Sendable` and a
/// test can build one without a live path.
nonisolated enum NetworkInterfaceKind: Hashable, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other

    init(_ interfaceType: NWInterface.InterfaceType) {
        switch interfaceType {
        case .wifi: self = .wifi
        case .cellular: self = .cellular
        case .wiredEthernet: self = .wiredEthernet
        case .loopback: self = .loopback
        case .other: self = .other
        @unknown default: self = .other
        }
    }
}

/// The part of an `NWPath` that Trawl reacts to.
///
/// Reduced to this before crossing onto the main actor because `NWPath` is neither
/// `Sendable` nor comparable in the way that matters here: what the app cares about
/// is "can anything be reached, and over what", so that a change of *route* - Wi-Fi
/// to cellular, or a VPN coming up - is visible even though the path was satisfied
/// both before and after.
nonisolated struct NetworkPathSummary: Equatable, Sendable {
    let isSatisfied: Bool
    let interfaces: Set<NetworkInterfaceKind>

    init(isSatisfied: Bool, interfaces: Set<NetworkInterfaceKind>) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        self.isSatisfied = path.status == .satisfied
        self.interfaces = Set(path.availableInterfaces.map { NetworkInterfaceKind($0.type) })
    }
}

/// Whether this device has a usable network path at all.
///
/// Read in one direction only, and the asymmetry is the entire design. An
/// **unsatisfied** path is proof that nothing can be reached, so it is safe to say
/// so plainly and to stop blaming five servers for one flight-mode switch. A
/// **satisfied** path proves nothing at all about the servers Trawl talks to: they
/// sit on a LAN, frequently behind a VPN or Tailscale, and "this iPhone has an LTE
/// interface" says nothing about whether `192.168.1.50` is on the other end of it.
///
/// So this never gates a connection attempt. Gating on reachability would break
/// every remote-access user the first time their tunnel was slower to come up than
/// the interface underneath it. It does two things: it makes the offline case say
/// what it actually is, and it tells the app *when to try again*.
///
/// That second half is the point. A path change is the clearest signal there is
/// that a retry is worth making right now - walking back into Wi-Fi range, a VPN
/// connecting, a handover finishing - and without it the app waits out whatever is
/// left of `ConnectionRetryScheduler`'s thirty seconds, plus whatever backoff its
/// pollers have accumulated, before noticing that the network came back.
@MainActor
@Observable
final class NetworkReachability {
    /// True only while the device has no usable path. Starts `false`: until the
    /// monitor says otherwise, assume the network works, because the alternative is
    /// flashing an offline state over every screen for the first moments of launch.
    private(set) var isOffline = false

    /// Bumped whenever the path meaningfully changes. Views and coordinators watch
    /// this rather than `isOffline`, because the interesting transition includes the
    /// ones where `isOffline` is false on both sides - cellular to Wi-Fi is a reason
    /// to retry, and it never touches the flag.
    private(set) var pathGeneration = 0

    @ObservationIgnored private var currentSummary: NetworkPathSummary?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let monitorQueue = DispatchQueue(label: "com.trawl.network-reachability")

    init() {}

    func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // Reduced here, on the monitor's own queue, so only a Sendable value
            // crosses onto the main actor.
            let summary = NetworkPathSummary(path)
            Task { @MainActor [weak self] in
                self?.apply(summary)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    deinit {
        monitor?.cancel()
    }

    /// Applies a path summary. Separate from the monitor so the policy - what counts
    /// as a change worth reacting to - can be tested without a live network.
    ///
    /// The first summary establishes a baseline and still counts: a launch into
    /// flight mode has to be able to set `isOffline` even though nothing has changed
    /// since the app started.
    func apply(_ summary: NetworkPathSummary) {
        guard summary != currentSummary else { return }
        currentSummary = summary
        isOffline = !summary.isSatisfied
        pathGeneration += 1
    }
}
