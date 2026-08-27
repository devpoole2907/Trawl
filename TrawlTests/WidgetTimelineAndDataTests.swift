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
        #expect(WidgetTimelinePolicy.pendingRequestsRefreshInterval(pendingCount: 1) == 10 * 60)
        #expect(WidgetTimelinePolicy.pendingRequestsRefreshInterval(pendingCount: 0) == 30 * 60)
        #expect(WidgetTimelinePolicy.openIssuesRefreshInterval(openCount: 1) == 15 * 60)
        #expect(WidgetTimelinePolicy.openIssuesRefreshInterval(openCount: 0) == 45 * 60)
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
