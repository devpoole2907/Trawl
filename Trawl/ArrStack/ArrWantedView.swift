import SwiftUI

struct ArrWantedView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(\.dismiss) private var dismiss

    @State private var sonarrViewModel: SonarrViewModel?
    @State private var radarrViewModel: RadarrViewModel?
    @State private var bazarrViewModel: BazarrViewModel?
    @State private var scope: ArrWantedScope

    @State private var showSearchAllConfirm = false
    @State private var isSearchingAll = false

    let showsCloseButton: Bool

    init(initialScope: ArrWantedScope = .all, showsCloseButton: Bool = false) {
        _scope = State(initialValue: initialScope)
        self.showsCloseButton = showsCloseButton
    }

    private var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance || serviceManager.hasBazarrInstance
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected || serviceManager.hasAnyConnectedBazarrInstance
    }

    private var isLoading: Bool {
        sonarrViewModel?.isLoadingWantedMissing == true ||
        radarrViewModel?.isLoadingWantedMissing == true ||
        bazarrViewModel?.isLoadingSeries == true ||
        bazarrViewModel?.isLoadingMovies == true
    }

    private var hasError: Bool {
        (sonarrViewModel?.error?.isEmpty == false) ||
        (radarrViewModel?.error?.isEmpty == false) ||
        (bazarrViewModel?.seriesError?.isEmpty == false) ||
        (bazarrViewModel?.moviesError?.isEmpty == false)
    }

    private var errorDescription: String {
        var errors: [String] = []
        if let sonarrError = sonarrViewModel?.error, !sonarrError.isEmpty {
            errors.append("Sonarr: \(sonarrError)")
        }
        if let radarrError = radarrViewModel?.error, !radarrError.isEmpty {
            errors.append("Radarr: \(radarrError)")
        }
        if let seriesError = bazarrViewModel?.seriesError, !seriesError.isEmpty {
            errors.append("Bazarr series: \(seriesError)")
        }
        if let moviesError = bazarrViewModel?.moviesError, !moviesError.isEmpty {
            errors.append("Bazarr movies: \(moviesError)")
        }
        return errors.isEmpty ? "An error occurred loading wanted items." : errors.joined(separator: "\n")
    }

    private var canSearchAllMissing: Bool {
        switch scope {
        case .all:
            return sonarrViewModel?.isConnected == true ||
                radarrViewModel?.isConnected == true ||
                bazarrViewModel?.isConnected == true
        case .series:
            return sonarrViewModel?.isConnected == true
        case .movies:
            return radarrViewModel?.isConnected == true
        case .subtitles:
            return bazarrViewModel?.isConnected == true
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
        case .subtitles:
            return "This will trigger a Bazarr search for all missing subtitles."
        }
    }

    var body: some View {
        Group {
            if !hasConfiguredService {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "server.rack",
                    description: Text("Connect Sonarr, Radarr, or Bazarr to view monitored items with missing files or subtitles.")
                )
            } else if !hasConnectedService {
                ContentUnavailableView(
                    "Services Unreachable",
                    systemImage: "network.slash",
                    description: Text("Unable to reach your configured Sonarr, Radarr, or Bazarr servers.")
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
                    description: Text("There are no monitored files or subtitles missing right now.")
                )
            } else {
                List {
                    if scope.includesSeries, let sonarrViewModel, !sonarrViewModel.wantedEpisodes.isEmpty {
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

                    if scope.includesMovies, let radarrViewModel, !radarrViewModel.wantedMovies.isEmpty {
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

                    if scope.includesSubtitles, let bazarrViewModel {
                        let missingSeries = bazarrViewModel.filteredSeries.filter { $0.episodeMissingCount > 0 }
                        let missingMovies = bazarrViewModel.filteredMovies.filter { !$0.missingSubtitles.isEmpty }

                        if !missingSeries.isEmpty {
                            Section("Subtitle Gaps - Series") {
                                ForEach(missingSeries) { series in
                                    BazarrWantedSeriesRow(series: series) {
                                        await searchBazarrSeries(series, in: bazarrViewModel)
                                    }
                                }
                            }
                        }

                        if !missingMovies.isEmpty {
                            Section("Subtitle Gaps - Movies") {
                                ForEach(missingMovies) { movie in
                                    BazarrWantedMovieRow(movie: movie) {
                                        await searchBazarrMovie(movie, in: bazarrViewModel)
                                    }
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
            if showsCloseButton {
                ToolbarItem(placement: platformCancellationPlacement) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
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
        let bazarrSeriesIsEmpty = bazarrViewModel?.filteredSeries.filter { $0.episodeMissingCount > 0 }.isEmpty ?? true
        let bazarrMoviesIsEmpty = bazarrViewModel?.filteredMovies.filter { !$0.missingSubtitles.isEmpty }.isEmpty ?? true
        let bazarrIsEmpty = bazarrSeriesIsEmpty && bazarrMoviesIsEmpty

        switch scope {
        case .all:    return sonarrIsEmpty && radarrIsEmpty && bazarrIsEmpty
        case .series: return sonarrIsEmpty
        case .movies: return radarrIsEmpty
        case .subtitles: return bazarrIsEmpty
        }
    }

    private var reloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)-\(serviceManager.hasAnyConnectedBazarrInstance)-\(serviceManager.activeBazarrProfileID?.uuidString ?? "none")"
    }

    // MARK: - Actions

    private func searchEpisode(_ episode: SonarrEpisode, in vm: SonarrViewModel) async {
        await vm.searchEpisode(episode)
    }

    private func searchMovie(_ movie: RadarrMovie, in vm: RadarrViewModel) async {
        await vm.searchMovie(movieId: movie.id)
    }

    private func searchBazarrSeries(_ series: BazarrSeries, in vm: BazarrViewModel) async {
        do {
            try await vm.runSeriesAction(.searchMissing, seriesId: series.sonarrSeriesId)
            InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(series.title) was sent to Bazarr.")
        } catch {
            InAppNotificationCenter.shared.showError(title: "Subtitle Search Failed", message: error.localizedDescription)
        }
    }

    private func searchBazarrMovie(_ movie: BazarrMovie, in vm: BazarrViewModel) async {
        do {
            try await vm.runMovieAction(.searchMissing, radarrId: movie.radarrId)
            InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(movie.title) was sent to Bazarr.")
        } catch {
            InAppNotificationCenter.shared.showError(title: "Subtitle Search Failed", message: error.localizedDescription)
        }
    }

    private func searchAllMissing() async {
        guard !isSearchingAll else { return }
        isSearchingAll = true
        defer { isSearchingAll = false }
        var errors: [String] = []
        let sonarrCanSearch = sonarrViewModel?.isConnected == true
        let radarrCanSearch = radarrViewModel?.isConnected == true
        let bazarrCanSearch = bazarrViewModel?.isConnected == true

        await withTaskGroup(of: String?.self) { group in
            if scope.includesSeries, let sonarrViewModel, sonarrCanSearch {
                group.addTask {
                    do {
                        try await sonarrViewModel.searchAllMissing()
                        return nil
                    } catch {
                        return "Sonarr: \(error.localizedDescription)"
                    }
                }
            }
            if scope.includesMovies, let radarrViewModel, radarrCanSearch {
                group.addTask {
                    do {
                        try await radarrViewModel.searchAllMissing()
                        return nil
                    } catch {
                        return "Radarr: \(error.localizedDescription)"
                    }
                }
            }
            if scope.includesSubtitles, let bazarrViewModel, bazarrCanSearch {
                let missingSeries = bazarrViewModel.filteredSeries.filter { $0.episodeMissingCount > 0 }
                let missingMovies = bazarrViewModel.filteredMovies.filter { !$0.missingSubtitles.isEmpty }
                group.addTask {
                    for series in missingSeries {
                        do {
                            try await bazarrViewModel.runSeriesAction(.searchMissing, seriesId: series.sonarrSeriesId)
                        } catch {
                            return "Bazarr \(series.title): \(error.localizedDescription)"
                        }
                    }
                    for movie in missingMovies {
                        do {
                            try await bazarrViewModel.runMovieAction(.searchMissing, radarrId: movie.radarrId)
                        } catch {
                            return "Bazarr \(movie.title): \(error.localizedDescription)"
                        }
                    }
                    return nil
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
        if serviceManager.hasAnyConnectedBazarrInstance, bazarrViewModel == nil {
            bazarrViewModel = BazarrViewModel(serviceManager: serviceManager)
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
            if let bazarrViewModel, bazarrViewModel.isConnected {
                group.addTask {
                    await bazarrViewModel.loadSeries()
                    await bazarrViewModel.loadMovies()
                }
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
        case .subtitles:
            return "Searches sent for missing subtitles."
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
    case subtitles

    var title: String {
        switch self {
        case .all:    "All"
        case .series: "Series"
        case .movies: "Movies"
        case .subtitles: "Subtitles"
        }
    }

    var includesSeries: Bool {
        self == .all || self == .series
    }

    var includesMovies: Bool {
        self == .all || self == .movies
    }

    var includesSubtitles: Bool {
        self == .all || self == .subtitles
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

                if let subtitle = movie.originalTitle,
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

private struct BazarrWantedSeriesRow: View {
    let series: BazarrSeries
    let onSearch: () async -> Void

    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var isSearching = false

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink {
                BazarrSeriesDetailView(seriesId: series.sonarrSeriesId, viewModel: BazarrViewModel(serviceManager: serviceManager))
            } label: {
                HStack(spacing: 12) {
                    ArrArtworkView(url: series.poster.flatMap(URL.init(string:))) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                            Image(systemName: "captions.bubble")
                                .font(.system(size: 14))
                                .foregroundStyle(.teal)
                        }
                    }
                    .frame(width: 46, height: 69)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(series.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            wantedStatusChip("\(series.episodeMissingCount) missing", color: .teal)
                            wantedStatusChip("\(series.episodeFileCount) files", color: .secondary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            searchButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var searchButton: some View {
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
}

private struct BazarrWantedMovieRow: View {
    let movie: BazarrMovie
    let onSearch: () async -> Void

    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var isSearching = false

    var body: some View {
        NavigationLink {
            BazarrMovieDetailView(radarrId: movie.radarrId, viewModel: BazarrViewModel(serviceManager: serviceManager))
        } label: {
            HStack(spacing: 12) {
                ArrArtworkView(url: movie.poster.flatMap(URL.init(string:))) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 14))
                            .foregroundStyle(.teal)
                    }
                }
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    Text(movie.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        wantedStatusChip("\(movie.missingSubtitles.count) missing", color: .teal)
                        if let year = movie.year {
                            wantedStatusChip(year, color: .secondary)
                        }
                    }
                }

                Spacer()

                searchButton
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var searchButton: some View {
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
}

private func wantedStatusChip(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
}
ome View {
    Text(text)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
}
le())
}
