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
        (sonarrViewModel?.error?.isEmpty == false) ||
        (radarrViewModel?.error?.isEmpty == false)
    }

    private var errorDescription: String {
        var errors: [String] = []
        if let sonarrError = sonarrViewModel?.error, !sonarrError.isEmpty {
            errors.append("Sonarr: \(sonarrError)")
        }
        if let radarrError = radarrViewModel?.error, !radarrError.isEmpty {
            errors.append("Radarr: \(radarrError)")
        }
        return errors.isEmpty ? "An error occurred loading wanted items." : errors.joined(separator: "\n")
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
            } else if isEmpty && hasError {
                ContentUnavailableView(
                    "Load Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorDescription)
                )
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
    }

    private func searchMovie(_ movie: RadarrMovie, in vm: RadarrViewModel) async {
        await vm.searchMovie(movieId: movie.id)
    }

    private func searchAllMissing() async {
        guard !isSearchingAll else { return }
        isSearchingAll = true
        defer { isSearchingAll = false }
        var errors: [String] = []
        let sonarrCanSearch = sonarrViewModel?.isConnected == true
        let radarrCanSearch = radarrViewModel?.isConnected == true

        await withTaskGroup(of: String?.self) { group in
            if let sonarrViewModel, sonarrCanSearch {
                group.addTask {
                    do {
                        try await sonarrViewModel.searchAllMissing()
                        return nil
                    } catch {
                        return "Sonarr: \(error.localizedDescription)"
                    }
                }
            }
            if let radarrViewModel, radarrCanSearch {
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
                if Task.isCancelled { break }
                if let result {
                    errors.append(result)
                }
            }
        }

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
        // Keep ViewModels alive to preserve pagination state
        // Connection state is checked via VM's isConnected property
    }

    private func reloadWantedMissing() async {
        await withTaskGroup(of: Void.self) { group in
            if let sonarrViewModel, sonarrViewModel.isConnected {
                group.addTask { await sonarrViewModel.loadWantedMissing() }
            }
            if let radarrViewModel, radarrViewModel.isConnected {
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
            ArrArtworkView(url: episode.series?.posterURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    Image(systemName: "tv")
                        .font(.system(size: 14))
                        .foregroundStyle(.purple)
                }
            }
            .frame(width: 46, height: 69)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.series?.title ?? "Unknown Series")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let title = episode.title, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    wantedStatusChip(episode.episodeIdentifier, color: .purple)
                    wantedStatusChip(formatDate(episode.airDate), color: .secondary)
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
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func formatDate(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "TBA" }
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
            ArrArtworkView(url: movie.posterURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    Image(systemName: "film")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 46, height: 69)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if let subtitle = movie.sortTitle ?? movie.originalTitle,
                   subtitle != movie.title {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let year = movie.year {
                        wantedStatusChip(String(year), color: .secondary)
                    }
                    wantedStatusChip(movie.displayStatus, color: .orange)
                }
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
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private func wantedStatusChip(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
}
