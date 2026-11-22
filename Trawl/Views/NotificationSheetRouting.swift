import Foundation

/// What the notification bar leads with, and so which tab a tap on it opens.
///
/// The sheet holds the stack's work in progress, and the bar is its one-line
/// summary, so the bar shows the most urgent thing in the sheet: a decision only the
/// user can make, then something broken, then something moving, then news. Each case
/// names the tab that holds it, so a tap always lands on the thing the bar described.
nonisolated enum NotificationBarLead: Equatable, Sendable {
    case requestsWaiting(Int)
    case downloadsFailing(Int)
    case downloading
    case latestEvent
    case importing
    case idle

    static func resolve(
        pendingRequests: Int,
        failingDownloads: Int,
        isDownloading: Bool,
        hasUnreadEvent: Bool,
        isImporting: Bool
    ) -> NotificationBarLead {
        if pendingRequests > 0 { return .requestsWaiting(pendingRequests) }
        if failingDownloads > 0 { return .downloadsFailing(failingDownloads) }
        if isDownloading { return .downloading }
        if hasUnreadEvent { return .latestEvent }
        if isImporting { return .importing }
        return .idle
    }

    /// `nil` leaves the sheet on whichever tab the user had open last.
    var tab: NotificationSheetTab? {
        switch self {
        case .requestsWaiting: .requests
        case .downloadsFailing, .downloading: .downloads
        case .latestEvent, .importing: .alerts
        case .idle: nil
        }
    }
}

/// Which tabs the sheet offers, and which one it opens on.
nonisolated enum NotificationSheetTabs {
    static func available(hasSeerr: Bool, hasDownloads: Bool) -> [NotificationSheetTab] {
        NotificationSheetTab.allCases.filter { tab in
            switch tab {
            case .requests: hasSeerr
            case .downloads: hasDownloads
            case .alerts, .actions: true
            }
        }
    }

    /// The requested tab when the sheet offers it. With no request, the last tab
    /// used. Anything else opens on Alerts: a request for a tab that isn't offered -
    /// Downloads in the sidebar chrome, Requests without Seerr - was still a request
    /// for "what's going on", and the last tab used would answer a different question.
    static func opening(
        requested: NotificationSheetTab?,
        lastUsed: NotificationSheetTab?,
        available: [NotificationSheetTab]
    ) -> NotificationSheetTab {
        if let requested {
            return available.contains(requested) ? requested : .alerts
        }
        if let lastUsed, available.contains(lastUsed) { return lastUsed }
        return .alerts
    }
}

/// The Alerts log, cut into the sections it reads in.
///
/// Everything newer than the last look goes under one "New since" heading, whatever
/// day it fell on - that is the question the user opened the sheet with. The rest is
/// grouped by day, newest first.
nonisolated enum NotificationTimeline {
    enum SectionKind: Hashable, Sendable {
        case new(since: Date?)
        case day(Date)
    }

    struct Section: Identifiable, Sendable {
        let kind: SectionKind
        let entries: [NotificationLogEntry]

        var id: SectionKind { kind }
    }

    static func sections(
        _ entries: [NotificationLogEntry],
        lastRead: Date,
        calendar: Calendar = .current
    ) -> [Section] {
        let sorted = entries.sorted { $0.timestamp > $1.timestamp }
        let newEntries = sorted.filter { $0.timestamp > lastRead }
        let older = sorted.filter { $0.timestamp <= lastRead }

        var result: [Section] = []
        if !newEntries.isEmpty {
            result.append(Section(kind: .new(since: lastRead == .distantPast ? nil : lastRead), entries: newEntries))
        }

        var days: [Date] = []
        var byDay: [Date: [NotificationLogEntry]] = [:]
        for entry in older {
            let day = calendar.startOfDay(for: entry.timestamp)
            if byDay[day] == nil { days.append(day) }
            byDay[day, default: []].append(entry)
        }
        result += days.map { Section(kind: .day($0), entries: byDay[$0] ?? []) }
        return result
    }

    static func title(for kind: SectionKind, now: Date, calendar: Calendar = .current) -> String {
        switch kind {
        case .new(let since):
            guard let since else { return "New" }
            if calendar.isDate(since, inSameDayAs: now) {
                return "New since \(since.formatted(date: .omitted, time: .shortened))"
            }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(since, inSameDayAs: yesterday) {
                return "New since yesterday"
            }
            return "New since \(since.formatted(.dateTime.day().month(.abbreviated)))"
        case .day(let day):
            if calendar.isDate(day, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(day, inSameDayAs: yesterday) {
                return "Yesterday"
            }
            return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// "now", "4m" and "2h" today; a clock time yesterday; a date before that. The
    /// full date and time is on the detail screen - repeating it on every row was most
    /// of what made the old rows three lines tall.
    static func timeText(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if calendar.isDate(date, inSameDayAs: now) {
            if seconds < 60 { return "now" }
            if seconds < 3_600 { return "\(Int(seconds / 60))m" }
            return "\(Int(seconds / 3_600))h"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
