import Foundation
import Network
import SwiftData
import Testing
@testable import Trawl

/// The blended library: two Sonarr and two Radarr servers presented as one list,
/// with server identity kept as provenance rather than as a navigation axis.
///
/// These tests pin the parts that are silently wrong rather than loudly broken.
/// Two *arr servers hand out the same small integer IDs for different titles, so
/// every failure mode here looks like success: a delete that removes the wrong
/// film, a badge that names the wrong server, a search dispatched to the server
/// that wasn't missing anything.
@Suite("Arr dual instance")
@MainActor
struct ArrDualInstanceTests {

    // MARK: - Quality tiers

    @Test("A server's badge is its declared tier, not its name")
    func badgeComesFromTheDeclaredTier() {
        // An earlier pass parsed "HD" and "4K" out of whatever the user had named
        // the server. That worked for "4K Radarr" and produced nonsense for
        // "Radarr (big box)". The tier is declared at setup instead.
        let refs = ArrInstanceRef.make(
            from: [
                (id: UUID(), displayName: "Radarr (big box)", tier: .uhd),
                (id: UUID(), displayName: "spare", tier: .hd)
            ],
            serviceType: .radarr
        )
        #expect(refs.map(\.shortLabel) == ["HD", "4K"])
        #expect(refs.map(\.displayName) == ["spare", "Radarr (big box)"])
    }

    @Test("HD always sorts and colours before 4K, whatever order they were added")
    func tierDrivesOrderingNotInsertionOrder() {
        // "The blue one" has to be the same server on every screen, so the badge
        // position comes from the tier rather than from which was configured first.
        let refs = ArrInstanceRef.make(
            from: [
                (id: UUID(), displayName: "Second", tier: .uhd),
                (id: UUID(), displayName: "First", tier: .hd)
            ],
            serviceType: .sonarr
        )
        #expect(refs.map(\.shortLabel) == ["HD", "4K"])
        #expect(refs.map(\.ordinal) == [0, 1])
    }

    @Test("There are exactly as many instance slots as there are tiers")
    func theCapIsAConsequenceOfTheTiers() {
        // The two-instance limit is not a separate rule: a third server would have
        // no tier to hold and no badge to wear.
        #expect(ArrInstanceRef.maxInstancesPerServiceType == ArrQualityTier.allCases.count)
        #expect(ArrQualityTier.allCases.map(\.label) == ["HD", "4K"])
    }

    // MARK: - Availability pills

