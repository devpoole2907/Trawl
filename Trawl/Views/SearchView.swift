import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

struct SearchView: View {
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var viewModel = SearchViewModel()
    @State private var showClearConfirmation = false
    @State private var showArrSetupSheet = false
    @State private var navigationPath = NavigationPath()
    @State private var trendingLookupTask: Task<Void, Never>? = nil
    /// A quick-add waiting on the user to say which server it lands on. Only ever
    /// set when the service actually has two - with one server the add stays one
    /// tap, which is the whole point of the control.
    @State private var pendingQuickAdd: PendingQuickAdd?

    private struct PendingQuickAdd: Identifiable {
        enum Target {
            case series(SonarrSeries)
            case movie(RadarrMovie)
        }

        let target: Target
        let instances: [ArrInstanceRef]

        var id: String {
            switch target {
            case .series(let series): "series-\(series.tvdbId ?? series.id)"
            case .movie(let movie): "movie-\(movie.tmdbId ?? movie.id)"
            }
        }

        var title: String {
            switch target {
            case .series(let series): series.title
            case .movie(let movie): movie.title
            }
        }
    }

    @Namespace private var trendingTransition

    // Recents
    @AppStorage("search.recents") private var recentsStorage: String = "[]"
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    /// How this view is being hosted.
    ///
    /// The same distinction `MoreView` draws, for the same reason. On iPhone Search is
    /// the root of a tab and brings its own `NavigationStack`. On iPad it is handed
    /// straight to the middle column of `ContentView`'s split view, which is already a
    /// navigation container - and a stack nested inside one is what produced the dead
    /// band of space above the More column, and here cost Search its search field
    /// entirely: `.searchable` puts the field in its container's navigation bar, and
    /// the nested stack's bar is not the one the column draws.
    enum Presentation {
        /// Root of a tab, on compact width.
        case stack
        /// The middle column of a `NavigationSplitView`, which supplies the
        /// navigation container and the bar the search field lives in.
        case contentColumn
    }

    private let presentation: Presentation
    @Binding var programmaticDestination: ArrMediaDestination?

    #if os(macOS)
    #endif

    init(presentation: Presentation = .stack, programmaticDestination: Binding<ArrMediaDestination?> = .constant(nil)) {
        self.presentation = presentation
        self._programmaticDestination = programmaticDestination
    }



    // MARK: - Body

    var body: some View {
        switch presentation {
        case .stack:
            searchChrome {
                NavigationStack(path: $navigationPath) { searchScreen }
            }
        case .contentColumn:
            // Deliberately bare - the split view is the navigation container, and its
            // column supplies the bar that `.searchable` needs.
            searchChrome { searchScreen }
        }
    }

