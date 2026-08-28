import Foundation

// Everything the rest of the app uses to talk about "which server".
//
// The manager already held every configured instance and connected them all; what
// it lacked was a way to *use* more than one at a time. These are the accessors
// that turn its instance arrays into a blended library: identity for badges,
// clients for routing a command back to the server that owns an item, and loads
// that fan out across both servers instead of picking one.

extension ArrServiceManager {

    // MARK: - Identity

    /// Badge-ready identity for every configured Sonarr server, in the user's
    /// configured order.
    var sonarrRefs: [ArrInstanceRef] {
        refs(from: sonarrInstances.map { (id: $0.id, displayName: $0.displayName) }, serviceType: .sonarr)
    }

    var radarrRefs: [ArrInstanceRef] {
        refs(from: radarrInstances.map { (id: $0.id, displayName: $0.displayName) }, serviceType: .radarr)
    }

    var bazarrRefs: [ArrInstanceRef] {
        refs(from: bazarrInstances.map { (id: $0.id, displayName: $0.displayName) }, serviceType: .bazarr)
    }

    /// The tier comes from the stored profile, which is the only place it is
    /// declared. A connected instance whose profile has gone is dropped rather
    /// than guessed at.
    private func refs(
        from entries: [(id: UUID, displayName: String)],
        serviceType: ArrServiceType
    ) -> [ArrInstanceRef] {
        let tiers = Dictionary(
            storedProfiles.map { ($0.id, $0.qualityTier) },
            uniquingKeysWith: { first, _ in first }
        )
        return ArrInstanceRef.make(
            from: entries.map { (id: $0.id, displayName: $0.displayName, tier: tiers[$0.id] ?? .hd) },
            serviceType: serviceType
        )
    }

    func refs(for serviceType: ArrServiceType) -> [ArrInstanceRef] {
        switch serviceType {
        case .sonarr: sonarrRefs
        case .radarr: radarrRefs
        case .bazarr: bazarrRefs
        case .prowlarr:
            prowlarrProfileRef.map { [$0] } ?? []
        }
    }

    private var prowlarrProfileRef: ArrInstanceRef? {
        guard let id = activeProwlarrProfileID else { return nil }
        let name = storedProfileName(for: id) ?? ArrServiceType.prowlarr.displayName
        // Prowlarr is a single indexer manager, not half of a library pair; it
        // takes the default tier and never badges.
        return ArrInstanceRef(id: id, serviceType: .prowlarr, displayName: name, tier: .hd)
    }

    /// Identity for one server, or `nil` if it is no longer configured.
    func instanceRef(_ serviceType: ArrServiceType, id: UUID?) -> ArrInstanceRef? {
        guard let id else { return nil }
        return refs(for: serviceType).first { $0.id == id }
    }

    /// True when more than one server of this type is configured — the condition
    /// under which a provenance badge earns its place. With a single instance the
    /// badge distinguishes nothing and is noise on every row in the app.
    func showsInstanceProvenance(for serviceType: ArrServiceType) -> Bool {
        refs(for: serviceType).count > 1
    }