    @Test("Availability says which tiers hold the title", arguments: [
        ([ArrQualityTier.hd, .uhd], true, "Available HD & 4K"),
        ([.hd], true, "Available HD"),
        ([.uhd], true, "Available 4K"),
        ([], true, "Missing")
    ])
    func availabilityLabelNamesTheTiers(tiers: [ArrQualityTier], showsTiers: Bool, expected: String) {
        #expect(
            ArrAvailabilityPill.label(availableTiers: tiers, showsTiers: showsTiers, unavailableStatus: "Missing")
                == expected
        )
    }

    @Test("A single-server library says only Available")
    func availabilityOmitsTiersWithOneServer() {
        // "Available HD" on a one-server setup implies a 4K library that does not
        // exist.
        #expect(
            ArrAvailabilityPill.label(availableTiers: [.hd], showsTiers: false, unavailableStatus: "Missing")
                == "Available"
        )
    }

    @Test("Tiers are named in HD-then-4K order however the copies arrive")
    func availabilityLabelIsOrderIndependent() {
        #expect(
            ArrAvailabilityPill.label(availableTiers: [.uhd, .hd], showsTiers: true, unavailableStatus: "Missing")
                == "Available HD & 4K"
        )
    }

    @Test("Availability is matched by server, not by position")
    func availabilityTiersAreMatchedByInstance() throws {
        // A filtered or partially-loaded library hands back fewer refs than
        // copies. Zipping them would then label a copy with the wrong server — and
        // "Available 4K" on a film that only exists in HD is the worst kind of
        // wrong, because it looks right.
        let hd = ArrInstanceRef.preview(.radarr, tier: .hd)
        let uhd = ArrInstanceRef.preview(.radarr, tier: .uhd)
        let entry = try #require([
            try Self.movie(id: 1, title: "Dune", tmdbId: 438_631, hasFile: false).stamped(with: hd.id),
            try Self.movie(id: 4, title: "Dune", tmdbId: 438_631, hasFile: true).stamped(with: uhd.id)
        ].mergedByTitle().first)

        #expect(entry.availableTiers(from: [hd, uhd]) { $0.hasFile == true } == [.uhd])
        // Only the HD server visible: the 4K copy contributes nothing.
        #expect(entry.availableTiers(from: [hd]) { $0.hasFile == true } == [])
    }

    // MARK: - Identity

    @Test("A movie's identity is its server plus its ID, not its ID alone")
    func movieIdentityIncludesTheServer() throws {
        // This is the correctness core of the whole change. Both Radarr servers
        // number their libraries from 1, so ID-only equality makes the HD copy of
        // one film compare equal to the 4K copy of a different one — and a merged
        // list then renders, selects and deletes the wrong rows.
        let hd = UUID()
        let uhd = UUID()
        let a = try Self.movie(id: 7, title: "Dune", tmdbId: 438_631).stamped(with: hd)
        let b = try Self.movie(id: 7, title: "Sinners", tmdbId: 1_233_413).stamped(with: uhd)
        let aAgain = try Self.movie(id: 7, title: "Dune", tmdbId: 438_631).stamped(with: hd)

        #expect(a != b)
        #expect(a == aAgain)
        #expect(Set([a, b]).count == 2)
    }

    @Test("A series' identity is its server plus its ID")
    func seriesIdentityIncludesTheServer() throws {
        let hd = UUID()
        let uhd = UUID()
        let a = try Self.series(id: 3, title: "Severance", tvdbId: 371_980).stamped(with: hd)
        let b = try Self.series(id: 3, title: "Andor", tvdbId: 368_051).stamped(with: uhd)

        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("Provenance is never sent back to a server")
    func instanceIDIsNotEncoded() throws {
        // instanceID is Trawl's own bookkeeping. Radarr's update endpoint takes the
        // whole movie back, so an encoded instanceID would be posted to the server
        // on every edit.
        let movie = try Self.movie(id: 1, title: "Dune", tmdbId: 438_631)
            .stamped(with: UUID())
        let data = try JSONEncoder().encode(movie)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["instanceID"] == nil)
        #expect(object["instanceId"] == nil)
    }

    @Test("An edit keeps the movie on the server it came from")
    func editPreservesProvenance() throws {
        let instance = UUID()
        let edited = try Self.movie(id: 1, title: "Dune", tmdbId: 438_631)
            .stamped(with: instance)
            .updatingForEdit(
                monitored: false,
                qualityProfileId: 2,
                minimumAvailability: "released",
                rootFolderPath: "/movies",
                tags: []
            )
        // Losing it here would leave the next command on the edited value unrouted.
        #expect(edited.instanceID == instance)
    }

    // MARK: - Merging

    @Test("The same film on two servers becomes one row carrying both copies")
    func sameFilmOnBothServersMergesIntoOneEntry() throws {
        let hd = UUID()
        let uhd = UUID()
        let union = [
            try Self.movie(id: 1, title: "Dune", tmdbId: 438_631).stamped(with: hd),
            try Self.movie(id: 9, title: "Sinners", tmdbId: 1_233_413).stamped(with: hd),
            try Self.movie(id: 4, title: "Dune", tmdbId: 438_631).stamped(with: uhd)
        ]

        let entries = union.mergedByTitle()

        #expect(entries.count == 2)
        let dune = try #require(entries.first { $0.primary.title == "Dune" })
        #expect(dune.copies.count == 2)
        // Copies keep the order the union arrived in, which is configured server
        // order — that is what makes `primary`, and so the rendered row, stable
        // across refreshes.
        #expect(dune.copies.map(\.instanceID) == [hd, uhd])
        #expect(dune.isOnMultipleInstances == true)
        #expect(entries.first { $0.primary.title == "Sinners" }?.isOnMultipleInstances == false)
    }

    @Test("Two different films sharing a library ID stay two rows")
    func differentFilmsWithTheSameLibraryIDDoNotMerge() throws {
        // The failure this guards is invisible without external IDs: both servers
        // call something id 1, and merging on the library ID would fuse unrelated
        // films into one row.
        let union = [
            try Self.movie(id: 1, title: "Dune", tmdbId: 438_631).stamped(with: UUID()),
            try Self.movie(id: 1, title: "Sinners", tmdbId: 1_233_413).stamped(with: UUID())
        ]
        #expect(union.mergedByTitle().count == 2)
    }

    @Test("A remake does not merge into its original")
    func sameTitleDifferentYearDoesNotMerge() throws {
        // With no external ID the merge falls back to title, and title alone would
        // collapse The Thing (1982) into The Thing (2011).
        let union = [
            try Self.movie(id: 1, title: "The Thing", tmdbId: nil, year: 1982).stamped(with: UUID()),
            try Self.movie(id: 2, title: "The Thing", tmdbId: nil, year: 2011).stamped(with: UUID())
        ]
        #expect(union.mergedByTitle().count == 2)
    }

    @Test("The same title with no external ID merges only with an equally yearless copy")
    func titleFallbackMergesOnTitleAndYear() throws {
        let union = [
            try Self.movie(id: 1, title: "The Thing", tmdbId: nil, year: 1982).stamped(with: UUID()),
            try Self.movie(id: 7, title: "the  thing", tmdbId: nil, year: 1982).stamped(with: UUID())
        ]
        #expect(union.mergedByTitle().count == 1)
    }

    @Test("Series merge on TVDb")
    func seriesMergeOnTvdb() throws {
        let union = [
            try Self.series(id: 1, title: "Severance", tvdbId: 371_980).stamped(with: UUID()),
            try Self.series(id: 8, title: "Severance", tvdbId: 371_980).stamped(with: UUID())
        ]
        #expect(union.mergedByTitle().count == 1)
    }

    @Test("A Sonarr and a Radarr entry can never collide")
    func mergeKeysAreScopedToTheirService() throws {
        // Both keys would otherwise be "…:12345" and could collide in a navigation
        // path, pushing a movie detail for a series.
        let movie = try Self.movie(id: 1, title: "Shared", tmdbId: 12_345)
        let series = try Self.series(id: 1, title: "Shared", tvdbId: 12_345)
        #expect(movie.mergeKey != series.mergeKey)
    }

    @Test("An entry resolves the copy a library ID belongs to")
    func entryResolvesCopyByLibraryID() throws {
        let hd = UUID()
        let uhd = UUID()
        let entry = try #require([
            try Self.movie(id: 1, title: "Dune", tmdbId: 438_631).stamped(with: hd),
            try Self.movie(id: 4, title: "Dune", tmdbId: 438_631).stamped(with: uhd)
        ].mergedByTitle().first)

        // This is how an ID-only entry point — a widget, a Siri intent, a Seerr
        // deep link — lands on the same screen as tapping the merged row.
        #expect(entry.copy(withLibraryID: 4)?.instanceID == uhd)
        #expect(entry.copy(on: hd)?.id == 1)
        #expect(entry.copy(withLibraryID: 99) == nil)
    }

    // MARK: - Instance filter

    @Test("An unconfigured filter shows everything")
    func filterDefaultsToShowingEverything() {
        let filter = ArrInstanceFilterState()
        #expect(filter.isIncluded(UUID(), serviceType: .radarr))
        #expect(filter.isShowingAll(.radarr))
    }

    @Test("Hiding a server removes only its items")
    func filterRemovesOnlyTheHiddenServersItems() throws {
        let hd = UUID()
        let uhd = UUID()
        var filter = ArrInstanceFilterState()
        let didHide = filter.setIncluded(false, instanceID: uhd, serviceType: .radarr, available: [hd, uhd])
        #expect(didHide)

        let items = [
            try Self.movie(id: 1, title: "HD", tmdbId: 1).stamped(with: hd),
            try Self.movie(id: 2, title: "4K", tmdbId: 2).stamped(with: uhd)
        ]
        #expect(filter.apply(to: items, serviceType: .radarr).map(\.title) == ["HD"])
    }

    @Test("Hiding the last visible server is refused")
    func filterRefusesToHideEverything() {
        // An empty library with the control that emptied it is a dead end, and the
        // filter has no UI yet, so there would be nothing to undo it with.
        let only = UUID()
        var filter = ArrInstanceFilterState()
        let didHide = filter.setIncluded(false, instanceID: only, serviceType: .radarr, available: [only])
        #expect(didHide == false)
        #expect(filter.isIncluded(only, serviceType: .radarr))
    }

    @Test("Narrowing to one server hides the other")
    func filterCanNarrowToASingleServer() {
        let hd = UUID()
        let uhd = UUID()
        var filter = ArrInstanceFilterState()
        filter.setOnly(instanceID: uhd, serviceType: .radarr, available: [hd, uhd])
        #expect(filter.isIncluded(uhd, serviceType: .radarr))
        #expect(filter.isIncluded(hd, serviceType: .radarr) == false)

        filter.includeAll(serviceType: .radarr)
        #expect(filter.isShowingAll(.radarr))
    }

    @Test("Items with no server survive the filter")
    func filterKeepsUnstampedItems() throws {
        // Lookup results, previews and fixtures belong to no server. Treating
        // "unknown" as "excluded" would make discover results vanish whenever a
        // filter happened to be set.
        let hidden = UUID()
        let kept = UUID()
        var filter = ArrInstanceFilterState()
        filter.setOnly(instanceID: kept, serviceType: .radarr, available: [hidden, kept])
        #expect(filter.isIncluded(hidden, serviceType: .radarr) == false)
        let lookupResult = try Self.movie(id: 0, title: "Not in library", tmdbId: 5)
        #expect(filter.apply(to: [lookupResult], serviceType: .radarr).count == 1)
    }

    @Test("A filter for a service is independent of the other service")
    func filterIsPerService() {
        let radarrID = UUID()
        let otherRadarrID = UUID()
        var filter = ArrInstanceFilterState()
        filter.setOnly(instanceID: otherRadarrID, serviceType: .radarr, available: [radarrID, otherRadarrID])
        #expect(filter.isIncluded(radarrID, serviceType: .radarr) == false)
        #expect(filter.isShowingAll(.sonarr))
        #expect(filter.isIncluded(radarrID, serviceType: .sonarr))
    }

    @Test("A removed server's exclusion is pruned")
    func filterPrunesDeletedServers() {
        // Without this, deleting and re-adding a server would silently inherit the
        // old hide, and removed UUIDs would accumulate in preferences forever.
        let gone = UUID()
        let kept = UUID()
        var filter = ArrInstanceFilterState()
        filter.setOnly(instanceID: kept, serviceType: .radarr, available: [gone, kept])
        #expect(filter.excludedInstanceIDs(for: .radarr) == [gone])

        filter.prune(keeping: [kept], serviceType: .radarr)
        #expect(filter.isShowingAll(.radarr))
    }

    @Test("A saved filter round-trips, and a corrupt one fails open")
    func filterPersistence() throws {
        let defaults = try #require(UserDefaults(suiteName: "ArrDualInstanceTests.filter"))
        defaults.removePersistentDomain(forName: "ArrDualInstanceTests.filter")

        let hidden = UUID()
        let kept = UUID()
        var filter = ArrInstanceFilterState()
        filter.setOnly(instanceID: kept, serviceType: .sonarr, available: [hidden, kept])
        filter.save(to: defaults)
        #expect(ArrInstanceFilterState.load(from: defaults).excludedInstanceIDs(for: .sonarr) == [hidden])

        // A corrupt preference should cost the user their filter, not their library.
        defaults.set(Data("not json".utf8), forKey: ArrInstanceFilterState.defaultsKey)
        #expect(ArrInstanceFilterState.load(from: defaults).isShowingAll(.sonarr))

        defaults.removePersistentDomain(forName: "ArrDualInstanceTests.filter")
    }

    // MARK: - Capacity

    @Test("Sonarr and Radarr are tiered; Prowlarr and Bazarr are not")
    func instanceLimits() {
        #expect(ArrSetupViewModel.usesQualityTiers(.sonarr))
        #expect(ArrSetupViewModel.usesQualityTiers(.radarr))
        #expect(ArrSetupViewModel.usesQualityTiers(.prowlarr) == false)
        #expect(ArrSetupViewModel.usesQualityTiers(.bazarr) == false)
        #expect(ArrSetupViewModel.instanceLimit(for: .sonarr) == 2)
        #expect(ArrSetupViewModel.instanceLimit(for: .prowlarr) == nil)
    }

    @Test("An existing untiered pair is split into HD and 4K by age")
    func migrationAssignsTiersToAnExistingPair() {
        // The tier was added after multi-instance already worked, so a user with
        // two Sonarr servers has two profiles that both default to HD. Left alone
        // they badge identically and collide in the merged row. The 4K instance is
        // the one added second, in every setup that grows this way.
        let older = ArrServiceProfile(displayName: "Sonarr", hostURL: "http://a", serviceType: .sonarr)
        let newer = ArrServiceProfile(displayName: "Sonarr 2", hostURL: "http://b", serviceType: .sonarr)
        newer.dateAdded = older.dateAdded.addingTimeInterval(60)
        #expect(older.qualityTier == .hd)
        #expect(newer.qualityTier == .hd)

        ArrServiceManager.normalizeQualityTiers(in: [newer, older])

        #expect(older.qualityTier == .hd)
        #expect(newer.qualityTier == .uhd)
    }

    @Test("A pair that already has a tier each is left alone")
    func migrationIsIdempotent() {
        let hd = ArrServiceProfile(displayName: "HD", hostURL: "http://a", serviceType: .radarr, qualityTier: .hd)
        let uhd = ArrServiceProfile(displayName: "4K", hostURL: "http://b", serviceType: .radarr, qualityTier: .uhd)
        uhd.dateAdded = hd.dateAdded.addingTimeInterval(-60)

        // Deliberately aged backwards: a correct assignment must survive a second
        // launch even when the 4K server happens to be the older profile.
        ArrServiceManager.normalizeQualityTiers(in: [hd, uhd])

        #expect(hd.qualityTier == .hd)
        #expect(uhd.qualityTier == .uhd)
    }

    // MARK: - Fixtures

    /// Decoded rather than constructed, so every fixture goes through the real
    /// decoder — which is where `instanceID` has to start out nil.
    private static func movie(
        id: Int,
        title: String,
        tmdbId: Int? = nil,
        year: Int? = nil,
        hasFile: Bool? = nil
    ) throws -> RadarrMovie {
        var fields = ["\"id\": \(id)", "\"title\": \"\(title)\""]
        if let tmdbId { fields.append("\"tmdbId\": \(tmdbId)") }
        if let year { fields.append("\"year\": \(year)") }
        if let hasFile { fields.append("\"hasFile\": \(hasFile)") }
        return try JSONDecoder().decode(RadarrMovie.self, from: Data("{\(fields.joined(separator: ", "))}".utf8))
    }

    private static func series(id: Int, title: String, tvdbId: Int? = nil) throws -> SonarrSeries {
        var fields = ["\"id\": \(id)", "\"title\": \"\(title)\""]
        if let tvdbId { fields.append("\"tvdbId\": \(tvdbId)") }
        return try JSONDecoder().decode(SonarrSeries.self, from: Data("{\(fields.joined(separator: ", "))}".utf8))
    }
}

