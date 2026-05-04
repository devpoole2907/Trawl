import SwiftUI

struct BazarrSeriesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: BazarrViewModel

    init() {
        _viewModel = State(wrappedValue: BazarrViewModel(serviceManager: ArrServiceManager()))
    }

    var body: some View {
        BazarrBrowserView(viewModel: viewModel)
            .environment(viewModel)
            .task(id: serviceManager.activeBazarrProfileID) {
                viewModel = BazarrViewModel(serviceManager: serviceManager)
                await viewModel.loadSeries()
                await viewModel.loadMovies()
            }
    }
}

struct BazarrMovieListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: BazarrViewModel

    init() {
        _viewModel = State(wrappedValue: BazarrViewModel(serviceManager: ArrServiceManager()))
    }

    var body: some View {
        BazarrBrowserView(viewModel: viewModel, initialTab: .movies)
            .environment(viewModel)
            .task(id: serviceManager.activeBazarrProfileID) {
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
                if viewModel.isConnecting {
                    ProgressView("Connecting to Bazarr...")
                } else if let error = viewModel.connectionError {
                    ContentUnavailableView {
                        Label("Connection Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
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
            Picker("Tab", selection: $selectedTab) {
                ForEach(BazarrBrowserTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

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

    private var seriesFilterBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $viewModel.showMonitoredOnly) {
                Text("Monitored")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(.orange)

            Toggle(isOn: $viewModel.showMissingOnly) {
                Text("Missing")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .tint(.red)

            Spacer()

            Button {
                viewModel.sortNewestFirst.toggle()
            } label: {
                Image(systemName: viewModel.sortNewestFirst ? "arrow.down" : "arrow.up")
            }
            .buttonStyle(.bordered)
        }
        .font(.caption)
        .padding(.vertical, 4)
    }

    private func seriesRow(_ series: BazarrSeries) -> some View {
        let status = BazarrViewModel.subtitleStatus(for: series)
        return HStack(spacing: 12) {
            ArrArtworkView(url: series.poster.flatMap(URL.init(string:))) {
                Image(systemName: "tv")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
        .padding(.vertical, 2)
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
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
        .padding(.vertical, 2)
    }
}
