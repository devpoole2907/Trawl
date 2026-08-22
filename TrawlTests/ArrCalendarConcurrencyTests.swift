import Foundation
import Testing
@testable import Trawl

@Suite("Arr calendar refresh concurrency")
@MainActor
struct ArrCalendarConcurrencyTests {
    @Test("Overlapping refreshes leave each calendar event in state once")
    func overlappingRefreshesDoNotDuplicateEvents() async throws {
        let eventDate = try #require(Calendar.current.date(byAdding: .day, value: 1, to: .now))
        let client = ControlledCalendarClient(event: try makeEpisode(id: 101, title: "Only Once", date: eventDate), eventDate: eventDate)
        let source = CalendarTestDataSource(activeClient: client, key: "profile-a")
        let viewModel = ArrCalendarViewModel(dataSource: source)

        let firstRefresh = Task { await viewModel.refresh() }
        await client.waitUntilCalendarRequestStarts()

        let secondRefresh = Task { await viewModel.refresh() }
        await client.waitUntilCalendarRequestCount(4)
        await client.releaseCalendarRequests()
        await firstRefresh.value
        await secondRefresh.value

        #expect(viewModel.calendarEventIDs == ["ep-101"])
        #expect(await client.calendarRequestCount == 6)
    }

    @Test("A refresh from a replaced active profile cannot overwrite the newer calendar")
    func staleRefreshCannotOverwriteReplacementProfile() async throws {
        let eventDate = try #require(Calendar.current.date(byAdding: .day, value: 1, to: .now))
        let clientA = ControlledCalendarClient(event: try makeEpisode(id: 201, title: "Server A", date: eventDate), eventDate: eventDate)
        let clientB = ControlledCalendarClient(event: try makeEpisode(id: 202, title: "Server B", date: eventDate), eventDate: eventDate, blocksCalendarRequests: false)
        let source = CalendarTestDataSource(activeClient: clientA, key: "profile-a")
        let viewModel = ArrCalendarViewModel(dataSource: source)

        let staleRefresh = Task { await viewModel.refresh() }
        await clientA.waitUntilCalendarRequestStarts()

        source.activate(clientB, key: "profile-b")
        await viewModel.refresh()
        await clientA.releaseCalendarRequests()
        await staleRefresh.value

        #expect(viewModel.calendarEventIDs == ["ep-202"])
        #expect(await clientB.calendarRequestCount == 3)
    }

    private func makeEpisode(id: Int, title: String, date: Date) throws -> SonarrEpisode {
        let json = """
        {
          "id": \(id),
          "seriesId": 1,
          "seasonNumber": 1,
          "episodeNumber": 1,
          "title": "\(title)",
          "airDateUtc": "\(date.ISO8601Format())"
        }
        """
        return try JSONDecoder().decode(SonarrEpisode.self, from: Data(json.utf8))
    }
}

@MainActor
private final class CalendarTestDataSource: ArrCalendarDataSource {
    private var activeClient: ControlledCalendarClient
    private var key: String

    init(activeClient: ControlledCalendarClient, key: String) {
        self.activeClient = activeClient
        self.key = key
    }

    var calendarConnectionKey: String { key }

    func activate(_ client: ControlledCalendarClient, key: String) {
        activeClient = client
        self.key = key
    }

    func calendarRefreshSnapshot() -> ArrCalendarRefreshSnapshot {
        let client = activeClient
        return ArrCalendarRefreshSnapshot(
            connectionKey: key,
            loadSeries: { [] },
            loadMovies: { [] },
            loadEpisodes: { start, end in
                await client.calendarEpisodes(start: start, end: end)
            },
            loadMovieCalendar: nil
        )
    }

    func iCalFeedLinks() async throws -> [ArrICalFeedLink] {
        throw ArrError.noServiceConfigured
    }

    func iCalFeedLink(for serviceType: ArrServiceType) async throws -> ArrICalFeedLink {
        throw ArrError.noServiceConfigured
    }
}

private actor ControlledCalendarClient {
    private let event: SonarrEpisode
    private let eventDate: Date
    private var blocksCalendarRequests: Bool
    private var hasReleasedCalendarRequests = false
    private var requestStartWaiters: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var requestReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calendarRequestCount = 0

    init(event: SonarrEpisode, eventDate: Date, blocksCalendarRequests: Bool = true) {
        self.event = event
        self.eventDate = eventDate
        self.blocksCalendarRequests = blocksCalendarRequests
    }

    func waitUntilCalendarRequestStarts() async {
        await waitUntilCalendarRequestCount(1)
    }

    func waitUntilCalendarRequestCount(_ minimumCount: Int) async {
        guard calendarRequestCount < minimumCount else { return }
        await withCheckedContinuation {
            requestStartWaiters.append((minimumCount, $0))
        }
    }

    func releaseCalendarRequests() {
        hasReleasedCalendarRequests = true
        let waiters = requestReleaseWaiters
        requestReleaseWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func calendarEpisodes(start: Date, end: Date) async -> [SonarrEpisode] {
        calendarRequestCount += 1
        let readyWaiters = requestStartWaiters.filter { $0.minimumCount <= calendarRequestCount }
        requestStartWaiters.removeAll { $0.minimumCount <= calendarRequestCount }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }

        if blocksCalendarRequests && !hasReleasedCalendarRequests {
            await withCheckedContinuation { requestReleaseWaiters.append($0) }
        }

        return start...end ~= eventDate ? [event] : []
    }
}