// MARK: - Two real servers

/// The manager and view-model half, driven against two loopback Radarr servers.
///
/// The unit tests above pin the merge and identity rules; these pin the thing that
/// actually breaks a user's library — which server a command is sent to. Both
/// servers here deliberately reuse the same library IDs for different films, which
/// is exactly what a real HD/4K pair does.
@Suite("Arr dual instance routing", .serialized)
@MainActor
struct ArrDualInstanceRoutingTests {

    @Test("The library is the union of both servers, each item knowing its server")
    func libraryIsTheUnionOfBothServers() async throws {
        let hd = try await DualInstanceRadarrServer(
            label: "hd",
            movies: #"[{"id":1,"title":"Dune","tmdbId":438631},{"id":2,"title":"Sinners","tmdbId":1233413}]"#
        )
        let uhd = try await DualInstanceRadarrServer(
            label: "4k",
            movies: #"[{"id":1,"title":"Dune","tmdbId":438631}]"#
        )
        defer { hd.stop(); uhd.stop() }

        try await withPair(hd: hd, uhd: uhd) { manager, hdID, uhdID in
            let union = try await manager.loadMovieLibrary()

            #expect(union.count == 3)
            #expect(union.filter { $0.instanceID == hdID }.map(\.title).sorted() == ["Dune", "Sinners"])
            #expect(union.filter { $0.instanceID == uhdID }.map(\.title) == ["Dune"])

            // And the merged view the list actually renders.
            let entries = manager.mergedMovieLibrary
            #expect(entries.count == 2)
            let dune = try #require(entries.first { $0.primary.title == "Dune" })
            #expect(dune.isOnMultipleInstances)
            #expect(dune.instanceIDs == [hdID, uhdID])
        }
    }

