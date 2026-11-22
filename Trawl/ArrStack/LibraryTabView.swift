import SwiftUI
import TipKit

/// The iPhone Library tab: every series and movie, or one kind of them.
///
/// Series and Movies were two tabs. They answered the same question - "what do I
/// have?" - split by which server happens to hold the answer, and switching between
/// them cost the same one tap as switching scope here does. Merging them freed a tab
/// for Calendar. The sidebar keeps a row for each, because it has the room.
///
/// The scope is the title menu, the same control Downloads and the single-kind lists
/// already use for "what am I looking at", and it is remembered across launches.
struct LibraryTabView: View {
    let seriesSession: ArrLibraryRootSession<SonarrViewModel>
    let moviesSession: ArrLibraryRootSession<RadarrViewModel>
    @Binding var scope: LibraryScope

    var body: some View {
        switch scope {
        case .all:
            LibraryAllListView(
                seriesSession: seriesSession,
                moviesSession: moviesSession,
                scope: $scope
            )
        case .series:
            SonarrSeriesListView(session: seriesSession, libraryScope: $scope)
        case .movies:
            RadarrMovieListView(session: moviesSession, libraryScope: $scope)
        }
    }
}

/// One row of the combined list.
enum LibraryAllEntry: Identifiable, Equatable {
    case series(ArrLibraryEntry<SonarrSeries>)
    case movie(ArrLibraryEntry<RadarrMovie>)

    /// Unique across both kinds: a merge key carries its service.
    var id: ArrMergeKey {
        switch self {
        case .series(let entry): entry.id
        case .movie(let entry): entry.id
        }
    }

    var sortTitle: String {
        switch self {
        case .series(let entry): entry.primary.sortTitle ?? entry.primary.title
        case .movie(let entry): entry.primary.sortTitle ?? entry.primary.title
        }
    }

    /// The latest any server added this title, as Sonarr and Radarr both send it -
    /// an ISO 8601 string, so it orders correctly as text.
    var added: String {
        switch self {
        case .series(let entry): entry.copies.compactMap(\.added).max() ?? ""
        case .movie(let entry): entry.copies.compactMap(\.added).max() ?? ""
        }
    }

    /// Interleaves the two libraries, each already filtered, into one order.
    static func merged(
        series: [ArrLibraryEntry<SonarrSeries>],
        movies: [ArrLibraryEntry<RadarrMovie>],
        sort: LibraryAllSort
    ) -> [LibraryAllEntry] {
        let all = series.map(LibraryAllEntry.series) + movies.map(LibraryAllEntry.movie)
        switch sort {
        case .title:
            return all.sorted {
                let order = $0.sortTitle.localizedStandardCompare($1.sortTitle)
                return order == .orderedSame ? $0.id.value < $1.id.value : order == .orderedAscending
            }
        case .recentlyAdded:
            return all.sorted {
                $0.added == $1.added ? $0.sortTitle < $1.sortTitle : $0.added > $1.added
            }
        }
    }
}

/// The filters both libraries share, by the name each already uses for it.
///
/// Only the ones that mean the same thing in both. Continuing and Ended are about
/// series, Downloaded about films; choosing one here would quietly empty the other
/// half of the list, which reads as data going missing rather than as a filter.
enum LibraryAllFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case monitored = "Monitored"
    case unmonitored = "Unmonitored"
    case missing = "Missing"
    case subtitlesPresent = "Subtitles Present"
    case inJellyfinLibrary = "In Jellyfin Library"

    var id: String { rawValue }

    var seriesFilter: SonarrFilter { SonarrFilter(rawValue: rawValue) ?? .all }
    var moviesFilter: RadarrFilter { RadarrFilter(rawValue: rawValue) ?? .all }
}

/// The sorts both libraries share.
enum LibraryAllSort: String, CaseIterable, Identifiable {
    case title = "Title"
    case recentlyAdded = "Recently Added"

    var id: String { rawValue }