    /// Badges for a merged library entry: one per server holding the title,
    /// suppressed entirely when provenance isn't worth showing.
    func badgeRefs<Item>(for entry: ArrLibraryEntry<Item>) -> [ArrInstanceRef] {
        let serviceType = entry.id.serviceType
        guard showsInstanceProvenance(for: serviceType) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: refs(for: serviceType).map { ($0.id, $0) })
        return entry.instanceIDs.compactMap { byID[$0] }
    }

    // MARK: - Capacity

    /// How many more servers of this type the user may add.
    ///
    /// Sonarr and Radarr are capped at two — the HD/4K pair the blended library is
    /// designed around. Prowlarr stays at one (a second replaces the first, as it
    /// always has) and Bazarr is uncapped, since it is matched to its own Sonarr
    /// and Radarr rather than merged into the library.
    func instanceSlotsRemaining(of serviceType: ArrServiceType) -> Int? {
        switch serviceType {
        case .sonarr, .radarr:
            return max(0, availableTiers(for: serviceType).count)
        case .prowlarr, .bazarr:
            return nil
        }
    }

    /// The tiers this service has no server for yet. Setup offers exactly these,
    /// so the pair can never end up with two HD servers and no 4K one.
    func availableTiers(for serviceType: ArrServiceType) -> [ArrQualityTier] {
        let taken = Set(refs(for: serviceType).map(\.tier))
        return ArrQualityTier.allCases.filter { !taken.contains($0) }
    }

    /// The server holding a given tier, if one is configured.
    func instance(_ serviceType: ArrServiceType, tier: ArrQualityTier) -> ArrInstanceRef? {
        refs(for: serviceType).first { $0.tier == tier }
    }

    func canAddInstance(of serviceType: ArrServiceType) -> Bool {
        guard let remaining = instanceSlotsRemaining(of: serviceType) else { return true }
        return remaining > 0
    }

    // MARK: - Clients

    /// Every connected Sonarr server, paired with its identity, in configured
    /// order. This is the list a fan-out iterates.
    var connectedSonarr: [(ref: ArrInstanceRef, client: SonarrAPIClient)] {
        pair(sonarrInstances, with: sonarrRefs)
    }

    var connectedRadarr: [(ref: ArrInstanceRef, client: RadarrAPIClient)] {
        pair(radarrInstances, with: radarrRefs)
    }

    /// The connected servers the instance filter is currently showing. Every
    /// unified surface reads this rather than `connectedSonarr`, so narrowing the
    /// filter narrows the whole app at once.
    var visibleSonarr: [(ref: ArrInstanceRef, client: SonarrAPIClient)] {
        connectedSonarr.filter { instanceFilter.isIncluded($0.ref.id, serviceType: .sonarr) }
    }

    var visibleRadarr: [(ref: ArrInstanceRef, client: RadarrAPIClient)] {
        connectedRadarr.filter { instanceFilter.isIncluded($0.ref.id, serviceType: .radarr) }
    }

    private func pair<C: SharedArrClient>(
        _ entries: [ArrClientEntry<C>],
        with refs: [ArrInstanceRef]
    ) -> [(ref: ArrInstanceRef, client: C)] {
        let byID = Dictionary(uniqueKeysWithValues: refs.map { ($0.id, $0) })
        return entries.compactMap { entry in
            guard entry.isConnected, let client = entry.client, let ref = byID[entry.id] else { return nil }
            return (ref: ref, client: client)
        }
    }

    // MARK: - Command routing

    /// The Radarr server that owns a given movie. Every mutation in a merged list
    /// goes through here: without it a delete issued from a merged row would land
    /// on whichever instance happened to be active, which in an HD/4K pair means
    /// deleting the wrong copy — or a different film entirely, since the two
    /// servers reuse the same integer IDs.
    func radarrClient(owning movie: RadarrMovie) -> RadarrAPIClient? {
        guard let instanceID = movie.instanceID else { return radarrClient }
        return radarrClient(for: instanceID)
    }

    func sonarrClient(owning series: SonarrSeries) -> SonarrAPIClient? {
        guard let instanceID = series.instanceID else { return sonarrClient }
        return sonarrClient(for: instanceID)
    }

    // MARK: - Blended library loads

    /// Every visible Sonarr server's library, as one flat union, each item stamped
    /// with the server it came from.
    ///
    /// Each instance keeps its own cache entry, so a slow second server doesn't
    /// re-fetch the first, and one server failing yields a partial library rather
    /// than none — a broken 4K instance should not empty the HD library off the
    /// screen. The first error is reported so the failure is still visible.
    @discardableResult
    func loadSeriesUnion(maxAge: TimeInterval = 0) async throws -> [SonarrSeries] {
        try await loadUnion(
            instances: visibleSonarr,
            cache: seriesLibrary,
            maxAge: maxAge
        ) { try await $0.getSeries() }
    }

    /// Every visible Radarr server's library. See `loadSeriesUnion(maxAge:)`.
    @discardableResult
    func loadMovieUnion(maxAge: TimeInterval = 0) async throws -> [RadarrMovie] {
        try await loadUnion(
            instances: visibleRadarr,
            cache: movieLibrary,
            maxAge: maxAge
        ) { try await $0.getMovies() }
    }

    private func loadUnion<C: SharedArrClient, Item: ArrInstanceScoped & Sendable>(
        instances: [(ref: ArrInstanceRef, client: C)],
        cache: ArrLibraryCache<Item>,
        maxAge: TimeInterval,
        fetch: @escaping @Sendable (C) async throws -> [Item]
    ) async throws -> [Item] {
        guard !instances.isEmpty else { return [] }

        var union: [Item] = []
        var firstError: Error?

        for (ref, client) in instances {
            do {
                let items = try await cache.load(instanceID: ref.id, maxAge: maxAge) {
                    // Stamped inside the cache's fetch so the cached copy carries
                    // provenance too — a cache hit must be indistinguishable from
                    // a fresh load, or a merged row would lose its badges the
                    // second time it renders.
                    try await fetch(client).stamped(with: ref.id)
                }
                union.append(contentsOf: items)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // A total failure is a real failure; a partial one is a partial library.
        if union.isEmpty, let firstError { throw firstError }
        return union
    }

    /// The blended movie library: one entry per title, carrying every server's
    /// copy of it.
    var mergedMovieLibrary: [ArrLibraryEntry<RadarrMovie>] {
        cachedMovieUnion.mergedByTitle()
    }

    /// The blended series library. See `mergedMovieLibrary`.
    var mergedSeriesLibrary: [ArrLibraryEntry<SonarrSeries>] {
        cachedSeriesUnion.mergedByTitle()
    }

    /// The flat union of what is currently cached for every visible Radarr server,
    /// in configured order. Kept alongside the merged view because per-server
    /// truth — disk usage, counts, which server to send a command to — cannot be
    /// recovered once titles are collapsed into rows.
    var cachedMovieUnion: [RadarrMovie] {
        visibleRadarr.flatMap { movieLibrary.items(for: $0.ref.id) }
    }

    var cachedSeriesUnion: [SonarrSeries] {
        visibleSonarr.flatMap { seriesLibrary.items(for: $0.ref.id) }
    }

    // MARK: - Instance filter

    /// Shows or hides one server across every unified surface at once.
    /// No UI calls this yet — the picker is the next piece of work.
    @discardableResult
    func setInstanceIncluded(
        _ included: Bool,
        instanceID: UUID,
        serviceType: ArrServiceType
    ) -> Bool {
        var filter = instanceFilter
        let changed = filter.setIncluded(
            included,
            instanceID: instanceID,
            serviceType: serviceType,
            available: Set(refs(for: serviceType).map(\.id))
        )
        if changed { applyInstanceFilter(filter) }
        return changed
    }

    func showOnlyInstance(_ instanceID: UUID, serviceType: ArrServiceType) {
        var filter = instanceFilter
        filter.setOnly(
            instanceID: instanceID,
            serviceType: serviceType,
            available: Set(refs(for: serviceType).map(\.id))
        )
        applyInstanceFilter(filter)
    }

    func showAllInstances(of serviceType: ArrServiceType) {
        var filter = instanceFilter
        filter.includeAll(serviceType: serviceType)
        applyInstanceFilter(filter)
    }

    /// Drops filter entries for servers that no longer exist. Called after every
    /// profile change so a deleted-and-re-added server can't inherit a stale hide.
    func pruneInstanceFilter() {
        var filter = instanceFilter
        for serviceType in ArrServiceType.allCases {
            filter.prune(keeping: Set(refs(for: serviceType).map(\.id)), serviceType: serviceType)
        }
        if filter != instanceFilter { applyInstanceFilter(filter) }
    }

    private func applyInstanceFilter(_ filter: ArrInstanceFilterState) {
        instanceFilter = filter
        filter.save(to: .standard)
        // What each surface shows is derived from the filter, so everything that
        // reads a cached library has to re-derive. Items are kept; only freshness
        // is dropped, so a narrowed filter re-renders immediately.
        invalidateLibraryCaches()
    }

    private func storedProfileName(for id: UUID) -> String? {
        storedProfiles.first { $0.id == id }?.displayName
    }
}

// MARK: - Admin fan-out

extension ArrServiceManager {

    /// Every connected Sonarr and Radarr instance, paired with its identity, in
    /// service then configured order.
    ///
    /// This is the list the per-server admin screens iterate. They used to read
    /// "the Sonarr client" and "the Radarr client" and present two sections; they
    /// now present one section per *server*, because root folders, download
    /// clients, naming formats and scheduled tasks are configured per server and a
    /// pair's two halves rarely agree.
    var visibleArrInstances: [(ref: ArrInstanceRef, client: any SharedArrClient)] {
        visibleSonarr.map { (ref: $0.ref, client: $0.client as any SharedArrClient) }
            + visibleRadarr.map { (ref: $0.ref, client: $0.client as any SharedArrClient) }
    }

    /// Runs one read against every visible Sonarr and Radarr, tagging each result
    /// with the server it came from and collecting per-server failures rather than
    /// failing the whole screen.
    func fanOutAcrossArrInstances<T: Identifiable & Sendable>(
        _ fetch: @Sendable (any SharedArrClient) async throws -> [T]
    ) async -> (items: [ArrInstanced<T>], errors: [String]) {
        var items: [ArrInstanced<T>] = []
        var errors: [String] = []
        for (ref, client) in visibleArrInstances {
            do {
                items += try await fetch(client).instanced(on: ref)
            } catch {
                errors.append("\(ref.displayName): \(error.localizedDescription)")
            }
        }
        return (items, errors)
    }

    /// The same fan-out for reads that return a single value per server rather
    /// than a list — naming config, media management, host config.
    func fanOutSingleAcrossArrInstances<T: Sendable>(
        _ fetch: @Sendable (any SharedArrClient) async throws -> T
    ) async -> (items: [(ref: ArrInstanceRef, value: T)], errors: [String]) {
        var items: [(ref: ArrInstanceRef, value: T)] = []
        var errors: [String] = []
        for (ref, client) in visibleArrInstances {
            do {
                items.append((ref: ref, value: try await fetch(client)))
            } catch {
                errors.append("\(ref.displayName): \(error.localizedDescription)")
            }
        }
        return (items, errors)
    }
}

// MARK: - Per-server configuration

extension ArrServiceManager {

    /// Root folders for every visible Sonarr and Radarr, tagged with the server
    /// that owns them.
    ///
    /// Already cached per instance by `connectService`, so this is a regrouping
    /// rather than a fetch. The screens that read it used to show "the Sonarr
    /// root folders", which meant one server's — and an HD/4K pair almost never
    /// shares a root folder, so the other server's were simply invisible.
    var rootFoldersByInstance: [(ref: ArrInstanceRef, values: [ArrRootFolder])] {
        configurationByInstance({ $0.rootFolders }, { $0.rootFolders })
    }

    var qualityProfilesByInstance: [(ref: ArrInstanceRef, values: [ArrQualityProfile])] {
        configurationByInstance({ $0.qualityProfiles }, { $0.qualityProfiles })
    }

    var tagsByInstance: [(ref: ArrInstanceRef, values: [ArrTag])] {
        configurationByInstance({ $0.tags }, { $0.tags })
    }

    private func configurationByInstance<T>(
        _ sonarrValues: (SonarrClientEntry) -> [T],
        _ radarrValues: (RadarrClientEntry) -> [T]
    ) -> [(ref: ArrInstanceRef, values: [T])] {
        let sonarrByID = Dictionary(uniqueKeysWithValues: sonarrInstances.map { ($0.id, $0) })
        let radarrByID = Dictionary(uniqueKeysWithValues: radarrInstances.map { ($0.id, $0) })
        return visibleSonarr.compactMap { pair in
            sonarrByID[pair.ref.id].map { (ref: pair.ref, values: sonarrValues($0)) }
        } + visibleRadarr.compactMap { pair in
            radarrByID[pair.ref.id].map { (ref: pair.ref, values: radarrValues($0)) }
        }
    }
}
