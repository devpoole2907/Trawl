import Foundation
import Testing
@testable import Trawl

// MARK: - Fixtures

/// Builds `LibraryImportItem` values the only way production can: through
/// `LibraryImportItem.init?(json:)`, from the same manual-import payload shape
/// Sonarr/Radarr return. The memberwise initialiser is private, so this also
/// keeps the JSON parser in the covered path rather than around it.
private nonisolated enum ScanFixture {

    /// The embedded `series` / `movie` object of a manual-import row.
    struct Media {
        var key: String                 // "series" or "movie"
        var title: String?
        /// Sonarr/Radarr send `0` for a parsed-but-not-in-library title, and
        /// `LibraryImportItem.intValue` maps 0 to `nil`.
        var id: Int = 0
        var catalogKey: String?         // "tvdbId" or "tmdbId"
        var catalogID: Int?
        var posterURL: String?

        static func series(title: String?, id: Int = 0, tvdbId: Int? = nil, posterURL: String? = nil) -> Media {
            Media(key: "series", title: title, id: id, catalogKey: "tvdbId", catalogID: tvdbId, posterURL: posterURL)
        }

        static func movie(title: String?, id: Int = 0, tmdbId: Int? = nil, posterURL: String? = nil) -> Media {
            Media(key: "movie", title: title, id: id, catalogKey: "tmdbId", catalogID: tmdbId, posterURL: posterURL)
        }
    }

    static func item(
        path: String,
        size: Int64 = 1_048_576,
        rejections: [String] = [],
        warnings: [String] = [],
        media: Media? = nil,
        seasonNumber: Int? = nil,
        episodeNumbers: [Int] = [],
        quality: String? = nil
    ) -> LibraryImportItem {
        var dict: [String: JSONValue] = [
            "path": .string(path),
            "name": .string((path as NSString).lastPathComponent),
            "size": .number(Double(size))
        ]
        if !rejections.isEmpty {
            dict["rejections"] = .array(rejections.map { JSONValue.object(["reason": .string($0)]) })
        }
        if !warnings.isEmpty {
            dict["warnings"] = .array(warnings.map { JSONValue.string($0) })
        }
        if let media {
            var mediaDict: [String: JSONValue] = ["id": .number(Double(media.id))]
            if let title = media.title { mediaDict["title"] = .string(title) }
            if let catalogKey = media.catalogKey, let catalogID = media.catalogID {
                mediaDict[catalogKey] = .number(Double(catalogID))
            }
            if let posterURL = media.posterURL {
                mediaDict["images"] = .array([
                    .object(["coverType": .string("poster"), "remoteUrl": .string(posterURL)])
                ])
            }
            dict[media.key] = .object(mediaDict)
        }
        if let seasonNumber { dict["seasonNumber"] = .number(Double(seasonNumber)) }
        if !episodeNumbers.isEmpty {
            dict["episodes"] = .array(episodeNumbers.map { number -> JSONValue in
                .object(["id": .number(Double(number * 100)), "episodeNumber": .number(Double(number)), "title": .string("Episode \(number)")])
            })
        }
        if let quality {
            dict["quality"] = .object(["quality": .object(["name": .string(quality)])])
        }
        guard let item = LibraryImportItem(json: .object(dict)) else {
            fatalError("ScanFixture built a manual-import row the production parser rejected: \(path)")
        }
        return item
    }

    static func movie(_ json: String) -> RadarrMovie {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(RadarrMovie.self, from: Data(json.utf8))
    }

    static func series(_ json: String) -> SonarrSeries {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(SonarrSeries.self, from: Data(json.utf8))
    }

    /// A rejection Sonarr/Radarr emits when the title itself is unknown - the
    /// scan view model treats these as auto-matchable rather than blocked.
    static let resolvableRejection = "Unknown Movie"
    /// A rejection nothing in the identify flow can fix.
    static let hardRejection = "Not an upgrade for existing movie file(s)"
}

@MainActor
private func makeViewModel(
    path: String = "/data/downloads/complete",
    service: ArrServiceType = .radarr,
    kind: ArrImportKind = .library
) -> LibraryImportScanViewModel {
    let viewModel = LibraryImportScanViewModel(
        path: path,
        service: service,
        serviceManager: ArrServiceManager(),
        kind: kind
    )
    // Several state transitions kick off `startAutoIdentify()`, an unstructured
    // long-running task. These suites assert on synchronous state only, so the
    // loop is disabled up front to keep every test deterministic.
    viewModel.autoIdentifyEnabled = false
    return viewModel
}

private extension LibraryImportGroup {
    var itemIDs: [String] { items.map(\.id) }
}

// MARK: - Priority 1: recomputeGroups / the grouping engine

@Suite("Library import scan grouping")
@MainActor
struct LibraryImportScanGroupingTests {

    @Test("An empty scan produces empty groups in every bucket")
    func emptyScanProducesNoGroups() {
        let viewModel = makeViewModel()

        viewModel.recomputeGroups()

        #expect(viewModel.groupedImportableFiles.isEmpty)
        #expect(viewModel.groupedNewImportableFiles.isEmpty)
        #expect(viewModel.groupedInLibraryFiles.isEmpty)
        #expect(viewModel.groupedIdentifiedPendingAddFiles.isEmpty)
        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
        #expect(viewModel.groupedBlockedFiles.isEmpty)
    }