    private var searchScreen: some View {
        Group {
            ZStack(alignment: .top) {
                content
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if viewModel.isSearchPresented && viewModel.searchText.isEmpty {
                        TrawlSegmentBar(
                            "Scope",
                            selection: $viewModel.scope,
                            items: SearchScope.segmentBarItems,
                            alignment: .center
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else if !viewModel.searchText.isEmpty {
                        filterSegmentBar
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.isSearchPresented)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.scope)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.searchText.isEmpty)
            #if os(macOS)
            .navigationTitle("")
            #else
            .navigationTitle(presentation == .stack ? (viewModel.isSearchPresented ? "" : "Search") : "")
            #endif
            .toolbarTitleDisplayMode(.inlineLarge)
            #if os(macOS)
            .toolbar { macOSSearchBarToolbarItem }
            #endif
            .arrMediaNavigationDestinations(
                onLibraryChanged: { await refreshLibrary() },
                zoomNamespace: trendingTransition
            )
            // A search that finds nothing looks like a search problem. An Arr with no
            // enabled indexer, or one that can only search interactively, is the
            // reason.
            //
            // Inside `searchScreen`, not around `searchChrome`'s result: `.searchable`
            // has to be the outermost thing so its field lands in the container's
            // navigation bar. Wrapping the chrome in a safe-area inset put a view
            // between them, and on iPad - where the container is the split view's
            // content column rather than a stack of its own - the field disappeared
            // entirely, which is the exact defect the two-chrome work fixed.
            .configurationAttention(.search)
        }
    }

    /// Everything that has to sit *outside* the navigation container: the search
    /// field, its submit and change handlers, and the loading tasks.
    ///
    /// One copy, applied to whichever root the presentation chose, so the two chromes
    /// cannot drift apart - the field, the debounce and the trending fetch are the
    /// same behaviour on both, and only their container differs.
    @ViewBuilder
    private func searchChrome(@ViewBuilder _ root: () -> some View) -> some View {
        #if os(iOS)
        root()
        .navigationDestination(item: $programmaticDestination) { dest in
            ArrMediaDetailPane(
                destination: dest,
                onLibraryChanged: { await refreshLibrary() }
            )
        }
        .searchable(
            text: $viewModel.searchText,
            isPresented: $viewModel.isSearchPresented,
            placement: searchFieldPlacement,
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
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            await viewModel.loadTrending(arrServiceManager: arrServiceManager, seerrServiceManager: seerrServiceManager)
        }
        .task(id: "\(arrServiceManager.sonarrConnected)\(arrServiceManager.radarrConnected)") {
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            // Reuses whatever the Series/Movies tabs already fetched, rather than
            // pulling both full libraries again just to build match badges.
            await refreshLibrary(maxAge: ArrLibraryCachePolicy.appearMaxAge)
            createLookupViewModels()
            await reconcileTrendingMatches()
        }
        .refreshable {
            await loadTrending()
            await refreshLibrary()
            await reconcileTrendingMatches()
        }
        .errorAlert(item: $viewModel.actionErrorAlert)
        .sheet(isPresented: $showArrSetupSheet) {
            ArrSetupSheet(onComplete: {
                Task { await arrServiceManager.refreshConfiguration() }
            })
            .environment(arrServiceManager)
        }
        .onDisappear {
            trendingLookupTask?.cancel()
            trendingLookupTask = nil
        }
        #else
        root()
        .navigationDestination(item: $programmaticDestination) { dest in
            ArrMediaDetailPane(
                destination: dest,
                onLibraryChanged: { await refreshLibrary() }
            )
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
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            await viewModel.loadTrending(arrServiceManager: arrServiceManager, seerrServiceManager: seerrServiceManager)
        }
        .task(id: "\(arrServiceManager.sonarrConnected)\(arrServiceManager.radarrConnected)") {
            #if DEBUG
            guard !skipsAutomaticLoading else { return }
            #endif
            // Reuses whatever the Series/Movies tabs already fetched, rather than
            // pulling both full libraries again just to build match badges.
            await refreshLibrary(maxAge: ArrLibraryCachePolicy.appearMaxAge)
            createLookupViewModels()
            await reconcileTrendingMatches()
        }
        .refreshable {
            await loadTrending()
            await refreshLibrary()
            await reconcileTrendingMatches()
        }
        .errorAlert(item: $viewModel.actionErrorAlert)
        .sheet(isPresented: $showArrSetupSheet) {
            ArrSetupSheet(onComplete: {
                Task { await arrServiceManager.refreshConfiguration() }
            })
            .environment(arrServiceManager)
        }
        .onDisappear {
            trendingLookupTask?.cancel()
            trendingLookupTask = nil
        }
        #endif
    }


    /// Where the search field sits, which depends on the container it is in.
    ///
    /// `.navigationBarDrawer(.always)` is the right answer for a tab root: it pins the
    /// field under a large title where it is always visible, which is what Search
    /// wants on a phone. It is the wrong answer for a split-view column, whose bar the
    /// drawer does not belong to - `.automatic` lets SwiftUI put the field where that
    /// chrome actually keeps one.
    private var searchFieldPlacement: SearchFieldPlacement {
        #if os(macOS)
        .sidebar
        #else
        // `.navigationBarDrawer(.always)` on both. `.automatic` in a split view's
        // content column produced no field at all on iPadOS 26: the split view
        // already carries the sidebar's own `.searchable`, and the system keeps that
        // one - so Search had a scope bar, a trending grid and nowhere to type.
        // Naming the placement stops it being merged away.
        .navigationBarDrawer(displayMode: .always)
        #endif
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
            .confirmationDialog(
                pendingQuickAdd.map { "Add \($0.title) to which server?" } ?? "",
                isPresented: Binding(
                    get: { pendingQuickAdd != nil },
                    set: { if !$0 { pendingQuickAdd = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingQuickAdd
            ) { pending in
                ForEach(pending.instances) { instance in
                    Button(arrServiceManager.scopeLabel(for: instance)) {
                        performQuickAdd(pending, on: instance)
                    }
                }
                Button("Cancel", role: .cancel) {}
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
            } else if let error = viewModel.trendingError, !hasContent {
                ServiceErrorView(title: "Couldn't Load Trending", message: error, onRetry: { await loadTrending() })
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
            let dest = ArrMediaDestination.movieLookup(match)
            NavigationLink(value: dest) {
                trendingCardLabel(item: item, inLibrary: inLibrary)
                    #if os(iOS)
                    .matchedTransitionSource(id: dest, in: trendingTransition)
                    #endif
            }
            .buttonStyle(.plain)
        } else if !item.isMovie, let match = viewModel.seriesMatches[item.id] {
            let dest = ArrMediaDestination.seriesLookup(match)
            NavigationLink(value: dest) {
                trendingCardLabel(item: item, inLibrary: inLibrary)
                    #if os(iOS)
                    .matchedTransitionSource(id: dest, in: trendingTransition)
                    #endif
            }
            .buttonStyle(.plain)
        } else {
            Button {
                trendingLookupTask?.cancel()
                trendingLookupTask = Task {
                    let resolver = ArrMediaLookupResolver(serviceManager: arrServiceManager)
                    if item.isMovie, let movie = await resolver.resolveMovie(tmdbId: item.id) {
                        guard !Task.isCancelled else { return }
                        navigationPath.append(ArrMediaDestination.movieLookup(movie))
                    } else if !item.isMovie, let series = await resolver.resolveSeries(tmdbId: item.id) {
                        guard !Task.isCancelled else { return }
                        navigationPath.append(ArrMediaDestination.seriesLookup(series))
                    } else if !Task.isCancelled {
                        // Arr not configured or lookup failed - fall back to text search
                        viewModel.searchText = item.year.map { "\(item.displayTitle) \($0)" } ?? item.displayTitle
                        viewModel.isSearchPresented = true
                        viewModel.scope = .arr
                        startArrLookup(immediate: true)
                    }
                }
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

    /// A one-copy entry. `ArrLibraryEntry(copies:)` only fails on an empty array,
    /// which a single element cannot be; this keeps the call site total.
    private func singleEntry<Item: ArrMergeableLibraryItem>(_ item: Item) -> ArrLibraryEntry<Item> {
        ArrLibraryEntry(copies: [item])!
    }

    /// The badge for a search result's server, suppressed when only one instance
    /// of that service is configured.
    private func badgeRefs(for instanceID: UUID?, serviceType: ArrServiceType) -> [ArrInstanceRef] {
        guard arrServiceManager.showsInstanceProvenance(for: serviceType),
              let ref = arrServiceManager.instanceRef(serviceType, id: instanceID) else { return [] }
        return [ref]
    }

    @ViewBuilder
    private func librarySeriesRow(_ series: SonarrSeries) -> some View {
        let isMonitored = series.monitored ?? true
        NavigationLink(value: ArrMediaDestination.series(id: series.id, instanceID: series.instanceID)) {
            // Search results stay per-server rather than merging: search answers
            // "find this row", and each row is badged with the server holding it.
            SonarrSeriesRow(
                entry: ArrLibraryEntry(copies: [series]) ?? singleEntry(series),
                hasIssue: false,
                showTypeLabel: viewModel.filter == .all,
                instances: badgeRefs(for: series.instanceID, serviceType: .sonarr)
            )
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
        NavigationLink(value: ArrMediaDestination.movie(id: movie.id, instanceID: movie.instanceID)) {
            RadarrMovieRow(
                entry: ArrLibraryEntry(copies: [movie]) ?? singleEntry(movie),
                hasIssue: false,
                showTypeLabel: viewModel.filter == .all,
                instances: badgeRefs(for: movie.instanceID, serviceType: .radarr)
            )
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

    private var hasAnyArrConfigured: Bool {
        arrServiceManager.hasSonarrInstance || arrServiceManager.hasRadarrInstance
    }

    @ViewBuilder
    private var discoverUnavailableContent: some View {
        ServiceSetupView(
            title: "Discovery Needs Sonarr or Radarr",
            message: "Add a Sonarr or Radarr server in Settings to search for and add new movies and shows.",
            systemImage: "sparkle.magnifyingglass",
            actionTitle: "Add Server",
            onSetup: { showArrSetupSheet = true }
        )
    }

    @ViewBuilder
    private var arrResultsContent: some View {
        if !hasAnyArrConfigured {
            discoverUnavailableContent
        } else {
            configuredArrResultsContent
        }
    }

    @ViewBuilder
    private var configuredArrResultsContent: some View {
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
                ServiceErrorView(
                    title: "Search Failed",
                    message: lookupErrors.map { "\($0.service): \($0.message)" }.joined(separator: "\n\n"),
                    onRetry: { await viewModel.performArrLookup(term: viewModel.searchText) }
                )
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

        NavigationLink(value: ArrMediaDestination.seriesLookup(series)) {
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

        NavigationLink(value: ArrMediaDestination.movieLookup(movie)) {
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
        ServiceErrorView(
            title: "Search Partially Unavailable",
            message: errors.map { "\($0.service): \($0.message)" }.joined(separator: "\n\n"),
            hasContent: true,
            onRetry: { await viewModel.performArrLookup(term: viewModel.searchText) }
        )
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

    private func refreshLibrary(maxAge: TimeInterval = 0) async {
        await viewModel.refreshLibrary(arrServiceManager: arrServiceManager, maxAge: maxAge)
    }

    private func loadTrending() async {
        await viewModel.loadTrending(arrServiceManager: arrServiceManager, seerrServiceManager: seerrServiceManager)
    }

    private func toggleLibrarySeriesMonitored(_ series: SonarrSeries) async {
        await viewModel.toggleLibrarySeriesMonitored(series, arrServiceManager: arrServiceManager)
    }

    private func toggleLibraryMovieMonitored(_ movie: RadarrMovie) async {
        await viewModel.toggleLibraryMovieMonitored(movie, arrServiceManager: arrServiceManager)
    }

    /// Adding to an HD/4K pair has to ask which one: the two servers are run
    /// precisely so that a title can go to one, the other, or both, and there is no
    /// sensible default to infer. With one server configured this stays a single tap.
    private func quickAddSeries(_ series: SonarrSeries) async {
        let instances = arrServiceManager.refs(for: .sonarr)
        if instances.count > 1 {
            pendingQuickAdd = PendingQuickAdd(target: .series(series), instances: instances)
            return
        }
        await viewModel.quickAddSeries(series, arrServiceManager: arrServiceManager)
    }

    private func quickAddMovie(_ movie: RadarrMovie) async {
        let instances = arrServiceManager.refs(for: .radarr)
        if instances.count > 1 {
            pendingQuickAdd = PendingQuickAdd(target: .movie(movie), instances: instances)
            return
        }
        await viewModel.quickAddMovie(movie, arrServiceManager: arrServiceManager)
    }

    private func performQuickAdd(_ pending: PendingQuickAdd, on instance: ArrInstanceRef) {
        Task {
            switch pending.target {
            case .series(let series):
                await viewModel.quickAddSeries(
                    series,
                    arrServiceManager: arrServiceManager,
                    instanceID: instance.id
                )
            case .movie(let movie):
                await viewModel.quickAddMovie(
                    movie,
                    arrServiceManager: arrServiceManager,
                    instanceID: instance.id
                )
            }
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

    #if os(macOS)
    @ToolbarContentBuilder
    private var macOSSearchBarToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            MacSearchField(
                text: $viewModel.searchText,
                placeholder: searchPrompt,
                onFocusChanged: { isFocused in
                    if viewModel.isSearchPresented != isFocused {
                        viewModel.isSearchPresented = isFocused
                    }
                },
                onSubmit: {
                    recordRecent(viewModel.searchText)
                    if viewModel.scope == .arr {
                        startArrLookup(immediate: true)
                    }
                }
            )
            .frame(minWidth: 150, idealWidth: 200, maxWidth: 300)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: viewModel.isSearchPresented)
        }
    }
    #endif
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

    /// Keyed on `lookupIdentity`, not the library `id`: these rows are Sonarr/Radarr
    /// *lookup* results, and both services report `id == 0` for anything not yet
    /// added, so an `id`-keyed `ForEach` collapsed every un-added result onto the
    /// first one and rendered a single row no matter how many the search returned.
    var id: String {
        switch self {
        case .series(let s): "s-\(s.lookupIdentity)"
        case .movie(let m): "m-\(m.lookupIdentity)"
        }
    }

    var sortKey: String {
        switch self {
        case .series(let s): (s.sortTitle ?? s.title).lowercased()
        case .movie(let m): (m.sortTitle ?? m.title).lowercased()
        }
    }
}


#if DEBUG
extension SearchView {
    init(previewViewModel: SearchViewModel) {
        self.init()
        self._viewModel = State(initialValue: previewViewModel)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Popular This Week") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        SearchView(previewViewModel: SearchViewModel())
    }
}

#Preview("Library Results") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        SearchView(previewViewModel: SearchViewModel(
            previewSearchText: "d",
            isSearchPresented: true,
            scope: .library,
            matchedSeries: SonarrSeries.previewList,
            matchedMovies: RadarrMovie.previewList
        ))
    }
}

#Preview("Loading") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        SearchView(previewViewModel: SearchViewModel(
            trendingMovies: [],
            trendingTV: [],
            isLoadingTrending: true
        ))
    }
}

#Preview("Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        SearchView(previewViewModel: SearchViewModel(
            trendingMovies: [],
            trendingTV: [],
            trendingError: "TMDb returned 401 Unauthorized."
        ))
    }
}