    @Test("One server being down leaves the other's library on screen")
    func oneServerFailingYieldsAPartialLibrary() async throws {
        let hd = try await DualInstanceRadarrServer(
            label: "hd-partial",
            movies: #"[{"id":1,"title":"Dune","tmdbId":438631}]"#
        )
        let uhd = try await DualInstanceRadarrServer(label: "4k-partial", movies: "[]")
        defer { hd.stop(); uhd.stop() }

        try await withPair(hd: hd, uhd: uhd) { manager, hdID, _ in
            // Kill the 4K server after both connected, the way one going offline
            // mid-session does. A broken 4K instance must not empty the HD library.
            uhd.stop()

            let union = try await manager.loadMovieLibrary()
            #expect(union.map(\.title) == ["Dune"])
            #expect(union.first?.instanceID == hdID)
        }
    }

    @Test("Deleting a merged row deletes it from both servers, at each server's own ID")
    func deletingAMergedRowHitsBothServers() async throws {
        // The IDs differ on purpose: sending the HD ID to the 4K server is the
        // exact bug this routes around, and it would silently delete a different
        // film rather than fail.
        let hd = try await DualInstanceRadarrServer(
            label: "hd-delete",
            movies: #"[{"id":11,"title":"Dune","tmdbId":438631}]"#
        )
        let uhd = try await DualInstanceRadarrServer(
            label: "4k-delete",
            movies: #"[{"id":77,"title":"Dune","tmdbId":438631}]"#
        )
        defer { hd.stop(); uhd.stop() }

        try await withPair(hd: hd, uhd: uhd) { manager, _, _ in
            let viewModel = RadarrViewModel(serviceManager: manager)
            await viewModel.loadMovies()

            let entry = try #require(viewModel.filteredItems.first)
            #expect(entry.copies.count == 2)

            await viewModel.deleteEntries([entry], deleteFiles: false)

            #expect(hd.deletedPaths == ["/api/v3/movie/11"])
            #expect(uhd.deletedPaths == ["/api/v3/movie/77"])
            #expect(viewModel.movies.isEmpty)
        }
    }