    @Test("Importable files group by library id and sort by display title")
    func importableFilesGroupByMediaID() {
        let viewModel = makeViewModel(service: .sonarr)
        viewModel.importableFiles = [
            ScanFixture.item(path: "/d/Zulu.S01E01.mkv", media: .series(title: "Zulu", id: 9), seasonNumber: 1, episodeNumbers: [1]),
            ScanFixture.item(path: "/d/Andor.S01E02.mkv", media: .series(title: "Andor", id: 7), seasonNumber: 1, episodeNumbers: [2]),
            ScanFixture.item(path: "/d/Andor.S01E01.mkv", media: .series(title: "Andor", id: 7), seasonNumber: 1, episodeNumbers: [1])
        ]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedImportableFiles.map(\.id) == ["id-7", "id-9"])
        let andor = viewModel.groupedImportableFiles[0]
        #expect(andor.displayTitle == "Andor")
        // sortItems orders by season, then first episode number, then filename.
        #expect(andor.itemIDs == ["/d/Andor.S01E01.mkv", "/d/Andor.S01E02.mkv"])
        #expect(viewModel.groupedImportableFiles[1].itemIDs == ["/d/Zulu.S01E01.mkv"])
    }

    @Test("inLibraryItemIDs splits one importable group across new and extra-copy buckets")
    func inLibraryIDsSplitAGroup() {
        let viewModel = makeViewModel()
        let owned = ScanFixture.item(path: "/d/Arrival.2016.1080p.mkv", media: .movie(title: "Arrival", id: 4))
        let fresh = ScanFixture.item(path: "/d/Arrival.2016.2160p.mkv", media: .movie(title: "Arrival", id: 4))
        viewModel.importableFiles = [owned, fresh]
        viewModel.inLibraryItemIDs = [owned.id]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedImportableFiles.count == 1)
        #expect(viewModel.groupedImportableFiles[0].items.count == 2)
        #expect(viewModel.groupedNewImportableFiles.map(\.itemIDs) == [[fresh.id]])
        #expect(viewModel.groupedInLibraryFiles.map(\.itemIDs) == [[owned.id]])
    }

    @Test("Marking every importable file in-library empties the new bucket")
    func allFilesInLibraryEmptiesNewBucket() {
        let viewModel = makeViewModel()
        let a = ScanFixture.item(path: "/d/A.mkv", media: .movie(title: "A", id: 1))
        let b = ScanFixture.item(path: "/d/B.mkv", media: .movie(title: "B", id: 2))
        viewModel.importableFiles = [a, b]
        viewModel.inLibraryItemIDs = [a.id, b.id]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedNewImportableFiles.isEmpty)
        #expect(viewModel.groupedInLibraryFiles.count == 2)
        #expect(viewModel.groupedImportableFiles.count == 2)
    }

    @Test("inLibraryItemIDs naming files that were not scanned changes nothing")
    func unknownInLibraryIDsAreIgnored() {
        let viewModel = makeViewModel()
        let a = ScanFixture.item(path: "/d/A.mkv", media: .movie(title: "A", id: 1))
        viewModel.importableFiles = [a]
        viewModel.inLibraryItemIDs = ["/somewhere/else.mkv"]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedInLibraryFiles.isEmpty)
        #expect(viewModel.groupedNewImportableFiles.map(\.itemIDs) == [[a.id]])
    }

    @Test("A file that is both pending-add and auto-matchable lands in pending-add only")
    func pendingAddWinsOverUnidentified() throws {
        let viewModel = makeViewModel()
        // No rejections + no library id + a parsed title: `isIdentifiedPendingAdd`
        // AND `isAutoMatchCandidate` are both true for this file.
        let item = ScanFixture.item(
            path: "/d/Arrival.2016.1080p.mkv",
            media: .movie(title: "Arrival", id: 0, tmdbId: 329865)
        )
        #expect(item.isIdentifiedPendingAdd)
        #expect(item.isAutoMatchCandidate)
        viewModel.blockedFiles = [item]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedIdentifiedPendingAddFiles.map(\.itemIDs) == [[item.id]])
        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
        #expect(viewModel.groupedBlockedFiles.isEmpty)
        let group = try #require(viewModel.groupedIdentifiedPendingAddFiles.first)
        #expect(group.id == "add-arrival")
        #expect(group.displayTitle == "Arrival")
    }

    @Test("Rejections that only mean 'title unknown' land in the unidentified bucket")
    func resolvableRejectionsBecomeUnidentified() {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(
            path: "/d/Arrival.2016.1080p.mkv",
            rejections: [ScanFixture.resolvableRejection]
        )
        viewModel.blockedFiles = [item]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedUnidentifiedFiles.map(\.itemIDs) == [[item.id]])
        #expect(viewModel.groupedBlockedFiles.isEmpty)
        #expect(viewModel.groupedIdentifiedPendingAddFiles.isEmpty)
    }

    @Test("A rejection the identify flow cannot fix lands in the blocked bucket")
    func hardRejectionBecomesBlocked() {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(
            path: "/d/Arrival.2016.1080p.mkv",
            rejections: [ScanFixture.hardRejection]
        )
        viewModel.blockedFiles = [item]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedBlockedFiles.map(\.itemIDs) == [[item.id]])
        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
        #expect(viewModel.groupedIdentifiedPendingAddFiles.isEmpty)
    }

    @Test("Mixing a resolvable and a hard rejection still blocks the file")
    func mixedRejectionsBlock() {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(
            path: "/d/Arrival.2016.1080p.mkv",
            rejections: [ScanFixture.resolvableRejection, ScanFixture.hardRejection]
        )
        viewModel.blockedFiles = [item]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedBlockedFiles.map(\.itemIDs) == [[item.id]])
        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
    }

    @Test("Every blocked file lands in exactly one of the three blocked-derived buckets")
    func blockedBucketsArePartition() {
        let viewModel = makeViewModel()
        let pendingAdd = ScanFixture.item(path: "/d/Arrival.2016.mkv", media: .movie(title: "Arrival"))
        let unidentifiedNoReason = ScanFixture.item(path: "/d/Unknown.File.mkv")
        let unidentifiedResolvable = ScanFixture.item(path: "/d/Dune.2021.mkv", rejections: [ScanFixture.resolvableRejection])
        let blocked = ScanFixture.item(path: "/d/Heat.1995.mkv", rejections: [ScanFixture.hardRejection])
        viewModel.blockedFiles = [pendingAdd, unidentifiedNoReason, unidentifiedResolvable, blocked]

        viewModel.recomputeGroups()

        let pendingIDs = viewModel.groupedIdentifiedPendingAddFiles.flatMap(\.itemIDs)
        let unidentifiedIDs = viewModel.groupedUnidentifiedFiles.flatMap(\.itemIDs)
        let blockedIDs = viewModel.groupedBlockedFiles.flatMap(\.itemIDs)

        #expect(pendingIDs == [pendingAdd.id])
        #expect(Set(unidentifiedIDs) == [unidentifiedNoReason.id, unidentifiedResolvable.id])
        #expect(blockedIDs == [blocked.id])
        let all = pendingIDs + unidentifiedIDs + blockedIDs
        #expect(all.count == 4)
        #expect(Set(all) == Set(viewModel.blockedFiles.map(\.id)))
    }

    @Test("Unidentified files group by inferred title across differing filename separators")
    func unidentifiedFilesGroupByInferredTitle() throws {
        let viewModel = makeViewModel(service: .sonarr)
        let dotted = ScanFixture.item(path: "/d/Andor.S01E01.1080p.WEB-DL.mkv", seasonNumber: 1, episodeNumbers: [1])
        let spaced = ScanFixture.item(path: "/d/Andor S01E02 720p.mkv", seasonNumber: 1, episodeNumbers: [2])
        let other = ScanFixture.item(path: "/d/Severance.S01E01.1080p.mkv", seasonNumber: 1, episodeNumbers: [1])
        viewModel.blockedFiles = [spaced, other, dotted]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedUnidentifiedFiles.map(\.id) == ["un-andor", "un-severance"])
        let andor = try #require(viewModel.groupedUnidentifiedFiles.first)
        #expect(andor.displayTitle == "Andor")
        #expect(andor.itemIDs == [dotted.id, spaced.id])
        #expect(andor.posterURL == nil)
    }

    @Test("A filename with no parseable title falls back to a filename-keyed group")
    func unparseableFilenameFallsBackToFilenameKey() throws {
        let viewModel = makeViewModel(service: .sonarr)
        let item = ScanFixture.item(path: "/d/S01E01.mkv", seasonNumber: 1, episodeNumbers: [1])
        viewModel.blockedFiles = [item]

        viewModel.recomputeGroups()

        let group = try #require(viewModel.groupedUnidentifiedFiles.first)
        #expect(viewModel.groupedUnidentifiedFiles.count == 1)
        #expect(group.id == "un-s01e01.mkv")
        #expect(group.itemIDs == [item.id])
    }

    @Test("Pending-add files group by their identified title, not their filenames")
    func pendingAddGroupsByMediaTitle() throws {
        let viewModel = makeViewModel(service: .sonarr)
        let first = ScanFixture.item(
            path: "/d/andor.s01e01.WEBRip.mkv",
            media: .series(title: "Andor", tvdbId: 372837, posterURL: "https://images.invalid/andor.jpg"),
            seasonNumber: 1,
            episodeNumbers: [1]
        )
        let second = ScanFixture.item(
            path: "/d/A.N.D.O.R.S01E02.mkv",
            media: .series(title: "Andor", tvdbId: 372837),
            seasonNumber: 1,
            episodeNumbers: [2]
        )
        viewModel.blockedFiles = [second, first]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
        let group = try #require(viewModel.groupedIdentifiedPendingAddFiles.first)
        #expect(viewModel.groupedIdentifiedPendingAddFiles.count == 1)
        #expect(group.id == "add-andor")
        #expect(group.displayTitle == "Andor")
        #expect(group.itemIDs == [first.id, second.id])
        #expect(group.posterURL?.absoluteString == "https://images.invalid/andor.jpg")
    }

    @Test("Blocked files split into library-id groups and inferred-title groups")
    func blockedGroupsSplitByLibraryIDAndInferredTitle() throws {
        let viewModel = makeViewModel(service: .sonarr)
        let linkedA = ScanFixture.item(
            path: "/d/Andor.S01E01.mkv",
            rejections: [ScanFixture.hardRejection],
            media: .series(title: "Andor", id: 7),
            seasonNumber: 1,
            episodeNumbers: [1]
        )
        let linkedB = ScanFixture.item(
            path: "/d/Andor.S01E02.mkv",
            rejections: [ScanFixture.hardRejection],
            media: .series(title: "Andor", id: 7),
            seasonNumber: 1,
            episodeNumbers: [2]
        )
        let unlinked = ScanFixture.item(
            path: "/d/Severance.S01E01.mkv",
            rejections: [ScanFixture.hardRejection],
            seasonNumber: 1,
            episodeNumbers: [1]
        )
        viewModel.blockedFiles = [unlinked, linkedB, linkedA]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedBlockedFiles.map(\.id) == ["id-7", "un-severance"])
        let andor = try #require(viewModel.groupedBlockedFiles.first)
        #expect(andor.isIdentified)
        #expect(andor.itemIDs == [linkedA.id, linkedB.id])
        #expect(andor.rejectionReasons == [ScanFixture.hardRejection])
        #expect(viewModel.groupedBlockedFiles[1].isIdentified == false)
    }

    @Test("Ready and blocked buckets are computed independently of each other")
    func readyAndBlockedBucketsCoexist() {
        let viewModel = makeViewModel()
        let ready = ScanFixture.item(path: "/d/Heat.1995.mkv", media: .movie(title: "Heat", id: 12))
        let blocked = ScanFixture.item(path: "/d/Dune.2021.mkv", rejections: [ScanFixture.hardRejection])
        viewModel.importableFiles = [ready]
        viewModel.blockedFiles = [blocked]

        viewModel.recomputeGroups()

        #expect(viewModel.groupedNewImportableFiles.flatMap(\.itemIDs) == [ready.id])
        #expect(viewModel.groupedBlockedFiles.flatMap(\.itemIDs) == [blocked.id])
        #expect(viewModel.groupedImportableFiles.flatMap(\.itemIDs) == [ready.id])
        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
    }

    @Test("Clearing the scanned arrays clears every published group")
    func clearingFilesClearsGroups() {
        let viewModel = makeViewModel()
        viewModel.importableFiles = [ScanFixture.item(path: "/d/Heat.1995.mkv", media: .movie(title: "Heat", id: 12))]
        viewModel.blockedFiles = [ScanFixture.item(path: "/d/Dune.2021.mkv", rejections: [ScanFixture.hardRejection])]
        viewModel.inLibraryItemIDs = ["/d/Heat.1995.mkv"]
        viewModel.recomputeGroups()
        #expect(viewModel.groupedInLibraryFiles.isEmpty == false)

        viewModel.importableFiles = []
        viewModel.blockedFiles = []
        viewModel.inLibraryItemIDs = []
        viewModel.recomputeGroups()

        #expect(viewModel.groupedImportableFiles.isEmpty)
        #expect(viewModel.groupedNewImportableFiles.isEmpty)
        #expect(viewModel.groupedInLibraryFiles.isEmpty)
        #expect(viewModel.groupedBlockedFiles.isEmpty)
    }

    @Test("An importable group takes its title and poster from the first sorted item")
    func importableGroupUsesFirstSortedItemForTitleAndPoster() throws {
        let viewModel = makeViewModel(service: .sonarr)
        let later = ScanFixture.item(
            path: "/d/Andor.S02E01.mkv",
            media: .series(title: "Andor", id: 7, posterURL: "https://images.invalid/later.jpg"),
            seasonNumber: 2,
            episodeNumbers: [1]
        )
        let earlier = ScanFixture.item(
            path: "/d/Andor.S01E01.mkv",
            media: .series(title: "Andor", id: 7, posterURL: "https://images.invalid/earlier.jpg"),
            seasonNumber: 1,
            episodeNumbers: [1]
        )
        viewModel.importableFiles = [later, earlier]

        viewModel.recomputeGroups()

        let group = try #require(viewModel.groupedImportableFiles.first)
        #expect(group.itemIDs == [earlier.id, later.id])
        #expect(group.posterURL?.absoluteString == "https://images.invalid/earlier.jpg")
    }

    @Test("Counting unresolved and hard-blocked files matches the bucket split")
    func unresolvedAndBlockedCounts() {
        let viewModel = makeViewModel()
        viewModel.blockedFiles = [
            ScanFixture.item(path: "/d/Arrival.2016.mkv", media: .movie(title: "Arrival")),
            ScanFixture.item(path: "/d/Dune.2021.mkv", rejections: [ScanFixture.resolvableRejection]),
            ScanFixture.item(path: "/d/Heat.1995.mkv", rejections: [ScanFixture.hardRejection])
        ]

        viewModel.recomputeGroups()

        // `unresolvedUnidentifiedCount` counts auto-match candidates, which
        // includes the pending-add file even though it has its own bucket.
        #expect(viewModel.unresolvedUnidentifiedCount == 2)
        #expect(viewModel.blockedWithRejectionCount == 1)
    }
}

