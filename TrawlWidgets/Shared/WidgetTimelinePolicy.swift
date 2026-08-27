import Foundation

/// Centralized refresh policy for every Trawl widget. Keeping these decisions
/// pure makes them deterministic to test without asking WidgetKit to wait.
enum WidgetTimelinePolicy {
    struct CalendarSlice: Sendable {
        let date: Date
        let events: [WidgetCalendarEvent]
    }

    static func speedRefreshInterval(isActive: Bool) -> TimeInterval {
        isActive ? 5 * 60 : 30 * 60
    }

    static func activeDownloadsRefreshInterval(activeCount: Int) -> TimeInterval {
        activeCount > 0 ? 5 * 60 : 30 * 60
    }

    static func calendarRefreshInterval(hasEntries: Bool, isFailure: Bool) -> TimeInterval {
        if isFailure { return 12 * 60 * 60 }
        return hasEntries ? 5 * 60 * 60 : 6 * 60 * 60
    }

    static func libraryHealthRefreshInterval(issueCount: Int) -> TimeInterval {
        issueCount > 0 ? 15 * 60 : 60 * 60
    }

    /// The merged Seerr Inbox refreshes on whichever of its two counts is more
    /// urgent. A pending request is a decision someone is waiting on, so it pulls
    /// the tile back sooner than an open issue does.
    static func seerrInboxRefreshInterval(pendingCount: Int, openIssueCount: Int) -> TimeInterval {
        if pendingCount > 0 { return 10 * 60 }
        if openIssueCount > 0 { return 15 * 60 }
        return 30 * 60
    }

    /// The small Upcoming Releases tile prints a countdown rather than a list, so
    /// it must come back sooner than the list families when the next release is
    /// close — otherwise the tile keeps showing a stale "in 4h 20m" for hours.
    /// `secondsUntilNextRelease` is `nil` when there is nothing upcoming.
    static func calendarCountdownRefreshInterval(secondsUntilNextRelease: TimeInterval?) -> TimeInterval {
        guard let seconds = secondsUntilNextRelease else { return 6 * 60 * 60 }
        if seconds <= 0 { return 15 * 60 }
        if seconds < 60 * 60 { return 5 * 60 }
        if seconds < 6 * 60 * 60 { return 30 * 60 }
        if seconds < 24 * 60 * 60 { return 60 * 60 }
        return 5 * 60 * 60
    }

    /// The short headline a calendar widget shows when it cannot load releases.
    /// Widgets have no room for a full error, so unknown failures collapse to a
    /// single neutral string rather than leaking transport detail onto the Home Screen.
    static func calendarUnavailableMessage(for error: Error) -> String {
        switch error as? WidgetFetchError {
        case .noArrServicesConfigured: "No Sonarr or Radarr"
        case .missingCredentials: "Sign-In Needed"
        default: "Unavailable"
        }
    }

    /// Creates one entry per unique release day. A current entry is prepended
    /// when the first release is in the future so WidgetKit has content now.
    static func calendarSlices(
        from events: [WidgetCalendarEvent],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [CalendarSlice] {
        guard !events.isEmpty else { return [] }
        let dayStarts = Set(events.map { calendar.startOfDay(for: $0.date) }).sorted()
        let perDay = dayStarts.map { dayStart in
            CalendarSlice(
                date: dayStart,
                events: events.filter { $0.date >= dayStart }
            )
        }

        guard let firstDay = dayStarts.first,
              firstDay > calendar.startOfDay(for: now) else {
            return perDay
        }

        return [CalendarSlice(date: now, events: events.filter { $0.date >= now })] + perDay
    }
}