    var seriesSort: SonarrSortOrder { SonarrSortOrder(rawValue: rawValue) ?? .title }
    var moviesSort: RadarrSortOrder { RadarrSortOrder(rawValue: rawValue) ?? .title }
}

/// Every series and movie in one list.
///
/// Reads the same view models the Series and Movies scopes use, through
/// `libraryEntries(filter:searchText:sort:)`, so the three never disagree about
/// what is in the library - and so choosing a filter here does not move the one
/// those screens are showing.
struct LibraryAllListView: View {
    let seriesSession: ArrLibraryRootSession<SonarrViewModel>
    let moviesSession: ArrLibraryRootSession<RadarrViewModel>
    @Binding var scope: LibraryScope

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("libraryAllFilter") private var filter: LibraryAllFilter = .all
    @AppStorage("libraryAllSort") private var sort: LibraryAllSort = .title
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @State private var isTitleCompact = false
    @State private var showMissing = false
    @State private var showSetup = false
    @State private var isRefreshing = false

    private var seriesViewModel: SonarrViewModel? { seriesSession.viewModel }
    private var moviesViewModel: RadarrViewModel? { moviesSession.viewModel }

    private var seriesEntries: [ArrLibraryEntry<SonarrSeries>] {
        seriesViewModel?.libraryEntries(filter: filter.seriesFilter, searchText: searchText, sort: sort.seriesSort) ?? []
    }

    private var movieEntries: [ArrLibraryEntry<RadarrMovie>] {
        moviesViewModel?.libraryEntries(filter: filter.moviesFilter, searchText: searchText, sort: sort.moviesSort) ?? []
    }