// MARK: - Priority 2: selection state

@Suite("Library import scan selection")
@MainActor
struct LibraryImportScanSelectionTests {

    private func seededViewModel() -> LibraryImportScanViewModel {
        let viewModel = makeViewModel(service: .sonarr)
        viewModel.importableFiles = [
            ScanFixture.item(path: "/d/Andor.S01E01.mkv", media: .series(title: "Andor", id: 7), seasonNumber: 1, episodeNumbers: [1]),
            ScanFixture.item(path: "/d/Andor.S01E02.mkv", media: .series(title: "Andor", id: 7), seasonNumber: 1, episodeNumbers: [2]),
            ScanFixture.item(path: "/d/Zulu.S01E01.mkv", media: .series(title: "Zulu", id: 9), seasonNumber: 1, episodeNumbers: [1])
        ]
        viewModel.blockedFiles = [
            ScanFixture.item(path: "/d/Severance.S01E01.mkv", seasonNumber: 1, episodeNumbers: [1]),
            ScanFixture.item(path: "/d/Severance.S01E02.mkv", seasonNumber: 1, episodeNumbers: [2])
        ]
        viewModel.recomputeGroups()
        return viewModel
    }

    @Test("Toggling a file adds it then removes it")
    func toggleFileRoundTrips() {
        let viewModel = seededViewModel()

        viewModel.toggleFile("/d/Andor.S01E01.mkv")
        #expect(viewModel.selectedFiles == ["/d/Andor.S01E01.mkv"])
        #expect(viewModel.hasAnySelection)

        viewModel.toggleFile("/d/Andor.S01E01.mkv")
        #expect(viewModel.selectedFiles.isEmpty)
        #expect(viewModel.hasAnySelection == false)
    }