#Preview("Nothing Configured") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        SearchView(previewViewModel: SearchViewModel(
            previewSearchText: "blade runner",
            isSearchPresented: true,
            scope: .arr,
            trendingMovies: [],
            trendingTV: [],
            hasSearchedArr: true
        ))
    }

}
#endif

#if os(macOS)
class TrawlMacSearchField: NSSearchField {
    var onFocusChanged: ((Bool) -> Void)?
    private var observer: NSKeyValueObservation?
    private var isCurrentlyFocused = false
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            observer = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] win, _ in
                guard let self = self else { return }
                let focused = (win.firstResponder == self) || (self.currentEditor() != nil && win.firstResponder == self.currentEditor())
                if focused != self.isCurrentlyFocused {
                    self.isCurrentlyFocused = focused
                    DispatchQueue.main.async { self.onFocusChanged?(focused) }
                }
            }
        } else {
            observer = nil
        }
    }
}

struct MacSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onFocusChanged: (Bool) -> Void
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = TrawlMacSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.submit(_:))
        searchField.onFocusChanged = onFocusChanged
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MacSearchField

        init(_ parent: MacSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                parent.text = field.stringValue
            }
        }
        
        @objc func submit(_ sender: NSSearchField) {
            parent.onSubmit()
        }
    }
}
#endif
