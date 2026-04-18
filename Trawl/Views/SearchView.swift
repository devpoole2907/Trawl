import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    let appServices: AppServices?

    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var scope: SearchScope = .library
    @State private var filter: ResultKind = .all
    @State private var showClearConfirmation = false
    @State private var actionErrorAlert: ErrorAlertItem?

    // Loaded library
    @State private var sonarrSeries: [SonarrSeries] = []
    @State private var radarrMovies: [RadarrMovie] = []
    @State private var isLoadingLibrary = false

    // Arr lookup
    @State private var sonarrLookupVM: SonarrViewModel?
    @State private var radarrLookupVM: RadarrViewModel?
    @State private var arrFilter: ArrResultKind = .all
    @State private var hasSearchedArr = false
    @State private var arrLookupTask: Task<Void, Never>?
    @State private var activeArrLookupTerm = ""
    @State private var lastCompletedArrLookupTerm = ""

    // TMDb trending
    @AppStorage("tmdb.apiKey") private var tmdbAPIKey: String = ""
    @State private var trendingMovies: [TMDbItem] = []
    @State private var trendingTV: [TMDbItem] = []
    @State private var isLoadingTrending = false
    @State private var trendingError: String?

    // Pre-fetched Arr matches for trending items (keyed by TMDb ID)
    @State private var movieMatches: [Int: RadarrMovie] = [:]
    @State private var seriesMatches: [Int: SonarrSeries] = [:]

    // Recents
    @AppStorage("search.recents") private var recentsStorage: String = "[]"

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                content
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                if isSearchPresented && searchText.isEmpty {
                    Picker("Scope", selection: $scope) { 
                        Text("Library").tag(SearchScope.library)
                        Text("Discover").tag(SearchScope.arr)
                    }
                    .pickerStyle(.segmented)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.horizontal, 48)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSearchPresented)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: scope)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: searchText.isEmpty)
            .navigationTitle("")
            .navigationDestination(for: String.self) { hash in
                if let services = appServices {
                    TorrentDetailView(torrentHash: hash)
                        .environment(services.syncService)
                        .environment(services.torrentService)
                }
            }
            .navigationDestination(for: SeriesDestination.self) { dest in
                if let vm = makeSonarrViewModel() {
                    SonarrSeriesDetailView(seriesId: dest.id, viewModel: vm)
                }
            }
            .navigationDestination(for: MovieDestination.self) { dest in
                if let vm = makeRadarrViewModel() {
                    RadarrMovieDetailView(movieId: dest.id, viewModel: vm)
                }
            }
            .navigationDestination(for: ArrSeriesLookupDestination.self) { dest in
                if let vm = sonarrLookupVM {
                    SonarrSeriesDetailView(
                        series: dest.series,
                        viewModel: vm,
                        onAdded: {
                            await refreshLibrary()
                        }
                    )
                }
            }
            .navigationDestination(for: ArrMovieLookupDestination.self) { dest in
                if let vm = radarrLookupVM {
                    RadarrMovieDetailView(
                        movie: dest.movie,
                        viewModel: vm,
                        onAdded: {
                            await refreshLibrary()
                        }
                    )
                }
            }
        }
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .automatic,
            prompt: searchPrompt
        )
        .onSubmit(of: .search) {
            recordRecent(searchText)
            if scope == .arr {
                startArrLookup(immediate: true)
            }
        }
        .onChange(of: scope) { _, newScope in
            if newScope == .arr {
                startArrLookup(immediate: true)
            } else {
                arrLookupTask?.cancel()
            }
        }
        .onChange(of: searchText) { _, newValue in
            guard scope == .arr else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                resetArrLookup()
            } else {
                startArrLookup()
            }
        }
        .task {
            await refreshLibrary()
            createLookupViewModels()
            await loadTrending()
        }
        .task(id: arrServiceManager.sonarrConnected) {
            await refreshLibrary()
            createLookupViewModels()
        }
        .task(id: arrServiceManager.radarrConnected) {
            await refreshLibrary()
            createLookupViewModels()
        }
        .task(id: tmdbAPIKey) {
            await loadTrending()
        }
        .alert(item: $actionErrorAlert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        if isSearchPresented && searchText.isEmpty {
            recentSearchesContent
        } else if searchText.isEmpty {
            popularThisWeekContent
        } else {
            switch scope {
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
                            searchText = term
                            if scope == .arr {
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
                            .foregroundStyle(.white)
                        Spacer()
                        Button("Clear", role: .destructive) {
                            showClearConfirmation = true
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
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
        let hasContent = !trendingMovies.isEmpty || !trendingTV.isEmpty

        ScrollView {
            if isLoadingTrending && !hasContent {
                VStack(spacing: 16) {
                    Spacer(minLength: 80)
                    ProgressView()
                    Text("Loading trending content…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else if tmdbAPIKey.isEmpty {
                ContentUnavailableView {
                    Label("Popular This Week", systemImage: "flame")
                } description: {
                    Text("Add a TMDb API key in Settings to see trending movies and TV shows.")
                }
                .padding(.top, 60)
            } else if let error = trendingError, !hasContent {
                ContentUnavailableView {
                    Label("Couldn't Load Trending", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
                .padding(.top, 60)
            } else if hasContent {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !trendingMovies.isEmpty {
                        trendingSection(title: "Trending Movies", icon: "film", items: trendingMovies)
                    }
                    if !trendingTV.isEmpty {
                        trendingSection(title: "Trending TV Shows", icon: "tv", items: trendingTV)
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
        }
    }

    @ViewBuilder
    private func trendingCard(item: TMDbItem) -> some View {
        let inLibrary = isInLibrary(item)

        if item.isMovie, let match = movieMatches[item.id] {
            NavigationLink(value: ArrMovieLookupDestination(movie: match)) {
                trendingCardLabel(item: item, inLibrary: inLibrary)
            }
            .buttonStyle(.plain)
        } else if !item.isMovie, let match = seriesMatches[item.id] {
            NavigationLink(value: ArrSeriesLookupDestination(series: match)) {
                trendingCardLabel(item: item, inLibrary: inLibrary)
            }
            .buttonStyle(.plain)
        } else {
            // Match not yet loaded — fall back to search with year for disambiguation
            Button {
                if let year = item.year {
                    searchText = "\(item.displayTitle) \(year)"
                } else {
                    searchText = item.displayTitle
                }
                isSearchPresented = true
                scope = .arr
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
                .frame(width: 140, height: 210)
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

    private func isInLibrary(_ item: TMDbItem) -> Bool {
        if item.isMovie {
            return radarrMovies.contains { $0.tmdbId == item.id }
        } else {
            let title = item.displayTitle.lowercased()
            return sonarrSeries.contains { $0.title.lowercased() == title }
        }
    }

    // MARK: - Library results

    @ViewBuilder
    private var resultsContent: some View {
        let torrentHits  = matchedTorrents
        let seriesHits   = matchedSeries
        let movieHits    = matchedMovies
        let totalCount   = torrentHits.count + seriesHits.count + movieHits.count

        VStack(spacing: 0) {
            filterPills(torrents: torrentHits.count,
                        series: seriesHits.count,
                        movies: movieHits.count)

            if totalCount == 0 {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if shouldShow(.torrents), !torrentHits.isEmpty {
                        Section("Torrents") {
                            ForEach(torrentHits) { torrent in
                                NavigationLink(value: torrent.hash) {
                                    TorrentRowView(torrent: torrent)
                                }
                            }
                        }
                    }

                    if shouldShow(.series), !seriesHits.isEmpty {
                        Section("Series") {
                            ForEach(seriesHits) { series in
                                let isMonitored = series.monitored ?? true
                                NavigationLink(value: SeriesDestination(id: series.id)) {
                                    SonarrSeriesRow(series: series)
                                }
                                .contextMenu {
                                    Button {
                                        Task { await toggleLibrarySeriesMonitored(series) }
                                    } label: {
                                        Label(
                                            isMonitored ? "Unmonitor" : "Monitor",
                                            systemImage: isMonitored ? "eye.slash" : "eye"
                                        )
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        Task { await toggleLibrarySeriesMonitored(series) }
                                    } label: {
                                        Label(
                                            isMonitored ? "Unmonitor" : "Monitor",
                                            systemImage: isMonitored ? "eye.slash" : "eye"
                                        )
                                    }
                                    .tint(isMonitored ? .orange : .green)
                                }
                            }
                        }
                    }

                    if shouldShow(.movies), !movieHits.isEmpty {
                        Section("Movies") {
                            ForEach(movieHits) { movie in
                                let isMonitored = movie.monitored ?? true
                                NavigationLink(value: MovieDestination(id: movie.id)) {
                                    RadarrMovieRow(movie: movie)
                                }
                                .contextMenu {
                                    Button {
                                        Task { await toggleLibraryMovieMonitored(movie) }
                                    } label: {
                                        Label(
                                            isMonitored ? "Unmonitor" : "Monitor",
                                            systemImage: isMonitored ? "eye.slash" : "eye"
                                        )
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        Task { await toggleLibraryMovieMonitored(movie) }
                                    } label: {
                                        Label(
                                            isMonitored ? "Unmonitor" : "Monitor",
                                            systemImage: isMonitored ? "eye.slash" : "eye"
                                        )
                                    }
                                    .tint(isMonitored ? .orange : .green)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Filter pills (library)

    @ViewBuilder
    private func filterPills(torrents: Int, series: Int, movies: Int) -> some View {
        let pills: [(ResultKind, String, String, Int)] = [
            (.all,      "All",      "square.stack.3d.up",   torrents + series + movies),
            (.torrents, "Torrents", "arrow.down.circle",    torrents),
            (.series,   "Series",   "tv",                   series),
            (.movies,   "Movies",   "film",                 movies)
        ]

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pills, id: \.0) { kind, title, icon, count in
                    pill(kind: kind, title: title, icon: icon, count: count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func pill(kind: ResultKind, title: String, icon: String, count: Int) -> some View {
        let isSelected = filter == kind
        return Button {
            filter = kind
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shouldShow(_ kind: ResultKind) -> Bool {
        filter == .all || filter == kind
    }

    // MARK: - Arr results

    @ViewBuilder
    private var arrResultsContent: some View {
        let seriesResults = sonarrLookupVM?.searchResults ?? []
        let movieResults = radarrLookupVM?.searchResults ?? []
        let isSearching = (sonarrLookupVM?.isSearching ?? false) || (radarrLookupVM?.isSearching ?? false)
        let totalCount = seriesResults.count + movieResults.count
        let lookupErrors = arrLookupErrors

        VStack(spacing: 0) {
            arrFilterPills(series: seriesResults.count, movies: movieResults.count)

            if totalCount == 0 && isSearching {
                Spacer()
                ProgressView("Searching…")
                Spacer()
            } else if totalCount == 0 && hasSearchedArr {
                if lookupErrors.isEmpty {
                    ContentUnavailableView.search(text: searchText)
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
                                Text("Updating results as Sonarr and Radarr respond…")
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

                    if arrShouldShow(.series), !seriesResults.isEmpty {
                        Section("Series") {
                            ForEach(seriesResults) { series in
                                let existsInLibrary = sonarrSeries.contains(where: { $0.tvdbId == series.tvdbId })
                                let libraryMatch = sonarrSeries.first(where: { $0.tvdbId == series.tvdbId })
                                NavigationLink(value: ArrSeriesLookupDestination(series: series)) {
                                    ArrSeriesResultRow(
                                        series: series,
                                        existsInLibrary: existsInLibrary
                                    )
                                }
                                .contextMenu {
                                    if existsInLibrary {
                                        if let libraryMatch {
                                            let isMonitored = libraryMatch.monitored ?? true
                                            Button {
                                                Task { await toggleLibrarySeriesMonitored(libraryMatch) }
                                            } label: {
                                                Label(
                                                    isMonitored ? "Unmonitor" : "Monitor",
                                                    systemImage: isMonitored ? "eye.slash" : "eye"
                                                )
                                            }
                                        }
                                    } else {
                                        Button {
                                            Task { await quickAddSeries(series) }
                                        } label: {
                                            Label("Add To Library", systemImage: "plus.circle")
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if existsInLibrary {
                                        if let libraryMatch {
                                            let isMonitored = libraryMatch.monitored ?? true
                                            Button {
                                                Task { await toggleLibrarySeriesMonitored(libraryMatch) }
                                            } label: {
                                                Label(
                                                    isMonitored ? "Unmonitor" : "Monitor",
                                                    systemImage: isMonitored ? "eye.slash" : "eye"
                                                )
                                            }
                                            .tint(isMonitored ? .orange : .green)
                                        }
                                    } else {
                                        Button {
                                            Task { await quickAddSeries(series) }
                                        } label: {
                                            Label("Add", systemImage: "plus.circle")
                                        }
                                        .tint(.green)
                                    }
                                }
                            }
                        }
                    }

                    if arrShouldShow(.movies), !movieResults.isEmpty {
                        Section("Movies") {
                            ForEach(movieResults) { movie in
                                let existsInLibrary = radarrMovies.contains(where: { $0.tmdbId == movie.tmdbId })
                                let libraryMatch = radarrMovies.first(where: { $0.tmdbId == movie.tmdbId })
                                NavigationLink(value: ArrMovieLookupDestination(movie: movie)) {
                                    ArrMovieResultRow(
                                        movie: movie,
                                        existsInLibrary: existsInLibrary
                                    )
                                }
                                .contextMenu {
                                    if existsInLibrary {
                                        if let libraryMatch {
                                            let isMonitored = libraryMatch.monitored ?? true
                                            Button {
                                                Task { await toggleLibraryMovieMonitored(libraryMatch) }
                                            } label: {
                                                Label(
                                                    isMonitored ? "Unmonitor" : "Monitor",
                                                    systemImage: isMonitored ? "eye.slash" : "eye"
                                                )
                                            }
                                        }
                                    } else {
                                        Button {
                                            Task { await quickAddMovie(movie) }
                                        } label: {
                                            Label("Add To Library", systemImage: "plus.circle")
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if existsInLibrary {
                                        if let libraryMatch {
                                            let isMonitored = libraryMatch.monitored ?? true
                                            Button {
                                                Task { await toggleLibraryMovieMonitored(libraryMatch) }
                                            } label: {
                                                Label(
                                                    isMonitored ? "Unmonitor" : "Monitor",
                                                    systemImage: isMonitored ? "eye.slash" : "eye"
                                                )
                                            }
                                            .tint(isMonitored ? .orange : .green)
                                        }
                                    } else {
                                        Button {
                                            Task { await quickAddMovie(movie) }
                                        } label: {
                                            Label("Add", systemImage: "plus.circle")
                                        }
                                        .tint(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var arrLookupErrors: [ArrLookupError] {
        var errors: [ArrLookupError] = []

        if let error = sonarrLookupVM?.error, !error.isEmpty {
            errors.append(ArrLookupError(service: "Sonarr", message: error))
        }

        if let error = radarrLookupVM?.error, !error.isEmpty {
            errors.append(ArrLookupError(service: "Radarr", message: error))
        }

        return errors
    }


    // MARK: - Arr filter pills

    @ViewBuilder
    private func arrFilterPills(series: Int, movies: Int) -> some View {
        let pills: [(ArrResultKind, String, String, Int)] = [
            (.all,    "All",    "square.stack.3d.up", series + movies),
            (.series, "Series", "tv",                 series),
            (.movies, "Movies", "film",               movies)
        ]

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pills, id: \.0) { kind, title, icon, count in
                    arrPill(kind: kind, title: title, icon: icon, count: count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func arrPill(kind: ArrResultKind, title: String, icon: String, count: Int) -> some View {
        let isSelected = arrFilter == kind
        return Button {
            arrFilter = kind
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func arrShouldShow(_ kind: ArrResultKind) -> Bool {
        arrFilter == .all || arrFilter == kind
    }

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
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
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

    // MARK: - Arr lookup

    private func createLookupViewModels() {
        if sonarrLookupVM == nil && arrServiceManager.sonarrConnected {
            sonarrLookupVM = SonarrViewModel(serviceManager: arrServiceManager, preloadedSeries: sonarrSeries)
        }
        if radarrLookupVM == nil && arrServiceManager.radarrConnected {
            radarrLookupVM = RadarrViewModel(serviceManager: arrServiceManager, preloadedMovies: radarrMovies)
        }
    }

    private func startArrLookup(immediate: Bool = false) {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            resetArrLookup()
            return
        }

        let isCurrentlySearchingTerm = activeArrLookupTerm == term
            && ((sonarrLookupVM?.isSearching ?? false) || (radarrLookupVM?.isSearching ?? false))
        if isCurrentlySearchingTerm || lastCompletedArrLookupTerm == term {
            return
        }

        arrLookupTask?.cancel()
        arrLookupTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            await performArrLookup(term: term)
        }
    }

    private func performArrLookup(term: String) async {
        hasSearchedArr = true
        activeArrLookupTerm = term
        sonarrLookupVM?.clearSearchResults()
        radarrLookupVM?.clearSearchResults()

        defer {
            if activeArrLookupTerm == term {
                activeArrLookupTerm = ""
                lastCompletedArrLookupTerm = term
            }
        }

        await withTaskGroup(of: Void.self) { group in
            if let sonarrLookupVM {
                group.addTask {
                    await sonarrLookupVM.searchForNewSeries(term: term)
                }
            }
            if let radarrLookupVM {
                group.addTask {
                    await radarrLookupVM.searchForNewMovies(term: term)
                }
            }
        }
    }

    private func resetArrLookup() {
        arrLookupTask?.cancel()
        activeArrLookupTerm = ""
        lastCompletedArrLookupTerm = ""
        hasSearchedArr = false
        sonarrLookupVM?.clearSearchResults()
        radarrLookupVM?.clearSearchResults()
    }


    // MARK: - Search prompt

    private var searchPrompt: String {
        switch scope {
        case .library: "Your library"
        case .arr:     "Sonarr & Radarr"
        }
    }

    // MARK: - Library matches

    private var matchedTorrents: [Torrent] {
        guard let services = appServices, !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return services.syncService.torrents.values
            .filter { $0.name.lowercased().contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var matchedSeries: [SonarrSeries] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return sonarrSeries
            .filter { $0.title.lowercased().contains(q) }
            .sorted { ($0.sortTitle ?? $0.title) < ($1.sortTitle ?? $1.title) }
    }

    private var matchedMovies: [RadarrMovie] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        return radarrMovies
            .filter { $0.title.lowercased().contains(q) }
            .sorted { ($0.sortTitle ?? $0.title) < ($1.sortTitle ?? $1.title) }
    }

    // MARK: - Library loading

    private func refreshLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        async let sonarrTask: [SonarrSeries] = {
            guard let client = arrServiceManager.sonarrClient else { return [] }
            return (try? await client.getSeries()) ?? []
        }()
        async let radarrTask: [RadarrMovie] = {
            guard let client = arrServiceManager.radarrClient else { return [] }
            return (try? await client.getMovies()) ?? []
        }()

        let (series, movies) = await (sonarrTask, radarrTask)
        sonarrSeries = series
        radarrMovies = movies
    }

    // MARK: - TMDb trending

    private func loadTrending() async {
        guard !tmdbAPIKey.isEmpty else {
            trendingMovies = []
            trendingTV = []
            return
        }
        isLoadingTrending = true
        trendingError = nil
        defer { isLoadingTrending = false }

        let client = TMDbClient(apiKey: tmdbAPIKey)
        do {
            async let moviesTask = client.trendingMovies()
            async let tvTask = client.trendingTV()
            let (movies, tv) = try await (moviesTask, tvTask)
            trendingMovies = movies
            trendingTV = tv
            await resolveTrendingMatches(movies: movies, tv: tv)
        } catch {
            trendingError = error.localizedDescription
        }
    }

    /// Resolve TMDb trending items to their Radarr/Sonarr representations in the background.
    private func resolveTrendingMatches(movies: [TMDbItem], tv: [TMDbItem]) async {
        let radarrClient = arrServiceManager.radarrClient
        let sonarrClient = arrServiceManager.sonarrClient

        // Movies: use Radarr's TMDb ID lookup (fast, one call per movie)
        if let radarrClient {
            await withTaskGroup(of: (Int, RadarrMovie?).self) { group in
                for item in movies.prefix(20) {
                    group.addTask {
                        let match = try? await radarrClient.lookupMovieByTmdb(tmdbId: item.id)
                        return (item.id, match)
                    }
                }
                for await (tmdbId, match) in group {
                    if let match {
                        movieMatches[tmdbId] = match
                    }
                }
            }
        }

        // TV: use Sonarr term search, prefer year match over first result
        if let sonarrClient {
            await withTaskGroup(of: (Int, SonarrSeries?).self) { group in
                for item in tv.prefix(20) {
                    group.addTask {
                        guard let results = try? await sonarrClient.lookupSeries(term: item.displayTitle),
                              !results.isEmpty else { return (item.id, nil) }
                        // Prefer exact year match to avoid e.g. "Euphoria 2019" → "Euphoria 2011"
                        if let yearStr = item.year, let year = Int(yearStr) {
                            if let yearMatch = results.first(where: { $0.year == year }) {
                                return (item.id, yearMatch)
                            }
                        }
                        return (item.id, results.first)
                    }
                }
                for await (tmdbId, match) in group {
                    if let match {
                        seriesMatches[tmdbId] = match
                    }
                }
            }
        }
    }

    private func makeSonarrViewModel() -> SonarrViewModel? {
        guard arrServiceManager.sonarrConnected else { return nil }
        return SonarrViewModel(serviceManager: arrServiceManager, preloadedSeries: sonarrSeries)
    }

    private func makeRadarrViewModel() -> RadarrViewModel? {
        guard arrServiceManager.radarrConnected else { return nil }
        return RadarrViewModel(serviceManager: arrServiceManager, preloadedMovies: radarrMovies)
    }

    private func toggleLibrarySeriesMonitored(_ series: SonarrSeries) async {
        guard let viewModel = makeSonarrViewModel() else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Series", message: "Sonarr is not connected.")
            return
        }

        await viewModel.toggleSeriesMonitored(series)
        await refreshLibrary()

        if let error = viewModel.error, !error.isEmpty {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Series", message: error)
        }
    }

    private func toggleLibraryMovieMonitored(_ movie: RadarrMovie) async {
        guard let viewModel = makeRadarrViewModel() else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Movie", message: "Radarr is not connected.")
            return
        }

        await viewModel.toggleMovieMonitored(movie)
        await refreshLibrary()

        if let error = viewModel.error, !error.isEmpty {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Update Movie", message: error)
        }
    }

    private func quickAddSeries(_ series: SonarrSeries) async {
        guard let viewModel = sonarrLookupVM else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "Sonarr is not connected.")
            return
        }
        guard let tvdbId = series.tvdbId else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "This search result is missing a TVDB ID.")
            return
        }
        guard let titleSlug = series.titleSlug, !titleSlug.isEmpty else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "This search result is missing a title slug.")
            return
        }
        guard let qualityProfileId = viewModel.qualityProfiles.first?.id else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "No Sonarr quality profile is available.")
            return
        }
        guard let rootFolderPath = viewModel.rootFolders.first?.path else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Series", message: "No Sonarr root folder is configured.")
            return
        }

        let wasAdded = await viewModel.addSeries(
            tvdbId: tvdbId,
            title: series.title,
            titleSlug: titleSlug,
            images: series.images ?? [],
            seasons: series.seasons ?? [],
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath
        )

        if wasAdded {
            await refreshLibrary()
        } else {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Add Series",
                message: viewModel.error ?? "Sonarr rejected the add request."
            )
        }
    }

    private func quickAddMovie(_ movie: RadarrMovie) async {
        guard let viewModel = radarrLookupVM else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "Radarr is not connected.")
            return
        }
        guard let tmdbId = movie.tmdbId else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "This search result is missing a TMDb ID.")
            return
        }
        guard let qualityProfileId = viewModel.qualityProfiles.first?.id else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "No Radarr quality profile is available.")
            return
        }
        guard let rootFolderPath = viewModel.rootFolders.first?.path else {
            actionErrorAlert = ErrorAlertItem(title: "Couldn't Add Movie", message: "No Radarr root folder is configured.")
            return
        }

        let wasAdded = await viewModel.addMovie(
            title: movie.title,
            tmdbId: tmdbId,
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath
        )

        if wasAdded {
            await refreshLibrary()
        } else {
            actionErrorAlert = ErrorAlertItem(
                title: "Couldn't Add Movie",
                message: viewModel.error ?? "Radarr rejected the add request."
            )
        }
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

private struct ArrLookupError: Identifiable {
    let service: String
    let message: String

    var id: String { "\(service):\(message)" }
}

private struct ArrSeriesResultRow: View {
    let series: SonarrSeries
    let existsInLibrary: Bool

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
                    if let year = series.year { Text(String(year)).font(.caption2) }
                    if let network = series.network { Text("• \(network)").font(.caption2) }
                    if let status = series.status { Text("• \(status.capitalized)").font(.caption2) }
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
}

private struct ArrMovieResultRow: View {
    let movie: RadarrMovie
    let existsInLibrary: Bool

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
                    if let year = movie.year { Text(String(year)).font(.caption2) }
                    if let studio = movie.studio, !studio.isEmpty { Text("• \(studio)").font(.caption2) }
                    if let runtime = movie.runtime, runtime > 0 { Text("• \(runtime)m").font(.caption2) }
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
}

// MARK: - Supporting types

enum SearchScope: Hashable {
    case library
    case arr
}

private enum ResultKind: Hashable {
    case all
    case torrents
    case series
    case movies
}

private enum ArrResultKind: Hashable {
    case all
    case series
    case movies
}

private struct SeriesDestination: Hashable { let id: Int }
private struct MovieDestination: Hashable { let id: Int }
private struct ArrSeriesLookupDestination: Hashable { let series: SonarrSeries }
private struct ArrMovieLookupDestination: Hashable { let movie: RadarrMovie }