    @Test("Toggling a blocked file only touches the blocked selection")
    func toggleBlockedFileRoundTrips() {
        let viewModel = seededViewModel()

        viewModel.toggleBlockedFile("/d/Severance.S01E01.mkv")
        #expect(viewModel.selectedBlockedFiles == ["/d/Severance.S01E01.mkv"])
        #expect(viewModel.selectedFiles.isEmpty)
        #expect(viewModel.hasAnySelection)

        viewModel.toggleBlockedFile("/d/Severance.S01E01.mkv")
        #expect(viewModel.selectedBlockedFiles.isEmpty)
    }

    @Test("Select-all covers both buckets, and toggling again clears both")
    func selectAllCoversBothBuckets() {
        let viewModel = seededViewModel()
        #expect(viewModel.allSelected == false)

        viewModel.toggleSelectAll()

        #expect(viewModel.selectedFiles == Set(viewModel.importableFiles.map(\.id)))
        #expect(viewModel.selectedBlockedFiles == Set(viewModel.blockedFiles.map(\.id)))
        #expect(viewModel.allSelected)

        viewModel.toggleSelectAll()

        #expect(viewModel.selectedFiles.isEmpty)
        #expect(viewModel.selectedBlockedFiles.isEmpty)
        #expect(viewModel.allSelected == false)
    }

    @Test("Select-all from a partial selection selects everything rather than clearing")
    func selectAllFromPartialSelectionSelectsEverything() {
        let viewModel = seededViewModel()
        viewModel.toggleFile("/d/Zulu.S01E01.mkv")
        viewModel.toggleBlockedFile("/d/Severance.S01E02.mkv")
        #expect(viewModel.allSelected == false)

        viewModel.toggleSelectAll()

        #expect(viewModel.selectedFiles.count == 3)
        #expect(viewModel.selectedBlockedFiles.count == 2)
    }

    @Test("Nothing scanned means nothing is 'all selected'")
    func allSelectedIsFalseWithNoFiles() {
        let viewModel = makeViewModel()

        #expect(viewModel.allSelected == false)
        #expect(viewModel.hasAnySelection == false)

        viewModel.toggleSelectAll()

        #expect(viewModel.selectedFiles.isEmpty)
        #expect(viewModel.selectedBlockedFiles.isEmpty)
        #expect(viewModel.allSelected == false)
    }

    @Test("Toggling a partially selected group selects the whole group")
    func toggleGroupCompletesAPartialSelection() {
        let viewModel = seededViewModel()
        let andorIDs = ["/d/Andor.S01E01.mkv", "/d/Andor.S01E02.mkv"]
        viewModel.toggleFile(andorIDs[0])

        viewModel.toggleGroup(itemIDs: andorIDs)

        #expect(viewModel.selectedFiles == Set(andorIDs))
    }

    @Test("Toggling a fully selected group deselects it and leaves other groups alone")
    func toggleGroupOnFullSelectionDeselects() {
        let viewModel = seededViewModel()
        let andorIDs = ["/d/Andor.S01E01.mkv", "/d/Andor.S01E02.mkv"]
        viewModel.toggleGroup(itemIDs: andorIDs)
        viewModel.toggleFile("/d/Zulu.S01E01.mkv")

        viewModel.toggleGroup(itemIDs: andorIDs)

        #expect(viewModel.selectedFiles == ["/d/Zulu.S01E01.mkv"])
    }

    @Test("Toggling an empty group is a no-op in both buckets")
    func toggleEmptyGroupIsANoOp() {
        let viewModel = seededViewModel()
        viewModel.toggleFile("/d/Zulu.S01E01.mkv")
        viewModel.toggleBlockedFile("/d/Severance.S01E01.mkv")

        viewModel.toggleGroup(itemIDs: [])
        viewModel.toggleBlockedGroup(itemIDs: [])

        #expect(viewModel.selectedFiles == ["/d/Zulu.S01E01.mkv"])
        #expect(viewModel.selectedBlockedFiles == ["/d/Severance.S01E01.mkv"])
    }

    @Test("Ready-group and blocked-group toggles never touch each other's selection")
    func groupTogglesStayInTheirOwnBucket() {
        let viewModel = seededViewModel()
        let andorIDs = ["/d/Andor.S01E01.mkv", "/d/Andor.S01E02.mkv"]
        let severanceIDs = ["/d/Severance.S01E01.mkv", "/d/Severance.S01E02.mkv"]

        viewModel.toggleGroup(itemIDs: andorIDs)
        #expect(viewModel.selectedBlockedFiles.isEmpty)

        viewModel.toggleBlockedGroup(itemIDs: severanceIDs)
        #expect(viewModel.selectedFiles == Set(andorIDs))
        #expect(viewModel.selectedBlockedFiles == Set(severanceIDs))

        viewModel.toggleBlockedGroup(itemIDs: severanceIDs)
        #expect(viewModel.selectedFiles == Set(andorIDs))
        #expect(viewModel.selectedBlockedFiles.isEmpty)
    }

