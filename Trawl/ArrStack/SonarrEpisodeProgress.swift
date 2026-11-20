//
//  SonarrEpisodeProgress.swift
//  Trawl
//
//  Where a series stands on its newest episode, and per-season counts that leave
//  out episodes which have not aired yet.
//

import Foundation

/// What an episode row, the Up Next card and the season chips all agree an episode is.
///
/// Before this existed each surface decided for itself, and they disagreed: a season
/// card counted next week's episode as missing ("4 of 6"), while the episode row
/// showed nothing at all for a missing episode - the same nothing it showed for one
/// that had not aired.
nonisolated enum SonarrEpisodeState: Equatable, Sendable {
    /// A file is on disk.
    case onDisk
    /// In a download queue. Progress runs 0...1.
    case downloading(progress: Double)
    /// In a queue but stuck: Sonarr could not import it.
    case importIssue
    /// Aired, monitored, no file - Sonarr should be looking for it.
    case missing
    /// Aired, no file, and not monitored, so Sonarr will never grab it on its own.
    case unmonitored
    /// Not aired yet. `nil` when Sonarr has no air date at all (TBA).
    case notAired(Date?)

    /// Whether the user has something to do about it: search, or monitor and search.
    var wantsSearch: Bool {
        switch self {
        case .missing, .unmonitored: true
        default: false
        }
    }
}

nonisolated enum SonarrEpisodeProgress {
    // MARK: Air dates

    /// When the episode airs, or aired. Sonarr sends a UTC instant for anything with
    /// a known time and sometimes only a calendar day.
    static func airDate(of episode: SonarrEpisode) -> Date? {
        parseInstant(episode.airDateUtc) ?? parseDay(episode.airDate)
    }

    /// Whether it has aired by `now`. An episode with a file has aired by definition,
    /// whatever its date says - Sonarr's dates are occasionally a day late for
    /// timezone reasons, and a downloaded episode must never read as "to come".
    static func hasAired(_ episode: SonarrEpisode, now: Date) -> Bool {
        if episode.hasFile == true { return true }
        guard let date = airDate(of: episode) else { return false }
        return date <= now
    }

    // MARK: State

    static func state(
        of episode: SonarrEpisode,
        queue: [ArrInstanced<ArrQueueItem>],
        now: Date
    ) -> SonarrEpisodeState {
        if let item = queueItem(for: episode, in: queue)?.value {
            return item.isImportIssueQueueItem ? .importIssue : .downloading(progress: item.progress)
        }
        if episode.hasFile == true { return .onDisk }
        guard hasAired(episode, now: now) else { return .notAired(airDate(of: episode)) }
        return episode.monitored == false ? .unmonitored : .missing
    }

    /// The queue row for this episode, matched on the episode *and* the server that
    /// owns it: both Sonarr servers number episodes from the same sequence.
    static func queueItem(
        for episode: SonarrEpisode,
        in queue: [ArrInstanced<ArrQueueItem>]
    ) -> ArrInstanced<ArrQueueItem>? {
        queue.first { record in
            guard record.value.episodeId == episode.id else { return false }
            guard let owner = episode.instanceID else { return true }
            return record.instance.id == owner
        }
    }

    // MARK: Latest and next

    /// The newest regular episode that has aired. Specials (season 0) are left out:
    /// they air out of order and are rarely what "the latest episode" means.
    static func latestAired(in episodes: [SonarrEpisode], now: Date) -> SonarrEpisode? {
        episodes
            .filter { $0.seasonNumber > 0 && hasAired($0, now: now) }
            .max { order($0, $1) }
    }

    /// The next regular episode to air, if Sonarr knows of one.
    static func nextToAir(in episodes: [SonarrEpisode], now: Date) -> SonarrEpisode? {
        episodes
            .filter { $0.seasonNumber > 0 && !hasAired($0, now: now) && airDate(of: $0) != nil }
            .min { order($0, $1) }
    }

    /// Season, then episode number. Air dates are not used for ordering: two
    /// episodes released on one day are common, and numbering breaks the tie the way
    /// people expect.
    private static func order(_ lhs: SonarrEpisode, _ rhs: SonarrEpisode) -> Bool {
        (lhs.seasonNumber, lhs.episodeNumber) < (rhs.seasonNumber, rhs.episodeNumber)
    }

    // MARK: Seasons

    struct SeasonCounts: Equatable, Sendable {
        /// Episodes with a file.
        var onDisk: Int
        /// Episodes that have aired (or have a file).
        var aired: Int
        /// Episodes still to come.
        var upcoming: Int

        var missing: Int { max(0, aired - onDisk) }
        var isComplete: Bool { aired > 0 && onDisk >= aired }
    }

    static func seasonCounts(_ episodes: [SonarrEpisode], now: Date) -> SeasonCounts {
        var counts = SeasonCounts(onDisk: 0, aired: 0, upcoming: 0)
        for episode in episodes {
            if hasAired(episode, now: now) {
                counts.aired += 1
                if episode.hasFile == true { counts.onDisk += 1 }
            } else {
                counts.upcoming += 1
            }
        }
        return counts
    }

    /// The season the Episodes section opens on: the one holding the newest aired
    /// episode, or failing that the newest regular season, or specials alone.
    static func defaultSeason(seasonNumbers: [Int], episodes: [SonarrEpisode], now: Date) -> Int? {
        if let latest = latestAired(in: episodes, now: now), seasonNumbers.contains(latest.seasonNumber) {
            return latest.seasonNumber
        }
        return seasonNumbers.filter { $0 > 0 }.max() ?? seasonNumbers.max()
    }

    // MARK: Parsing

    private static func parseInstant(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func parseDay(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }
}
