import Foundation

/// Which instances of each service the blended library is currently showing.
///
/// The library is unified by default: every configured server contributes, and
/// this filter narrows it. No UI surfaces it yet - the plumbing is wired through
/// every instance-aware surface first so that adding a picker later is a view
/// change rather than another pass over the data layer.
///
/// Exclusions are stored rather than inclusions, deliberately. An empty state
/// means "show everything", so a newly added second server appears in the library
/// the moment it connects instead of being invisible until the user opts it in,
/// and a wiped or migrated preferences file fails open rather than showing an
/// empty library with no control to fix it.
nonisolated struct ArrInstanceFilterState: Equatable, Sendable, Codable {
    private var excluded: [String: Set<UUID>]

    init(excluded: [String: Set<UUID>] = [:]) {
        self.excluded = excluded
    }

    /// The servers of `serviceType` the user has hidden.
    func excludedInstanceIDs(for serviceType: ArrServiceType) -> Set<UUID> {
        excluded[serviceType.rawValue] ?? []
    }

    func isIncluded(_ instanceID: UUID, serviceType: ArrServiceType) -> Bool {
        !excludedInstanceIDs(for: serviceType).contains(instanceID)
    }

    /// True when nothing of this service type is filtered out.
    func isShowingAll(_ serviceType: ArrServiceType) -> Bool {
        excludedInstanceIDs(for: serviceType).isEmpty
    }

    /// Shows or hides one server.
    ///
    /// `available` is the full set of configured servers of this type, and it is
    /// what stops the filter hiding the last one: an empty library with the
    /// control that emptied it is a dead end, so hiding everything is refused and
    /// the call is a no-op.
    @discardableResult
    mutating func setIncluded(
        _ included: Bool,
        instanceID: UUID,
        serviceType: ArrServiceType,
        available: Set<UUID>
    ) -> Bool {
        var current = excludedInstanceIDs(for: serviceType)
        if included {
            current.remove(instanceID)
        } else {
            guard available.subtracting(current).subtracting([instanceID]).isEmpty == false else {
                return false
            }
            current.insert(instanceID)
        }
        store(current, for: serviceType)
        return true
    }

    /// Narrows to a single server, hiding every other one of the same type.
    mutating func setOnly(instanceID: UUID, serviceType: ArrServiceType, available: Set<UUID>) {
        guard available.contains(instanceID) else { return }
        store(available.subtracting([instanceID]), for: serviceType)
    }

    /// Clears the filter for one service type.
    mutating func includeAll(serviceType: ArrServiceType) {
        store([], for: serviceType)
    }

    /// Drops exclusions for servers that no longer exist, so deleting and
    /// re-adding a profile can't leave a stale hide in place - and so a removed
    /// server's UUID doesn't accumulate in preferences forever.
    mutating func prune(keeping available: Set<UUID>, serviceType: ArrServiceType) {
        let current = excludedInstanceIDs(for: serviceType)
        let kept = current.intersection(available)
        if kept != current { store(kept, for: serviceType) }
    }

    /// Keeps only the items that came from a currently-visible server.
    ///
    /// Items with no instance stamp are always kept: those are lookup results,
    /// previews and fixtures, which don't belong to a server and would silently
    /// vanish if the filter treated "unknown" as "excluded".
    func apply<T: ArrInstanceScoped>(to items: [T], serviceType: ArrServiceType) -> [T] {
        let hidden = excludedInstanceIDs(for: serviceType)
        guard !hidden.isEmpty else { return items }
        return items.filter { item in
            guard let instanceID = item.instanceID else { return true }
            return !hidden.contains(instanceID)
        }
    }

    private mutating func store(_ ids: Set<UUID>, for serviceType: ArrServiceType) {
        if ids.isEmpty {
            excluded[serviceType.rawValue] = nil
        } else {
            excluded[serviceType.rawValue] = ids
        }
    }
}

// MARK: - Persistence

nonisolated extension ArrInstanceFilterState {
    static let defaultsKey = "arr.instanceFilter.excluded"

    /// Reads the saved filter. A decode failure returns the unfiltered state
    /// rather than throwing: a corrupt preference should cost the user their
    /// filter, not their library.
    static func load(from defaults: UserDefaults) -> ArrInstanceFilterState {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ArrInstanceFilterState.self, from: data) else {
            return ArrInstanceFilterState()
        }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        if excluded.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