    @Test("selectedReadyGroups narrows a partially selected group to the selected files")
    func selectedReadyGroupsNarrowsPartialGroups() throws {
        let viewModel = seededViewModel()
        viewModel.toggleFile("/d/Andor.S01E02.mkv")

        let groups = viewModel.selectedReadyGroups

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.id == "id-7")
        #expect(group.itemIDs == ["/d/Andor.S01E02.mkv"])
        // The underlying published group is untouched.
        #expect(viewModel.groupedImportableFiles[0].items.count == 2)
    }

    @Test("selectedReadyGroups is empty with no selection")
    func selectedReadyGroupsEmptyWithoutSelection() {
        let viewModel = seededViewModel()

        #expect(viewModel.selectedReadyGroups.isEmpty)
        #expect(viewModel.selectedBlockedGroups.isEmpty)
        #expect(viewModel.selectedBlockedItems.isEmpty)
    }

    @Test("selectedBlockedGroups spans the pending-add, unidentified and blocked sections")
    func selectedBlockedGroupsSpansAllBlockedSections() {
        let viewModel = makeViewModel()
        let pendingAdd = ScanFixture.item(path: "/d/Arrival.2016.mkv", media: .movie(title: "Arrival"))
        let unidentified = ScanFixture.item(path: "/d/Dune.2021.mkv", rejections: [ScanFixture.resolvableRejection])
        let blocked = ScanFixture.item(path: "/d/Heat.1995.mkv", rejections: [ScanFixture.hardRejection])
        viewModel.blockedFiles = [pendingAdd, unidentified, blocked]
        viewModel.recomputeGroups()

        viewModel.selectedBlockedFiles = [pendingAdd.id, blocked.id]

        let ids = Set(viewModel.selectedBlockedGroups.flatMap(\.itemIDs))
        #expect(ids == [pendingAdd.id, blocked.id])
        #expect(viewModel.selectedBlockedGroups.count == 2)
        #expect(Set(viewModel.selectedBlockedItems.map(\.id)) == [pendingAdd.id, blocked.id])
    }

    @Test("selectedBlockedItems only reports files still in the blocked list")
    func selectedBlockedItemsFiltersToBlockedFiles() {
        let viewModel = seededViewModel()
        viewModel.selectedBlockedFiles = ["/d/Severance.S01E01.mkv", "/d/gone.mkv"]

        #expect(viewModel.selectedBlockedItems.map(\.id) == ["/d/Severance.S01E01.mkv"])
    }
}

// MARK: - Priority 3: pure helpers

@Suite("Library import scan helpers")
@MainActor
struct LibraryImportScanHelperTests {

    @Test("folderName is the last path component of the scanned path")
    func folderNameIsLastPathComponent() {
        #expect(makeViewModel(path: "/data/downloads/complete").folderName == "complete")
        #expect(makeViewModel(path: "/data/downloads/complete/").folderName == "complete")
        #expect(makeViewModel(path: "/").folderName == "/")
    }

    @Test("isBusy is true while scanning or importing")
    func isBusyTracksScanAndImport() {
        let viewModel = makeViewModel()
        #expect(viewModel.isBusy == false)

        viewModel.isScanning = true
        #expect(viewModel.isBusy)

        viewModel.isScanning = false
        viewModel.isImporting = true
        #expect(viewModel.isBusy)

        viewModel.isImporting = false
        #expect(viewModel.isBusy == false)
    }

