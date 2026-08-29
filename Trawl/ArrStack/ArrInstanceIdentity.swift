import Foundation

/// Identity of one configured Sonarr or Radarr server.
///
/// Trawl presents two instances of each service — the intended setup is an HD
/// pair and a 4K pair — as a single blended library. Server identity is kept as
/// *provenance*: it rides along with every item, queue row, calendar entry and
/// health check so the UI can say which server a thing came from, and so a
/// command can be routed back to the server that owns it. It is deliberately not
/// a navigation axis; there is no "4K Radarr" screen.
nonisolated struct ArrInstanceRef: Identifiable, Hashable, Sendable {
    /// The `ArrServiceProfile` ID. Stable across edits to the profile.
    let id: UUID
    let serviceType: ArrServiceType
    /// The profile's full name, as the user typed it in setup. Used in menus and
    /// confirmations, where there is room for it.
    let displayName: String
    /// Which copy of the library this server holds.
    let tier: ArrQualityTier

    /// The badge text — "Default" or "4K", matching Seerr's own wording.
    ///
    /// Taken from the declared tier rather than parsed out of `displayName`. The
    /// name is whatever the user felt like typing; the tier is the thing the
    /// blended library is actually organised around.
    var shortLabel: String { tier.label }

    /// The server named in full — "Sonarr Default", "Radarr 4K".
    ///
    /// `shortLabel` is for badges *on* something that already says what it is: a
    /// library row, a queue entry, a calendar item. Where the label is the whole
    /// answer to "which server is this?" — a `Server` field on a form — a bare
    /// "Default" or "4K" names a tier rather than a server and leaves the reader
    /// to supply the service themselves.
    var qualifiedLabel: String { "\(serviceType.displayName) \(tier.label)" }

    /// Position in the badge row and the palette, from the tier itself so a ref
    /// and a bare profile can never disagree about which server sorts first.
    var ordinal: Int { tier.ordinalForDisplay }
}

nonisolated extension ArrInstanceRef {
    /// The most instances of one service type Trawl will connect.
    ///
    /// Two, because there are two tiers. The cap is a consequence of the model
    /// rather than a rule bolted onto it: a third server would have no tier left
    /// to hold, no badge to wear, and nowhere to sit in a merged row.
    static let maxInstancesPerServiceType = ArrQualityTier.allCases.count

    /// Builds refs for one service type's profiles, ordered HD first.
    static func make(
        from profiles: [(id: UUID, displayName: String, tier: ArrQualityTier)],
        serviceType: ArrServiceType
    ) -> [ArrInstanceRef] {
        profiles
            .map {
                ArrInstanceRef(
                    id: $0.id,
                    serviceType: serviceType,
                    displayName: $0.displayName,
                    tier: $0.tier
                )
            }
            .sorted { $0.ordinal < $1.ordinal }
    }
}

// MARK: - Instance-scoped items

/// An API model that remembers which server it was fetched from.
///
/// The *arr APIs have no concept of this — two servers hand out the same small
/// integer IDs for different titles — so provenance is stamped on at the point of
/// the fetch and travels with the value from then on. Without it, a merged
/// library could not route a delete, a monitor toggle or an interactive search
/// back to the server that actually holds the item.
nonisolated protocol ArrInstanceScoped {
    /// The server this value came from. `nil` for values that never went through
    /// an instance-aware load — lookup/discover results, previews, and fixtures.
    var instanceID: UUID? { get set }
}

nonisolated extension ArrInstanceScoped {
    /// A copy stamped as belonging to `instanceID`.
    func stamped(with instanceID: UUID?) -> Self {
        var copy = self
        copy.instanceID = instanceID
        return copy
    }
}

nonisolated extension Array where Element: ArrInstanceScoped {
    /// Stamps every element with the server the array was fetched from.
    func stamped(with instanceID: UUID?) -> [Element] {
        map { $0.stamped(with: instanceID) }
    }
}

// MARK: - Pairing a value with the server it came from

/// A value together with the server that produced it.
///
/// Used for everything the *arr APIs return that isn't a merged library item:
/// queue rows, history, health checks, root folders, download clients, backups,
/// scheduled tasks. Those are per-server facts, and the alternative — stamping an
/// `instanceID` onto each wire model — risks encoding Trawl's bookkeeping back to
/// a server on the next PUT. Wrapping keeps the wire models exactly as the API
/// defines them and makes provenance impossible to drop by accident: a caller
/// that wants the value has to acknowledge the instance to reach it.
nonisolated struct ArrInstanced<Value: Sendable>: Identifiable, Sendable {
    let instance: ArrInstanceRef
    let value: Value

    /// Unique across instances even when two servers hand out the same row ID.
    var id: String { "\(instance.id.uuidString):\(elementID)" }
    private let elementID: String

    init(_ value: Value, on instance: ArrInstanceRef, elementID: String) {
        self.value = value
        self.instance = instance
        self.elementID = elementID
    }
}

nonisolated extension ArrInstanced where Value: Identifiable {
    init(_ value: Value, on instance: ArrInstanceRef) {
        self.init(value, on: instance, elementID: String(describing: value.id))
    }
}

nonisolated extension Array where Element: Identifiable & Sendable {
    /// Tags every element of one server's response with that server.
    func instanced(on instance: ArrInstanceRef) -> [ArrInstanced<Element>] {
        map { ArrInstanced($0, on: instance) }
    }
}

#if DEBUG
nonisolated extension ArrInstanceRef {
    /// A stable stand-in server for previews and fixtures.
    ///
    /// The UUID is derived from the service and tier rather than generated, so a
    /// preview that rebuilds its body doesn't hand SwiftUI a new identity for the
    /// same row every time it re-renders.
    static func preview(
        _ serviceType: ArrServiceType,
        tier: ArrQualityTier = .hd,
        displayName: String? = nil
    ) -> ArrInstanceRef {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(truncatingIfNeeded: serviceType.rawValue.hashValue)
        bytes[15] = tier == .hd ? 1 : 2
        for index in 1..<15 { bytes[index] = UInt8(index) }
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                               bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        return ArrInstanceRef(
            id: uuid,
            serviceType: serviceType,
            displayName: displayName ?? "\(serviceType.displayName) \(tier.label)",
            tier: tier
        )
    }

    /// The HD/4K pair, as the blended library expects to find them.
    static func previewPair(_ serviceType: ArrServiceType) -> [ArrInstanceRef] {
        [preview(serviceType, tier: .hd), preview(serviceType, tier: .uhd)]
    }
}
#endif

// MARK: - Keying by (server, library ID)

/// A library ID together with the server that issued it.
///
/// The *arr APIs number their libraries from the same sequence, so an `Int` on its
/// own is not a key: two servers each hand out series 1, for different shows.
/// Keying a lookup on the bare ID resolves an episode against whichever server's
/// copy happened to win — and with a trapping `Dictionary` init it does not resolve
/// anything at all, it crashes the app on the duplicate key.
nonisolated struct ArrScopedID: Hashable, Sendable {
    let instanceID: UUID?
    let id: Int

    init(_ instanceID: UUID?, _ id: Int) {
        self.instanceID = instanceID
        self.id = id
    }
}