    @Test("A search is dispatched to the server that owns the copy")
    func searchIsRoutedToTheOwningServer() async throws {
        let hd = try await DualInstanceRadarrServer(
            label: "hd-search",
            movies: #"[{"id":11,"title":"Dune","tmdbId":438631}]"#
        )
        let uhd = try await DualInstanceRadarrServer(
            label: "4k-search",
            movies: #"[{"id":77,"title":"Dune","tmdbId":438631}]"#
        )
        defer { hd.stop(); uhd.stop() }

        try await withPair(hd: hd, uhd: uhd) { manager, _, uhdID in
            let viewModel = RadarrViewModel(serviceManager: manager)
            await viewModel.loadMovies()

            // "Search for the 4K copy" must reach the 4K server. Sent to the HD
            // server it would grab an HD release into the wrong library.
            _ = await viewModel.searchMovie(movieId: 77, instanceID: uhdID)

            #expect(uhd.commandBodies.count == 1)
            #expect(hd.commandBodies.isEmpty)
        }
    }

    @Test("An import scan stays on the selected 4K server")
    func importScanUsesTheSelectedServer() async throws {
        let hd = try await DualInstanceRadarrServer(label: "hd-import", movies: "[]")
        let uhd = try await DualInstanceRadarrServer(label: "4k-import", movies: "[]")
        defer { hd.stop(); uhd.stop() }

        try await withPair(hd: hd, uhd: uhd) { manager, _, uhdID in
            let viewModel = LibraryImportScanViewModel(
                path: "/imports/movies",
                service: .radarr,
                serviceManager: manager,
                instanceID: uhdID
            )
            viewModel.autoIdentifyEnabled = false

            await viewModel.loadFiles()

            #expect(viewModel.scanError == nil)
            #expect(hd.requestedPaths.filter { $0.hasPrefix("/api/v3/manualimport") }.isEmpty)
            #expect(uhd.requestedPaths.contains { $0.hasPrefix("/api/v3/manualimport") })
        }
    }

