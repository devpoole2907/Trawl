import SwiftUI
import TipKit
import Observation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Calendar View Model

@MainActor
protocol ArrCalendarDataSource: AnyObject {
    var calendarConnectionKey: String { get }
    func calendarRefreshSnapshot() -> ArrCalendarRefreshSnapshot
    func iCalFeedLinks() async throws -> [ArrICalFeedLink]
    func iCalFeedLink(for serviceType: ArrServiceType) async throws -> ArrICalFeedLink
}

struct ArrCalendarRefreshSnapshot: Sendable {
    let connectionKey: String
    let loadSeries: @Sendable () async throws -> [SonarrSeries]
    let loadMovies: @Sendable () async throws -> [RadarrMovie]
    let loadEpisodes: (@Sendable (Date, Date) async throws -> [SonarrEpisode])?
    let loadMovieCalendar: (@Sendable (Date, Date) async throws -> [RadarrMovie])?
}

extension ArrServiceManager: ArrCalendarDataSource {
    /// Keyed by every visible instance, so adding, losing or filtering a server
    /// rebuilds the calendar instead of leaving one server's airings on screen.
    var calendarConnectionKey: String {
        (visibleSonarr.map(\.ref.id.uuidString) + visibleRadarr.map(\.ref.id.uuidString))
            .joined(separator: "|")
    }

    /// The calendar is the union of both servers' schedules.
    ///
    /// Every fetch is stamped with the server it came from, so an episode that
    /// both a HD and a 4K Sonarr are tracking shows as two airings - which is the
    /// truth, since each will grab its own release - each labelled with its
    /// server rather than silently collapsing into one.
    func calendarRefreshSnapshot() -> ArrCalendarRefreshSnapshot {
        let sonarr = visibleSonarr
        let radarr = visibleRadarr

        let loadEpisodes: (@Sendable (Date, Date) async throws -> [SonarrEpisode])? = sonarr.isEmpty ? nil : { @Sendable start, end in
            var all: [SonarrEpisode] = []
            for (ref, client) in sonarr {
                let page = try await client.getCalendar(start: start, end: end, unmonitored: true, includeSeries: true)
                all += page.stamped(with: ref.id)
            }
            return all
        }

        let loadMovieCalendar: (@Sendable (Date, Date) async throws -> [RadarrMovie])? = radarr.isEmpty ? nil : { @Sendable start, end in
            var all: [RadarrMovie] = []
            for (ref, client) in radarr {
                let page = try await client.getCalendar(start: start, end: end, unmonitored: true)
                all += page.stamped(with: ref.id)
            }
            return all
        }

        return ArrCalendarRefreshSnapshot(
            connectionKey: calendarConnectionKey,
            loadSeries: {
                var all: [SonarrSeries] = []
                for (ref, client) in sonarr {
                    all += try await client.getSeries().stamped(with: ref.id)
                }
                return all
            },
            loadMovies: {
                var all: [RadarrMovie] = []
                for (ref, client) in radarr {
                    all += try await client.getMovies().stamped(with: ref.id)
                }
                return all
            },
            loadEpisodes: loadEpisodes,
            loadMovieCalendar: loadMovieCalendar
        )
    }
}

@MainActor
@Observable
final class ArrCalendarViewModel {
    fileprivate let serviceManager: any ArrCalendarDataSource
    
    // Core Data
    fileprivate var loadedMonths: [YearMonth] = []
    fileprivate var eventsByDay: [Date: [CalendarEvent]] = [:]
    fileprivate var monthLoadErrors: [YearMonth: String] = [:]
    var sonarrSeries: [SonarrSeries] = []
    var radarrMovies: [RadarrMovie] = []
    
    // State
    var isLoadingInitial = true
    var isRefreshing = false
    var isLoadingMore = false
    var isLoadingEarlier = false
    private var lastRefreshKey: String = ""
    
    // Scroll state persistence
    var scrollID: Date? = Calendar.current.startOfDay(for: .now)
    
    private var seriesLookup: [ArrScopedID: SonarrSeries] = [:]
    private let calendar = Calendar.current
    private var refreshGeneration = 0
    
    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    init(dataSource: any ArrCalendarDataSource) {
        self.serviceManager = dataSource
    }

    func iCalFeedLinks() async throws -> [ArrICalFeedLink] {
        try await serviceManager.iCalFeedLinks()
    }

    func iCalFeedLink(for serviceType: ArrServiceType) async throws -> ArrICalFeedLink {
        try await serviceManager.iCalFeedLink(for: serviceType)
    }

