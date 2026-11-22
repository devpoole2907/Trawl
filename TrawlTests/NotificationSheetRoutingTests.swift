import Foundation
import Testing
@testable import Trawl

/// The notification sheet's rules, each a pure function: what the bar leads with and
/// which tab that opens, which tabs exist, how the Alerts log is cut into sections,
/// what gets logged at all, and which requests count as recently available.
@Suite("Notification sheet routing")
@MainActor
struct NotificationSheetRoutingTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    /// 23 Nov 2026, 14:00 London.
    private static let now = Date(timeIntervalSince1970: 1_795_442_400)

    private static func entry(_ title: String, minutesAgo: Double) -> NotificationLogEntry {
        NotificationLogEntry(
            title: title,
            message: "",
            style: .success,
            source: .system,
            timestamp: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    // MARK: - Bar lead

    @Test("The bar leads with a decision, then a failure, then a download, then news")
    func barPriority() {
        #expect(NotificationBarLead.resolve(
            pendingRequests: 2, failingDownloads: 3, isDownloading: true, hasUnreadEvent: true, isImporting: true
        ) == .requestsWaiting(2))
        #expect(NotificationBarLead.resolve(
            pendingRequests: 0, failingDownloads: 3, isDownloading: true, hasUnreadEvent: true, isImporting: true
        ) == .downloadsFailing(3))
        #expect(NotificationBarLead.resolve(
            pendingRequests: 0, failingDownloads: 0, isDownloading: true, hasUnreadEvent: true, isImporting: true
        ) == .downloading)
        #expect(NotificationBarLead.resolve(
            pendingRequests: 0, failingDownloads: 0, isDownloading: false, hasUnreadEvent: true, isImporting: true
        ) == .latestEvent)
        #expect(NotificationBarLead.resolve(
            pendingRequests: 0, failingDownloads: 0, isDownloading: false, hasUnreadEvent: false, isImporting: true
        ) == .importing)
        #expect(NotificationBarLead.resolve(
            pendingRequests: 0, failingDownloads: 0, isDownloading: false, hasUnreadEvent: false, isImporting: false
        ) == .idle)
    }

    @Test("A tap on the bar opens the tab holding what it showed")
    func barTabs() {
        #expect(NotificationBarLead.requestsWaiting(1).tab == .requests)
        #expect(NotificationBarLead.downloadsFailing(1).tab == .downloads)
        #expect(NotificationBarLead.downloading.tab == .downloads)
        #expect(NotificationBarLead.latestEvent.tab == .alerts)
        #expect(NotificationBarLead.importing.tab == .alerts)
        #expect(NotificationBarLead.idle.tab == nil)
    }

    // MARK: - Tabs

    @Test("Tabs run in pipeline order, and Requests and Downloads only where they have a home")
    func availableTabs() {
        #expect(NotificationSheetTabs.available(hasSeerr: true, hasDownloads: true) == [.requests, .downloads, .alerts, .actions])
        #expect(NotificationSheetTabs.available(hasSeerr: false, hasDownloads: true) == [.downloads, .alerts, .actions])
        #expect(NotificationSheetTabs.available(hasSeerr: true, hasDownloads: false) == [.requests, .alerts, .actions])
        #expect(NotificationSheetTabs.available(hasSeerr: false, hasDownloads: false) == [.alerts, .actions])
    }

    @Test("The sheet opens on the requested tab, else the last used, else Alerts")
    func openingTab() {
        let all = NotificationSheetTab.allCases
        #expect(NotificationSheetTabs.opening(requested: .requests, lastUsed: .actions, available: all) == .requests)
        #expect(NotificationSheetTabs.opening(requested: nil, lastUsed: .actions, available: all) == .actions)
        #expect(NotificationSheetTabs.opening(requested: nil, lastUsed: nil, available: all) == .alerts)
        // A request for a tab that isn't offered is still "what's going on" - not the
        // last tab used, which would answer a different question.
        let noSeerr: [NotificationSheetTab] = [.downloads, .alerts, .actions]
        #expect(NotificationSheetTabs.opening(requested: .requests, lastUsed: .downloads, available: noSeerr) == .alerts)
        #expect(NotificationSheetTabs.opening(requested: nil, lastUsed: .requests, available: noSeerr) == .alerts)
    }

    // MARK: - Timeline

    @Test("New entries share one section; older ones are grouped by day, newest first")
    func timelineSections() {
        let lastRead = Self.now.addingTimeInterval(-30 * 60)
        let entries = [
            Self.entry("Yesterday evening", minutesAgo: 18 * 60),
            Self.entry("Just now", minutesAgo: 2),
            Self.entry("This morning", minutesAgo: 5 * 60),
            Self.entry("Ten minutes ago", minutesAgo: 10),
            Self.entry("Earlier today", minutesAgo: 60)
        ]

        let sections = NotificationTimeline.sections(entries, lastRead: lastRead, calendar: Self.calendar)

        #expect(sections.map(\.kind) == [
            .new(since: lastRead),
            .day(Self.calendar.startOfDay(for: Self.now)),
            .day(Self.calendar.startOfDay(for: Self.now.addingTimeInterval(-86_400)))
        ])
        #expect(sections[0].entries.map(\.title) == ["Just now", "Ten minutes ago"])
        #expect(sections[1].entries.map(\.title) == ["Earlier today", "This morning"])
        #expect(sections[2].entries.map(\.title) == ["Yesterday evening"])
    }

    @Test("A first look has nothing to be new since")
    func timelineFirstLook() {
        let sections = NotificationTimeline.sections(
            [Self.entry("Only", minutesAgo: 1)],
            lastRead: .distantPast,
            calendar: Self.calendar
        )
        #expect(sections.map(\.kind) == [.new(since: nil)])
        #expect(NotificationTimeline.title(for: .new(since: nil), now: Self.now, calendar: Self.calendar) == "New")
    }

    @Test("Headings say Today and Yesterday, and when the last look was")
    func timelineTitles() {
        let today = Self.calendar.startOfDay(for: Self.now)
        let yesterday = today.addingTimeInterval(-86_400)
        #expect(NotificationTimeline.title(for: .day(today), now: Self.now, calendar: Self.calendar) == "Today")
        #expect(NotificationTimeline.title(for: .day(yesterday), now: Self.now, calendar: Self.calendar) == "Yesterday")
        #expect(NotificationTimeline.title(
            for: .new(since: Self.now.addingTimeInterval(-20 * 3_600)),
            now: Self.now,
            calendar: Self.calendar
        ) == "New since yesterday")
        #expect(NotificationTimeline.title(
            for: .new(since: Self.now.addingTimeInterval(-60 * 60)),
            now: Self.now,
            calendar: Self.calendar
        ).hasPrefix("New since "))
    }

    @Test("Times read now, minutes and hours today, and a clock time yesterday")
    func timelineTimes() {
        #expect(NotificationTimeline.timeText(for: Self.now.addingTimeInterval(-20), now: Self.now, calendar: Self.calendar) == "now")
        #expect(NotificationTimeline.timeText(for: Self.now.addingTimeInterval(-4 * 60), now: Self.now, calendar: Self.calendar) == "4m")
        #expect(NotificationTimeline.timeText(for: Self.now.addingTimeInterval(-2 * 3_600), now: Self.now, calendar: Self.calendar) == "2h")
        let yesterdayEvening = Self.now.addingTimeInterval(-16 * 3_600)
        #expect(
            NotificationTimeline.timeText(for: yesterdayEvening, now: Self.now, calendar: Self.calendar)
                == yesterdayEvening.formatted(date: .omitted, time: .shortened)
        )
    }

    // MARK: - What gets logged

    @Test("Pushes, errors and outcomes are logged; tap confirmations and progress are not")
    func logPolicy() {
        #expect(NotificationLogPolicy.logs(style: .error, source: .inApp, destination: nil, isOutcome: false))
        #expect(NotificationLogPolicy.logs(style: .success, source: .system, destination: nil, isOutcome: false))
        #expect(NotificationLogPolicy.logs(style: .success, source: .inApp, destination: .movies, isOutcome: false))
        #expect(NotificationLogPolicy.logs(style: .success, source: .inApp, destination: nil, isOutcome: true))
        #expect(!NotificationLogPolicy.logs(style: .success, source: .inApp, destination: nil, isOutcome: false))
        #expect(!NotificationLogPolicy.logs(style: .progress, source: .inApp, destination: nil, isOutcome: true))
    }

    @Test("A tap confirmation still shows its banner but stays out of the log")
    @MainActor
    func confirmationShowsBannerOnly() {
        let center = InAppNotificationCenter()
        center.dismissCurrentBanner()
        let before = center.recentNotifications.count

        center.showSuccess(title: "Copied", message: "Magnet link copied.")
        #expect(center.recentNotifications.count == before)
        #expect(center.currentBanner?.title == "Copied")

        center.showSuccess(title: "Rescan Libraries", message: "Rescanned Jellyfin.", isOutcome: true)
        #expect(center.recentNotifications.count == before + 1)
        #expect(center.recentNotifications.first?.title == "Rescan Libraries")
    }

    // MARK: - Requests

    private static func request(id: Int, mediaAddedAt: String?, updatedAt: String? = nil) throws -> SeerrMediaRequest {
        var media: [String: Any] = ["id": id, "tmdbId": id, "mediaType": "movie", "status": 5]
        if let mediaAddedAt { media["mediaAddedAt"] = mediaAddedAt }
        var object: [String: Any] = ["id": id, "status": 5, "media": media]
        if let updatedAt { object["updatedAt"] = updatedAt }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SeerrMediaRequest.self, from: data)
    }

    @Test("Recently available keeps the last day's arrivals, newest first, and drops undated ones")
    func recentlyAvailable() throws {
        let requests = [
            try Self.request(id: 1, mediaAddedAt: "2026-11-23T10:00:00.000Z"),
            try Self.request(id: 2, mediaAddedAt: "2026-11-21T10:00:00.000Z"),
            try Self.request(id: 3, mediaAddedAt: nil),
            try Self.request(id: 4, mediaAddedAt: nil, updatedAt: "2026-11-23T12:30:00.000Z"),
            try Self.request(id: 5, mediaAddedAt: "2026-11-22T15:00:00.000Z")
        ]
        let kept = SeerrServiceManager.recentlyAvailable(requests, now: Self.now)
        #expect(kept.map(\.id) == [4, 1, 5])
    }

    @Test("Download progress sums every queue item for the requested quality")
    func downloadProgress() throws {
        let json = #"""
        {"id":1,"status":2,"is4k":false,"media":{"id":1,"tmdbId":1,"mediaType":"tv","status":3,
         "downloadStatus":[{"size":100,"sizeLeft":50,"title":"E01"},{"size":300,"sizeLeft":150,"title":"E02"}],
         "downloadStatus4k":[]}}
        """#
        let request = try JSONDecoder().decode(SeerrMediaRequest.self, from: Data(json.utf8))
        #expect(request.media?.downloadProgress(is4k: false) == 0.5)
        #expect(request.media?.downloadingCount(is4k: false) == 2)
        #expect(request.media?.downloadProgress(is4k: true) == nil)
    }
}