    @Test("Root folders remain scoped to their server")
    func rootFoldersAreScopedByInstance() async throws {
        let hd = try await DualInstanceRadarrServer(
            label: "hd-roots",
            movies: "[]",
            rootFolders: #"[{"id":1,"path":"/media/hd"}]"#
        )
        let uhd = try await DualInstanceRadarrServer(
            label: "4k-roots",
            movies: "[]",
            rootFolders: #"[{"id":2,"path":"/media/4k"}]"#
        )
        defer { hd.stop(); uhd.stop() }

        try await withPair(hd: hd, uhd: uhd) { manager, hdID, uhdID in
            #expect(manager.rootFolders(for: hdID).map(\.path) == ["/media/hd"])
            #expect(manager.rootFolders(for: uhdID).map(\.path) == ["/media/4k"])
        }
    }

    @Test("Badges appear only once a second server exists")
    func provenanceIsSuppressedForASingleServer() async throws {
        let hd = try await DualInstanceRadarrServer(label: "hd-badge", movies: "[]")
        let uhd = try await DualInstanceRadarrServer(label: "4k-badge", movies: "[]")
        defer { hd.stop(); uhd.stop() }

        let manager = ArrServiceManager()
        let hdProfile = ArrServiceProfile(displayName: "Radarr HD", hostURL: hd.baseURL, serviceType: .radarr, qualityTier: .hd)
        try await KeychainHelper.shared.save(key: hdProfile.apiKeyKeychainKey, value: "dual-key")
        defer { Task { try? await KeychainHelper.shared.delete(key: hdProfile.apiKeyKeychainKey) } }
        await manager.connectService(hdProfile)

        // One server: a badge saying "Radarr" on every row distinguishes nothing.
        #expect(manager.showsInstanceProvenance(for: .radarr) == false)

        let uhdProfile = ArrServiceProfile(displayName: "4K Radarr", hostURL: uhd.baseURL, serviceType: .radarr, qualityTier: .uhd)
        try await KeychainHelper.shared.save(key: uhdProfile.apiKeyKeychainKey, value: "dual-key")
        defer { Task { try? await KeychainHelper.shared.delete(key: uhdProfile.apiKeyKeychainKey) } }
        await manager.connectService(uhdProfile)

        #expect(manager.showsInstanceProvenance(for: .radarr))
        #expect(manager.radarrRefs.map(\.shortLabel) == ["HD", "4K"])
        #expect(manager.canAddInstance(of: .radarr) == false)
        #expect(manager.instanceSlotsRemaining(of: .radarr) == 0)
    }

