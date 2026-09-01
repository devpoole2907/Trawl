import Foundation
import Testing
@testable import Trawl

@Suite("Widget timeline and data contracts")
struct WidgetTimelineAndDataTests {
    @Test("Every widget refresh policy distinguishes active, idle, empty, and failed states")
    func refreshPolicy() {
        #expect(WidgetTimelinePolicy.speedRefreshInterval(isActive: true) == 5 * 60)
        #expect(WidgetTimelinePolicy.speedRefreshInterval(isActive: false) == 30 * 60)
        #expect(WidgetTimelinePolicy.activeDownloadsRefreshInterval(activeCount: 2) == 5 * 60)
        #expect(WidgetTimelinePolicy.activeDownloadsRefreshInterval(activeCount: 0) == 30 * 60)
        #expect(WidgetTimelinePolicy.calendarRefreshInterval(hasEntries: true, isFailure: false) == 5 * 60 * 60)
        #expect(WidgetTimelinePolicy.calendarRefreshInterval(hasEntries: false, isFailure: false) == 6 * 60 * 60)
        #expect(WidgetTimelinePolicy.calendarRefreshInterval(hasEntries: false, isFailure: true) == 12 * 60 * 60)
        #expect(WidgetTimelinePolicy.libraryHealthRefreshInterval(issueCount: 1) == 15 * 60)
        #expect(WidgetTimelinePolicy.libraryHealthRefreshInterval(issueCount: 0) == 60 * 60)
        #expect(WidgetTimelinePolicy.seerrInboxRefreshInterval(pendingCount: 1, openIssueCount: 0) == 10 * 60)
        #expect(WidgetTimelinePolicy.seerrInboxRefreshInterval(pendingCount: 0, openIssueCount: 1) == 15 * 60)
        #expect(WidgetTimelinePolicy.seerrInboxRefreshInterval(pendingCount: 0, openIssueCount: 0) == 30 * 60)
        // A pending decision outranks an open issue when the inbox holds both.
        #expect(WidgetTimelinePolicy.seerrInboxRefreshInterval(pendingCount: 2, openIssueCount: 3) == 10 * 60)
    }

