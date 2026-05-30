import SwiftUI

struct BazarrSeriesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: BazarrViewModel
    private let loadsOnAppear: Bool

    init() {
        _viewModel = State(wrappedValue: BazarrViewModel(serviceManager: ArrServiceManager()))
        loadsOnAppear = true
    }

    var body: some View {
        BazarrBrowserView(viewModel: viewModel)
            .environment(viewModel)
            .task(id: serviceManager.activeBazarrProfileID) {
                guard loadsOnAppear else { return }
                viewModel = BazarrViewModel(serviceManager: serviceManager)
                await viewModel.loadSeries()
                await viewModel.loadMovies()
            }
    }
}

struct BazarrMovieListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: BazarrViewModel
    private let loadsOnAppear: Bool

    init() {
        _viewModel = State(wrappedValue: BazarrViewModel(serviceManager: ArrServiceManager()))
        loadsOnAppear = true
    }

    var body: some View {
        BazarrBrowserView(viewModel: viewModel, initialTab: .movies)
            .environment(viewModel)
            .task(id: serviceManager.activeBazarrProfileID) {
                guard loadsOnAppear else { return }
                viewModel = BazarrViewModel(serviceManager: serviceManager)
                await viewModel.loadSeries()
                await viewModel.loadMovies()
            }
    }
}

// MARK: - Browser View

struct BazarrBrowserView: View {
    @Bindable var viewModel: BazarrViewModel
    var initialTab: BazarrBrowserTab = .series
    @State private var selectedTab: BazarrBrowserTab = .series
    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        Group {
            if !viewModel.isConnected {
                if viewModel.isConnecting || viewModel.connectionError != nil {
                    ArrServiceConnectionStatusView(
                        serviceType: .bazarr,
                        title: viewModel.isConnecting ? "Connecting to Bazarr" : "Bazarr Unreachable",
                        message: viewModel.connectionError ?? "Checking your configured Bazarr server."
                    )
                } else {
                    ContentUnavailableView {
                        Label("Bazarr Not Set Up", systemImage: "captions.bubble")
                    } description: {
                        Text("Add a Bazarr server in Settings to browse subtitles.")
                    }
                }
            } else {
                contentView
            }
        }
        .navigationTitle("Subtitles")
        .navigationSubtitle("Bazarr")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $viewModel.searchText, prompt: "Search series & movies...")
        .onAppear {
            selectedTab = initialTab
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            TrawlSegmentBar(
                "Tab",
                selection: $selectedTab,
                items: BazarrBrowserTab.allCases.map { TrawlSegmentBarItem($0.rawValue, value: $0) }
            )

            if selectedTab == .series {
                seriesList
            } else {
                moviesList
            }
        }
    }

    // MARK: - Series List

    @ViewBuilder
    private var seriesList: some View {
        let effectiveError: String? = viewModel.series.isEmpty ? viewModel.seriesError : nil
        let seriesItems: [BazarrSeries] = viewModel.filteredSeries
        ArrLoadingErrorEmptyView(
            isLoading: viewModel.isLoadingSeries,
            error: effectiveError,
            isEmpty: seriesItems.isEmpty,
            emptyTitle: "No Series Found",
            emptyIcon: "tv",
            emptyDescription: LocalizedStringKey(viewModel.searchText.isEmpty ? "No series are being tracked by Bazarr." : "No series match your search."),
            onRetry: { await viewModel.loadSeries() }
        ) {
            List {
                ForEach(seriesItems, id: \.sonarrSeriesId) { item in
                    NavigationLink(value: MoreDestination.bazarrSeriesDetail(seriesId: item.sonarrSeriesId)) {
                        seriesRow(item)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .refreshable {
                await viewModel.loadSeries()
            }
        }
    }

    private func seriesRow(_ series: BazarrSeries) -> some View {
        let status = BazarrViewModel.subtitleStatus(for: series)
        return HStack(spacing: 12) {
            ArrArtworkView(url: series.poster.flatMap(URL.init(string:))) {
                Image(systemName: "tv")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(series.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let year = series.year {
                        Text(year)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(series.episodeFileCount) episodes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "captions.bubble.fill")
                .foregroundStyle(status == .allPresent ? .teal : .secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Movies List

    @ViewBuilder
    private var moviesList: some View {
        let effectiveError: String? = viewModel.movies.isEmpty ? viewModel.moviesError : nil
        ArrLoadingErrorEmptyView(
            isLoading: viewModel.isLoadingMovies,
            error: effectiveError,
            isEmpty: viewModel.filteredMovies.isEmpty,
            emptyTitle: "No Movies Found",
            emptyIcon: "film",
            emptyDescription: LocalizedStringKey(viewModel.searchText.isEmpty ? "No movies are being tracked by Bazarr." : "No movies match your search."),
            onRetry: { await viewModel.loadMovies() }
        ) {
            List {
                ForEach(viewModel.filteredMovies) { item in
                    NavigationLink(value: MoreDestination.bazarrMovieDetail(radarrId: item.radarrId)) {
                        movieRow(item)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .refreshable {
                await viewModel.loadMovies()
            }
        }
    }

    private func movieRow(_ movie: BazarrMovie) -> some View {
        let status = BazarrViewModel.subtitleStatus(for: movie)
        return HStack(spacing: 12) {
            ArrArtworkView(url: movie.poster.flatMap(URL.init(string:))) {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let year = movie.year {
                        Text(year)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !movie.subtitles.isEmpty {
                        Text("\(movie.subtitles.count) subtitle\(movie.subtitles.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "captions.bubble.fill")
                .foregroundStyle(status == .allPresent ? .teal : .secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
extension BazarrSeriesListView {
    init(previewViewModel: BazarrViewModel) {
        _viewModel = State(wrappedValue: previewViewModel)
        loadsOnAppear = false
    }
}

extension BazarrMovieListView {
    init(previewViewModel: BazarrViewModel) {
        _viewModel = State(wrappedValue: previewViewModel)
        loadsOnAppear = false
    }
}

#Preview("Series Loaded") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrSeriesListView(previewViewModel: BazarrViewModel(
                previewSeries: BazarrSeries.previewList,
                previewMovies: BazarrMovie.previewList
            ))
        }
    }
}

#Preview("Series Loaded Heavy") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrSeriesListView(previewViewModel: BazarrViewModel(
                previewSeries: BazarrSeries.previewHeavyList,
                previewMovies: BazarrMovie.previewList
            ))
        }
    }
}

#Preview("Series Empty") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrSeriesListView(previewViewModel: BazarrViewModel(
                previewSeries: [],
                previewMovies: BazarrMovie.previewList
            ))
        }
    }
}

#Preview("Series Loading") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrSeriesListView(previewViewModel: BazarrViewModel(
                previewSeries: [],
                previewMovies: [],
                isLoadingSeries: true
            ))
        }
    }
}