    @Test("A hidden server drops out of the library without disconnecting")
    func filterNarrowsTheBlendedLibrary() async throws {
        let hd = try await DualInstanceRadarrServer(
            label: "hd-filter",
            movies: #"[{"id":1,"title":"Dune","tmdbId":438631}]"#
        )
        let uhd = try await DualInstanceRadarrServer(
            label: "4k-filter",
            movies: #"[{"id":1,"title":"Sinners","tmdbId":1233413}]"#
        )
        defer { hd.stop(); uhd.stop() }

        try await withPair(hd: hd, uhd: uhd) { manager, hdID, uhdID in
            #expect(try await manager.loadMovieLibrary().count == 2)

            manager.showOnlyInstance(hdID, serviceType: .radarr)
            let narrowed = try await manager.loadMovieLibrary()
            #expect(narrowed.map(\.title) == ["Dune"])
            // Hidden, not disconnected — the server is still there to come back to.
            #expect(manager.connectedRadarr.count == 2)
            #expect(manager.visibleRadarr.map(\.ref.id) == [hdID])

            manager.showAllInstances(of: .radarr)
            #expect(try await manager.loadMovieLibrary().count == 2)
            #expect(manager.visibleRadarr.map(\.ref.id) == [hdID, uhdID])
        }
    }

