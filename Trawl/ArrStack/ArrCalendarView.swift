import SwiftUI
import Observation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Calendar View Model

@MainActor
@Observable
final class ArrCalendarViewModel {
    fileprivate let serviceManager: ArrServiceManager
    
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
    
    private var seriesLookup: [Int: SonarrSeries] = [:]
    private let calendar = Calendar.current
    
    init(serviceManager: ArrServiceManager) {
        self.serviceManager = serviceManager
    }

    func iCalFeedLinks() async throws -> [ArrICalFeedLink] {
        try await serviceManager.iCalFeedLinks()
    }

    func iCalFeedLink(for serviceType: ArrServiceType) async throws -> ArrICalFeedLink {
        try await serviceManager.iCalFeedLink(for: serviceType)
    }
    
    func initialize() async {
        let currentKey = "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
        if isLoadingInitial || loadedMonths.isEmpty || currentKey != lastRefreshKey {
            await refresh()
            isLoadingInitial = false
        }
    }
    
    func refresh() async {
        isRefreshing = true
        let currentKey = "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
        lastRefreshKey = currentKey

        await loadLibraries()

        // Clear existing data for a clean refresh of the initial window
        loadedMonths = []
        eventsByDay = [:]
        monthLoadErrors = [:]
        
        let today = calendar.startOfDay(for: .now)
        let startMonth = YearMonth.from(today).advanced(by: -1)
        
        // Load initial window: Prev, Current, Next Month
        var monthsToLoad: [YearMonth] = []
        for i in 0..<3 {
            monthsToLoad.append(startMonth.advanced(by: i))
        }
        
        await withTaskGroup(of: Result<(YearMonth, [Date: [CalendarEvent]]), Error>.self) { group in
            for month in monthsToLoad {
                let lookup = self.seriesLookup
                group.addTask { await self.fetchMonthData(month, lookup: lookup) }
            }
            
            for await result in group {
                switch result {
                case let .success((month, data)):
                    self.monthLoadErrors[month] = nil
                    self.mergeMonth(month, data: data)
                case let .failure(error):
                    if let monthError = error as? CalendarMonthLoadError {
                        self.monthLoadErrors[monthError.month] = monthError.localizedDescription
                    }
                }
            }
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
        switch await fetchMonthData(next, lookup: lookup) {
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
        switch await fetchMonthData(prev, lookup: lookup) {
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
    
    private func loadLibraries() async {
        async let seriesTask = (try? await serviceManager.sonarrClient?.getSeries()) ?? []
        async let moviesTask = (try? await serviceManager.radarrClient?.getMovies()) ?? []
        (sonarrSeries, radarrMovies) = await (seriesTask, moviesTask)
        seriesLookup = Dictionary(uniqueKeysWithValues: sonarrSeries.map { ($0.id, $0) })
    }

    private func fetchMonthData(_ month: YearMonth, lookup: [Int: SonarrSeries]) async -> Result<(YearMonth, [Date: [CalendarEvent]]), Error> {
        let start = month.startDate
        let end = month.endDate

        let results: Result<[Date: [CalendarEvent]], Error> = await withTaskGroup(of: Result<[Date: [CalendarEvent]], Error>.self) { group in
            if let client = serviceManager.sonarrClient {
                group.addTask {
                    var dict: [Date: [CalendarEvent]] = [:]
                    do {
                        let episodes = try await client.getCalendar(start: start, end: end, unmonitored: true, includeSeries: true)
                        for ep in episodes {
                            guard let seriesId = ep.seriesId,
                                  let date = ArrDateParser.parse(ep.airDateUtc) ?? ArrDateParser.parseDay(ep.airDate) else { continue }
                            let day = Calendar.current.startOfDay(for: date)
                            dict[day, default: []].append(.episode(ep, series: lookup[seriesId], date: date))
                        }
                        return .success(dict)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            if let client = serviceManager.radarrClient {
                group.addTask {
                    var dict: [Date: [CalendarEvent]] = [:]
                    do {
                        let movies = try await client.getCalendar(start: start, end: end, unmonitored: true)
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

private struct CalendarMonthLoadError: LocalizedError {
    let month: YearMonth
    let messages: [String]

    var errorDescription: String? {
        messages.joined(separator: "\n")
    }
}

extension ArrCalendarView where SeriesDest == Int, MovieDest == Int64 {
    init(showsCloseButton: Bool = false) {
        self.init(
            showsCloseButton: showsCloseButton,
            seriesNavigationValue: { $0 },
            movieNavigationValue: { Int64($0) }
        )
    }
}

struct ArrCalendarView<SeriesDest: Hashable, MovieDest: Hashable>: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.setTabChromeHidden) private var setTabChromeHidden
    #endif
    
    let showsCloseButton: Bool
    let seriesNavigationValue: (Int) -> SeriesDest
    let movieNavigationValue: (Int) -> MovieDest

    init(
        showsCloseButton: Bool = false,
        seriesNavigationValue: @escaping (Int) -> SeriesDest,
        movieNavigationValue: @escaping (Int) -> MovieDest
    ) {
        self.showsCloseButton = showsCloseButton
        self.seriesNavigationValue = seriesNavigationValue
        self.movieNavigationValue = movieNavigationValue
    }
    
    @State private var scope: CalendarScope = .all
    @State private var showMonitoredOnly = false
    @State private var scrollView: ScrollViewProxy?
    @State private var hideCalendarView = true
    @State private var didInitialScroll = false
    @State private var showiCalAlert = false
    
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
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }
    
    var body: some View {
        Group {
            if !hasConfiguredService {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "server.rack",
                    description: Text("Connect Sonarr or Radarr to see upcoming releases.")
                )
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
        .navigationTitle("Calendar")
        .navigationSubtitle(navigationSubtitleText)
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
                }
            }
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Button("Today") {
                    scrollToToday()
                }
            }
            ToolbarSpacer(.flexible, placement: platformTopBarTrailingPlacement)
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Menu {
                    Picker("Show", selection: $showMonitoredOnly) {
                        Text("All").tag(false)
                        Text("Monitored Only").tag(true)
                    }
                } label: {
                    Image(systemName: showMonitoredOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
            }
            if isConnected {
                ToolbarItem(placement: .bottomBar) {
                    Button("Subscribe") {
                        showiCalAlert = true
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar("Scope", selection: Binding(
                get: { scope },
                set: { newValue in withAnimation { scope = newValue } }
            ), items: CalendarScope.allCases.map(\.segmentBarItem), alignment: .center)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .refreshable {
            await serviceManager.calendarViewModel.refresh()
            await revealCalendarIfNeeded(forceScrollToToday: true)
        }
        .task(id: calendarReloadKey) {
            guard isConnected else { return }
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
        .navigationDestination(for: Int.self) { seriesId in
            SonarrSeriesDetailView(seriesId: seriesId, viewModel: SonarrViewModel(serviceManager: serviceManager, preloadedSeries: serviceManager.calendarViewModel!.sonarrSeries))
                .environment(syncService)
        }
        .navigationDestination(for: Int64.self) { movieId in
            RadarrMovieDetailView(movieId: Int(movieId), viewModel: RadarrViewModel(serviceManager: serviceManager, preloadedMovies: serviceManager.calendarViewModel!.radarrMovies))
                .environment(syncService)
        }
        .sheet(isPresented: $showiCalAlert) {
            ICalSubscribeSheet(availableServices: subscribableServices)
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
                            VStack(spacing: 8) {
                                Text(loadEarlierError)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Retry Load Earlier") {
                                    Task { await viewModel.loadPreviousMonth() }
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                            }
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
                            VStack(spacing: 8) {
                                Text(loadMoreError)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("Retry Load More") {
                                    Task { await viewModel.loadNextMonth() }
                                }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                            }
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
        switch event {
        case .episode(let episode, _, _):
            if let seriesID = episode.seriesId {
                NavigationLink(value: seriesNavigationValue(seriesID)) {
                    EventRow(event: event)
                }
                .buttonStyle(.plain)
            } else {
                EventRow(event: event)
            }
        case .movie(let movie, _, _):
            NavigationLink(value: movieNavigationValue(movie.id)) {
                EventRow(event: event)
            }
            .buttonStyle(.plain)
        }
    }
}

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
                Text(event.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                
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

    var id: String {
        switch self {
        case .episode(let ep, _, _): "ep-\(ep.id)"
        case .movie(let m, _, let k): "movie-\(m.id)-\(k.label)"
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

    @State private var selectedService: ArrServiceType?
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

    private var accentColor: Color {
        selectedService?.serviceIdentity.brandColor ?? .secondary
    }

    private var availableTags: [ArrTag] {
        guard let selectedService else { return [] }
        let tags: [ArrTag] = switch selectedService {
        case .sonarr: serviceManager.sonarrTags
        case .radarr: serviceManager.radarrTags
        case .prowlarr, .bazarr: []
        }
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
            if selectedService == nil, availableServices.count == 1 {
                selectedService = availableServices.first
            }
        }
        .task(id: selectedService) {
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
            sectionTitle("Service")

            VStack(spacing: 12) {
                ForEach(availableServices) { service in
                    serviceRow(service)
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
                        Text(selectedService == nil ? "Select a service to generate a feed URL." : "Generating feed URL...")
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

    private func serviceRow(_ service: ArrServiceType) -> some View {
        let brand = service.serviceIdentity.brandColor
        let isSelected = selectedService == service
        return Button {
            withAnimation {
                selectedService = service
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
        guard let selectedService else {
            feedLink = nil
            feedErrorMessage = nil
            return
        }

        feedLink = nil
        feedErrorMessage = nil

        do {
            let link = try await serviceManager.iCalFeedLink(for: selectedService)
            guard self.selectedService == selectedService else { return }
            feedLink = link
        } catch {
            guard self.selectedService == selectedService else { return }
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
