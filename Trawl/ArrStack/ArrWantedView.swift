import SwiftUI

struct ArrWantedView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var sonarrViewModel: SonarrViewModel?
    @State private var radarrViewModel: RadarrViewModel?
    @State private var scope: ArrWantedScope

    @State private var showSearchAllConfirm = false
    @State private var isSearchingAll = false

    init(initialScope: ArrWantedScope = .all) {
        _scope = State(initialValue: initialScope)
    }

    private var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var isLoading: Bool {
        sonarrViewModel?.isLoadingWantedMissing == true || radarrViewModel?.isLoadingWantedMissing == true
    }

    private var hasError: Bool {
        (sonarrViewModel?.error != nil && !sonarrViewModel!.error!.isEmpty) ||
        (radarrViewModel?.error != nil && !radarrViewModel!.error!.isEmpty)
    }

    private var canSearchAllMissing: Bool {
        switch scope {
        case .all:
            return sonarrViewModel?.isConnected == true || radarrViewModel?.isConnected == true
        case .series:
            return sonarrViewModel?.isConnected == true
        case .movies:
            return radarrViewModel?.isConnected == true
        }
    }

    private var searchAllConfirmMessage: String {
        switch scope {
        case .all:
            return "This will trigger a search for all missing items across your connected Arr services."
        case .series:
            return "This will trigger a search for all missing series items."
        case .movies:
            return "This will trigger a search for all missing movies."
        }
    }

    var body: some View {
        Group {
            if !hasConfiguredService {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "server.rack",
                    description: Text("Connect Sonarr or Radarr to view monitored items that are still missing files.")
                )
            } else if !hasConnectedService {
                ContentUnavailableView(
                    "Services Unreachable",
                    systemImage: "network.slash",
                    description: Text("Unable to reach your configured Sonarr or Radarr servers.")
                )
            } else if isLoading && isEmpty {
                ProgressView("Loading wanted items...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isEmpty && !hasError {
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
                                    await searchEpisode(episode, in: sonarrViewModel)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task { await searchEpisode(episode, in: sonarrViewModel) }
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
                                    await searchMovie(movie, in: radarrViewModel)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        Task { await searchMovie(movie, in: radarrViewModel) }
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
                .scrollContentBackground(.hidden)
                .background(backgroundGradient)
            }
        }
        .navigationTitle("Wanted / Missing")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSearchingAll {
                    ProgressView()
                } else {
                    Button("Search All Missing") {
                        showSearchAllConfirm = true
                    }
                    .disabled(!canSearchAllMissing)
                }
            }
        }
        .alert("Search All Missing?", isPresented: $showSearchAllConfirm) {
            Button("Search") {
                Task { await searchAllMissing() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(searchAllConfirmMessage)
        }
        .safeAreaInset(edge: .top) {
            Picker("Scope", selection: $scope) {
                ForEach(ArrWantedScope.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .glassEffect(.regular.interactive(), in: Capsule())
            .padding(.horizontal, 48)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .task(id: reloadKey) {
            await initializeIfNeeded()
            await reloadWantedMissing()
        }
    }

    // MARK: - Computed

    private var isEmpty: Bool {
        let sonarrIsEmpty = sonarrViewModel?.wantedEpisodes.isEmpty ?? true
        let radarrIsEmpty = radarrViewModel?.wantedMovies.isEmpty ?? true

        switch scope {
        case .all:    return sonarrIsEmpty && radarrIsEmpty
        case .series: return sonarrIsEmpty
        case .movies: return radarrIsEmpty
        }
    }

    private var reloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }

    // MARK: - Actions

    private func searchEpisode(_ episode: SonarrEpisode, in vm: SonarrViewModel) async {
        await vm.searchEpisode(episode)
        if let error = vm.error, !error.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
        } else {
            InAppNotificationCenter.shared.showSuccess(
                title: "Search Queued",
                message: "\(episode.series?.title ?? episode.episodeIdentifier) – search sent to indexers."
            )
        }
    }

    private func searchMovie(_ movie: RadarrMovie, in vm: RadarrViewModel) async {
        await vm.searchMovie(movieId: movie.id)
        if let error = vm.error, !error.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
        } else {
            InAppNotificationCenter.shared.showSuccess(
                title: "Search Queued",
                message: "\(movie.title) – search sent to indexers."
            )
        }
    }

    private func searchAllMissing() async {
        isSearchingAll = true
        var errors: [String] = []

        await withTaskGroup(of: String?.self) { group in
            if let sonarrViewModel {
                group.addTask {
                    do {
                        try await sonarrViewModel.searchAllMissing()
                        return nil
                    } catch {
                        return "Sonarr: \(error.localizedDescription)"
                    }
                }
            }
            if let radarrViewModel {
                group.addTask {
                    do {
                        try await radarrViewModel.searchAllMissing()
                        return nil
                    } catch {
                        return "Radarr: \(error.localizedDescription)"
                    }
                }
            }

            for await result in group {
                if let result {
                    errors.append(result)
                }
            }
        }

        isSearchingAll = false

        if errors.isEmpty {
            InAppNotificationCenter.shared.showSuccess(
                title: "Search Queued",
                message: successMessageForAllMissingSearch
            )
        } else {
            InAppNotificationCenter.shared.showError(
                title: "Search Failed",
                message: errors.joined(separator: "\n")
            )
        }
    }

    // MARK: - Data

    private func initializeIfNeeded() async {
        if serviceManager.sonarrConnected, sonarrViewModel == nil {
            sonarrViewModel = SonarrViewModel(serviceManager: serviceManager)
        }
        if serviceManager.radarrConnected, radarrViewModel == nil {
            radarrViewModel = RadarrViewModel(serviceManager: serviceManager)
        }
        if !serviceManager.sonarrConnected { sonarrViewModel = nil }
        if !serviceManager.radarrConnected { radarrViewModel = nil }
    }

    private func reloadWantedMissing() async {
        await withTaskGroup(of: Void.self) { group in
            if let sonarrViewModel {
                group.addTask { await sonarrViewModel.loadWantedMissing() }
            }
            if let radarrViewModel {
                group.addTask { await radarrViewModel.loadWantedMissing() }
            }
        }
    }

    private var successMessageForAllMissingSearch: String {
        switch scope {
        case .all:
            return "Searches sent for all missing series and movies."
        case .series:
            return "Searches sent for all missing series."
        case .movies:
            return "Searches sent for all missing movies."
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.15), Color.clear],
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

    @ViewBuilder
    private func loadMoreLabel(isLoading: Bool) -> some View {
        HStack {
            Spacer()
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text("Load More")
            }
            Spacer()
        }
    }
}

// MARK: - Scope

enum ArrWantedScope: CaseIterable, Hashable {
    case all
    case series
    case movies

    var title: String {
        switch self {
        case .all:    "All"
        case .series: "Series"
        case .movies: "Movies"
        }
    }
}

// MARK: - Row views

private struct WantedEpisodeRow: View {
    let episode: SonarrEpisode
    let onSearch: () async -> Void

    @State private var isSearching = false

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

            if isSearching {
                ProgressView().controlSize(.small)
            } else {
                Button("Search", systemImage: "magnifyingglass") {
                    Task {
                        isSearching = true
                        async let search: Void = onSearch()
                        async let minDelay: Void = { try? await Task.sleep(for: .seconds(1.5)) }()
                        _ = await (search, minDelay)
                        isSearching = false
                    }
                }
                .labelStyle(.iconOnly)
            }
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
    let onSearch: () async -> Void

    @State private var isSearching = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(movie.title)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    if let year = movie.year { Text(String(year)) }
                    Text(movie.displayStatus)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isSearching {
                ProgressView().controlSize(.small)
            } else {
                Button("Search", systemImage: "magnifyingglass") {
                    Task {
                        isSearching = true
                        await onSearch()
                        isSearching = false
                    }
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(.vertical, 4)
    }
}
