import Foundation

/// Pure presentation mapping for the glanceable widget surfaces: the lock-screen
/// accessory families and the small Upcoming Releases tile.
///
/// This deliberately imports nothing but Foundation. The decisions here - what a
/// gauge fills to, what one line of inline text says, how far away the next
/// release reads - are the parts of those layouts that can actually be wrong, so
/// they live outside SwiftUI where a test can compile and pin them.
nonisolated enum WidgetGlanceFormatter {

    // MARK: - Gauges

    /// How many active downloads count as a "full" circular gauge.
    static let activeDownloadsGaugeCeiling = 10

    /// How many library issues count as a "full" circular gauge.
    static let libraryIssuesGaugeCeiling = 10

    /// Rate treated as a full dial when no qBittorrent rate cap is configured.
    static let unlimitedSpeedCeiling: Int64 = 100 * 1_048_576

    /// Fraction a circular accessory gauge fills for a plain count.
    static func countGaugeFraction(count: Int, ceiling: Int) -> Double {
        guard count > 0, ceiling > 0 else { return 0 }
        return min(1, Double(count) / Double(ceiling))
    }

    /// Fraction the download-speed dial fills.
    ///
    /// With a rate cap configured the dial is a straight fraction of that cap. With
    /// no cap there is no true maximum, so the dial uses a log curve against
    /// `unlimitedSpeedCeiling`: a typical few-MB/s transfer stays visible instead of
    /// sitting pinned near zero, and a very fast one still cannot exceed full.
    static func speedGaugeFraction(bytesPerSecond: Int64, limitBytesPerSecond: Int64) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        if limitBytesPerSecond > 0 {
            return min(1, Double(bytesPerSecond) / Double(limitBytesPerSecond))
        }
        let ratio = min(1, Double(bytesPerSecond) / Double(unlimitedSpeedCeiling))
        return min(1, log2(1 + 15 * ratio) / log2(16))
    }

    /// Short centre label for the speed dial. The unit is implied by the dial's
    /// arrow, so only the magnitude is printed - a circular accessory has room for
    /// roughly three or four characters.
    static func compactRateLabel(bytesPerSecond: Int64, isUnavailable: Bool = false) -> String {
        if isUnavailable { return "--" }
        guard bytesPerSecond > 0 else { return "0" }

        let megabytes = Double(bytesPerSecond) / 1_048_576
        if megabytes >= 10 { return String(Int(megabytes.rounded())) }
        if megabytes >= 1 { return String(format: "%.1f", megabytes) }
        return "\(max(1, bytesPerSecond / 1024))K"
    }

    // MARK: - Inline accessories

    /// The single inline row has no room for both directions, so an idle client
    /// says so in a word rather than printing a meaningless `↓ 0 B/s`.
    static func inlineSpeedText(formattedDownloadRate: String, isActive: Bool, isUnavailable: Bool = false) -> String {
        if isUnavailable { return "Downloads unavailable" }
        guard isActive else { return "Downloads idle" }
        return "↓ \(formattedDownloadRate)"
    }

    /// One line summarising the Seerr inbox for `accessoryInline`.
    static func seerrInboxInlineText(pendingCount: Int, openIssueCount: Int, isUnavailable: Bool = false) -> String {
        if isUnavailable { return "Seerr unavailable" }

        let requests = pendingCount == 1 ? "1 request" : "\(pendingCount) requests"
        let issues = openIssueCount == 1 ? "1 issue" : "\(openIssueCount) issues"

        switch (pendingCount > 0, openIssueCount > 0) {
        case (true, true): return "\(requests) · \(issues)"
        case (true, false): return requests
        case (false, true): return issues
        case (false, false): return "Seerr all clear"
        }
    }

    // MARK: - Seerr inbox routing

    /// Where a tap on the merged Seerr Inbox tile should land.
    enum SeerrInboxDestination: String, Sendable, Equatable {
        case requests = "trawl://seerr-requests"
        case issues = "trawl://seerr-issue"
    }

    /// Requests are the decision the user is being asked for, so they win when both
    /// counts are non-zero. Issues only take the tap when nothing is pending.
    static func seerrInboxDestination(pendingCount: Int, openIssueCount: Int) -> SeerrInboxDestination {
        if pendingCount > 0 { return .requests }
        if openIssueCount > 0 { return .issues }
        return .requests
    }

    // MARK: - Release countdown

    /// The countdown printed on the small Upcoming Releases tile.
    ///
    /// Day-level wording is used beyond today because a Home Screen tile is glanced
    /// at, not read; inside today the remaining hours and minutes are what matter.
    static func releaseCountdown(
        to release: Date,
        from now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let releaseDay = calendar.startOfDay(for: release)
        let days = calendar.dateComponents([.day], from: today, to: releaseDay).day ?? 0

        if days < 0 { return "Released" }

        if days == 0 {
            let seconds = Int(release.timeIntervalSince(now))
            guard seconds > 0 else { return "Out now" }
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            if hours > 0 { return "in \(hours)h \(minutes)m" }
            if minutes > 0 { return "in \(minutes)m" }
            return "Out now"
        }

        if days == 1 { return "Tomorrow" }
        if days < 7 { return "in \(days) days" }

        let weeks = days / 7
        return weeks == 1 ? "in 1 week" : "in \(weeks) weeks"
    }
}