#Preview("Series Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrSeriesListView(previewViewModel: BazarrViewModel(
                previewSeries: [],
                previewMovies: [],
                seriesError: "The Bazarr API returned 500 Internal Server Error."
            ))
        }
    }
}

#Preview("Series Connection Issue") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrSeriesListView(previewViewModel: BazarrViewModel(
                previewSeries: [],
                previewMovies: [],
                isConnected: false,
                connectionError: "Unable to reach 192.168.1.50:6767."
            ))
        }
    }
}

#Preview("Movies Loaded") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrMovieListView(previewViewModel: BazarrViewModel(
                previewSeries: BazarrSeries.previewList,
                previewMovies: BazarrMovie.previewList,
                selectedTab: .movies
            ))
        }
    }
}

#Preview("Movies Loaded Heavy") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrMovieListView(previewViewModel: BazarrViewModel(
                previewSeries: BazarrSeries.previewList,
                previewMovies: BazarrMovie.previewHeavyList,
                selectedTab: .movies
            ))
        }
    }
}

#Preview("Movies Empty") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrMovieListView(previewViewModel: BazarrViewModel(
                previewSeries: BazarrSeries.previewList,
                previewMovies: [],
                selectedTab: .movies
            ))
        }
    }
}

#Preview("Movies Loading") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrMovieListView(previewViewModel: BazarrViewModel(
                previewSeries: [],
                previewMovies: [],
                isLoadingMovies: true,
                selectedTab: .movies
            ))
        }
    }
}

#Preview("Movies Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrMovieListView(previewViewModel: BazarrViewModel(
                previewSeries: [],
                previewMovies: [],
                moviesError: "The Bazarr API returned 502 Bad Gateway.",
                selectedTab: .movies
            ))
        }
    }
}

#Preview("Movies Connection Issue") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            BazarrMovieListView(previewViewModel: BazarrViewModel(
                previewSeries: [],
                previewMovies: [],
                selectedTab: .movies,
                isConnected: false,
                connectionError: "Unable to reach 192.168.1.50:6767."
            ))
        }
    }
}
#endif
