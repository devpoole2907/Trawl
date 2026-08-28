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
    /// The profile's full name, as the user typed it in setup.
    let displayName: String
    /// Position in the user's configured order, 0-based. Drives badge colour and
    /// the order copies appear inside a merged library entry, so both stay stable
    /// as long as the user doesn't reorder their servers.
    let ordinal: Int
    /// The badge text: `displayName` with the service's own name removed, so
    /// "4K Radarr" badges as "4K". Disambiguated against the other instance of
    /// the same service — see `ArrInstanceRef.make(from:)`.
    let shortLabel: String
}

nonisolated extension ArrInstanceRef {
    /// The most instances of one service type Trawl will connect. The product
    /// shape is an HD/4K pair; a third instance has no place to go in a merged
    /// library entry's badge row, and every "which server owns this" affordance
    /// is designed around a binary choice.
    static let maxInstancesPerServiceType = 2

    /// Builds refs for one service type's profiles, in the given order, deriving
    /// a short badge label for each and disambiguating collisions.
    ///
    /// - Parameters:
    ///   - profiles: `(id, displayName)` pairs, already ordered and already
    ///     limited to a single service type.
    ///   - serviceType: the service all `profiles` belong to.
    static func make(
        from profiles: [(id: UUID, displayName: String)],
        serviceType: ArrServiceType
    ) -> [ArrInstanceRef] {
        let rawLabels = profiles.map { badgeLabel(for: $0.displayName, serviceType: serviceType) }

        // Two servers both called "Radarr" (or both "Radarr 4K") would otherwise
        // badge identically, which is worse than no badge — it claims a
        // distinction the label doesn't actually make. Number them instead.
        var counts: [String: Int] = [:]
        for label in rawLabels { counts[label.lowercased(), default: 0] += 1 }

        var seen: [String: Int] = [:]
        return profiles.enumerated().map { index, profile in
            let raw = rawLabels[index]
            let key = raw.lowercased()
            let label: String
            if counts[key, default: 0] > 1 {
                let occurrence = (seen[key] ?? 0) + 1
                seen[key] = occurrence
                label = "\(raw) \(occurrence)"
            } else {
                label = raw
            }
            return ArrInstanceRef(
                id: profile.id,
                serviceType: serviceType,
                displayName: profile.displayName,
                ordinal: index,
                shortLabel: label
            )
        }
    }

    /// Strips the service's own name out of a display name, so the badge carries
    /// only what distinguishes this server from its sibling.
    ///
    /// "4K Radarr" → "4K", "Radarr - HD" → "HD", "radarr(2160p)" → "2160p".
    /// A name that is *only* the service name ("Radarr") has nothing to strip and
    /// keeps its full text, because an empty badge would be worse than a
    /// redundant one.
    static func badgeLabel(for displayName: String, serviceType: ArrServiceType) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return serviceType.displayName }

        let serviceName = serviceType.displayName
        // Word-boundary removal only: a server called "Radarrific" keeps its name.
        var result = ""
        var remainder = Substring(trimmed)
        while let range = remainder.range(of: serviceName, options: [.caseInsensitive]) {
            let precedingOK = range.lowerBound == remainder.startIndex
                || !remainder[remainder.index(before: range.lowerBound)].isLetter
            let followingOK = range.upperBound == remainder.endIndex
                || !remainder[range.upperBound].isLetter
            if precedingOK && followingOK {
                result += remainder[remainder.startIndex..<range.lowerBound]
                remainder = remainder[range.upperBound...]
            } else {
                result += remainder[remainder.startIndex..<range.upperBound]
                remainder = remainder[range.upperBound...]
            }
        }
        result += remainder

        let separators = CharacterSet(charactersIn: " -–—:_|/()[]{}·•,")
        let stripped = result
            .trimmingCharacters(in: separators)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")

        return stripped.isEmpty ? trimmed : stripped
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