    var body: some View {
        let series = seriesEntries
        let movies = movieEntries
        let entries = LibraryAllEntry.merged(series: series, movies: movies, sort: sort)

        content(entries: entries)
            .trawlTitleMenuShrinksOnScroll($isTitleCompact)
            .libraryScopeTitleMenu($scope, subtitle: LibraryScope.countSummary(series: series.count, movies: movies.count))
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top) {
                if hasAnyLibrary {
                    TrawlSegmentBar(
                        "Filter",
                        selection: $filter,
                        items: LibraryAllFilter.allCases.map { TrawlSegmentBarItem($0.rawValue, value: $0) },
                        searchText: $searchText,
                        searchHint: "Search library",
                        isSearchExpanded: $isSearchExpanded,
                        searchPlacement: .leading
                    )
                }
            }
            .navigationDestination(for: ArrMergeKey.self) { key in
                detail(for: key)
                    .environment(syncService)
            }
            .refreshable { await reload(force: true) }
            .background(LibraryAllBackground())
            .onAppear { updateTipEligibility(isEmpty: entries.isEmpty) }
            .onChange(of: entries.isEmpty) { _, isEmpty in updateTipEligibility(isEmpty: isEmpty) }
            .task(id: viewModelKey) {
                makeViewModelsIfNeeded()
                await reload(force: false)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await reload(force: false) }
            }
            .sheet(isPresented: $showMissing) {
                NavigationStack {
                    ArrWantedView(initialScope: .all, showsCloseButton: true)
                        .environment(serviceManager)
                }
            }
            .sheet(isPresented: $showSetup) {
                ArrSetupSheet(initialServiceType: .sonarr, onComplete: {
                    Task { await serviceManager.refreshConfiguration() }
                })
                .environment(serviceManager)
            }
    }

    // MARK: - Content

    private var hasAnyLibrary: Bool {
        seriesViewModel != nil || moviesViewModel != nil
    }

    private var isLoading: Bool {
        (seriesViewModel?.isLoading ?? false) && (seriesViewModel?.items.isEmpty ?? true)
            || (moviesViewModel?.isLoading ?? false) && (moviesViewModel?.items.isEmpty ?? true)
    }

    @ViewBuilder
    private func content(entries: [LibraryAllEntry]) -> some View {
        if !hasAnyLibrary {
            unavailableContent
        } else if entries.isEmpty {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(
                        searchText.isEmpty ? "Nothing Here" : "No Results",
                        systemImage: searchText.isEmpty ? "rectangle.stack" : "magnifyingglass"
                    )
                } description: {
                    Text(searchText.isEmpty
                         ? "No series or movies match \(filter.rawValue.lowercased())."
                         : "Nothing in your library matches “\(searchText)”.")
                }
                .scrollableUnavailableState()
            }
        } else {
            List {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("library-all-list")
        }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        if serviceManager.isInitializing
            || serviceManager.sonarrIsConnecting
            || serviceManager.radarrIsConnecting {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !serviceManager.hasSonarrInstance && !serviceManager.hasRadarrInstance {
            ServiceSetupView(
                title: "Library Not Set Up",
                message: "Add a Sonarr or Radarr server in Settings to see your series and movies here.",
                systemImage: "rectangle.stack",
                actionTitle: "Add Server",
                onSetup: { showSetup = true }
            )
            .scrollableUnavailableState()
        } else {
            ContentUnavailableView {
                Label("Library Unreachable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(serviceManager.sonarrConnectionError
                     ?? serviceManager.radarrConnectionError
                     ?? "Trawl can't reach your Sonarr or Radarr server.")
            } actions: {
                Button("Retry") {
                    Task {
                        await serviceManager.retry(.sonarr)
                        await serviceManager.retry(.radarr)
                    }
                }
            }
            .scrollableUnavailableState()
        }
    }

    @ViewBuilder
    private func row(_ entry: LibraryAllEntry) -> some View {
        switch entry {
        case .series(let item):
            if let vm = seriesViewModel {
                NavigationLink(value: item.id) {
                    SonarrSeriesRow(
                        entry: item,
                        hasIssue: vm.queueRecords.contains { record in
                            record.value.isImportIssueQueueItem
                                && item.copies.contains {
                                    $0.instanceID == record.instance.id && $0.id == record.value.seriesId
                                }
                        },
                        subtitleCoverage: serviceManager.subtitleCoverage(for: item.primary),
                        showTypeLabel: true,
                        instances: serviceManager.badgeRefs(for: item)
                    )
                }
                .contextMenu {
                    SonarrSeriesQuickActions(entry: item, refs: serviceManager.badgeRefs(for: item), viewModel: vm)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    monitorButton(isMonitored: item.copies.contains { $0.monitored ?? true }) {
                        await vm.toggleMonitoredAcrossInstances(item)
                    }
                }
            }
        case .movie(let item):
            if let vm = moviesViewModel {
                NavigationLink(value: item.id) {
                    RadarrMovieRow(
                        entry: item,
                        hasIssue: vm.queueRecords.contains { record in
                            record.value.isImportIssueQueueItem
                                && item.copies.contains {
                                    $0.instanceID == record.instance.id && $0.id == record.value.movieId
                                }
                        },
                        subtitleCoverage: serviceManager.subtitleCoverage(for: item.primary),
                        showTypeLabel: true,
                        instances: serviceManager.badgeRefs(for: item)
                    )
                }
                .contextMenu {
                    RadarrMovieQuickActions(entry: item, refs: serviceManager.badgeRefs(for: item), viewModel: vm)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    monitorButton(isMonitored: item.copies.contains { $0.monitored ?? true }) {
                        await vm.toggleMonitoredAcrossInstances(item)
                    }
                }
            }
        }
    }

    private func monitorButton(isMonitored: Bool, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(isMonitored ? "Unmonitor" : "Monitor", systemImage: isMonitored ? "bookmark.slash" : "bookmark.fill")
        }
        .tint(isMonitored ? .orange : .blue)
    }

    @ViewBuilder
    private func detail(for key: ArrMergeKey) -> some View {
        switch key.serviceType {
        case .sonarr:
            if let vm = seriesViewModel {
                SonarrSeriesDetailView(mergeKey: key, viewModel: vm)
            }
        case .radarr:
            if let vm = moviesViewModel {
                RadarrMovieDetailView(mergeKey: key, viewModel: vm)
            }
        case .prowlarr, .bazarr:
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(LibraryAllSort.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: sort == .title ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
            }

            Menu {
                Button("Missing", systemImage: "exclamationmark.triangle") {
                    showMissing = true
                }
                Divider()
                Button("Refresh All", systemImage: "arrow.clockwise") {
                    Task {
                        isRefreshing = true
                        await reload(force: true)
                        isRefreshing = false
                    }
                }
                .disabled(isRefreshing)
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                }
            }
            .accessibilityLabel("Library Actions")
        }
    }

    // MARK: - Loading

    /// The same keys the single-kind lists rebuild on, so a view model made here is
    /// the one they adopt, and the other way round.
    private var viewModelKey: String {
        let sonarr = serviceManager.connectedSonarr.map { "\($0.ref.id.uuidString):\($0.ref.ordinal)" }.joined(separator: "|")
        let radarr = serviceManager.connectedRadarr.map { "\($0.ref.id.uuidString):\($0.ref.ordinal)" }.joined(separator: "|")
        return "\(sonarr)#\(radarr)"
    }

    private var sonarrKey: String {
        serviceManager.connectedSonarr.map { "\($0.ref.id.uuidString):\($0.ref.ordinal)" }.joined(separator: "|")
    }

    private var radarrKey: String {
        serviceManager.connectedRadarr.map { "\($0.ref.id.uuidString):\($0.ref.ordinal)" }.joined(separator: "|")
    }

    private func makeViewModelsIfNeeded() {
        if serviceManager.hasAnyConnectedSonarrInstance {
            if seriesSession.viewModel == nil || seriesSession.lifecycleKey != sonarrKey {
                seriesSession.viewModel = SonarrViewModel(serviceManager: serviceManager, jellyfinManager: jellyfinManager)
                seriesSession.lifecycleKey = sonarrKey
            }
        } else {
            seriesSession.viewModel = nil
            seriesSession.lifecycleKey = nil
        }
        if serviceManager.hasAnyConnectedRadarrInstance {
            if moviesSession.viewModel == nil || moviesSession.lifecycleKey != radarrKey {
                moviesSession.viewModel = RadarrViewModel(serviceManager: serviceManager, jellyfinManager: jellyfinManager)
                moviesSession.lifecycleKey = radarrKey
            }
        } else {
            moviesSession.viewModel = nil
            moviesSession.lifecycleKey = nil
        }
    }

    private func reload(force: Bool) async {
        let maxAge = force ? 0 : ArrLibraryCachePolicy.appearMaxAge
        async let series: Void = load(seriesViewModel, maxAge: maxAge)
        async let movies: Void = load(moviesViewModel, maxAge: maxAge)
        _ = await (series, movies)
        if serviceManager.hasAnyConnectedBazarrInstance {
            await serviceManager.refreshActiveBazarrSubtitleCache()
        }
    }

    private func load<VM: ArrMediaListViewModel>(_ viewModel: VM?, maxAge: TimeInterval) async {
        guard let viewModel else { return }
        viewModel.adoptCachedLibraryItems()
        async let items: Void = viewModel.loadLibraryItems(maxAge: maxAge)
        async let queue: Void = viewModel.loadQueue()
        _ = await (items, queue)
    }

    private func updateTipEligibility(isEmpty: Bool) {
        LibraryScopeTip.isEligible = !isEmpty
    }
}

/// Both services' brand colours, faintly - the list is both of them.
private struct LibraryAllBackground: View {
    var body: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [ServiceIdentity.sonarr.brandColor.opacity(0.14), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            LinearGradient(
                colors: [ServiceIdentity.radarr.brandColor.opacity(0.14), Color.clear],
                startPoint: .topTrailing,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}