    @Test("The small calendar tile tightens its refresh as the next release approaches")
    func calendarCountdownRefreshPolicy() {
        #expect(WidgetTimelinePolicy.calendarCountdownRefreshInterval(secondsUntilNextRelease: nil) == 6 * 60 * 60)
        #expect(WidgetTimelinePolicy.calendarCountdownRefreshInterval(secondsUntilNextRelease: -60) == 15 * 60)
        #expect(WidgetTimelinePolicy.calendarCountdownRefreshInterval(secondsUntilNextRelease: 30 * 60) == 5 * 60)
        #expect(WidgetTimelinePolicy.calendarCountdownRefreshInterval(secondsUntilNextRelease: 3 * 60 * 60) == 30 * 60)
        #expect(WidgetTimelinePolicy.calendarCountdownRefreshInterval(secondsUntilNextRelease: 10 * 60 * 60) == 60 * 60)
        #expect(WidgetTimelinePolicy.calendarCountdownRefreshInterval(secondsUntilNextRelease: 48 * 60 * 60) == 5 * 60 * 60)

        // The tightest bucket must still be sooner than the list families' cadence,
        // otherwise the countdown is stale for longer than it is accurate.
        #expect(
            WidgetTimelinePolicy.calendarCountdownRefreshInterval(secondsUntilNextRelease: 30 * 60)
                < WidgetTimelinePolicy.calendarRefreshInterval(hasEntries: true, isFailure: false)
        )
    }

    // MARK: - Lock-screen accessories and the small calendar tile

    @Test("Circular accessory gauges clamp to their ceiling and never divide by zero")
    func countGaugeFractions() {
        #expect(WidgetGlanceFormatter.countGaugeFraction(count: 0, ceiling: 10) == 0)
        #expect(WidgetGlanceFormatter.countGaugeFraction(count: 5, ceiling: 10) == 0.5)
        #expect(WidgetGlanceFormatter.countGaugeFraction(count: 10, ceiling: 10) == 1)
        #expect(WidgetGlanceFormatter.countGaugeFraction(count: 25, ceiling: 10) == 1)
        #expect(WidgetGlanceFormatter.countGaugeFraction(count: -3, ceiling: 10) == 0)
        #expect(WidgetGlanceFormatter.countGaugeFraction(count: 3, ceiling: 0) == 0)
    }

    @Test("The speed dial reads against a configured cap, and against a log curve without one")
    func speedGaugeFraction() {
        // With a cap the dial is a plain fraction of it.
        #expect(
            WidgetGlanceFormatter.speedGaugeFraction(
                bytesPerSecond: 5_242_880, limitBytesPerSecond: 10_485_760
            ) == 0.5
        )
        #expect(
            WidgetGlanceFormatter.speedGaugeFraction(
                bytesPerSecond: 20_971_520, limitBytesPerSecond: 10_485_760
            ) == 1
        )
        #expect(WidgetGlanceFormatter.speedGaugeFraction(bytesPerSecond: 0, limitBytesPerSecond: 10_485_760) == 0)

        // With no cap, the ceiling still reads full and nothing exceeds it.
        #expect(
            WidgetGlanceFormatter.speedGaugeFraction(
                bytesPerSecond: WidgetGlanceFormatter.unlimitedSpeedCeiling, limitBytesPerSecond: 0
            ) == 1
        )
        #expect(
            WidgetGlanceFormatter.speedGaugeFraction(
                bytesPerSecond: WidgetGlanceFormatter.unlimitedSpeedCeiling * 4, limitBytesPerSecond: 0
            ) == 1
        )
        #expect(WidgetGlanceFormatter.speedGaugeFraction(bytesPerSecond: 0, limitBytesPerSecond: 0) == 0)

        // A 1 MB/s transfer is 1% of the ceiling but must not render as 1% of the
        // dial, which is the whole reason the uncapped curve is not linear.
        let oneMegabyte = WidgetGlanceFormatter.speedGaugeFraction(
            bytesPerSecond: 1_048_576, limitBytesPerSecond: 0
        )
        #expect(oneMegabyte > 0.04)
        #expect(oneMegabyte < 0.10)
    }

    @Test("The circular dial's centre label stays short at every magnitude")
    func compactRateLabels() {
        #expect(WidgetGlanceFormatter.compactRateLabel(bytesPerSecond: 0) == "0")
        #expect(WidgetGlanceFormatter.compactRateLabel(bytesPerSecond: 512) == "1K")
        #expect(WidgetGlanceFormatter.compactRateLabel(bytesPerSecond: 524_288) == "512K")
        #expect(WidgetGlanceFormatter.compactRateLabel(bytesPerSecond: 1_572_864) == "1.5")
        #expect(WidgetGlanceFormatter.compactRateLabel(bytesPerSecond: 12_582_912) == "12")
        #expect(WidgetGlanceFormatter.compactRateLabel(bytesPerSecond: 4_718_592, isUnavailable: true) == "--")

        for bytes in [Int64(0), 512, 524_288, 1_572_864, 12_582_912, 1_073_741_824] {
            #expect(WidgetGlanceFormatter.compactRateLabel(bytesPerSecond: bytes).count <= 4)
        }
    }

    @Test("The inline speed row says idle rather than printing a zero rate")
    func inlineSpeedText() {
        #expect(
            WidgetGlanceFormatter.inlineSpeedText(formattedDownloadRate: "12.4 MB/s", isActive: true)
                == "↓ 12.4 MB/s"
        )
        #expect(
            WidgetGlanceFormatter.inlineSpeedText(formattedDownloadRate: "0 B/s", isActive: false)
                == "Downloads idle"
        )
        #expect(
            WidgetGlanceFormatter.inlineSpeedText(
                formattedDownloadRate: "0 B/s", isActive: false, isUnavailable: true
            ) == "Downloads unavailable"
        )
    }

    @Test("The next-release countdown reads in days beyond today and in hours inside it")
    func releaseCountdown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try Date("2026-08-28T12:00:00Z", strategy: .iso8601)

        func countdown(_ iso: String) throws -> String {
            WidgetGlanceFormatter.releaseCountdown(
                to: try Date(iso, strategy: .iso8601), from: now, calendar: calendar
            )
        }

        #expect(try countdown("2026-08-28T16:30:00Z") == "in 4h 30m")
        #expect(try countdown("2026-08-28T12:20:00Z") == "in 20m")
        #expect(try countdown("2026-08-28T11:00:00Z") == "Out now")
        #expect(try countdown("2026-08-29T02:00:00Z") == "Tomorrow")
        #expect(try countdown("2026-08-31T09:00:00Z") == "in 3 days")
        #expect(try countdown("2026-09-04T09:00:00Z") == "in 1 week")
        #expect(try countdown("2026-09-15T09:00:00Z") == "in 2 weeks")
        #expect(try countdown("2026-08-27T09:00:00Z") == "Released")
    }

    // MARK: - Seerr Inbox

    @Test("The merged Seerr inbox summarises both counts in one inline row")
    func seerrInboxInlineText() {
        #expect(WidgetGlanceFormatter.seerrInboxInlineText(pendingCount: 0, openIssueCount: 0) == "Seerr all clear")
        #expect(WidgetGlanceFormatter.seerrInboxInlineText(pendingCount: 1, openIssueCount: 0) == "1 request")
        #expect(WidgetGlanceFormatter.seerrInboxInlineText(pendingCount: 3, openIssueCount: 0) == "3 requests")
        #expect(WidgetGlanceFormatter.seerrInboxInlineText(pendingCount: 0, openIssueCount: 1) == "1 issue")
        #expect(WidgetGlanceFormatter.seerrInboxInlineText(pendingCount: 0, openIssueCount: 2) == "2 issues")
        #expect(
            WidgetGlanceFormatter.seerrInboxInlineText(pendingCount: 3, openIssueCount: 2)
                == "3 requests · 2 issues"
        )
        #expect(
            WidgetGlanceFormatter.seerrInboxInlineText(pendingCount: 3, openIssueCount: 2, isUnavailable: true)
                == "Seerr unavailable"
        )
    }

    @Test("The Seerr inbox deep link targets the surface the counts point at")
    func seerrInboxDestination() {
        #expect(
            WidgetGlanceFormatter.seerrInboxDestination(pendingCount: 2, openIssueCount: 5) == .requests
        )
        #expect(
            WidgetGlanceFormatter.seerrInboxDestination(pendingCount: 0, openIssueCount: 5) == .issues
        )
        #expect(
            WidgetGlanceFormatter.seerrInboxDestination(pendingCount: 0, openIssueCount: 0) == .requests
        )

        // These are the exact hosts ContentView routes; a rename here silently
        // breaks the tap without breaking the build.
        #expect(WidgetGlanceFormatter.SeerrInboxDestination.requests.rawValue == "trawl://seerr-requests")
        #expect(WidgetGlanceFormatter.SeerrInboxDestination.issues.rawValue == "trawl://seerr-issue")
        #expect(URL(string: WidgetGlanceFormatter.SeerrInboxDestination.requests.rawValue) != nil)
        #expect(URL(string: WidgetGlanceFormatter.SeerrInboxDestination.issues.rawValue) != nil)
    }

    // MARK: - Control Center pause/resume

    @Test("Download pause state blends qBittorrent and SABnzbd rather than reading one client")
    func downloadControlStateBlendsClients() {
        // Nothing answered: the control must not claim the stack is paused.
        #expect(DownloadControlState.unavailable.isAvailable == false)
        #expect(DownloadControlState.unavailable.isRunning == false)
        #expect(DownloadControlState.unavailable.statusLabel == "No Client")

        let qbRunning = DownloadControlState(
            runningTorrentCount: 2, stoppedTorrentCount: 1, reachableClientCount: 1
        )
        #expect(qbRunning.isRunning)
        #expect(qbRunning.statusLabel == "Downloading")

        let qbAllStopped = DownloadControlState(
            runningTorrentCount: 0, stoppedTorrentCount: 4, reachableClientCount: 1
        )
        #expect(qbAllStopped.isRunning == false)
        #expect(qbAllStopped.statusLabel == "Paused")

        // A live SABnzbd queue makes the blended stack running even with every
        // torrent stopped - this is the case a qBittorrent-only control gets wrong.
        let soleLiveSAB = DownloadControlState(
            runningTorrentCount: 0,
            stoppedTorrentCount: 4,
            sabQueuePausedFlags: [false],
            reachableClientCount: 2
        )
        #expect(soleLiveSAB.isRunning)

        let sabStillLive = DownloadControlState(
            runningTorrentCount: 0,
            stoppedTorrentCount: 4,
            sabQueuePausedFlags: [true, false],
            reachableClientCount: 3
        )
        #expect(sabStillLive.isRunning)

        let everythingPaused = DownloadControlState(
            runningTorrentCount: 0,
            stoppedTorrentCount: 4,
            sabQueuePausedFlags: [true],
            reachableClientCount: 2
        )
        #expect(everythingPaused.isRunning == false)

        // An empty qBittorrent with no SABnzbd is idle, not paused.
        let emptyButUp = DownloadControlState(
            runningTorrentCount: 0, stoppedTorrentCount: 0, reachableClientCount: 1
        )
        #expect(emptyButUp.isRunning)

        // ...but an empty qBittorrent beside a paused SABnzbd queue is paused.
        let emptyBesidePausedSAB = DownloadControlState(
            runningTorrentCount: 0,
            stoppedTorrentCount: 0,
            sabQueuePausedFlags: [true],
            reachableClientCount: 2
        )
        #expect(emptyBesidePausedSAB.isRunning == false)
    }

    @Test("The control applies the requested switch position and refuses when no client answered")
    func downloadControlAction() {
        let available = DownloadControlState(runningTorrentCount: 1, reachableClientCount: 1)
        #expect(DownloadControlState.action(requestedRunning: false, state: available) == .pause)
        #expect(DownloadControlState.action(requestedRunning: true, state: available) == .resume)

        // The position is applied as asked even when the cached read already agrees,
        // because that read can be minutes old.
        let alreadyPaused = DownloadControlState(stoppedTorrentCount: 3, reachableClientCount: 1)
        #expect(DownloadControlState.action(requestedRunning: false, state: alreadyPaused) == .pause)

        #expect(
            DownloadControlState.action(requestedRunning: true, state: .unavailable) == .unavailable
        )
        #expect(
            DownloadControlState.action(requestedRunning: false, state: .unavailable) == .unavailable
        )
    }

    @Test("qBittorrent v4 and v5 stopped-state spellings are both recognised")
    func torrentStateClassification() {
        for running in ["downloading", "stalledDL", "queuedDL", "metaDL", "uploading", "moving"] {
            #expect(DownloadControlState.isRunningTorrentState(running))
            #expect(DownloadControlState.isStoppedTorrentState(running) == false)
        }

        // qBittorrent 5 renamed `paused*` to `stopped*`; both must count as stopped.
        for stopped in ["pausedDL", "pausedUP", "stoppedDL", "stoppedUP"] {
            #expect(DownloadControlState.isStoppedTorrentState(stopped))
            #expect(DownloadControlState.isRunningTorrentState(stopped) == false)
        }

        // A broken torrent is neither running nor resumable, so it must not tip
        // the blended state either way.
        for neither in ["error", "missingFiles", "unknown", "somethingNew"] {
            #expect(DownloadControlState.isRunningTorrentState(neither) == false)
            #expect(DownloadControlState.isStoppedTorrentState(neither) == false)
        }
    }

    @Test("Calendar timeline advances by release day without dropping later releases")
    func calendarEntriesAdvanceByDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try Date("2026-08-28T12:00:00Z", strategy: .iso8601)
        let tomorrow = try Date("2026-08-29T10:00:00Z", strategy: .iso8601)
        let nextDay = try Date("2026-08-30T11:00:00Z", strategy: .iso8601)
        let events = [
            makeEvent(id: "tomorrow", date: tomorrow),
            makeEvent(id: "next-day", date: nextDay),
        ]

        let entries = WidgetTimelinePolicy.calendarSlices(from: events, now: now, calendar: calendar)

        #expect(entries.count == 3)
        #expect(entries[0].date == now)
        #expect(entries[0].events.map(\.id) == ["tomorrow", "next-day"])
        #expect(entries[1].events.map(\.id) == ["tomorrow", "next-day"])
        #expect(entries[2].events.map(\.id) == ["next-day"])
    }

    @Test("Calendar with no releases emits no timeline slices")
    func emptyCalendarHasNoSlices() {
        #expect(WidgetTimelinePolicy.calendarSlices(from: []).isEmpty)
    }

    // MARK: - Calendar scope and failure states

    @Test("Calendar scope decides whether unmonitored releases are requested")
    func calendarScopeControlsUnmonitored() {
        #expect(CalendarScopeOption.all.includeUnmonitored == true)
        #expect(CalendarScopeOption.monitored.includeUnmonitored == false)
    }

    @Test("Calendar failures collapse to a short headline without leaking transport detail")
    func calendarUnavailableMessages() {
        #expect(
            WidgetTimelinePolicy.calendarUnavailableMessage(for: WidgetFetchError.noArrServicesConfigured)
                == "No Sonarr or Radarr"
        )
        #expect(
            WidgetTimelinePolicy.calendarUnavailableMessage(for: WidgetFetchError.missingCredentials)
                == "Sign-In Needed"
        )
        #expect(
            WidgetTimelinePolicy.calendarUnavailableMessage(for: WidgetFetchError.noServerConfigured)
                == "Unavailable"
        )

        // A transport failure must not put a URL or host name on the Home Screen.
        let transport = URLError(.cannotConnectToHost)
        #expect(WidgetTimelinePolicy.calendarUnavailableMessage(for: transport) == "Unavailable")
    }

    @Test("Calendar distinguishes a genuine empty result from every server being unreachable")
    func calendarEmptyVersusUnavailable() {
        #expect(WidgetTimelinePolicy.calendarFetchIsUnavailable(configuredCount: 2, answeredCount: 0))
        #expect(WidgetTimelinePolicy.calendarFetchIsUnavailable(configuredCount: 2, answeredCount: 1) == false)
        #expect(WidgetTimelinePolicy.calendarFetchIsUnavailable(configuredCount: 0, answeredCount: 0) == false)
    }

    @Test("Download widget selection scopes either client type and preserves old qBittorrent IDs")
    func downloadWidgetClientSelection() {
        let all = WidgetDownloadClientSelection(nil)
        #expect(all.includesQBittorrent)
        #expect(all.includesSABnzbd)

        let qb = WidgetDownloadClientSelection("qb:11111111-1111-1111-1111-111111111111")
        #expect(qb.qbittorrentID == "11111111-1111-1111-1111-111111111111")
        #expect(qb.includesQBittorrent)
        #expect(qb.includesSABnzbd == false)

        let sab = WidgetDownloadClientSelection("sab:22222222-2222-2222-2222-222222222222")
        #expect(sab.sabnzbdID == "22222222-2222-2222-2222-222222222222")
        #expect(sab.includesQBittorrent == false)
        #expect(sab.includesSABnzbd)

        let legacy = WidgetDownloadClientSelection("33333333-3333-3333-3333-333333333333")
        #expect(legacy.qbittorrentID == "33333333-3333-3333-3333-333333333333")
        #expect(legacy.includesQBittorrent)
        #expect(legacy.includesSABnzbd == false)
    }

    // MARK: - Seerr decoding and display fallbacks

    @Test("Seerr request payloads decode and fall back through every title field")
    func seerrRequestDecoding() throws {
        let json = """
        {
          "pageInfo": { "results": 3 },
          "results": [
            { "id": 11, "is4k": true, "createdAt": "2026-08-27T10:00:00.000Z",
              "media": { "mediaType": "movie", "title": "Arrival" },
              "requestedBy": { "id": 2, "displayName": "Ada" } },
            { "id": 12, "is4k": false,
              "media": { "mediaType": "tv", "name": "Severance" },
              "requestedBy": { "id": 3, "jellyfinUsername": "grace" } },
            { "id": 13,
              "media": { "mediaType": "book", "originalName": "Solaris" },
              "requestedBy": { "id": 4, "email": "ada.lovelace@example.com" } }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(
            WidgetSeerrRequestListResponse.self, from: Data(json.utf8)
        )

        #expect(decoded.pageInfo.results == 3)
        #expect(decoded.results.map(\.id) == [11, 12, 13])

        #expect(decoded.results[0].media?.displayTitle == "Arrival")
        #expect(decoded.results[0].media?.typeLabel == "Movie")
        #expect(decoded.results[0].is4k == true)
        #expect(decoded.results[0].requestedBy?.displayName == "Ada")

        // `name` covers series, which carry no `title`.
        #expect(decoded.results[1].media?.displayTitle == "Severance")
        #expect(decoded.results[1].media?.typeLabel == "Series")
        #expect(decoded.results[1].requestedBy?.displayName == "grace")

        // An unknown media type is shown capitalised rather than dropped.
        #expect(decoded.results[2].media?.displayTitle == "Solaris")
        #expect(decoded.results[2].media?.typeLabel == "Book")
        // No name of any kind: the email local part becomes a readable name.
        #expect(decoded.results[2].requestedBy?.displayName == "Ada Lovelace")
        #expect(decoded.results[2].is4k == nil)
    }

    @Test("Seerr media with no usable title still renders a label")
    func seerrMissingTitleFallsBack() throws {
        let json = """
        { "pageInfo": {}, "results": [ { "id": 1, "media": {}, "requestedBy": { "id": 9 } } ] }
        """
        let decoded = try JSONDecoder().decode(
            WidgetSeerrRequestListResponse.self, from: Data(json.utf8)
        )

        #expect(decoded.pageInfo.results == nil)
        #expect(decoded.results[0].media?.displayTitle == "Unknown Media")
        #expect(decoded.results[0].media?.typeLabel == "Media")
        #expect(decoded.results[0].requestedBy?.displayName == "User")
    }

    @Test("Seerr issue payloads decode and name every issue kind")
    func seerrIssueDecoding() throws {
        let json = """
        {
          "pageInfo": { "results": 5 },
          "results": [
            { "id": 1, "issueType": 1, "media": { "title": "Dune" }, "createdBy": { "id": 1, "username": "sam" } },
            { "id": 2, "issueType": 2, "media": { "name": "Andor" }, "createdBy": { "id": 2, "plexUsername": "plexer" } },
            { "id": 3, "issueType": 3, "media": { "originalTitle": "Ran" }, "createdBy": { "id": 3, "discordUsername": "disc" } },
            { "id": 4, "issueType": 4, "media": { "originalName": "Shogun" }, "createdBy": { "id": 4 } },
            { "id": 5, "media": {}, "createdBy": { "id": 5 } }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(
            WidgetSeerrIssueListResponse.self, from: Data(json.utf8)
        )

        #expect(decoded.results.map(\.issueKindLabel) == ["Video", "Audio", "Subtitle", "Other", "Issue"])
        #expect(decoded.results.map { $0.media?.displayTitle ?? "" }
            == ["Dune", "Andor", "Ran", "Shogun", "Unknown Media"])
        #expect(decoded.results[0].createdBy?.displayName == "sam")
        #expect(decoded.results[1].createdBy?.displayName == "plexer")
        #expect(decoded.results[2].createdBy?.displayName == "disc")
        #expect(decoded.results[3].createdBy?.displayName == "User")
    }

    @Test("Seerr display name prefers the explicit display name over every other field")
    func seerrDisplayNamePrecedence() throws {
        let json = """
        { "id": 1, "displayName": "Explicit", "jellyfinUsername": "jelly",
          "username": "user", "plexUsername": "plex", "discordUsername": "discord",
          "email": "fallback@example.com" }
        """
        let user = try JSONDecoder().decode(WidgetSeerrUser.self, from: Data(json.utf8))
        #expect(user.displayName == "Explicit")

        // Underscores and hyphens in an email local part also become word breaks.
        let hyphenated = """
        { "id": 2, "email": "grace_brewster-murray@example.com" }
        """
        let other = try JSONDecoder().decode(WidgetSeerrUser.self, from: Data(hyphenated.utf8))
        #expect(other.displayName == "Grace Brewster Murray")
    }

    private func makeEvent(id: String, date: Date) -> WidgetCalendarEvent {
        WidgetCalendarEvent(
            id: id,
            date: date,
            title: id,
            subtitle: nil,
            posterURL: nil,
            placeholderIcon: "tv",
            accentColorName: "purple",
            badgeLabel: nil,
            isDownloaded: false
        )
    }
}