    @Test("isAbsoluteImportPath accepts POSIX, UNC and Windows drive paths")
    func absoluteImportPaths() {
        let cases: [(path: String, expected: Bool)] = [
            ("/downloads/completed", true),
            ("/", true),
            ("\\\\server\\share", true),
            ("C:\\Media\\Movies", true),
            ("c:/media/movies", true),
            ("Z:/x", true),
            ("downloads/completed", false),
            ("", false),
            ("C:", false),
            ("C:x", false),
            ("1:/movies", false),
            ("CC:\\movies", false),
            ("\\single", false),
            ("./relative", false)
        ]
        for testCase in cases {
            #expect(
                isAbsoluteImportPath(testCase.path) == testCase.expected,
                "isAbsoluteImportPath(\(testCase.path)) should be \(testCase.expected)"
            )
        }
    }

    @Test("posterURL prefers remoteUrl, ignores non-poster art, and tolerates no art")
    func posterURLSelection() {
        #expect(posterURL(from: nil) == nil)
        #expect(posterURL(from: []) == nil)

        let noPoster = [ArrImage(coverType: "fanart", url: "https://images.invalid/fanart.jpg", remoteUrl: nil)]
        #expect(posterURL(from: noPoster) == nil)

        let preferred = [
            ArrImage(coverType: "banner", url: "https://images.invalid/banner.jpg", remoteUrl: nil),
            ArrImage(coverType: "poster", url: "https://local.invalid/poster.jpg", remoteUrl: "https://images.invalid/poster.jpg")
        ]
        #expect(posterURL(from: preferred)?.absoluteString == "https://images.invalid/poster.jpg")

        let localOnly = [ArrImage(coverType: "poster", url: "https://local.invalid/poster.jpg", remoteUrl: nil)]
        #expect(posterURL(from: localOnly)?.absoluteString == "https://local.invalid/poster.jpg")

        let firstPosterWins = [
            ArrImage(coverType: "poster", url: nil, remoteUrl: "https://images.invalid/first.jpg"),
            ArrImage(coverType: "poster", url: nil, remoteUrl: "https://images.invalid/second.jpg")
        ]
        #expect(posterURL(from: firstPosterWins)?.absoluteString == "https://images.invalid/first.jpg")
    }

    @Test("normalizedFolderPath drops a single trailing slash")
    func normalizedFolderPath() {
        #expect(LibraryImportScanViewModel.normalizedFolderPath("/data/Movies/") == "/data/Movies")
        #expect(LibraryImportScanViewModel.normalizedFolderPath("/data/Movies") == "/data/Movies")
        #expect(LibraryImportScanViewModel.normalizedFolderPath("") == "")
    }

    @Test("path(_:isUnder:) is path-segment aware")
    func pathIsUnderIsSegmentAware() {
        #expect(LibraryImportScanViewModel.path("/data/Movies", isUnder: "/data/Movies"))
        #expect(LibraryImportScanViewModel.path("/data/Movies/", isUnder: "/data/Movies"))
        #expect(LibraryImportScanViewModel.path("/data/Movies/Heat (1995)", isUnder: "/data/Movies"))
        #expect(LibraryImportScanViewModel.path("/data/Movies2", isUnder: "/data/Movies") == false)
        #expect(LibraryImportScanViewModel.path("/data", isUnder: "/data/Movies") == false)
    }

    @Test("Owned Radarr titles require a file on disk and a path under the scanned folder")
    func ownedRadarrTitles() {
        let viewModel = makeViewModel(path: "/data/Movies/", service: .radarr)
        viewModel.libraryMovies = [
            ScanFixture.movie(#"{"id":1,"title":"Zulu","year":1964,"hasFile":true,"path":"/data/Movies/Zulu (1964)"}"#),
            ScanFixture.movie(#"{"id":2,"title":"Arrival","year":2016,"hasFile":true,"path":"/data/Movies/Arrival (2016)"}"#),
            ScanFixture.movie(#"{"id":3,"title":"No File","year":2020,"hasFile":false,"path":"/data/Movies/No File"}"#),
            ScanFixture.movie(#"{"id":4,"title":"Elsewhere","year":2020,"hasFile":true,"path":"/data/Movies2/Elsewhere"}"#),
            ScanFixture.movie(#"{"id":5,"title":"No Path","year":2020,"hasFile":true}"#)
        ]

        viewModel.computeOwnedTitlesInFolder()

        #expect(viewModel.ownedTitlesInFolder.map(\.title) == ["Arrival", "Zulu"])
        #expect(viewModel.ownedTitlesInFolder.map(\.id) == [2, 1])
        #expect(viewModel.ownedTitlesInFolder.first?.year == 2016)
    }

    @Test("Owned Sonarr titles are matched on path alone")
    func ownedSonarrTitles() {
        let viewModel = makeViewModel(path: "/data/TV", service: .sonarr)
        viewModel.librarySeries = [
            ScanFixture.series(#"{"id":1,"title":"Severance","year":2022,"path":"/data/TV/Severance"}"#),
            ScanFixture.series(#"{"id":2,"title":"Andor","year":2022,"path":"/data/TV/Andor"}"#),
            ScanFixture.series(#"{"id":3,"title":"Other","year":2022,"path":"/data/TVShows/Other"}"#)
        ]

        viewModel.computeOwnedTitlesInFolder()

        #expect(viewModel.ownedTitlesInFolder.map(\.title) == ["Andor", "Severance"])
    }

    @Test("importedEpisodeKeys skips files with no season number and de-duplicates")
    func importedEpisodeKeys() {
        let withSeason = ScanFixture.item(path: "/d/Andor.S01E01E02.mkv", seasonNumber: 1, episodeNumbers: [1, 2])
        let duplicate = ScanFixture.item(path: "/d/Andor.S01E01.copy.mkv", seasonNumber: 1, episodeNumbers: [1])
        let noSeason = ScanFixture.item(path: "/d/Special.mkv", episodeNumbers: [5])
        let noEpisodes = ScanFixture.item(path: "/d/Andor.S02.mkv", seasonNumber: 2)

        let keys = LibraryImportScanViewModel.importedEpisodeKeys(from: [withSeason, duplicate, noSeason, noEpisodes])

        #expect(keys == [
            LibraryImportEpisodeKey(seasonNumber: 1, episodeNumber: 1),
            LibraryImportEpisodeKey(seasonNumber: 1, episodeNumber: 2)
        ])
    }
}

// MARK: - Priority 4: identification

@Suite("Library import scan identification")
@MainActor
struct LibraryImportScanIdentificationTests {

    @Test("Identifying a blocked file moves it into the importable set and selects it")
    func applyIdentificationPromotesABlockedFile() throws {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(path: "/d/Arrival.2016.mkv", rejections: [ScanFixture.resolvableRejection])
        viewModel.blockedFiles = [item]
        viewModel.selectedBlockedFiles = [item.id]
        viewModel.recomputeGroups()

        viewModel.applyIdentification(
            to: item,
            mediaID: 42,
            title: "Arrival",
            posterURL: URL(string: "https://images.invalid/arrival.jpg")
        )

        #expect(viewModel.blockedFiles.isEmpty)
        #expect(viewModel.selectedBlockedFiles.isEmpty)
        #expect(viewModel.importableFiles.map(\.id) == [item.id])
        #expect(viewModel.selectedFiles == [item.id])

        let promoted = try #require(viewModel.importableFiles.first)
        #expect(promoted.mediaID == 42)
        #expect(promoted.mediaTitle == "Arrival")
        #expect(promoted.rejectionReasons.isEmpty)
        #expect(promoted.isImportable)

        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
        #expect(viewModel.groupedNewImportableFiles.map(\.id) == ["id-42"])
    }

    @Test("The array overload identifies every file in one pass")
    func applyIdentificationToManyFiles() {
        let viewModel = makeViewModel(service: .sonarr)
        let first = ScanFixture.item(path: "/d/Andor.S01E01.mkv", seasonNumber: 1, episodeNumbers: [1])
        let second = ScanFixture.item(path: "/d/Andor.S01E02.mkv", seasonNumber: 1, episodeNumbers: [2])
        viewModel.blockedFiles = [first, second]
        viewModel.recomputeGroups()

        viewModel.applyIdentification(to: [first, second], mediaID: 7, title: "Andor", posterURL: nil)

        #expect(viewModel.blockedFiles.isEmpty)
        #expect(Set(viewModel.importableFiles.map(\.id)) == [first.id, second.id])
        #expect(viewModel.selectedFiles == [first.id, second.id])
        #expect(viewModel.groupedNewImportableFiles.map(\.id) == ["id-7"])
        #expect(viewModel.groupedNewImportableFiles[0].items.count == 2)
    }

    @Test("Identifying an empty list changes nothing")
    func applyIdentificationWithNoItemsIsANoOp() {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(path: "/d/Arrival.2016.mkv", rejections: [ScanFixture.resolvableRejection])
        viewModel.blockedFiles = [item]
        viewModel.recomputeGroups()

        viewModel.applyIdentification(to: [], mediaID: 42, title: "Arrival", posterURL: nil)

        #expect(viewModel.blockedFiles.map(\.id) == [item.id])
        #expect(viewModel.importableFiles.isEmpty)
        #expect(viewModel.selectedFiles.isEmpty)
    }

    @Test("Re-identifying an already importable file replaces it instead of duplicating it")
    func reIdentifyingReplacesTheExistingCopy() throws {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(path: "/d/Arrival.2016.mkv", media: .movie(title: "Wrong Movie", id: 7))
        viewModel.importableFiles = [item]
        viewModel.recomputeGroups()

        viewModel.applyIdentification(to: item, mediaID: 42, title: "Arrival", posterURL: nil)

        #expect(viewModel.importableFiles.count == 1)
        let updated = try #require(viewModel.importableFiles.first)
        #expect(updated.mediaID == 42)
        #expect(updated.mediaTitle == "Arrival")
        #expect(viewModel.groupedNewImportableFiles.map(\.id) == ["id-42"])
    }

    @Test("Identifying the file the identify sheet is showing dismisses that sheet")
    func identifyingDismissesTheMatchingSheet() {
        let viewModel = makeViewModel()
        let target = ScanFixture.item(path: "/d/Arrival.2016.mkv", rejections: [ScanFixture.resolvableRejection])
        let other = ScanFixture.item(path: "/d/Dune.2021.mkv", rejections: [ScanFixture.resolvableRejection])
        viewModel.blockedFiles = [target, other]
        viewModel.recomputeGroups()
        viewModel.identifyingTarget = LibraryImportIdentifyTarget(id: "item-\(target.id)", items: [target], displayLabel: target.fileName)

        viewModel.applyIdentification(to: other, mediaID: 9, title: "Dune", posterURL: nil)
        #expect(viewModel.identifyingTarget?.id == "item-\(target.id)")

        viewModel.applyIdentification(to: target, mediaID: 42, title: "Arrival", posterURL: nil)
        #expect(viewModel.identifyingTarget == nil)
    }

    @Test("A pending-add identification keeps the file blocked but titled")
    func applyPendingAddIdentificationKeepsFileBlocked() throws {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(path: "/d/Arrival.2016.mkv", rejections: [ScanFixture.resolvableRejection])
        viewModel.blockedFiles = [item]
        viewModel.selectedBlockedFiles = [item.id]
        viewModel.recomputeGroups()
        #expect(viewModel.groupedUnidentifiedFiles.count == 1)

        viewModel.applyPendingAddIdentification(
            to: [item],
            title: "Arrival",
            catalogID: 329865,
            posterURL: URL(string: "https://images.invalid/arrival.jpg")
        )

        #expect(viewModel.importableFiles.isEmpty)
        #expect(viewModel.blockedFiles.map(\.id) == [item.id])
        let updated = try #require(viewModel.blockedFiles.first)
        #expect(updated.mediaTitle == "Arrival")
        #expect(updated.mediaID == nil)
        #expect(updated.catalogID == 329865)
        #expect(updated.isIdentifiedPendingAdd)

        #expect(viewModel.groupedUnidentifiedFiles.isEmpty)
        #expect(viewModel.groupedIdentifiedPendingAddFiles.map(\.id) == ["add-arrival"])
        // The prior blocked selection is dropped and not re-established.
        #expect(viewModel.selectedBlockedFiles.isEmpty)
        #expect(viewModel.selectedFiles.isEmpty)
    }

    @Test("A pending-add identification of no files changes nothing")
    func applyPendingAddIdentificationWithNoItemsIsANoOp() {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(path: "/d/Arrival.2016.mkv", rejections: [ScanFixture.resolvableRejection])
        viewModel.blockedFiles = [item]
        viewModel.recomputeGroups()

        viewModel.applyPendingAddIdentification(to: [], title: "Arrival", catalogID: 1, posterURL: nil)

        #expect(viewModel.blockedFiles.count == 1)
        #expect(viewModel.groupedUnidentifiedFiles.count == 1)
        #expect(viewModel.groupedIdentifiedPendingAddFiles.isEmpty)
    }

    @Test("beginIdentifying(item:) targets that one file and clears stale catalog results")
    func beginIdentifyingSingleItem() throws {
        let viewModel = makeViewModel()
        let item = ScanFixture.item(path: "/d/Arrival.2016.1080p.mkv", rejections: [ScanFixture.resolvableRejection])
        viewModel.blockedFiles = [item]
        viewModel.recomputeGroups()
        viewModel.catalogMovieResults = [ScanFixture.movie(#"{"id":1,"title":"Stale Result"}"#)]
        viewModel.catalogSeriesResults = [ScanFixture.series(#"{"id":1,"title":"Stale Series"}"#)]
        viewModel.isSearchingCatalog = true

        viewModel.beginIdentifying(item)

        let target = try #require(viewModel.identifyingTarget)
        #expect(target.id == "item-/d/Arrival.2016.1080p.mkv")
        #expect(target.items.map(\.id) == [item.id])
        #expect(target.displayLabel == "Arrival.2016.1080p.mkv")
        #expect(viewModel.catalogMovieResults.isEmpty)
        #expect(viewModel.catalogSeriesResults.isEmpty)
        #expect(viewModel.isSearchingCatalog == false)
    }

    @Test("beginIdentifying(group:) labels single-file and multi-file groups differently")
    func beginIdentifyingGroupLabels() throws {
        let viewModel = makeViewModel(service: .sonarr)
        let first = ScanFixture.item(path: "/d/Andor.S01E01.mkv", seasonNumber: 1, episodeNumbers: [1])
        let second = ScanFixture.item(path: "/d/Andor.S01E02.mkv", seasonNumber: 1, episodeNumbers: [2])
        viewModel.blockedFiles = [first, second]
        viewModel.recomputeGroups()

        let multi = try #require(viewModel.groupedUnidentifiedFiles.first)
        viewModel.beginIdentifying(group: multi)
        let multiTarget = try #require(viewModel.identifyingTarget)
        #expect(multiTarget.id == "un-andor")
        #expect(multiTarget.displayLabel == "Andor · 2 files")
        #expect(multiTarget.items.count == 2)

        viewModel.blockedFiles = [first]
        viewModel.recomputeGroups()
        let single = try #require(viewModel.groupedUnidentifiedFiles.first)
        viewModel.beginIdentifying(group: single)
        let singleTarget = try #require(viewModel.identifyingTarget)
        #expect(singleTarget.displayLabel == "Andor.S01E01.mkv")
    }

    @Test("beginIdentifying(group:) on an empty group leaves the current target alone")
    func beginIdentifyingEmptyGroupIsANoOp() {
        let viewModel = makeViewModel()
        let existing = LibraryImportIdentifyTarget(id: "existing", items: [], displayLabel: "Existing")
        viewModel.identifyingTarget = existing
        let empty = LibraryImportGroup(kind: .unidentified(inferredKey: "none"), displayTitle: "None", posterURL: nil, items: [])

        viewModel.beginIdentifying(group: empty)

        #expect(viewModel.identifyingTarget?.id == "existing")
    }

    @Test("Relinking promotes catalog-matched blocked files into the importable set")
    func relinkPromotesCatalogMatches() throws {
        let viewModel = makeViewModel(service: .radarr)
        let relinkable = ScanFixture.item(path: "/d/Arrival.2016.mkv", media: .movie(title: "Arrival", id: 0, tmdbId: 329865))
        let unmatched = ScanFixture.item(path: "/d/Dune.2021.mkv", media: .movie(title: "Dune", id: 0, tmdbId: 438631))
        viewModel.blockedFiles = [relinkable, unmatched]
        viewModel.recomputeGroups()
        viewModel.libraryMovies = [
            ScanFixture.movie(#"{"id":42,"title":"Arrival","tmdbId":329865,"hasFile":false}"#)
        ]

        viewModel.relinkIdentifiedItemsToLibrary()

        #expect(viewModel.blockedFiles.map(\.id) == [unmatched.id])
        #expect(viewModel.importableFiles.map(\.id) == [relinkable.id])
        let promoted = try #require(viewModel.importableFiles.first)
        #expect(promoted.mediaID == 42)
        #expect(promoted.mediaTitle == "Arrival")
        #expect(viewModel.groupedNewImportableFiles.map(\.id) == ["id-42"])
        #expect(viewModel.groupedIdentifiedPendingAddFiles.map(\.itemIDs) == [[unmatched.id]])
    }

    @Test("Relinking skips files with rejections or an existing library id")
    func relinkSkipsIneligibleFiles() {
        let viewModel = makeViewModel(service: .radarr)
        let rejected = ScanFixture.item(
            path: "/d/Arrival.2016.mkv",
            rejections: [ScanFixture.hardRejection],
            media: .movie(title: "Arrival", id: 0, tmdbId: 329865)
        )
        let alreadyLinked = ScanFixture.item(path: "/d/Dune.2021.mkv", media: .movie(title: "Dune", id: 9, tmdbId: 438631))
        let noCatalogID = ScanFixture.item(path: "/d/Heat.1995.mkv", media: .movie(title: "Heat"))
        viewModel.blockedFiles = [rejected, alreadyLinked, noCatalogID]
        viewModel.recomputeGroups()
        viewModel.libraryMovies = [
            ScanFixture.movie(#"{"id":42,"title":"Arrival","tmdbId":329865}"#),
            ScanFixture.movie(#"{"id":9,"title":"Dune","tmdbId":438631}"#)
        ]

        viewModel.relinkIdentifiedItemsToLibrary()

        #expect(viewModel.importableFiles.isEmpty)
        #expect(viewModel.blockedFiles.map(\.id) == [rejected.id, alreadyLinked.id, noCatalogID.id])
    }

    @Test("Relinking with no library match and with nothing blocked is a no-op")
    func relinkWithNothingToDoIsANoOp() {
        let viewModel = makeViewModel(service: .radarr)
        viewModel.relinkIdentifiedItemsToLibrary()
        #expect(viewModel.blockedFiles.isEmpty)
        #expect(viewModel.importableFiles.isEmpty)

        let item = ScanFixture.item(path: "/d/Arrival.2016.mkv", media: .movie(title: "Arrival", id: 0, tmdbId: 329865))
        viewModel.blockedFiles = [item]
        viewModel.recomputeGroups()
        viewModel.libraryMovies = [ScanFixture.movie(#"{"id":1,"title":"Something Else","tmdbId":11}"#)]

        viewModel.relinkIdentifiedItemsToLibrary()

        #expect(viewModel.blockedFiles.map(\.id) == [item.id])
        #expect(viewModel.importableFiles.isEmpty)
    }

    @Test("Relinking matches Sonarr blocked files by TVDb id")
    func relinkMatchesSonarrByTVDbID() throws {
        let viewModel = makeViewModel(service: .sonarr)
        let item = ScanFixture.item(
            path: "/d/Andor.S01E01.mkv",
            media: .series(title: "Andor", id: 0, tvdbId: 372837),
            seasonNumber: 1,
            episodeNumbers: [1]
        )
        viewModel.blockedFiles = [item]
        viewModel.recomputeGroups()
        viewModel.librarySeries = [ScanFixture.series(#"{"id":7,"title":"Andor","tvdbId":372837}"#)]

        viewModel.relinkIdentifiedItemsToLibrary()

        #expect(viewModel.blockedFiles.isEmpty)
        let promoted = try #require(viewModel.importableFiles.first)
        #expect(promoted.mediaID == 7)
        #expect(viewModel.groupedNewImportableFiles.map(\.id) == ["id-7"])
    }
}

// MARK: - Session store

/// A scan's grouped files and Auto Match results were held in the scan view's
/// `@State`, so popping the view destroyed them and returning re-scanned from
/// scratch. These pin the store that now owns them for the app session.
@Suite("Library import scan session store")
@MainActor
struct LibraryImportScanSessionStoreTests {

    private func makeStore(limit: Int = 6) -> LibraryImportScanSessionStore {
        LibraryImportScanSessionStore(limit: limit)
    }

    private func requestModel(
        from store: LibraryImportScanSessionStore,
        manager: ArrServiceManager,
        path: String = "/data/Movies",
        service: ArrServiceType = .radarr,
        instanceID: UUID? = nil,
        libraryItemID: Int? = nil,
        kind: ArrImportKind = .library
    ) -> LibraryImportScanViewModel {
        store.viewModel(
            path: path,
            service: service,
            serviceManager: manager,
            instanceID: instanceID,
            libraryItemID: libraryItemID,
            kind: kind
        )
    }

    @Test("Re-opening a folder returns the same scan, with its matches intact")
    func reopeningAFolderKeepsItsScan() {
        let store = makeStore()
        let manager = ArrServiceManager()

        let first = requestModel(from: store, manager: manager)
        first.autoIdentifyEnabled = false
        first.hasPerformedInitialScan = true
        first.importableFiles = [
            ScanFixture.item(path: "/data/Movies/Matched.2019.mkv", media: .movie(title: "Matched", id: 11))
        ]
        first.recomputeGroups()

        let second = requestModel(from: store, manager: manager)

        #expect(second === first)
        #expect(second.hasPerformedInitialScan)
        #expect(second.groupedImportableFiles.count == 1)
        #expect(store.retainedScanCount == 1)
    }

    @Test("Each scanned folder gets its own view model")
    func differentFoldersAreSeparateScans() {
        let store = makeStore()
        let manager = ArrServiceManager()

        let movies = requestModel(from: store, manager: manager, path: "/data/Movies")
        let shows = requestModel(from: store, manager: manager, path: "/data/Shows")

        #expect(movies !== shows)
        #expect(store.retainedScanCount == 2)
    }

    /// An HD/4K pair can expose the same path on two servers with different
    /// libraries, and Library Import and Manual Import scan a folder with
    /// different server-side filtering - so neither may share a cached scan.
    @Test("Service, instance, library item and import kind each split the cache")
    func everyIdentityComponentSplitsTheCache() {
        let store = makeStore()
        let manager = ArrServiceManager()
        let hd = UUID()
        let uhd = UUID()

        let radarr = requestModel(from: store, manager: manager, service: .radarr)
        let sonarr = requestModel(from: store, manager: manager, service: .sonarr)
        let onHD = requestModel(from: store, manager: manager, instanceID: hd)
        let onUHD = requestModel(from: store, manager: manager, instanceID: uhd)
        let forItem = requestModel(from: store, manager: manager, libraryItemID: 7)
        let manual = requestModel(from: store, manager: manager, kind: .manual)

        #expect(radarr !== sonarr)
        #expect(onHD !== onUHD)
        #expect(radarr !== onHD)
        #expect(radarr !== forItem)
        #expect(radarr !== manual)
        #expect(store.retainedScanCount == 6)
    }

    @Test("Retained scans are capped, dropping the least recently opened first")
    func retainedScansAreCapped() {
        let store = makeStore(limit: 2)
        let manager = ArrServiceManager()

        let first = requestModel(from: store, manager: manager, path: "/data/A")
        _ = requestModel(from: store, manager: manager, path: "/data/B")
        _ = requestModel(from: store, manager: manager, path: "/data/C")

        #expect(store.retainedScanCount == 2)
        #expect(requestModel(from: store, manager: manager, path: "/data/A") !== first)
    }

    @Test("Re-opening a folder keeps it from being the next one evicted")
    func reopeningAFolderRefreshesItsPlaceInTheCache() {
        let store = makeStore(limit: 2)
        let manager = ArrServiceManager()

        let a = requestModel(from: store, manager: manager, path: "/data/A")
        let b = requestModel(from: store, manager: manager, path: "/data/B")
        _ = requestModel(from: store, manager: manager, path: "/data/A")
        _ = requestModel(from: store, manager: manager, path: "/data/C")

        #expect(requestModel(from: store, manager: manager, path: "/data/A") === a)
        #expect(requestModel(from: store, manager: manager, path: "/data/B") !== b)
    }

    @Test("Clearing the store drops every retained scan")
    func clearingDropsEveryScan() {
        let store = makeStore()
        let manager = ArrServiceManager()

        let movies = requestModel(from: store, manager: manager, path: "/data/Movies")
        _ = requestModel(from: store, manager: manager, path: "/data/Shows")
        store.removeAll()

        #expect(store.retainedScanCount == 0)
        #expect(requestModel(from: store, manager: manager, path: "/data/Movies") !== movies)
    }

    @Test("A limit below one still retains the folder being viewed")
    func aDegenerateLimitStillRetainsTheCurrentFolder() {
        let store = makeStore(limit: 0)
        let manager = ArrServiceManager()

        let movies = requestModel(from: store, manager: manager, path: "/data/Movies")

        #expect(store.retainedScanCount == 1)
        #expect(requestModel(from: store, manager: manager, path: "/data/Movies") === movies)
    }
}