    func initialize() async {
        let currentKey = serviceManager.calendarConnectionKey
        if isLoadingInitial || loadedMonths.isEmpty || currentKey != lastRefreshKey {
            await refresh()
            isLoadingInitial = false
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshot = serviceManager.calendarRefreshSnapshot()
        isRefreshing = true
        let libraries = await loadLibraries(from: snapshot)
        
        let today = calendar.startOfDay(for: .now)
        let startMonth = YearMonth.from(today).advanced(by: -1)
        
        // Load initial window: Prev, Current, Next Month
        var monthsToLoad: [YearMonth] = []
        for i in 0..<3 {
            monthsToLoad.append(startMonth.advanced(by: i))
        }

        // Keyed by (server, series ID), and non-trapping: with a pair configured
        // both servers hand back a series 1, which a bare-Int key either resolves
        // to the wrong show or crashes on.
        let lookup = Dictionary(
            libraries.series.map { (ArrScopedID($0.instanceID, $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var monthData: [(YearMonth, [Date: [CalendarEvent]])] = []
        var errors: [YearMonth: String] = [:]

        await withTaskGroup(of: Result<(YearMonth, [Date: [CalendarEvent]]), Error>.self) { group in
            for month in monthsToLoad {
                group.addTask { await self.fetchMonthData(month, lookup: lookup, snapshot: snapshot) }
            }
            
            for await result in group {
                switch result {
                case let .success((month, data)):
                    monthData.append((month, data))
                case let .failure(error):
                    if let monthError = error as? CalendarMonthLoadError {
                        errors[monthError.month] = monthError.localizedDescription
                    }
                }
            }
        }

        guard generation == refreshGeneration else { return }

        lastRefreshKey = snapshot.connectionKey
        sonarrSeries = libraries.series
        radarrMovies = libraries.movies
        seriesLookup = lookup
        loadedMonths = []
        eventsByDay = [:]
        monthLoadErrors = errors
        for (month, data) in monthData {
            mergeMonth(month, data: data)
        }
        self.loadedMonths.sort()

        if scrollID == nil {
            scrollID = today
        }
        isRefreshing = false
    }
    
    func loadNextMonth() async {
        guard !isLoadingMore, let latest = loadedMonths.last else { return }
        isLoadingMore = true
        let next = latest.advanced(by: 1)
        let lookup = seriesLookup
        let snapshot = serviceManager.calendarRefreshSnapshot()
        switch await fetchMonthData(next, lookup: lookup, snapshot: snapshot) {
        case let .success((month, data)):
            withAnimation {
                monthLoadErrors[month] = nil
                mergeMonth(month, data: data)
            }
        case let .failure(error):
            if let monthError = error as? CalendarMonthLoadError {
                monthLoadErrors[monthError.month] = monthError.localizedDescription
            }
        }
        isLoadingMore = false
    }

    func loadPreviousMonth() async {
        guard !isLoadingEarlier, let earliest = loadedMonths.first else { return }
        isLoadingEarlier = true
        let prev = earliest.advanced(by: -1)
        let lookup = seriesLookup
        let snapshot = serviceManager.calendarRefreshSnapshot()
        switch await fetchMonthData(prev, lookup: lookup, snapshot: snapshot) {
        case let .success((month, data)):
            withAnimation {
                monthLoadErrors[month] = nil
                mergeMonth(month, data: data, insertAtStart: true)
            }
        case let .failure(error):
            if let monthError = error as? CalendarMonthLoadError {
                monthLoadErrors[monthError.month] = monthError.localizedDescription
            }
        }
        isLoadingEarlier = false
    }
    
    var calendarEventIDs: [String] {
        eventsByDay.values.flatMap { $0.map(\.id) }.sorted()
    }

    private func loadLibraries(from snapshot: ArrCalendarRefreshSnapshot) async -> (series: [SonarrSeries], movies: [RadarrMovie]) {
        async let series = (try? await snapshot.loadSeries()) ?? []
        async let movies = (try? await snapshot.loadMovies()) ?? []
        return await (series, movies)
    }

    private func fetchMonthData(
        _ month: YearMonth,
        lookup: [ArrScopedID: SonarrSeries],
        snapshot: ArrCalendarRefreshSnapshot
    ) async -> Result<(YearMonth, [Date: [CalendarEvent]]), Error> {
        let start = month.startDate
        let end = month.endDate

        let results: Result<[Date: [CalendarEvent]], Error> = await withTaskGroup(of: Result<[Date: [CalendarEvent]], Error>.self) { group in
            if let loadEpisodes = snapshot.loadEpisodes {
                group.addTask {
                    var dict: [Date: [CalendarEvent]] = [:]
                    do {
                        let episodes = try await loadEpisodes(start, end)
                        for ep in episodes {
                            guard let seriesId = ep.seriesId,
                                  let date = ArrDateParser.parse(ep.airDateUtc) ?? ArrDateParser.parseDay(ep.airDate) else { continue }
                            let day = Calendar.current.startOfDay(for: date)
                            // Resolved on the episode's own server: an airing from the
                            // 4K server must find that server's series 1, not the HD one's.
                            let series = lookup[ArrScopedID(ep.instanceID, seriesId)]
                            dict[day, default: []].append(.episode(ep, series: series, date: date))
                        }
                        return .success(dict)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            if let loadMovieCalendar = snapshot.loadMovieCalendar {
                group.addTask {
                    var dict: [Date: [CalendarEvent]] = [:]
                    do {
                        let movies = try await loadMovieCalendar(start, end)
                        for movie in movies {
                            let releases = [
                                (movie.digitalRelease, MovieReleaseKind.digital),
                                (movie.physicalRelease, MovieReleaseKind.physical),
                                (movie.inCinemas, MovieReleaseKind.cinema)
                            ]
                            for (dateStr, kind) in releases {
                                if let dateStr = dateStr, let date = ArrDateParser.parse(dateStr) {
                                    let day = Calendar.current.startOfDay(for: date)
                                    dict[day, default: []].append(.movie(movie, date: date, kind: kind))
                                }
                            }
                        }
                        return .success(dict)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var combined: [Date: [CalendarEvent]] = [:]
            var errors: [String] = []
            var successes = 0
            for await result in group {
                switch result {
                case let .success(dict):
                    successes += 1
                    for (day, events) in dict {
                        combined[day, default: []].append(contentsOf: events)
                    }
                case let .failure(error):
                    errors.append(error.localizedDescription)
                }
            }

            // Keep partial data: only fail if every service errored and produced no data.
            if successes > 0 || errors.isEmpty {
                return Result.success(combined)
            } else {
                return Result.failure(CalendarMonthLoadError(month: month, messages: errors))
            }
        }
        
        switch results {
        case let .success(events):
            var finalEvents = events
            for day in finalEvents.keys {
                finalEvents[day]?.sort { $0.date < $1.date }
            }
            return .success((month, finalEvents))
        case let .failure(error):
            return .failure(error)
        }
    }

    fileprivate var initialLoadErrorMessage: String? {
        guard loadedMonths.isEmpty else { return nil }
        return monthLoadErrors.values.sorted().first
    }

    fileprivate var nextMonthErrorMessage: String? {
        guard let latest = loadedMonths.last else { return nil }
        return monthLoadErrors[latest.advanced(by: 1)]
    }

    fileprivate var previousMonthErrorMessage: String? {
        guard let earliest = loadedMonths.first else { return nil }
        return monthLoadErrors[earliest.advanced(by: -1)]
    }

    private func mergeMonth(_ month: YearMonth, data: [Date: [CalendarEvent]], insertAtStart: Bool = false) {
        if !loadedMonths.contains(month) {
            if insertAtStart {
                loadedMonths.insert(month, at: 0)
            } else {
                loadedMonths.append(month)
            }
        }

        for (day, events) in data {
            eventsByDay[day, default: []].append(contentsOf: events)
            eventsByDay[day]?.sort { $0.date < $1.date }
        }
    }
}

#if DEBUG
extension ArrCalendarViewModel {
    func installPreviewEvents(referenceDate: Date = .now) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let currentMonth = YearMonth.from(today)
        loadedMonths = [currentMonth.advanced(by: -1), currentMonth, currentMonth.advanced(by: 1)]
        sonarrSeries = SonarrSeries.previewList
        radarrMovies = RadarrMovie.previewList
        seriesLookup = Dictionary(
            sonarrSeries.map { (ArrScopedID($0.instanceID, $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        monthLoadErrors = [:]
        isLoadingInitial = false
        isRefreshing = false
        isLoadingEarlier = false
        isLoadingMore = false
        lastRefreshKey = "preview"
        scrollID = today

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let nextWeek = calendar.date(byAdding: .day, value: 6, to: today) ?? today
        let lastWeek = calendar.date(byAdding: .day, value: -5, to: today) ?? today

        eventsByDay = [
            today: [
                .episode(SonarrEpisode.preview, series: SonarrSeries.preview, date: calendar.date(byAdding: .hour, value: 20, to: today) ?? today),
                .movie(RadarrMovie.previewAnnounced, date: today, kind: .cinema),
            ],
            tomorrow: [
                .episode(SonarrEpisode.previewList[1], series: SonarrSeries.previewList[3], date: calendar.date(byAdding: .hour, value: 21, to: tomorrow) ?? tomorrow),
            ],
            nextWeek: [
                .movie(RadarrMovie.preview, date: nextWeek, kind: .digital),
                .movie(RadarrMovie.previewReleased, date: nextWeek, kind: .physical),
            ],
            lastWeek: [
                .episode(SonarrEpisode.previewList[2], series: SonarrSeries.previewEnded, date: lastWeek),
            ],
        ]
    }
}
#endif

private struct CalendarMonthLoadError: LocalizedError {
    let month: YearMonth
    let messages: [String]

    var errorDescription: String? {
        messages.joined(separator: "\n")
    }
}

struct ArrCalendarView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.setTabChromeHidden) private var setTabChromeHidden
    #endif
    @Environment(\.hasDetailPane) private var hasDetailPane

    let showsCloseButton: Bool

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    @State private var scope: CalendarScope = .all
    /// Which release the detail pane is showing, at regular width. Nil on iPhone,
    /// where a row pushes instead.
    @State private var selectedMedia: ArrMediaDestination?
    @State private var showMonitoredOnly = false
    @State private var scrollView: ScrollViewProxy?
    @State private var hideCalendarView = true
    @State private var didInitialScroll = false
    @State private var showiCalAlert = false
    private let subscribeTip = ArrCalendarSubscribeTip()
    
    private let today = Calendar.current.startOfDay(for: .now)
    private let firstWeekday = Calendar.current.firstWeekday
    
    var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var calendarServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var subscribableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.sonarrConnected { services.append(.sonarr) }
        if serviceManager.radarrConnected { services.append(.radarr) }
        return services
    }

    var isConnected: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var viewModel: ArrCalendarViewModel {
        serviceManager.calendarViewModel!
    }

    private var visibleDays: [Date] {
        viewModel.loadedMonths
            .flatMap(\.days)
            .sorted()
    }

    private var totalVisibleEventCount: Int {
        visibleDays.reduce(into: 0) { count, day in
            count += filteredEvents(for: day).count
        }
    }

    private var calendarReloadKey: String {
        // Active Sonarr/Radarr instance IDs are part of the key so switching between
        // connected instances re-fires this task and reloads the calendar.
        serviceManager.arrConnectionKey
    }
    
    var body: some View {
        calendarPanes
        #if os(iOS)
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: platformCancellationPlacement) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            if hasConfiguredService {
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    Button("Today") {
                        scrollToToday()
                    }
                }
                ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    Menu {
                        Picker("Show", selection: Binding(
                            get: { showMonitoredOnly },
                            set: { newValue in withAnimation { showMonitoredOnly = newValue } }
                        )) {
                            Text("All").tag(false)
                            Text("Monitored Only").tag(true)
                        }
                    } label: {
                        Image(systemName: showMonitoredOnly
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter")
                    .accessibilityValue(showMonitoredOnly ? "Monitored only" : "All")
                }
            }
            if isConnected {
                ToolbarItem(placement: platformBottomBarPlacement) {
                    Button("Subscribe") {
                        // The advertised action, performed - before the sheet, so a
                        // user who opens it once is never told about it again.
                        subscribeTip.invalidate(reason: .actionPerformed)
                        showiCalAlert = true
                    }
                    // On the button rather than floating: "Subscribe" is one word in a
                    // bottom bar, and pointing straight at it is most of the message.
                    .popoverTip(subscribeTip)
                }
            }
        }
        .sheet(isPresented: $showiCalAlert) {
            ICalSubscribeSheet(availableServices: subscribableServices)
        }
        .onChange(of: subscribableServices.isEmpty) { _, isEmpty in
            ArrCalendarSubscribeTip.isEligible = !isEmpty
        }
        .refreshable {
            await serviceManager.calendarViewModel.refresh()
            await revealCalendarIfNeeded(forceScrollToToday: true)
        }
        .task(id: calendarReloadKey) {
            #if DEBUG
            if ArrPreviewRuntime.isActive {
                hideCalendarView = false
                return
            }
            #endif
            guard isConnected else { return }
            // Counted only here: this is the one path that means a real, connected
            // Calendar screen actually appeared. A visit that landed on "No Services
            // Configured" or "Services Unreachable" returned above, and previews
            // returned before that - neither is evidence of wanting a feed.
            await TrawlTipEvents.calendarOpened.donate()
            ArrCalendarSubscribeTip.isEligible = !subscribableServices.isEmpty
            await serviceManager.calendarViewModel.initialize()
            await revealCalendarIfNeeded(forceScrollToToday: !didInitialScroll)
        }
        .onAppear {
            #if os(iOS)
            setTabChromeHidden(true)
            #endif
        }
        .onDisappear {
            #if os(iOS)
            setTabChromeHidden(false)
            #endif
        }
        .arrMediaNavigationDestinations()
    }


    /// The calendar beside whatever it has open.
    ///
    /// Not while it is a sheet: presented from the Series and Movies toolbars this is
    /// a panel a few hundred points wide, and a list pane with a minimum width plus a
    /// detail beside it does not fit in one.
    @ViewBuilder
    private var calendarPanes: some View {
        if showsCloseButton {
            calendarScreen
                .navigationTitle("Calendar")
                .navigationSubtitle(navigationSubtitleText)
        } else {
            TrawlListDetailPanes(title: "Calendar", subtitle: navigationSubtitleText) {
                calendarScreen
            } detail: {
                selectedMediaDetail
            }
        }
    }

    /// Deliberately nothing selected to begin with. A calendar is a list of dates,
    /// not a list of things one of which is "the current one" - opening it on
    /// whatever happens to be first would be an arbitrary choice presented as a
    /// default.
    @ViewBuilder
    private var selectedMediaDetail: some View {
        if let selectedMedia {
            ArrMediaDetailPane(destination: selectedMedia)
                .id(selectedMedia)
        } else {
            listDetailPlaceholder("Select a calendar item to view it", systemImage: "calendar")
        }
    }

    private var calendarScreen: some View {
        Group {
            if !hasConfiguredService {
                ServiceSetupView(title: "No Services Configured", message: "Connect Sonarr or Radarr to see upcoming releases.", systemImage: "server.rack")
                .scrollableUnavailableState()
            } else if !isConnected {
                ArrServicesConnectionStatusView(
                    services: calendarServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else {
                ArrLoadingErrorEmptyView(
                    isLoading: viewModel.isLoadingInitial || viewModel.isRefreshing,
                    error: viewModel.initialLoadErrorMessage,
                    isEmpty: viewModel.loadedMonths.isEmpty && !(viewModel.isLoadingInitial || viewModel.isRefreshing),
                    emptyTitle: "No Upcoming Releases",
                    emptyIcon: "calendar.badge.exclamationmark",
                    emptyDescription: "No calendar data has been loaded for the selected date range.",
                    onRetry: { await serviceManager.calendarViewModel.refresh() }
                ) {
                    calendarContent
                }
            }
        }
        .moreDestinationBackground(.calendar)
        .safeAreaInset(edge: .top) {
            if hasConfiguredService {
                TrawlSegmentBar("Scope", selection: Binding(
                    get: { scope },
                    set: { newValue in withAnimation { scope = newValue } }
                ), items: CalendarScope.allCases.map(\.segmentBarItem), alignment: .center)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    
    @ViewBuilder
    private var calendarContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Group {
                        if viewModel.isLoadingEarlier {
                            ProgressView()
                                .tint(.secondary)
                        } else if let loadEarlierError = viewModel.previousMonthErrorMessage {
                            ServiceErrorView(
                                title: "Earlier Events Unavailable",
                                message: loadEarlierError,
                                hasContent: true,
                                onRetry: { await viewModel.loadPreviousMonth() }
                            )
                        } else if !visibleDays.isEmpty {
                            Button("Load Earlier") {
                                Task { await viewModel.loadPreviousMonth() }
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)

                    ForEach(visibleDays, id: \.self) { day in
                        if Calendar.current.component(.weekday, from: day) == firstWeekday {
                            CalendarWeekRange(date: day)
                        }

                        CalendarDayRow(
                            date: day,
                            events: filteredEvents(for: day),
                            isToday: day == today,
                            eventLink: { calendarEventLink(for: $0) }
                        )
                        .id(day)
                    }

                    Group {
                        if viewModel.isLoadingMore {
                            ProgressView()
                                .tint(.secondary)
                        } else if let loadMoreError = viewModel.nextMonthErrorMessage {
                            ServiceErrorView(
                                title: "More Events Unavailable",
                                message: loadMoreError,
                                hasContent: true,
                                onRetry: { await viewModel.loadNextMonth() }
                            )
                        } else if !visibleDays.isEmpty {
                            Button("Load More") {
                                Task { await viewModel.loadNextMonth() }
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                        }
                    }
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
            }
            .opacity(hideCalendarView ? 0 : 1)
            .scrollIndicators(.never)
            .onAppear {
                scrollView = proxy
            }
        }
    }
    
    private func filteredEvents(for day: Date) -> [CalendarEvent] {
        guard let all = viewModel.eventsByDay[day] else { return [] }
        return all.filter { event in
            if showMonitoredOnly && !event.monitored { return false }
            switch scope {
            case .all: return true
            case .series: if case .episode = event { return true }; return false
            case .movies: if case .movie = event { return true }; return false
            }
        }
    }

    private var navigationSubtitleText: String {
        let count = totalVisibleEventCount
        guard count > 0 else { return "" }
        return count == 1 ? "1 release" : "\(count) releases"
    }

    private func revealCalendarIfNeeded(forceScrollToToday: Bool) async {
        if forceScrollToToday || !didInitialScroll {
            try? await Task.sleep(for: .milliseconds(15))
            scrollToToday(animated: false)
            try? await Task.sleep(for: .milliseconds(15))
            didInitialScroll = true
        }
        hideCalendarView = false
    }

    private func scrollToToday(animated: Bool = true) {
        guard let scrollView else { return }
        if animated {
            withAnimation(.smooth) {
                scrollView.scrollTo(today, anchor: .center)
            }
        } else {
            scrollView.scrollTo(today, anchor: .center)
        }
    }
    @ViewBuilder
    private func calendarEventLink(for event: CalendarEvent) -> some View {
        let instance = badgeInstance(for: event)
        switch event {
        case .episode(let episode, _, _):
            if let seriesID = episode.seriesId {
                calendarEventRow(event: event, instance: instance, destination: .series(id: seriesID))
            } else {
                EventRow(event: event, instance: instance)
            }
        case .movie(let movie, _, _):
            calendarEventRow(event: event, instance: instance, destination: .movie(id: movie.id))
        }
    }

    /// Opens the release in the pane beside the calendar, or pushes it when there is
    /// no pane. These rows live in a `ScrollView` rather than a `List`, so the
    /// selecting form is a button rather than a tag.
    @ViewBuilder
    private func calendarEventRow(
        event: CalendarEvent,
        instance: ArrInstanceRef?,
        destination: ArrMediaDestination
    ) -> some View {
        if hasDetailPane {
            Button {
                selectedMedia = destination
            } label: {
                EventRow(event: event, instance: instance)
            }
            .buttonStyle(.plain)
            .background {
                if selectedMedia == destination {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .padding(.horizontal, -8)
                }
            }
        } else {
            NavigationLink(value: destination) {
                EventRow(event: event, instance: instance)
            }
            .buttonStyle(.plain)
        }
    }

    /// The server tracking an airing, shown only when a second instance of that
    /// service exists. With a pair, the same episode legitimately appears twice -
    /// each server grabs its own release - and the badge is what tells them apart.
    private func badgeInstance(for event: CalendarEvent) -> ArrInstanceRef? {
        guard serviceManager.showsInstanceProvenance(for: event.serviceType) else { return nil }
        return serviceManager.instanceRef(event.serviceType, id: event.instanceID)
    }
}

#if DEBUG
private struct ArrCalendarPreview: View {
    let manager: ArrServiceManager

    init(isEmpty: Bool = false) {
        let manager = ArrServiceManager.preview(.allConfigured)
        if isEmpty {
            manager.calendarViewModel.isLoadingInitial = false
        } else {
            manager.calendarViewModel.installPreviewEvents()
        }
        self.manager = manager
    }

    var body: some View {
        PreviewHost(profiles: .allServices, arr: manager) {
            NavigationStack {
                ArrCalendarView()
            }
            .environment(SyncService.preview())
        }
    }
}

#Preview("Calendar - Loaded") {
    ArrCalendarPreview()
}

#Preview("Calendar - Empty") {
    ArrCalendarPreview(isEmpty: true)
}

#Preview("Calendar - Loading") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrCalendarView()
        }
        .environment(SyncService.preview())
    }
}

#Preview("Calendar - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrCalendarView()
        }
        .environment(SyncService.preview())
    }
}
#endif

// MARK: - Supporting Subviews

private struct CalendarDayRow<Link: View>: View {
    let date: Date
    let events: [CalendarEvent]
    let isToday: Bool
    let eventLink: (CalendarEvent) -> Link
    
    private var isPast: Bool { date < Calendar.current.startOfDay(for: .now) }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .center, spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption2)
                    .kerning(1.05)
                    .lineLimit(1)
                    .foregroundStyle(isToday ? .primary : .secondary)
                    .offset(y: 3)
                
                Text(date.formatted(.dateTime.day()))
                    .font(.title3.weight(isToday ? .bold : .regular))

                Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.caption2)
                    .kerning(1.05)
                    .lineLimit(1)
                    .foregroundStyle(isToday ? .primary : .secondary)
                    .offset(y: -3)
            }
            .foregroundStyle(isToday ? Color.accentColor : (isPast ? Color.secondary : Color.primary))
            .frame(width: 50)
            .padding(.top, 8)
            
            VStack(alignment: .leading, spacing: 0) {
                if events.isEmpty {
                Spacer()
                        .frame(height: 50)
                } else {
                    ForEach(events) { event in
                        eventLink(event)
                        if event.id != events.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private struct CalendarWeekRange: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer()
            Text(weekRangeText)
                .font(.subheadline)
                .textCase(.uppercase)
                .kerning(1.0)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
                .padding(.leading, 1)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var weekRangeText: String {
        let calendar = Calendar.current
        guard let endDate = calendar.date(byAdding: .day, value: 6, to: date) else {
            return ""
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        let startText = formatter.string(from: date)

        if calendar.isDate(date, equalTo: endDate, toGranularity: .month) {
            formatter.dateFormat = "d"
        }

        let endText = formatter.string(from: endDate)
        return "\(startText) – \(endText)"
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    var instance: ArrInstanceRef? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: event.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(event.accentColor.opacity(0.1))
                    Image(systemName: event.placeholderIcon)
                        .font(.caption)
                        .foregroundStyle(event.accentColor)
                }
            }
            .frame(width: 36, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if let instance {
                        ArrInstanceBadge(label: instance.shortLabel, ordinal: instance.ordinal)
                    }
                }
                
                if let sub = event.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                HStack(spacing: 8) {
                    if let time = event.timeLabel {
                        Text(time)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let badge = event.badgeLabel {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(event.accentColor.opacity(0.15))
                            .foregroundStyle(event.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
            
            Spacer()
            
            if event.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Core Models

fileprivate enum CalendarEvent: Identifiable {
    case episode(SonarrEpisode, series: SonarrSeries?, date: Date)
    case movie(RadarrMovie, date: Date, kind: MovieReleaseKind)

    /// Keyed by server as well as record: both instances number their episodes
    /// and movies from the same sequence, so without it two servers' airings on
    /// the same day collide into one row.
    var id: String {
        switch self {
        case .episode(let ep, _, _): "ep-\(Self.instanceSegment(ep.instanceID))\(ep.id)"
        case .movie(let m, _, let k): "movie-\(Self.instanceSegment(m.instanceID))\(m.id)-\(k.label)"
        }
    }

    /// The server segment only appears when there is a server to name, so an
    /// unstamped event - a fixture, or a single-instance setup that never needed
    /// disambiguating - keeps the plain "ep-101" form.
    private static func instanceSegment(_ instanceID: UUID?) -> String {
        instanceID.map { "\($0.uuidString)-" } ?? ""
    }

    /// The server tracking this airing.
    var instanceID: UUID? {
        switch self {
        case .episode(let ep, let series, _): ep.instanceID ?? series?.instanceID
        case .movie(let m, _, _): m.instanceID
        }
    }

    var serviceType: ArrServiceType {
        switch self {
        case .episode: .sonarr
        case .movie: .radarr
        }
    }

    var date: Date {
        switch self {
        case .episode(_, _, let d): d
        case .movie(_, let d, _): d
        }
    }

    var title: String {
        switch self {
        case .episode(_, let series, _): series?.title ?? "Unknown Series"
        case .movie(let m, _, _): m.title
        }
    }

    var subtitle: String? {
        switch self {
        case .episode(let ep, _, _):
            return ep.episodeIdentifier + (ep.title.map { " · \($0)" } ?? "")
        case .movie(let m, _, _):
            return m.year.map { String($0) }
        }
    }

    var posterURL: URL? {
        switch self {
        case .episode(_, let series, _): series?.posterURL
        case .movie(let m, _, _): m.posterURL
        }
    }

    var accentColor: Color {
        switch self {
        case .episode: .purple
        case .movie(_, _, let k): k.color
        }
    }

    var placeholderIcon: String {
        switch self {
        case .episode: "tv"
        case .movie: "film"
        }
    }

    var badgeLabel: String? {
        switch self {
        case .episode: nil
        case .movie(_, _, let k): k.label
        }
    }

    var timeLabel: String? {
        switch self {
        case .episode(_, _, let d):
            let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
            if comps.hour == 0 && comps.minute == 0 { return nil }
            return d.formatted(date: .omitted, time: .shortened)
        case .movie: return nil
        }
    }

    var isDownloaded: Bool {
        switch self {
        case .episode(let ep, _, _): ep.hasFile == true
        case .movie(let m, _, _): m.hasFile == true
        }
    }

    var monitored: Bool {
        switch self {
        case .episode(let ep, _, _): ep.monitored ?? true
        case .movie(let m, _, _): m.monitored ?? true
        }
    }
}

fileprivate enum CalendarScope: CaseIterable {
    case all, series, movies
    var title: String {
        switch self { case .all: "All"; case .series: "Series"; case .movies: "Movies" }
    }

    var segmentBarItem: TrawlSegmentBarItem<Self> {
        TrawlSegmentBarItem(title, value: self)
    }
}

fileprivate enum MovieReleaseKind {
    case digital, physical, cinema
    var label: String {
        switch self { case .digital: "Digital"; case .physical: "Physical"; case .cinema: "Cinema" }
    }
    var color: Color {
        switch self { case .digital: .blue; case .physical: .indigo; case .cinema: .orange }
    }
}

fileprivate struct YearMonth: Hashable, Comparable, Identifiable {
    let year: Int
    let month: Int
    var id: String { "\(year)-\(month)" }

    var startDate: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    var endDate: Date {
        Calendar.current.date(byAdding: DateComponents(month: 1, second: -1), to: startDate)!
    }

    var days: [Date] {
        var result: [Date] = []
        var current = startDate
        let end = Calendar.current.date(byAdding: .month, value: 1, to: startDate)!
        while current < end {
            result.append(current)
            current = Calendar.current.date(byAdding: .day, value: 1, to: current)!
        }
        return result
    }

    var displayName: String { startDate.formatted(.dateTime.month(.wide).year()) }

    func advanced(by months: Int) -> YearMonth {
        let date = Calendar.current.date(byAdding: .month, value: months, to: startDate)!
        return YearMonth.from(date)
    }

    static func from(_ date: Date) -> YearMonth {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return YearMonth(year: comps.year!, month: comps.month!)
    }

    static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }
}

fileprivate enum ArrDateParser {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return formatter.date(from: string) ?? fallbackFormatter.date(from: string)
    }

    nonisolated static func parseDay(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: string)
    }
}

// MARK: - iCal Subscribe Sheet

fileprivate enum ICalReleaseType: String, CaseIterable, Identifiable {
    case cinema = "cinemaRelease"
    case digital = "digitalRelease"
    case physical = "physicalRelease"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cinema: "Cinema"
        case .digital: "Digital"
        case .physical: "Physical"
        }
    }

    var systemImage: String {
        switch self {
        case .cinema: "popcorn.fill"
        case .digital: "play.rectangle.fill"
        case .physical: "opticaldisc.fill"
        }
    }

    var sortOrder: Int {
        switch self {
        case .cinema: 0
        case .digital: 1
        case .physical: 2
        }
    }
}

fileprivate struct ICalFeedConfiguration: Equatable {
    var includeUnmonitored = false
    var showAsAllDayEvents = false
    var tagIDs: Set<Int> = []
    var releaseTypes: Set<ICalReleaseType> = Set(ICalReleaseType.allCases)

    func queryItems(for service: ArrServiceType) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "unmonitored", value: String(includeUnmonitored)),
            URLQueryItem(name: "asAllDay", value: String(showAsAllDayEvents))
        ]

        if !tagIDs.isEmpty {
            let tagValue = tagIDs.sorted().map(String.init).joined(separator: ",")
            items.append(URLQueryItem(name: "tags", value: tagValue))
        }

        if service == .radarr && releaseTypes.count < ICalReleaseType.allCases.count && !releaseTypes.isEmpty {
            let releaseTypeValue = releaseTypes
                .sorted { $0.sortOrder < $1.sortOrder }
                .map(\.rawValue)
                .joined(separator: ",")
            items.append(URLQueryItem(name: "releaseTypes", value: releaseTypeValue))
        }

        return items
    }
}

private struct ICalSubscribeSheet: View {
    let availableServices: [ArrServiceType]

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(InAppNotificationCenter.self) private var notificationCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The server whose feed is being configured. A calendar feed is a URL on one
    /// server, so an HD/4K pair has two of them - picking a *service* could only
    /// ever offer the active one, leaving the other server's airings unsubscribable.
    @State private var selectedInstanceID: UUID?
    @State private var feedLink: ArrICalFeedLink?
    @State private var feedErrorMessage: String?
    @State private var includeUnmonitored = false
    @State private var showAsAllDayEvents = false
    @State private var selectedTagIDs: Set<Int> = []
    @State private var selectedReleaseTypes: Set<ICalReleaseType> = Set(ICalReleaseType.allCases)

    private var configuration: ICalFeedConfiguration {
        ICalFeedConfiguration(
            includeUnmonitored: includeUnmonitored,
            showAsAllDayEvents: showAsAllDayEvents,
            tagIDs: selectedTagIDs,
            releaseTypes: selectedReleaseTypes
        )
    }

    private var availableInstances: [ArrInstanceRef] {
        serviceManager.visibleArrInstances
            .map(\.ref)
            .filter { availableServices.contains($0.serviceType) }
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID }
    }

    private var selectedService: ArrServiceType? {
        selectedInstance?.serviceType
    }

    private var accentColor: Color {
        selectedService?.serviceIdentity.brandColor ?? .secondary
    }

    /// The chosen server's own tags. Tags are per-server and their IDs are not
    /// comparable across a pair, so offering the other server's would build a feed
    /// URL filtered on IDs this server has never heard of.
    private var availableTags: [ArrTag] {
        guard let instance = selectedInstance else { return [] }
        let tags = serviceManager.tagsByInstance.first { $0.ref.id == instance.id }?.values ?? []
        return tags.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var configuredCopyURL: URL? {
        guard let feedLink, let selectedService else { return nil }
        return configuredURL(from: feedLink.url, service: selectedService)
    }

    private var configuredSubscribeURL: URL? {
        guard let feedLink, let selectedService else { return nil }
        return configuredURL(from: feedLink.webcalURL, service: selectedService)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    servicePicker
                    optionsSection

                    if selectedService == .radarr {
                        releaseTypesSection
                    }

                    tagsSection
                    feedSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 132)
            }
            .scrollIndicators(.hidden)

            openInCalendarButton
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            if selectedInstanceID == nil, availableInstances.count == 1 {
                selectedInstanceID = availableInstances.first?.id
            }
        }
        // Keyed on the server, not the service: switching HD -> 4K leaves the
        // service unchanged, and the feed would stay the previous server's.
        .task(id: selectedInstanceID) {
            await loadFeedLink()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscribe to iCal")
                .font(.title2.bold())
            Text("Configure the feed URL, copy it to another client, or open the webcal subscription in Calendar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var servicePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(availableInstances.count > availableServices.count ? "Server" : "Service")

            VStack(spacing: 12) {
                ForEach(availableInstances) { instance in
                    serviceRow(instance)
                }
            }
        }
    }

    private var optionsSection: some View {
        sheetCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle("Options")

                Toggle(isOn: $includeUnmonitored) {
                    optionLabel(
                        title: "Include Unmonitored",
                        subtitle: "Include releases for unmonitored items in the feed."
                    )
                }

                Divider()

                Toggle(isOn: $showAsAllDayEvents) {
                    optionLabel(
                        title: "Show as All-Day Events",
                        subtitle: "Calendar entries appear without a specific time."
                    )
                }
            }
        }
    }

    private var releaseTypesSection: some View {
        sheetCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Release Types")
                    Text("Include only movies with specific release types. If unspecified, all options are used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(ICalReleaseType.allCases) { releaseType in
                    if releaseType != ICalReleaseType.allCases.first {
                        Divider()
                    }

                    Toggle(isOn: releaseTypeBinding(for: releaseType)) {
                        Label(releaseType.title, systemImage: releaseType.systemImage)
                    }
                }
            }
        }
    }

    private var tagsSection: some View {
        sheetCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Tags")
                    Text(tagSectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if availableTags.isEmpty {
                    Text("No tags available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableTags) { tag in
                        if tag.id != availableTags.first?.id {
                            Divider()
                        }

                        Toggle(isOn: tagBinding(for: tag.id)) {
                            Text(tag.label)
                        }
                    }
                }
            }
        }
    }

    private var feedSection: some View {
        sheetCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("iCal Feed")
                    Text("Copy this URL to your clients or click to subscribe if your browser supports webcal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let feedErrorMessage {
                    Text(feedErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let configuredCopyURL {
                    HStack(spacing: 10) {
                        Text(configuredCopyURL.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            copyFeedURL()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.headline)
                        }
                        .buttonStyle(.glass(.regular.tint(accentColor)))
                        .help("Copy iCal Feed URL")
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(selectedInstanceID == nil ? "Select a server to generate a feed URL." : "Generating feed URL...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var openInCalendarButton: some View {
        Button {
            if let configuredSubscribeURL {
                openURL(configuredSubscribeURL)
                dismiss()
            }
        } label: {
            Label("Open in Calendar", systemImage: "calendar.badge.plus")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
        }
        .buttonStyle(.glass(.regular.tint(accentColor)))
        .disabled(configuredSubscribeURL == nil)
    }

    private var tagSectionSubtitle: String {
        switch selectedService {
        case .radarr: "Applies to movies with at least one matching tag."
        case .sonarr: "Applies to series with at least one matching tag."
        case .prowlarr, .bazarr, nil: "Select a service to choose matching tags."
        }
    }

    private func serviceRow(_ instance: ArrInstanceRef) -> some View {
        let service = instance.serviceType
        let brand = service.serviceIdentity.brandColor
        let isSelected = selectedInstanceID == instance.id
        return Button {
            withAnimation {
                selectedInstanceID = instance.id
                // Tag IDs and release types belong to the server they were chosen
                // on; carrying them across would filter a feed on IDs the new
                // server has never issued.
                selectedTagIDs.removeAll()
                selectedReleaseTypes = Set(ICalReleaseType.allCases)
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: service.systemImage)
                    .font(.title3)
                    .foregroundStyle(brand)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(service == .sonarr ? "Upcoming episodes" : "Upcoming movie releases")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? brand : .secondary)
                    .font(.title3)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? brand.opacity(0.13) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? brand : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func sheetCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func optionLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func releaseTypeBinding(for releaseType: ICalReleaseType) -> Binding<Bool> {
        Binding(
            get: { selectedReleaseTypes.contains(releaseType) },
            set: { isSelected in
                if isSelected {
                    selectedReleaseTypes.insert(releaseType)
                } else if selectedReleaseTypes.count > 1 {
                    selectedReleaseTypes.remove(releaseType)
                }
            }
        )
    }

    private func tagBinding(for tagID: Int) -> Binding<Bool> {
        Binding(
            get: { selectedTagIDs.contains(tagID) },
            set: { isSelected in
                if isSelected {
                    selectedTagIDs.insert(tagID)
                } else {
                    selectedTagIDs.remove(tagID)
                }
            }
        )
    }

    private func loadFeedLink() async {
        guard let instance = selectedInstance else {
            feedLink = nil
            feedErrorMessage = nil
            return
        }

        feedLink = nil
        feedErrorMessage = nil

        do {
            let link = try await serviceManager.iCalFeedLink(for: instance)
            guard self.selectedInstanceID == instance.id else { return }
            feedLink = link
        } catch {
            guard self.selectedInstanceID == instance.id else { return }
            feedErrorMessage = error.localizedDescription
        }
    }

    private func configuredURL(from url: URL, service: ArrServiceType) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let optionNames: Set<String> = ["unmonitored", "asAllDay", "tags", "releaseTypes"]
        var preservedItems = (components.queryItems ?? []).filter { !optionNames.contains($0.name) }
        let apiKeyItems = preservedItems.filter { $0.name == "apikey" }
        preservedItems.removeAll { $0.name == "apikey" }
        preservedItems.append(contentsOf: configuration.queryItems(for: service))
        preservedItems.append(contentsOf: apiKeyItems)
        components.queryItems = preservedItems.isEmpty ? nil : preservedItems
        return components.url
    }

    private func copyFeedURL() {
        guard let urlString = configuredCopyURL?.absoluteString else { return }

        #if os(iOS)
        UIPasteboard.general.string = urlString
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        #endif

        notificationCenter.showSuccess(title: "Copied", message: "iCal feed URL copied.")
    }
}
