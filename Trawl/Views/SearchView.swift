import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SyncService.self) private var syncService
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var viewModel = SearchViewModel()
    @State private var showClearConfirmation = false

    @Namespace private var trendingTransition

    // Recents
    @AppStorage("search.recents") private var recentsStorage: String = "[]"

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                content
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                if viewModel.isSearchPresented && viewModel.searchText.isEmpty {
                    TrawlSegmentBar(
                        "Scope",
                        selection: $viewModel.scope,
                        items: SearchScope.segmentBarItems,
                        alignment: .center
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .safeAreaInset(edge: .top) {
                if !viewModel.searchText.isEmpty {
                    filterSegmentBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.isSearchPresented)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.scope)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.searchText.isEmpty)
            .navigationTitle("")
            .navigationDestination(for: SeriesDestination.self) { dest in
                if let vm = makeSonarrViewModel() {
                    SonarrSeriesDetailView(seriesId: dest.id, viewModel: vm)
                        .environment(syncService)
                }
            }
            .navigationDestination(for: MovieDestination.self) { dest in
                if let vm = makeRadarrViewModel() {
                    RadarrMovieDetailView(movieId: dest.id, viewModel: vm)
                        .environment(syncService)
                }
            }
            .navigationDestination(for: ArrSeriesLookupDestination.self) { dest in
                if let vm = viewModel.sonarrLookupVM {
                    SonarrSeriesDetailView(
                        series: dest.series,
                        viewModel: vm,
                        onAdded: {
                            await refreshLibrary()
                        }
                    )
                    .environment(syncService)
                    #if os(iOS)
                    .navigationTransition(.zoom(sourceID: dest, in: trendingTransition))
                    #endif
                }
            }
            .navigationDestination(for: ArrMovieLookupDestination.self) { dest in
                if let vm = viewModel.radarrLookupVM {
                    RadarrMovieDetailView(
                        movie: dest.movie,
                        viewModel: vm,
                        onAdded: {
                            await refreshLibrary()
                        }
                    )
                    .environment(syncService)
                    #if os(iOS)
                    .navigationTransition(.zoom(sourceID: dest, in: trendingTransition))
                    #endif
                }
            }
        }
        .searchable(
            text: $viewModel.searchText,
            isPresented: $viewModel.isSearchPresented,
            placement: .automatic,
            prompt: searchPrompt
        )
        .onSubmit(of: .search) {
            recordRecent(viewModel.searchText)
            if viewModel.scope == .arr {
                startArrLookup(immediate: true)
            }
        }
        .onChange(of: viewModel.scope) { _, newScope in
            if newScope == .arr {
                startArrLookup(immediate: true)
            } else {
                viewModel.arrLookupTask?.cancel()
            }
        }
        .onChange(of: viewModel.searchText) { _, newValue in
            if viewModel.scope == .arr {
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    resetArrLookup()
                } else {
                    startArrLookup()
                }
            } else {
                startLibrarySearch()
            }
        }
        .task {
            await viewModel.loadStoredTMDbAPIKeyAndTrending(arrServiceManager: arrServiceManager)
        }
        .task(id: "\(arrServiceManager.sonarrConnected)\(arrServiceManager.radarrConnected)") {
            await refreshLibrary()
            createLookupViewModels()
            await reconcileTrendingMatches()
        }
        .refreshable {
            await loadTrending()
            await refreshLibrary()
            await reconcileTrendingMatches()
        }
        .errorAlert(item: $viewModel.actionErrorAlert)
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearchPresented && viewModel.searchText.isEmpty {
            recentSearchesContent
        } else if viewModel.searchText.isEmpty {
            popularThisWeekContent
        } else {
            switch viewModel.scope {
            case .library:
                resultsContent
            case .arr:
                arrResultsContent
            }
        }
    }

    // MARK: - Recent Searches (shown when search bar is focused)

    @ViewBuilder
    private var recentSearchesContent: some View {
        let recents = loadRecents()

        if recents.isEmpty {
            ContentUnavailableView {
                Label("Search", systemImage: "magnifyingglass")
            } description: {
                Text("Search your library or discover new content.")
            }
        } else {
            List {
                Section {
                    ForEach(recents, id: \.self) { term in
                        Button {
                            viewModel.searchText = term
                            if viewModel.scope == .arr {
                                startArrLookup(immediate: true)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                Text(term)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                removeRecent(term)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recently Searched")
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("Clear", role: .destructive) {
                            showClearConfirmation = true
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 44)
            }
            .alert("Clear Recent Searches?", isPresented: $showClearConfirmation) {
                Button("Clear All", role: .destructive) {
                    clearRecents()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all recently searched terms.")
            }
        }
    }

    // MARK: - Popular This Week

    @ViewBuilder
    private var popularThisWeekContent: some View {
        let hasContent = !viewModel.trendingMovies.isEmpty || !viewModel.trendingTV.isEmpty

        ScrollView {
            if viewModel.isLoadingTrending && !hasContent {
                VStack(spacing: 16) {
                    Spacer(minLength: 80)
                    ProgressView()
                    Text("Loading trending content…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.tmdbAPIKey.isEmpty {
                ContentUnavailableView {
                    Label("Popular This Week", systemImage: "flame")
                } description: {
                    Text("Add a TMDb API key in Settings to see trending movies and TV shows.")
                }
                .padding(.top, 60)
            } else if let error = viewModel.trendingError, !hasContent {
                ContentUnavailableView {
                    Label("Couldn't Load Trending", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
                .padding(.top, 60)
            } else if hasContent {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !viewModel.trendingMovies.isEmpty {
                        trendingSection(title: "Trending Movies", icon: "film", items: viewModel.trendingMovies)
                    }
                    if !viewModel.trendingTV.isEmpty {
                        trendingSection(title: "Trending TV Shows", icon: "tv", items: viewModel.trendingTV)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private func trendingSection(title: String, icon: String, items: [TMDbItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items.prefix(20)) { item in
                        trendingCard(item: item)
                    }
                }
                .padding(.horizontal, 16)
            }
            .horizontalSoftEdges()
        }
    }

    @ViewBuilder
    private func trendingCard(item: TMDbItem) -> some View {
        let inLibrary = isInLibrary(item)

        if item.isMovie, let match = viewModel.movieMatches[item.id] {
            let dest = ArrMovieLookupDestination(movie: match)
            NavigationLink(value: dest) {
                trendingCardLabel(item: item, inLibrary: inLibrary)
                    #if os(iOS)
                    .matchedTransitionSource(id: dest, in: trendingTransition)
                    #endif
            }
            .buttonStyle(.plain)
        } else if !item.isMovie, let match = viewModel.seriesMatches[item.id] {
            let dest = ArrSeriesLookupDestination(series: match)
            NavigationLink(value: dest) {
                trendingCardLabel(item: item, inLibrary: inLibrary)
                    #if os(iOS)
                    .matchedTransitionSource(id: dest, in: trendingTransition)
                    #endif
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if let year = item.year {
                    viewModel.searchText = "\(item.displayTitle) \(year)"
                } else {
                    viewModel.searchText = item.displayTitle
                }
                viewModel.isSearchPresented = true
                viewModel.scope = .arr
                startArrLookup(immediate: true)
            } label: {
                trendingCardLabel(item: item, inLibrary: inLibrary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func trendingCardLabel(item: TMDbItem, inLibrary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ArrArtworkView(url: item.posterURL(), contentMode: .fill) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: item.isMovie ? "film" : "tv")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                }
                .frame(width: hSizeClass == .regular ? 180 : 140, height: hSizeClass == .regular ? 270 : 210)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if inLibrary {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    if let year = item.year {
                        Text(year)
                    }
                    if let rating = item.voteAverage, rating > 0 {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(width: 140, alignment: .leading)
            .padding(.top, 6)
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Library results

    private var libraryRows: [SearchResultEntry] {
        let series: [SearchResultEntry] = (shouldShow(.series) ? viewModel.matchedSeries.map(SearchResultEntry.series) : [])
        let movies: [SearchResultEntry] = (shouldShow(.movies) ? viewModel.matchedMovies.map(SearchResultEntry.movie) : [])
        return (series + movies).sorted { $0.sortKey < $1.sortKey }
    }

    @ViewBuilder
    private var resultsContent: some View {
        let rows = libraryRows

        if rows.isEmpty {
            ContentUnavailableView.search(text: viewModel.searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(rows) { row in
                    switch row {
                    case .series(let series):
                        librarySeriesRow(series)
                    case .movie(let movie):
                        libraryMovieRow(movie)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func librarySeriesRow(_ series: SonarrSeries) -> some View {
        let isMonitored = series.monitored ?? true
        NavigationLink(value: SeriesDestination(id: series.id)) {
            SonarrSeriesRow(series: series, hasIssue: false, showTypeLabel: viewModel.filter == .all)
        }
        .contextMenu {
            Button {
                Task { await toggleLibrarySeriesMonitored(series) }
            } label: {
                Label(
                    isMonitored ? "Unmonitor" : "Monitor",
                    systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await toggleLibrarySeriesMonitored(series) }
            } label: {
                Label(
                    isMonitored ? "Unmonitor" : "Monitor",
                    systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                )
            }
            .tint(isMonitored ? .orange : .green)
        }
    }

    @ViewBuilder
    private func libraryMovieRow(_ movie: RadarrMovie) -> some View {
        let isMonitored = movie.monitored ?? true
        NavigationLink(value: MovieDestination(id: movie.id)) {
            RadarrMovieRow(movie: movie, hasIssue: false, showTypeLabel: viewModel.filter == .all)
        }
        .contextMenu {
            Button {
                Task { await toggleLibraryMovieMonitored(movie) }
            } label: {
                Label(
                    isMonitored ? "Unmonitor" : "Monitor",
                    systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                Task { await toggleLibraryMovieMonitored(movie) }
            } label: {
                Label(
                    isMonitored ? "Unmonitor" : "Monitor",
                    systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                )
            }
            .tint(isMonitored ? .orange : .green)
        }
    }

    // MARK: - Filter segment bar

    @ViewBuilder
    private var filterSegmentBar: some View {
        TrawlSegmentBar(
            "Filter",
            selection: Binding(
                get: { viewModel.filter },
                set: { newValue in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        viewModel.filter = newValue
                    }
                }
            ),
            items: SearchResultFilter.segmentBarItems,
            alignment: .leading
        )
    }

    private func shouldShow(_ kind: SearchResultFilter) -> Bool {
        viewModel.filter == .all || viewModel.filter == kind
    }

    // MARK: - Arr results

    private var arrRows: [SearchResultEntry] {
        let seriesResults = viewModel.sonarrLookupVM?.searchResults ?? []
        let movieResults = viewModel.radarrLookupVM?.searchResults ?? []
        let series: [SearchResultEntry] = (shouldShow(.series) ? seriesResults.map(SearchResultEntry.series) : [])
        let movies: [SearchResultEntry] = (shouldShow(.movies) ? movieResults.map(SearchResultEntry.movie) : [])
        return (series + movies).sorted { $0.sortKey < $1.sortKey }
    }

    @ViewBuilder
    private var arrResultsContent: some View {
        let isSearching = (viewModel.sonarrLookupVM?.isSearching ?? false) || (viewModel.radarrLookupVM?.isSearching ?? false)
        let rows = arrRows
        let lookupErrors = arrLookupErrors

        if rows.isEmpty && isSearching {
            VStack(spacing: 16) {
                Spacer(minLength: 80)
                ProgressView()
                Text("Searching Sonarr and Radarr…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if rows.isEmpty && viewModel.hasSearchedArr {
            if lookupErrors.isEmpty {
                ContentUnavailableView.search(text: viewModel.searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The request reached Sonarr and/or Radarr but the API returned an error.")
                        ForEach(lookupErrors) { error in
                            lookupErrorLine(error)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List {
                if isSearching {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating results as services respond…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                }

                if !lookupErrors.isEmpty {
                    Section {
                        lookupErrorsCard(lookupErrors)
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(rows) { row in
                    switch row {
                    case .series(let series):
                        arrSeriesRow(series)
                    case .movie(let movie):
                        arrMovieRow(movie)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func arrSeriesRow(_ series: SonarrSeries) -> some View {
        let existsInLibrary = viewModel.sonarrSeries.contains(where: { $0.tvdbId == series.tvdbId })
        let libraryMatch = viewModel.sonarrSeries.first(where: { $0.tvdbId == series.tvdbId })

        NavigationLink(value: ArrSeriesLookupDestination(series: series)) {
            ArrSeriesResultRow(
                series: series,
                existsInLibrary: existsInLibrary,
                showTypeLabel: viewModel.filter == .all
            )
        }
        .contextMenu {
            if existsInLibrary, let libraryMatch {
                let isMonitored = libraryMatch.monitored ?? true
                Button {
                    Task { await toggleLibrarySeriesMonitored(libraryMatch) }
                } label: {
                    Label(
                        isMonitored ? "Unmonitor" : "Monitor",
                        systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                    )
                }
            } else if !existsInLibrary {
                Button {
                    Task { await quickAddSeries(series) }
                } label: {
                    Label("Add To Library", systemImage: "plus.circle")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if existsInLibrary, let libraryMatch {
                let isMonitored = libraryMatch.monitored ?? true
                Button {
                    Task { await toggleLibrarySeriesMonitored(libraryMatch) }
                } label: {
                    Label(
                        isMonitored ? "Unmonitor" : "Monitor",
                        systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                    )
                }
                .tint(isMonitored ? .orange : .green)
            } else if !existsInLibrary {
                Button {
                    Task { await quickAddSeries(series) }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .tint(.green)
            }
        }
    }

    @ViewBuilder
    private func arrMovieRow(_ movie: RadarrMovie) -> some View {
        let existsInLibrary = viewModel.radarrMovies.contains(where: { $0.tmdbId == movie.tmdbId })
        let libraryMatch = viewModel.radarrMovies.first(where: { $0.tmdbId == movie.tmdbId })

        NavigationLink(value: ArrMovieLookupDestination(movie: movie)) {
            ArrMovieResultRow(
                movie: movie,
                existsInLibrary: existsInLibrary,
                showTypeLabel: viewModel.filter == .all
            )
        }
        .contextMenu {
            if existsInLibrary, let libraryMatch {
                let isMonitored = libraryMatch.monitored ?? true
                Button {
                    Task { await toggleLibraryMovieMonitored(libraryMatch) }
                } label: {
                    Label(
                        isMonitored ? "Unmonitor" : "Monitor",
                        systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                    )
                }
            } else if !existsInLibrary {
                Button {
                    Task { await quickAddMovie(movie) }
                } label: {
                    Label("Add To Library", systemImage: "plus.circle")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if existsInLibrary, let libraryMatch {
                let isMonitored = libraryMatch.monitored ?? true
                Button {
                    Task { await toggleLibraryMovieMonitored(libraryMatch) }
                } label: {
                    Label(
                        isMonitored ? "Unmonitor" : "Monitor",
                        systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill"
                    )
                }
                .tint(isMonitored ? .orange : .green)
            } else if !existsInLibrary {
                Button {
                    Task { await quickAddMovie(movie) }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .tint(.green)
            }
        }
    }

    private var arrLookupErrors: [ArrLookupError] { viewModel.arrLookupErrors }

    private var searchPrompt: String { viewModel.searchPrompt }

    @ViewBuilder
    private func lookupErrorsCard(_ errors: [ArrLookupError]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API Errors", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("One or more discovery requests failed. These are API responses rather than empty search results.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(errors) { error in
                lookupErrorLine(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func lookupErrorLine(_ error: ArrLookupError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.service)
                .font(.subheadline.weight(.semibold))
            Text(error.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isInLibrary(_ item: TMDbItem) -> Bool {
        viewModel.isInLibrary(item)
    }

    private func createLookupViewModels() {
        viewModel.createLookupViewModels(arrServiceManager: arrServiceManager)
    }

    private func reconcileTrendingMatches() async {
        await viewModel.reconcileTrendingMatches(arrServiceManager: arrServiceManager)
    }

    private func startArrLookup(immediate: Bool = false) {
        viewModel.startArrLookup(arrServiceManager: arrServiceManager, immediate: immediate)
    }

    private func resetArrLookup() {
        viewModel.resetArrLookup()
    }

    private func startLibrarySearch() {
        viewModel.startLibrarySearch()
    }

    private func refreshLibrary() async {
        await viewModel.refreshLibrary(arrServiceManager: arrServiceManager)
    }

    private func loadTrending() async {
        await viewModel.loadTrending(arrServiceManager: arrServiceManager)
    }

    private func makeSonarrViewModel() -> SonarrViewModel? {
        viewModel.makeSonarrViewModel(arrServiceManager: arrServiceManager)
    }

    private func makeRadarrViewModel() -> RadarrViewModel? {
        viewModel.makeRadarrViewModel(arrServiceManager: arrServiceManager)
    }

    private func toggleLibrarySeriesMonitored(_ series: SonarrSeries) async {
        await viewModel.toggleLibrarySeriesMonitored(series, arrServiceManager: arrServiceManager)
    }

    private func toggleLibraryMovieMonitored(_ movie: RadarrMovie) async {
        await viewModel.toggleLibraryMovieMonitored(movie, arrServiceManager: arrServiceManager)
    }

    private func quickAddSeries(_ series: SonarrSeries) async {
        await viewModel.quickAddSeries(series, arrServiceManager: arrServiceManager)
    }

    private func quickAddMovie(_ movie: RadarrMovie) async {
        await viewModel.quickAddMovie(movie, arrServiceManager: arrServiceManager)
    }

    // MARK: - Recents persistence

    private func loadRecents() -> [String] {
        guard let data = recentsStorage.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    private func saveRecents(_ arr: [String]) {
        if let data = try? JSONEncoder().encode(arr),
           let str = String(data: data, encoding: .utf8) {
            recentsStorage = str
        }
    }

    private func recordRecent(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var arr = loadRecents()
        arr.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        arr.insert(trimmed, at: 0)
        if arr.count > 20 { arr = Array(arr.prefix(20)) }
        saveRecents(arr)
    }

    private func removeRecent(_ term: String) {
        var arr = loadRecents()
        arr.removeAll { $0 == term }
        saveRecents(arr)
    }

    private func clearRecents() {
        saveRecents([])
    }
}

// MARK: - Arr result rows

struct ArrLookupError: Identifiable {
    let service: String
    let message: String

    var id: String { "\(service):\(message)" }
}

private struct ArrSeriesResultRow: View {
    let series: SonarrSeries
    let existsInLibrary: Bool
    let showTypeLabel: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: series.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
            }
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(series.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Text("•")
                        }
                        Text(item)
                    }
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
                if let overview = series.overview {
                    Text(overview).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if existsInLibrary {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var metadataItems: [String] {
        var items: [String] = []
        if let year = series.year {
            items.append(String(year))
        }
        if showTypeLabel {
            items.append("Series")
        }
        if let network = series.network, !network.isEmpty {
            items.append(network)
        }
        if let status = series.status, !status.isEmpty {
            items.append(status.capitalized)
        }
        return items
    }
}

private struct ArrMovieResultRow: View {
    let movie: RadarrMovie
    let existsInLibrary: Bool
    let showTypeLabel: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: movie.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Text("•")
                        }
                        Text(item)
                    }
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)
                if let overview = movie.overview {
                    Text(overview).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if existsInLibrary {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var metadataItems: [String] {
        var items: [String] = []
        if let year = movie.year {
            items.append(String(year))
        }
        if showTypeLabel {
            items.append("Movie")
        }
        if let studio = movie.studio, !studio.isEmpty {
            items.append(studio)
        }
        if let runtime = movie.runtime, runtime > 0 {
            items.append("\(runtime)m")
        }
        return items
    }
}

// MARK: - Supporting types

enum SearchScope: Hashable {
    case library
    case arr

    static var segmentBarItems: [TrawlSegmentBarItem<SearchScope>] {
        [
            TrawlSegmentBarItem("Discover", value: .arr),
            TrawlSegmentBarItem("Library", value: .library)
        ]
    }
}

enum SearchResultFilter: Hashable {
    case all
    case series
    case movies

    static var segmentBarItems: [TrawlSegmentBarItem<SearchResultFilter>] {
        [
            TrawlSegmentBarItem("All", value: .all),
            TrawlSegmentBarItem("Series", value: .series),
            TrawlSegmentBarItem("Movies", value: .movies)
        ]
    }
}

fileprivate enum SearchResultEntry: Identifiable {
    case series(SonarrSeries)
    case movie(RadarrMovie)

    var id: String {
        switch self {
        case .series(let s): "s-\(s.id)"
        case .movie(let m): "m-\(m.id)"
        }
    }

    var sortKey: String {
        switch self {
        case .series(let s): (s.sortTitle ?? s.title).lowercased()
        case .movie(let m): (m.sortTitle ?? m.title).lowercased()
        }
    }
}

private struct SeriesDestination: Hashable { let id: Int }
private struct MovieDestination: Hashable { let id: Int }
private struct ArrSeriesLookupDestination: Hashable { let series: SonarrSeries }
private struct ArrMovieLookupDestination: Hashable { let movie: RadarrMovie }
