import SwiftUI

// MARK: - Main View

struct ArrCalendarView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var loadedMonths: [YearMonth] = []
    @State private var eventsByDay: [Date: [CalendarEvent]] = [:]
    @State private var seriesLookup: [Int: SonarrSeries] = [:]
    @State private var radarrMovies: [RadarrMovie] = []
    @State private var sonarrSeries: [SonarrSeries] = []
    @State private var isLoadingMonths: Set<YearMonth> = []
    @State private var scope: CalendarScope = .all
    @State private var isLoadingInitial = true
    @State private var hasScrolledToToday = false
    @State private var isLoadingMore = false
    @State private var visibleDay: Date?

    private let today = Calendar.current.startOfDay(for: .now)

    private var isConnected: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    var body: some View {
        Group {
            if !isConnected {
                ContentUnavailableView(
                    "No Arr Services Connected",
                    systemImage: "calendar",
                    description: Text("Connect Sonarr or Radarr to see upcoming releases.")
                )
            } else {
                // Timeline is always in the hierarchy — never destroyed by conditionals
                ZStack {
                    calendarContent

                    if isLoadingInitial {
                        Color(.systemBackground)
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle("Calendar")
        .navigationDestination(for: CalendarSeriesDestination.self) { dest in
            if let vm = makeSonarrViewModel() {
                SonarrSeriesDetailView(seriesId: dest.id, viewModel: vm)
            }
        }
        .navigationDestination(for: CalendarMovieDestination.self) { dest in
            if let vm = makeRadarrViewModel() {
                RadarrMovieDetailView(movieId: dest.id, viewModel: vm)
            }
        }
        .task {
            guard isConnected else {
                isLoadingInitial = false
                return
            }
            await loadLibraries()
            let start = YearMonth.from(today).advanced(by: -1)
            for offset in 0..<3 {
                await loadMonth(start.advanced(by: offset))
            }
            isLoadingInitial = false
            // Give SwiftUI a frame to lay out the VStack with data, then scroll
            try? await Task.sleep(for: .milliseconds(150))
            visibleDay = today
            hasScrolledToToday = true
        }
        .task(id: reloadKey) {
            guard !isLoadingInitial else { return }
            eventsByDay = [:]
            loadedMonths = []
            hasScrolledToToday = false
            await loadLibraries()
            let start = YearMonth.from(today).advanced(by: -1)
            for offset in 0..<3 {
                await loadMonth(start.advanced(by: offset))
            }
            try? await Task.sleep(for: .milliseconds(150))
            visibleDay = today
            hasScrolledToToday = true
        }
    }

    // MARK: - Calendar content (always mounted)

    private var calendarContent: some View {
        VStack(spacing: 0) {
            scopePicker
            timeline
        }
    }

    // MARK: - Scope picker

    private var scopePicker: some View {
        Picker("Filter", selection: $scope) {
            ForEach(CalendarScope.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Load earlier control
                Button {
                    Task { await loadPreviousMonth() }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingMonths.contains(earliestMonth.advanced(by: -1)) {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Load Earlier")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                ForEach(loadedMonths, id: \.self) { month in
                    MonthSectionHeader(title: month.displayName)

                    ForEach(month.days, id: \.self) { day in
                        DayTimelineRow(
                            date: day,
                            events: filteredEvents(for: day),
                            isToday: day == today,
                            isPast: day < today
                        )
                        .id(day)
                    }
                }

                // Load more button
                Button {
                    Task {
                        isLoadingMore = true
                        await loadNextMonth()
                        isLoadingMore = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingMore {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Load More")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingMore)
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $visibleDay, anchor: .top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Today") {
                    withAnimation {
                        visibleDay = today
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var earliestMonth: YearMonth {
        loadedMonths.first ?? YearMonth.from(today)
    }

    private var latestMonth: YearMonth {
        loadedMonths.last ?? YearMonth.from(today)
    }

    private var reloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }

    private func filteredEvents(for day: Date) -> [CalendarEvent] {
        guard let all = eventsByDay[day] else { return [] }
        return all.filter { event in
            switch scope {
            case .all: return true
            case .series: if case .episode = event { return true }; return false
            case .movies: if case .movie = event { return true }; return false
            }
        }
    }

    private func makeSonarrViewModel() -> SonarrViewModel? {
        guard serviceManager.sonarrConnected else { return nil }
        return SonarrViewModel(serviceManager: serviceManager, preloadedSeries: sonarrSeries)
    }

    private func makeRadarrViewModel() -> RadarrViewModel? {
        guard serviceManager.radarrConnected else { return nil }
        return RadarrViewModel(serviceManager: serviceManager, preloadedMovies: radarrMovies)
    }

    // MARK: - Data loading

    private func loadLibraries() async {
        async let seriesTask: [SonarrSeries] = (try? await serviceManager.sonarrClient?.getSeries()) ?? []
        async let moviesTask: [RadarrMovie] = (try? await serviceManager.radarrClient?.getMovies()) ?? []
        let (series, movies) = await (seriesTask, moviesTask)
        sonarrSeries = series
        radarrMovies = movies
        var lookup: [Int: SonarrSeries] = [:]
        for s in series { lookup[s.id] = s }
        seriesLookup = lookup
    }

    private func loadMonth(_ month: YearMonth) async {
        guard !isLoadingMonths.contains(month) else { return }
        isLoadingMonths.insert(month)
        defer { isLoadingMonths.remove(month) }

        let start = month.startDate
        let end = month.endDate
        let cal = Calendar.current

        async let sonarrTask: [SonarrEpisode] = {
            guard let client = serviceManager.sonarrClient else { return [] }
            return (try? await client.getCalendar(start: start, end: end, unmonitored: false, includeSeries: true)) ?? []
        }()

        async let radarrTask: [RadarrMovie] = {
            guard let client = serviceManager.radarrClient else { return [] }
            return (try? await client.getCalendar(start: start, end: end, unmonitored: false)) ?? []
        }()

        let (episodes, movies) = await (sonarrTask, radarrTask)

        var newEvents: [Date: [CalendarEvent]] = [:]

        for episode in episodes {
            guard let seriesId = episode.seriesId,
                  let date = ArrDateParser.parse(episode.airDateUtc) ?? ArrDateParser.parseDay(episode.airDate) else { continue }
            let day = cal.startOfDay(for: date)
            let event = CalendarEvent.episode(episode, series: seriesLookup[seriesId], date: date)
            newEvents[day, default: []].append(event)
        }

        for movie in movies {
            if let date = ArrDateParser.parse(movie.digitalRelease) {
                let day = cal.startOfDay(for: date)
                newEvents[day, default: []].append(.movie(movie, date: date, kind: .digital))
            } else if let date = ArrDateParser.parse(movie.physicalRelease) {
                let day = cal.startOfDay(for: date)
                newEvents[day, default: []].append(.movie(movie, date: date, kind: .physical))
            } else if let date = ArrDateParser.parse(movie.inCinemas) {
                let day = cal.startOfDay(for: date)
                newEvents[day, default: []].append(.movie(movie, date: date, kind: .cinema))
            }
        }

        for day in newEvents.keys {
            newEvents[day]?.sort { $0.date < $1.date }
        }

        for (day, events) in newEvents {
            eventsByDay[day] = events
        }

        if !loadedMonths.contains(month) {
            loadedMonths.append(month)
            loadedMonths.sort()
        }
    }

    private func loadNextMonth() async {
        let next = latestMonth.advanced(by: 1)
        await loadMonth(next)
    }

    private func loadPreviousMonth() async {
        let prev = earliestMonth.advanced(by: -1)
        await loadMonth(prev)
    }
}

// MARK: - Month header

private struct MonthSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
    }
}

// MARK: - Day row

private struct DayTimelineRow: View {
    let date: Date
    let events: [CalendarEvent]
    let isToday: Bool
    let isPast: Bool

    private var weekdayText: String {
        date.formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }

    private var dayText: String {
        date.formatted(.dateTime.day())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 2) {
                Text(weekdayText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isToday ? Color.accentColor : .secondary)

                ZStack {
                    if isToday {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 30, height: 30)
                    }
                    Text(dayText)
                        .font(.system(size: 17, weight: isToday ? .bold : .regular))
                        .foregroundStyle(
                            isToday ? Color.white : (isPast ? Color.secondary : Color.primary)
                        )
                }
            }
            .frame(width: 56)
            .padding(.top, 12)
            .padding(.bottom, events.isEmpty ? 12 : 10)

            Rectangle()
                .fill(Color(uiColor: .separator).opacity(events.isEmpty ? 0.4 : 0.8))
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)

            if events.isEmpty {
                Spacer()
                    .frame(height: 44)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        Group {
                            switch event {
                            case .episode(let ep, _, _):
                                if let seriesId = ep.seriesId {
                                    NavigationLink(value: CalendarSeriesDestination(id: seriesId)) {
                                        EventTimelineRow(event: event)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    EventTimelineRow(event: event)
                                }
                            case .movie(let m, _, _):
                                NavigationLink(value: CalendarMovieDestination(id: m.id)) {
                                    EventTimelineRow(event: event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if index < events.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(isToday ? Color.accentColor.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) {
            if !events.isEmpty {
                Divider()
            }
        }
    }
}

// MARK: - Event row within a day

private struct EventTimelineRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(event.accentColor)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 8)

            ArrArtworkView(url: event.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(event.accentColor.opacity(0.2))
                    Image(systemName: event.placeholderIcon)
                        .font(.caption)
                        .foregroundStyle(event.accentColor)
                }
            }
            .frame(width: 38, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let sub = event.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if let badge = event.badgeLabel {
                    Text(badge)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(event.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(event.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }
                if let timeStr = event.timeLabel {
                    Text(timeStr)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if event.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - CalendarEvent

private enum CalendarEvent: Identifiable {
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
            var parts: [String] = [ep.episodeIdentifier]
            if let t = ep.title, !t.isEmpty { parts.append(t) }
            return parts.joined(separator: " · ")
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
            guard let h = comps.hour, let m = comps.minute, !(h == 0 && m == 0) else { return nil }
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

// MARK: - Supporting types

private struct CalendarSeriesDestination: Hashable { let id: Int }
private struct CalendarMovieDestination: Hashable { let id: Int }

private enum CalendarScope: Hashable, CaseIterable {
    case all, series, movies
    var title: String {
        switch self {
        case .all: "All"; case .series: "Series"; case .movies: "Movies"
        }
    }
    var icon: String {
        switch self {
        case .all: "square.stack.3d.up"; case .series: "tv"; case .movies: "film"
        }
    }
}

private enum MovieReleaseKind {
    case digital, physical, cinema
    var label: String {
        switch self { case .digital: "Digital"; case .physical: "Physical"; case .cinema: "Cinema" }
    }
    var color: Color {
        switch self { case .digital: .blue; case .physical: .indigo; case .cinema: .orange }
    }
}

private struct YearMonth: Hashable, Comparable, Identifiable {
    let year: Int
    let month: Int

    var id: String { "\(year)-\(month)" }

    var startDate: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now
    }

    var endDate: Date {
        Calendar.current.date(byAdding: DateComponents(month: 1, second: -1), to: startDate) ?? .now
    }

    var days: [Date] {
        var result: [Date] = []
        let cal = Calendar.current
        var current = startDate
        let end = cal.date(byAdding: .month, value: 1, to: startDate) ?? startDate
        while current < end {
            result.append(current)
            current = cal.date(byAdding: .day, value: 1, to: current) ?? end
        }
        return result
    }

    var displayName: String {
        startDate.formatted(.dateTime.month(.wide).year())
    }

    func advanced(by months: Int) -> YearMonth {
        let date = Calendar.current.date(byAdding: .month, value: months, to: startDate) ?? startDate
        return YearMonth.from(date)
    }

    static func from(_ date: Date) -> YearMonth {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return YearMonth(year: comps.year ?? 2025, month: comps.month ?? 1)
    }

    static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }
}

// MARK: - Date parsing

private enum ArrDateParser {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return withFraction.date(from: string) ?? plain.date(from: string)
    }

    static func parseDay(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return dayOnly.date(from: string)
    }
}
