import SwiftUI

struct ArrWantedView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var sonarrViewModel: SonarrViewModel?
    @State private var radarrViewModel: RadarrViewModel?
    @State private var scope: ArrWantedScope

    init(initialScope: ArrWantedScope = .all) {
        _scope = State(initialValue: initialScope)
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var isLoading: Bool {
        sonarrViewModel?.isLoadingWantedMissing == true || radarrViewModel?.isLoadingWantedMissing == true
    }

    var body: some View {
        Group {
            if !hasConnectedService {
                ContentUnavailableView(
                    "No Arr Services Connected",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Connect Sonarr or Radarr to view monitored items that are still missing files.")
                )
            } else if isLoading && isEmpty {
                ProgressView("Loading wanted items...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty {
                ContentUnavailableView(
                    "Nothing Missing",
                    systemImage: "checkmark.circle",
                    description: Text("There are no monitored series episodes or movies waiting for files right now.")
                )
            } else {
                List {
                    if scope != .movies, let sonarrViewModel, !sonarrViewModel.wantedEpisodes.isEmpty {
                        Section("Series") {
                            ForEach(sonarrViewModel.wantedEpisodes) { episode in
                                WantedEpisodeRow(episode: episode) {
                                    Task { await sonarrViewModel.searchEpisode(episode) }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task { await sonarrViewModel.searchEpisode(episode) }
                                    } label: {
                                        Label("Search", systemImage: "magnifyingglass")
                                    }
                                    .tint(.purple)
                                }
                            }

                            if sonarrViewModel.canLoadMoreWantedMissing {
                                Button {
                                    Task { await sonarrViewModel.loadMoreWantedMissing() }
                                } label: {
                                    loadMoreLabel(isLoading: sonarrViewModel.isLoadingWantedMissing)
                                }
                            }
                        }
                    }

                    if scope != .series, let radarrViewModel, !radarrViewModel.wantedMovies.isEmpty {
                        Section("Movies") {
                            ForEach(radarrViewModel.wantedMovies) { movie in
                                WantedMovieRow(movie: movie) {
                                    Task { await radarrViewModel.searchMovie(movieId: movie.id) }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task { await radarrViewModel.searchMovie(movieId: movie.id) }
                                    } label: {
                                        Label("Search", systemImage: "magnifyingglass")
                                    }
                                    .tint(.purple)
                                }
                            }

                            if radarrViewModel.canLoadMoreWantedMissing {
                                Button {
                                    Task { await radarrViewModel.loadMoreWantedMissing() }
                                } label: {
                                    loadMoreLabel(isLoading: radarrViewModel.isLoadingWantedMissing)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(backgroundGradient)
        .navigationTitle("Wanted / Missing")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search All Missing") {
                    Task { await searchAllMissing() }
                }
                .disabled(!hasConnectedService)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Scope", selection: $scope) {
                ForEach(ArrWantedScope.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .task(id: reloadKey) {
            await initializeIfNeeded()
            await reloadWantedMissing()
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.orange.opacity(0.12), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 240
            )
        }
        .ignoresSafeArea()
    }

    private var isEmpty: Bool {
        let sonarrIsEmpty = sonarrViewModel?.wantedEpisodes.isEmpty ?? true
        let radarrIsEmpty = radarrViewModel?.wantedMovies.isEmpty ?? true

        switch scope {
        case .all:
            return sonarrIsEmpty && radarrIsEmpty
        case .series:
            return sonarrIsEmpty
        case .movies:
            return radarrIsEmpty
        }
    }

    private var reloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }

    private func initializeIfNeeded() async {
        if serviceManager.sonarrConnected, sonarrViewModel == nil {
            sonarrViewModel = SonarrViewModel(serviceManager: serviceManager)
        }

        if serviceManager.radarrConnected, radarrViewModel == nil {
            radarrViewModel = RadarrViewModel(serviceManager: serviceManager)
        }

        if !serviceManager.sonarrConnected {
            sonarrViewModel = nil
        }

        if !serviceManager.radarrConnected {
            radarrViewModel = nil
        }
    }

    private func reloadWantedMissing() async {
        await withTaskGroup(of: Void.self) { group in
            if let sonarrViewModel {
                group.addTask {
                    await sonarrViewModel.loadWantedMissing()
                }
            }

            if let radarrViewModel {
                group.addTask {
                    await radarrViewModel.loadWantedMissing()
                }
            }
        }
    }

    private func searchAllMissing() async {
        await withTaskGroup(of: Void.self) { group in
            if let sonarrViewModel {
                group.addTask {
                    await sonarrViewModel.searchAllMissing()
                }
            }

            if let radarrViewModel {
                group.addTask {
                    await radarrViewModel.searchAllMissing()
                }
            }
        }
    }

    @ViewBuilder
    private func loadMoreLabel(isLoading: Bool) -> some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Load More")
            }
            Spacer()
        }
    }
}

enum ArrWantedScope: CaseIterable, Hashable {
    case all
    case series
    case movies

    var title: String {
        switch self {
        case .all:
            "All"
        case .series:
            "Series"
        case .movies:
            "Movies"
        }
    }
}

private struct WantedEpisodeRow: View {
    let episode: SonarrEpisode
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .foregroundStyle(.purple)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.series?.title ?? "Unknown Series")
                    .font(.subheadline.weight(.semibold))

                Text(episode.episodeIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let airDate = episode.airDate, !airDate.isEmpty {
                    Text(formatDate(airDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Search", systemImage: "magnifyingglass", action: onSearch)
                .labelStyle(.iconOnly)
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct WantedMovieRow: View {
    let movie: RadarrMovie
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(movie.title)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    if let year = movie.year {
                        Text(String(year))
                    }
                    Text(movie.displayStatus)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Search", systemImage: "magnifyingglass", action: onSearch)
                .labelStyle(.iconOnly)
        }
        .padding(.vertical, 4)
    }
}
