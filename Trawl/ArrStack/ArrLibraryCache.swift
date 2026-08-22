import Foundation

/// How long a fetched library stays usable without going back to the server.
enum ArrLibraryCachePolicy {
    /// Staleness window for appear-time refreshes. Long enough that switching tabs
    /// or popping a detail view reuses what's already loaded, short enough that a
    /// library edited elsewhere shows up quickly.
    static let appearMaxAge: TimeInterval = 120
}

/// Shared, instance-keyed store for a Sonarr or Radarr library.
///
/// Sonarr's `/series` and Radarr's `/movie` are unpaged full-library dumps, and
/// three separate owners used to fetch them independently: the Series/Movies tab
/// view models, `SearchViewModel`, and the throwaway view models
/// `SeerrRequestDetailView` builds for cast-credit navigation. That meant the
/// whole library came down the wire once per owner per visit, into copies that
/// drifted apart the moment one of them added, deleted, or re-monitored something.
///
/// Everything now funnels through here: one fetch per instance, coalesced while
/// in flight, and reused while still fresh.
@MainActor
final class ArrLibraryCache<Item: Sendable> {
    private var itemsByInstance: [UUID: [Item]] = [:]
    private var fetchedAt: [UUID: Date] = [:]
    private var inFlight: [UUID: (sequence: Int, task: Task<[Item], Error>)] = [:]
    /// Monotonic request counter, so a slow older fetch can't overwrite the result
    /// of a newer one that was started after a mutation.
    private var lastStartedSequence = 0
    private var lastStoredSequence: [UUID: Int] = [:]

    /// Last-known library for an instance. Empty when nothing has loaded yet —
    /// use `hasItems(for:)` to tell "not loaded" apart from "genuinely empty".
    func items(for instanceID: UUID?) -> [Item] {
        guard let instanceID else { return [] }
        return itemsByInstance[instanceID] ?? []
    }

    func hasItems(for instanceID: UUID?) -> Bool {
        guard let instanceID else { return false }
        return itemsByInstance[instanceID] != nil
    }

    /// True when this instance was fetched within `maxAge`. Always false for an
    /// instance that has never loaded, so a cold cache can't be mistaken for fresh.
    func isFresh(_ instanceID: UUID?, maxAge: TimeInterval) -> Bool {
        guard let instanceID, let fetched = fetchedAt[instanceID] else { return false }
        return Date().timeIntervalSince(fetched) <= maxAge
    }

    /// Returns the library for `instanceID`, fetching only when the cached copy is
    /// older than `maxAge`.
    ///
    /// `maxAge` defaults to 0, which always issues a fresh request — that keeps
    /// every mutation-driven reload (delete, monitor toggle, add, quality edit)
    /// seeing post-mutation state, as it did before this cache existed. Appear-time
    /// callers pass a window instead, and those are the ones that share a request
    /// already in flight.
    @discardableResult
    func load(
        instanceID: UUID?,
        maxAge: TimeInterval = 0,
        fetch: @escaping @MainActor () async throws -> [Item]
    ) async throws -> [Item] {
        // No active instance means no cache key, so there is nothing to share.
        guard let instanceID else { return try await fetch() }

        if maxAge > 0 {
            if isFresh(instanceID, maxAge: maxAge), let cached = itemsByInstance[instanceID] {
                return cached
            }
            // A caller willing to accept data up to `maxAge` old is equally happy
            // with what a request already in flight is about to return. A forced
            // caller deliberately isn't: joining a request that started before its
            // mutation would hand back pre-mutation state, so it starts its own.
            if let existing = inFlight[instanceID] {
                return try await existing.task.value
            }
        }

        lastStartedSequence += 1
        let sequence = lastStartedSequence

        // Deliberately unstructured: a view disappearing mid-fetch shouldn't cancel
        // a request another caller is still awaiting, and finishing it leaves the
        // cache warm for the next visit.
        let task = Task<[Item], Error> { @MainActor in
            defer {
                // Only retract our own registration — a newer forced request may
                // already have replaced it.
                if self.inFlight[instanceID]?.sequence == sequence {
                    self.inFlight[instanceID] = nil
                }
            }
            let fetched = try await fetch()
            // An older request finishing late must not overwrite a newer answer.
            if sequence > self.lastStoredSequence[instanceID] ?? 0 {
                self.lastStoredSequence[instanceID] = sequence
                self.store(fetched, for: instanceID)
            }
            return fetched
        }
        inFlight[instanceID] = (sequence, task)
        return try await task.value
    }

    /// Records items fetched elsewhere (or mutated locally) as the current library.
    func store(_ items: [Item], for instanceID: UUID?) {
        guard let instanceID else { return }
        itemsByInstance[instanceID] = items
        fetchedAt[instanceID] = Date()
    }

    /// Marks an instance stale without dropping its items, so the next appear-time
    /// load refetches but the UI keeps rendering what it already has.
    func invalidate(_ instanceID: UUID?) {
        guard let instanceID else { return }
        fetchedAt[instanceID] = nil
    }

    func invalidateAll() {
        fetchedAt.removeAll()
    }

    /// Drops everything for instances that no longer exist, so removed profiles
    /// don't pin a full library in memory for the rest of the session.
    func prune(keeping instanceIDs: Set<UUID>) {
        for id in itemsByInstance.keys where !instanceIDs.contains(id) {
            itemsByInstance[id] = nil
            fetchedAt[id] = nil
            lastStoredSequence[id] = nil
            inFlight[id]?.task.cancel()
            inFlight[id] = nil
        }
    }
}
