import Foundation
import SwiftUI
import Testing
@testable import Trawl

/// The one set of rules Up Next, the Episodes section, the episode rows, the Series
/// list's long-press and the Shortcuts action all read. Each test names the user-visible
/// mistake it prevents.
@Suite("Sonarr episode progress")
struct SonarrEpisodeProgressTests {
    /// Thursday 19 November 2026, 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_795_089_600)

    private static func episode(
        id: Int,
        season: Int,
        number: Int,
        airDateUtc: String?,
        hasFile: Bool = false,
        monitored: Bool = true
    ) -> SonarrEpisode {
        var json: [String: Any] = [
            "id": id,
            "seriesId": 1,
            "seasonNumber": season,
            "episodeNumber": number,
            "title": "Episode \(number)",
            "hasFile": hasFile,
            "monitored": monitored
        ]
        if let airDateUtc { json["airDateUtc"] = airDateUtc }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SonarrEpisode.self, from: data)
    }

    private static func queueRow(episodeID: Int, on instance: ArrInstanceRef, sizeLeft: Double = 500, status: String = "downloading") -> ArrInstanced<ArrQueueItem> {
        let json: [String: Any] = [
            "id": 9_000 + episodeID,
            "title": "release",
            "status": status,
            "trackedDownloadStatus": status == "downloading" ? "ok" : "warning",
            "trackedDownloadState": status == "downloading" ? "downloading" : "importPending",
            "episodeId": episodeID,
            "seriesId": 1,
            "size": 1_000,
            "sizeleft": sizeLeft
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let item = try! JSONDecoder().decode(ArrQueueItem.self, from: data)
        return ArrInstanced(item, on: instance, elementID: String(item.id))
    }

    private static let hd = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr", tier: .hd)
    private static let uhd = ArrInstanceRef(id: UUID(), serviceType: .sonarr, displayName: "Sonarr 4K", tier: .uhd)

    /// A running season: four on disk, one aired and missing, one next week.
    private static let runningSeason: [SonarrEpisode] = [
        episode(id: 1, season: 27, number: 1, airDateUtc: "2026-10-15T02:00:00Z", hasFile: true),
        episode(id: 2, season: 27, number: 2, airDateUtc: "2026-10-22T02:00:00Z", hasFile: true),
        episode(id: 3, season: 27, number: 3, airDateUtc: "2026-10-29T02:00:00Z", hasFile: true),
        episode(id: 4, season: 27, number: 4, airDateUtc: "2026-11-05T02:00:00Z", hasFile: true),
        episode(id: 5, season: 27, number: 5, airDateUtc: "2026-11-19T02:00:00Z"),
        episode(id: 6, season: 27, number: 6, airDateUtc: "2026-12-03T02:00:00Z")
    ]

    // MARK: Counts

    @Test("Season counts leave out episodes that have not aired")
    func seasonCountsExcludeUnaired() {
        // The capture that started this read "4 of 6" for a season with five aired.
        let counts = SonarrEpisodeProgress.seasonCounts(Self.runningSeason, now: Self.now)
        #expect(counts == .init(onDisk: 4, aired: 5, upcoming: 1))
        #expect(counts.missing == 1)
        #expect(!counts.isComplete)
    }

    @Test("A downloaded episode counts as aired even when its date is in the future")
    func fileMeansAired() {
        let early = Self.episode(id: 1, season: 1, number: 1, airDateUtc: "2026-11-20T02:00:00Z", hasFile: true)
        #expect(SonarrEpisodeProgress.hasAired(early, now: Self.now))
        #expect(SonarrEpisodeProgress.seasonCounts([early], now: Self.now).isComplete)
    }

    @Test("An episode with no air date is to come, not missing")
    func undatedIsUpcoming() {
        let tba = Self.episode(id: 1, season: 2, number: 1, airDateUtc: nil)
        #expect(SonarrEpisodeProgress.state(of: tba, queue: [], now: Self.now) == .notAired(nil))
        #expect(SonarrEpisodeProgress.seasonCounts([tba], now: Self.now).upcoming == 1)
    }

    @Test("Section summaries say what is missing and what is to come")
    @MainActor
    func summaryText() {
        let counts = SonarrEpisodeProgress.SeasonCounts(onDisk: 4, aired: 5, upcoming: 1)
        #expect(SonarrSeriesEpisodesSection<EmptyView>.summary(counts) == "4 of 5 aired · 1 missing · 1 to come")
        #expect(SonarrSeriesEpisodesSection<EmptyView>.summary(.init(onDisk: 0, aired: 0, upcoming: 0)) == "No episodes yet")
    }

    // MARK: States

    @Test("Missing, not monitored and not aired are three different states")
    func distinctStates() {
        let missing = Self.runningSeason[4]
        let upcoming = Self.runningSeason[5]
        let unmonitored = Self.episode(id: 7, season: 27, number: 5, airDateUtc: "2026-11-19T02:00:00Z", monitored: false)
        #expect(SonarrEpisodeProgress.state(of: missing, queue: [], now: Self.now) == .missing)
        #expect(SonarrEpisodeProgress.state(of: unmonitored, queue: [], now: Self.now) == .unmonitored)
        if case .notAired(let date) = SonarrEpisodeProgress.state(of: upcoming, queue: [], now: Self.now) {
            #expect(date != nil)
        } else {
            Issue.record("Next week's episode should read as not aired")
        }
        #expect(SonarrEpisodeProgress.state(of: Self.runningSeason[0], queue: [], now: Self.now) == .onDisk)
    }

    @Test("A queued episode reads as downloading only on the server that holds it")
    func queueIsServerScoped() {
        let missing = Self.runningSeason[4].stamped(with: Self.hd.id)
        let on4K = [Self.queueRow(episodeID: missing.id, on: Self.uhd)]
        #expect(SonarrEpisodeProgress.state(of: missing, queue: on4K, now: Self.now) == .missing)

        let onHD = [Self.queueRow(episodeID: missing.id, on: Self.hd, sizeLeft: 250)]
        #expect(SonarrEpisodeProgress.state(of: missing, queue: onHD, now: Self.now) == .downloading(progress: 0.75))
    }

    @Test("A stuck download reads as an import issue")
    func importIssueState() {
        let missing = Self.runningSeason[4]
        let stuck = [Self.queueRow(episodeID: missing.id, on: Self.hd, sizeLeft: 0, status: "completed")]
        #expect(SonarrEpisodeProgress.state(of: missing, queue: stuck, now: Self.now) == .importIssue)
    }

    // MARK: Latest and next

    @Test("Latest is the newest aired regular episode; next is the next dated one")
    func latestAndNext() {
        let special = Self.episode(id: 99, season: 0, number: 3, airDateUtc: "2026-11-18T02:00:00Z")
        let episodes = Self.runningSeason + [special]
        #expect(SonarrEpisodeProgress.latestAired(in: episodes, now: Self.now)?.id == 5)
        #expect(SonarrEpisodeProgress.nextToAir(in: episodes, now: Self.now)?.id == 6)
    }

    @Test("The Episodes section opens on the season holding the newest episode")
    func defaultSeason() {
        let older = Self.episode(id: 50, season: 26, number: 1, airDateUtc: "2025-03-01T02:00:00Z", hasFile: true)
        // Season 28 is announced but nothing has aired: still open on 27.
        let announced = Self.episode(id: 60, season: 28, number: 1, airDateUtc: nil)
        let episodes = Self.runningSeason + [older, announced]
        #expect(SonarrEpisodeProgress.defaultSeason(seasonNumbers: [28, 27, 26, 0], episodes: episodes, now: Self.now) == 27)
        #expect(SonarrEpisodeProgress.defaultSeason(seasonNumbers: [0, 1, 2], episodes: [], now: Self.now) == 2)
        #expect(SonarrEpisodeProgress.defaultSeason(seasonNumbers: [0], episodes: [], now: Self.now) == 0)
    }

    // MARK: Search latest

    @Test("Search Latest Episode searches the newest missing episode")
    func latestActionSearches() {
        let action = SonarrEpisodeProgress.latestEpisodeAction(episodes: Self.runningSeason, queuedEpisodeIDs: [], now: Self.now)
        #expect(action == .search(Self.runningSeason[4]))
    }

    @Test("Search Latest Episode leaves a downloading episode alone")
    func latestActionSkipsQueued() {
        let action = SonarrEpisodeProgress.latestEpisodeAction(episodes: Self.runningSeason, queuedEpisodeIDs: [5], now: Self.now)
        #expect(action == .alreadyQueued(Self.runningSeason[4]))
    }

    @Test("Search Latest Episode reports an episode already on disk")
    func latestActionReportsOnDisk() {
        let complete = Array(Self.runningSeason.prefix(4))
        let action = SonarrEpisodeProgress.latestEpisodeAction(episodes: complete, queuedEpisodeIDs: [], now: Self.now)
        #expect(action == .alreadyOnDisk(Self.runningSeason[3]))
    }

    @Test("Search Latest Episode says so when nothing has aired")
    func latestActionNothingAired() {
        let future = [Self.runningSeason[5]]
        #expect(SonarrEpisodeProgress.latestEpisodeAction(episodes: future, queuedEpisodeIDs: [], now: Self.now) == .nothingAired)
    }

    // MARK: Series list

    @Test("The Series list's next air date is the soonest future one across seasons")
    @MainActor
    func seriesNextAiring() throws {
        let json = #"""
        {"id":1,"title":"Long Runner","seasons":[
          {"seasonNumber":26,"statistics":{"nextAiring":"2025-01-01T02:00:00Z"}},
          {"seasonNumber":27,"statistics":{"nextAiring":"2026-12-03T02:00:00Z"}},
          {"seasonNumber":28,"statistics":{"nextAiring":"2027-02-01T02:00:00Z"}}
        ]}
        """#
        let series = try JSONDecoder().decode(SonarrSeries.self, from: Data(json.utf8))
        let next = SonarrSeriesQuickActions.nextAiring(of: series, now: Self.now)
        #expect(next == ISO8601DateFormatter().date(from: "2026-12-03T02:00:00Z"))
    }
}
