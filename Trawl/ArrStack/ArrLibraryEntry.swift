import Foundation

/// Identifies one logical title across every configured instance of a service.
///
/// Two Radarr servers each hold their own copy of *Dune* under their own integer
/// IDs; both copies share a merge key, and the blended library shows them as one
/// row. The service type is part of the key so a Sonarr and a Radarr entry can
/// never collide in a navigation path even if their external IDs coincide.
nonisolated struct ArrMergeKey: Hashable, Sendable, Codable {
    let serviceType: ArrServiceType
    let value: String

    init(serviceType: ArrServiceType, value: String) {
        self.serviceType = serviceType
        self.value = value
    }
}

/// A library item that can be merged across instances.
nonisolated protocol ArrMergeableLibraryItem: ArrInstanceScoped, Identifiable, Sendable where ID == Int {
    /// Groups this item with the same title on another server.
    ///
    /// Prefer a metadata-database ID (TMDb, TVDb, IMDb): those are what both
    /// servers looked the title up by, so they agree. Only fall back to
    /// title+year when an item carries no external ID at all — a lookup result
    /// the user hasn't added yet, or a fixture.
    var mergeKey: ArrMergeKey { get }
}

/// One title in the blended library, together with every server's copy of it.
///
/// `copies` is never empty and is ordered by the owning instance's configured
/// position, so the HD server's copy comes before the 4K server's for every entry
/// in the list. That ordering is what makes `primary` stable: the list can sort,
/// filter and render off one copy without rows shuffling between refreshes.
nonisolated struct ArrLibraryEntry<Item: ArrMergeableLibraryItem>: Identifiable, Sendable {
    let id: ArrMergeKey
    /// Every server's copy of this title, ordered by instance position.
    let copies: [Item]

    /// The copy the list renders from. Shared metadata — title, year, overview,
    /// cast, artwork — is identical across servers, so any copy will do; taking
    /// the first keeps it deterministic.
    var primary: Item { copies[0] }

    /// True when more than one server holds this title. The badge row only earns
    /// its space when this is true, or when the user has more than one instance
    /// configured at all.
    var isOnMultipleInstances: Bool { copies.count > 1 }

    /// The servers holding this title.
    var instanceIDs: [UUID] { copies.compactMap(\.instanceID) }

    init?(copies: [Item]) {
        guard let first = copies.first else { return nil }
        self.id = first.mergeKey
        self.copies = copies
    }

    /// The copy held by a specific server, if that server has this title.
    func copy(on instanceID: UUID?) -> Item? {
        guard let instanceID else { return nil }
        return copies.first { $0.instanceID == instanceID }
    }

    /// The copy carrying a specific server-side library ID. Used to resolve a
    /// legacy `Int`-keyed navigation target (a widget, a Siri intent, a Seerr
    /// deep link) back to the merged entry it belongs to.
    func copy(withLibraryID libraryID: Int) -> Item? {
        copies.first { $0.id == libraryID }
    }
}

nonisolated extension Array where Element: ArrMergeableLibraryItem {
    /// Collapses a flat union of every instance's library into one entry per
    /// title, preserving the order the items arrived in.
    ///
    /// Callers hand this the union already ordered by instance position, so the
    /// copies inside each entry inherit that order and the entries themselves
    /// come out in first-seen order — which is then re-sorted by the list's own
    /// sort mode. Merging here rather than in the list keeps the flat union
    /// available for anything that needs per-server truth (counts, disk usage,
    /// routing a command).
    func mergedByTitle() -> [ArrLibraryEntry<Element>] {
        var order: [ArrMergeKey] = []
        var grouped: [ArrMergeKey: [Element]] = [:]

        for item in self {
            let key = item.mergeKey
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = [item]
            } else {
                grouped[key]?.append(item)
            }
        }

        return order.compactMap { key in
            grouped[key].flatMap { ArrLibraryEntry(copies: $0) }
        }
    }
}

nonisolated extension ArrMergeKey {
    /// Builds a key from whichever external ID is present, most trustworthy
    /// first, falling back to a normalised title+year.
    ///
    /// The fallback is deliberately narrow. Matching two servers' libraries on
    /// title alone would merge *The Thing (1982)* into *The Thing (2011)*, so the
    /// year is part of the key and a title with no year only ever merges with
    /// another yearless copy of the same title.
    static func external(
        serviceType: ArrServiceType,
        databaseName: String,
        databaseID: Int?,
        imdbID: String?,
        title: String,
        year: Int?
    ) -> ArrMergeKey {
        if let databaseID, databaseID > 0 {
            return ArrMergeKey(serviceType: serviceType, value: "\(databaseName):\(databaseID)")
        }
        if let imdbID, !imdbID.isEmpty {
            return ArrMergeKey(serviceType: serviceType, value: "imdb:\(imdbID)")
        }
        let normalisedTitle = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ")
            .joined(separator: " ")
        let yearPart = year.map(String.init) ?? "?"
        return ArrMergeKey(serviceType: serviceType, value: "title:\(normalisedTitle)|\(yearPart)")
    }
}
