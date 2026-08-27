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

    static func pendingRequestsRefreshInterval(pendingCount: Int) -> TimeInterval {
        pendingCount > 0 ? 10 * 60 : 30 * 60
    }

    static func openIssuesRefreshInterval(openCount: Int) -> TimeInterval {
        openCount > 0 ? 15 * 60 : 45 * 60
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