    /// Connects both servers as a Radarr pair, runs the body, and cleans up the
    /// Keychain entries and the persisted instance filter afterwards.
    private func withPair(
        hd: DualInstanceRadarrServer,
        uhd: DualInstanceRadarrServer,
        _ body: (ArrServiceManager, UUID, UUID) async throws -> Void
    ) async throws {
        let manager = ArrServiceManager()
        let hdProfile = ArrServiceProfile(displayName: "Radarr HD", hostURL: hd.baseURL, serviceType: .radarr, qualityTier: .hd)
        let uhdProfile = ArrServiceProfile(displayName: "4K Radarr", hostURL: uhd.baseURL, serviceType: .radarr, qualityTier: .uhd)

        for profile in [hdProfile, uhdProfile] {
            try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "dual-instance-key")
        }
        defer {
            let keys = [hdProfile.apiKeyKeychainKey, uhdProfile.apiKeyKeychainKey]
            Task {
                for key in keys { try? await KeychainHelper.shared.delete(key: key) }
            }
        }

        await manager.connectService(hdProfile)
        await manager.connectService(uhdProfile)
        #expect(manager.connectedRadarr.count == 2)

        try await body(manager, hdProfile.id, uhdProfile.id)

        // The filter persists to standard defaults; leave nothing behind.
        manager.showAllInstances(of: .radarr)
    }
}

/// A loopback Radarr that records the deletes and commands it is sent, so a test
/// can assert *which* server received an action rather than only that it succeeded.
private final class DualInstanceRadarrServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let moviesBody: String
    private let rootFoldersBody: String
    private let lock = NSLock()
    private var deletes: [String] = []
    private var commands: [String] = []
    private var requests: [String] = []

    init(label: String, movies: String, rootFolders: String = "[]") async throws {
        self.queue = DispatchQueue(label: "DualInstanceRadarrServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.moviesBody = movies
        self.rootFoldersBody = rootFolders
        listener.newConnectionHandler = { [weak self] connection in
            self?.respond(to: connection)
        }
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else { fatalError("Dual-instance test server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var deletedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return deletes
    }

    var commandBodies: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }

    var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func stop() { listener.cancel() }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
            let method = parts.first.map(String.init) ?? ""
            let rawPath = parts.dropFirst().first.map(String.init) ?? ""
            let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")

            self.lock.lock()
            self.requests.append(rawPath)
            if method == "DELETE" { self.deletes.append(path) }
            if method == "POST", path == "/api/v3/command" {
                let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
                self.commands.append(body)
            }
            self.lock.unlock()

            let body: String
            switch (method, path) {
            case ("GET", "/api/v3/movie"): body = self.moviesBody
            case ("GET", "/api/v3/rootfolder"): body = self.rootFoldersBody
            case ("GET", "/api/v3/system/status"): body = "{}"
            case ("POST", "/api/v3/command"): body = #"{"id":1,"name":"MoviesSearch"}"#
            case ("DELETE", _): body = "{}"
            default: body = "[]"
            }
            connection.send(
                content: Self.httpResponse(body: body),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func httpResponse(body: String) -> Data {
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }
}
