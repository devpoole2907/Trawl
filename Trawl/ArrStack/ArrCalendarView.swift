import SwiftUI
import Observation

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
    
    func initialize() async {
        let currentKey = "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
        if isLoadingInitial || loadedMonths.isEmpty || currentKey != lastRefreshKey {
            await refresh()
            isLoadingInitial = false
        }
    }
    
    func refresh() async {
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
    }
    
    func loadNextMonth() async {
        guard !isLoadingMore, let latest = loadedMonths.last else { return }
        isLoadingMore = true
        let next = latest.advanced(by: 1)
        let lookup = seriesLookup
        switch await fetchMonthData(next, lookup: lookup) {
        case let .success((month, data)):
            monthLoadErrors[month] = nil
            mergeMonth(month, data: data)
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
            monthLoadErrors[month] = nil
            mergeMonth(month, data: data, insertAtStart: true)
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
                        let episodes = try await client.getCalendar(start: start, end: end, unmonitored: false, includeSeries: true)
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
                        let movies = try await client.getCalendar(start: start, end: end, unmonitored: false)
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
            for await result in group {
                switch result {
                case let .success(dict):
                    for (day, events) in dict {
                        combined[day, default: []].append(contentsOf: events)
                    }
                case let .failure(error):
                    errors.append(error.localizedDescription)
                }
            }

            if errors.isEmpty {
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
    @State private var scrollView: ScrollViewProxy?
    @State private var hideCalendarView = true
    @State private var didInitialScroll = false
    
    private let today = Calendar.current.startOfDay(for: .now)
    private let firstWeekday = Calendar.current.firstWeekday
    
    var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
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
                ContentUnavailableView(
                    "Services Unreachable",
                    systemImage: "network.slash",
                    description: Text("Unable to reach your configured Sonarr or Radarr servers.")
                )
            } else if viewModel.isLoadingInitial && viewModel.loadedMonths.isEmpty {
                ProgressView("Loading calendar...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError = viewModel.initialLoadErrorMessage {
                ContentUnavailableView {
                    Label("Calendar Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Retry") {
                        Task { await serviceManager.calendarViewModel.refresh() }
                    }
                }
            } else if totalVisibleEventCount == 0 {
                ContentUnavailableView(
                    "No Upcoming Releases",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Nothing is scheduled for the selected scope in the loaded date range.")
                )
            } else {
                calendarContent
            }
        }
        .moreDestinationBackground(.calendar)
        .navigationTitle("Calendar")
        .navigationSubtitle(navigationSubtitleText)
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
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button("Today") {
                    scrollToToday()
                }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Scope", selection: Binding(
                get: { scope },
                set: { newValue in withAnimation { scope = newValue } }
            )) {
                ForEach(CalendarScope.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, 48)
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
        .navigationDestination(for: Int.self) { seriesId in
            SonarrSeriesDetailView(seriesId: seriesId, viewModel: SonarrViewModel(serviceManager: serviceManager, preloadedSeries: serviceManager.calendarViewModel!.sonarrSeries))
                .environment(syncService)
        }
        .navigationDestination(for: Int64.self) { movieId in
            RadarrMovieDetailView(movieId: Int(movieId), viewModel: RadarrViewModel(serviceManager: serviceManager, preloadedMovies: serviceManager.calendarViewModel!.radarrMovies))
                .environment(syncService)
        }
    }
    
    @ViewBuilder
    private var calendarContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
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
}

fileprivate enum CalendarScope: CaseIterable {
    case all, series, movies
    var title: String {
        switch self { case .all: "All"; case .series: "Series"; case .movies: "Movies" }
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
