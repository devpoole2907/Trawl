import SwiftUI

// MARK: - Add to Library Sheet

struct SonarrAddToLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries
    let onAdded: () async -> Void

    @State private var selectedQualityProfileId: Int?
    @State private var selectedRootFolderPath: String?
    @State private var searchForMissing = true
    @State private var isAdding = false
    @State private var seasonMonitored: [Int: Bool] = [:]

    private var seasons: [SonarrSeason] {
        (series.seasons ?? []).sorted { $0.seasonNumber < $1.seasonNumber }
    }

    var body: some View {
        AppSheetShell(
            title: "Add to Sonarr",
            confirmTitle: "Add",
            isConfirmDisabled: !canAdd,
            isConfirmLoading: isAdding,
            onConfirm: { Task { await addSeries() } },
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ArrArtworkView(url: series.posterURL) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.blue.opacity(0.3))
                                .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
                        }
                        .frame(width: 52, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(series.title)
                                .font(.headline)
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                if let network = series.network { Text(network) }
                                if series.network != nil && series.year != nil { Text("·") }
                                if let year = series.year { Text(String(year)) }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Library Settings") {
                    Picker("Quality Profile", selection: $selectedQualityProfileId) {
                        ForEach(viewModel.qualityProfiles, id: \.id) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }

                    Picker("Root Folder", selection: $selectedRootFolderPath) {
                        ForEach(viewModel.rootFolders, id: \.path) { folder in
                            HStack {
                                Text(folder.path)
                                Spacer()
                                if let free = folder.freeSpace, free > 0 {
                                    Text("\(ByteFormatter.format(bytes: free)) free")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(Optional(folder.path))
                        }
                    }

                    Toggle("Search Immediately", isOn: $searchForMissing)
                }

                if !seasons.isEmpty {
                    Section("Seasons") {
                        ForEach(seasons, id: \.seasonNumber) { season in
                            Toggle(
                                season.seasonNumber == 0 ? "Specials" : "Season \(season.seasonNumber)",
                                isOn: seasonBinding(for: season.seasonNumber, default: season.monitored ?? true)
                            )
                        }
                    }
                }

                if let error = viewModel.error, !error.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .task {
                await refreshConfigurationAndDefaults()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func seasonBinding(for seasonNumber: Int, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { seasonMonitored[seasonNumber] ?? defaultValue },
            set: { seasonMonitored[seasonNumber] = $0 }
        )
    }

    private func refreshConfigurationAndDefaults() async {
        await viewModel.refreshConfiguration()
        if selectedQualityProfileId == nil {
            selectedQualityProfileId = viewModel.qualityProfiles.first?.id
        }
        if selectedRootFolderPath == nil {
            selectedRootFolderPath = viewModel.rootFolders.first?.path
        }
    }

    private var resolvedSeasons: [SonarrSeason] {
        seasons.map { season in
            let monitored = seasonMonitored[season.seasonNumber] ?? season.monitored ?? true
            return SonarrSeason(seasonNumber: season.seasonNumber, monitored: monitored, statistics: season.statistics)
        }
    }

    private var canAdd: Bool {
        !isAdding &&
        selectedQualityProfileId != nil &&
        selectedRootFolderPath != nil &&
        series.tvdbId != nil &&
        series.titleSlug != nil
    }

    private func addSeries() async {
        guard !isAdding else { return }
        guard let tvdbId = series.tvdbId,
              let titleSlug = series.titleSlug,
              let qualityProfileId = selectedQualityProfileId,
              let rootFolderPath = selectedRootFolderPath else { return }

        isAdding = true
        defer { isAdding = false }

        let success = await viewModel.addSeries(
            tvdbId: tvdbId,
            title: series.title,
            titleSlug: titleSlug,
            images: series.images ?? [],
            seasons: resolvedSeasons,
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath,
            monitorOption: "none",
            searchForMissing: searchForMissing
        )

        if success {
            await onAdded()
            dismiss()
        }
    }
}

struct SonarrInteractiveSearchSheet: View {
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries
    let episode: SonarrEpisode?
    let seasonNumber: Int?

    init(viewModel: SonarrViewModel, series: SonarrSeries, episode: SonarrEpisode? = nil, seasonNumber: Int? = nil) {
        self.viewModel = viewModel
        self.series = series
        self.episode = episode
        self.seasonNumber = seasonNumber
    }

    private var initialSort: ArrReleaseSort {
        var sort = ArrReleaseSort()
        sort.seasonPack = episode != nil ? .episode : .season
        return sort
    }

    private var titleString: String {
        if let episode {
            "\(series.title) · \(episode.episodeIdentifier)"
        } else if let seasonNumber {
            "\(series.title) · Season \(seasonNumber)"
        } else {
            series.title
        }
    }

    var body: some View {
        ArrInteractiveSearchBrowser(
            title: titleString,
            emptyDescription: "Sonarr didn't return any manual search results.",
            loadingDescription: "Results will appear here as soon as Sonarr returns them.",
            supportsSeasonPackFiltering: true,
            initialSort: initialSort,
            loadAction: {
                try await viewModel.interactiveSearch(
                    episodeId: episode?.id,
                    seriesId: series.id,
                    seasonNumber: seasonNumber
                )
            },
            grabAction: { release in
                await viewModel.grabRelease(release)
            },
            currentErrorMessage: {
                viewModel.error
            }
        ) { release, isGrabbing, onGrab in
            ArrReleaseActionContent(
                release: release,
                artURL: series.posterURL ?? series.fanartURL,
                accentColor: .purple,
                isGrabbing: isGrabbing,
                onGrab: onGrab
            )
        }
    }
}

struct SonarrSeasonSearchView: View {
    private struct AutomaticSearchFeedback: Equatable {
        enum Kind {
            case searching
            case found
            case noResults
        }

        let kind: Kind
        let message: String

        var title: String {
            switch kind {
            case .searching: "Searching"
            case .found: "Result Found"
            case .noResults: "No Results Seen"
            }
        }

        var icon: String {
            switch kind {
            case .searching: "magnifyingglass.circle.fill"
            case .found: "checkmark.circle.fill"
            case .noResults: "exclamationmark.circle.fill"
            }
        }

        var tint: Color {
            switch kind {
            case .searching: .blue
            case .found: .green
            case .noResults: .orange
            }
        }
    }

    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries?
    let seasonNumber: Int
    private let initialEpisodes: [SonarrEpisode]
    private let initialBazarrEpisodes: [BazarrEpisode]
    private let bazarrClient: BazarrAPIClient?
    private let onBazarrEpisodesUpdated: ([BazarrEpisode]) -> Void

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var isDispatchingBazarrSearch = false
    @State private var bazarrInteractiveSearchTarget: BazarrEpisode?
    @State private var refreshedBazarrEpisodes: [BazarrEpisode]?

    @State private var isDispatchingAutomaticSearch = false
    @State private var showInteractiveSearchSheet = false
    @State private var automaticSearchFeedback: AutomaticSearchFeedback?
    @State private var automaticSearchMonitorTask: Task<Void, Never>?

    init(
        viewModel: SonarrViewModel,
        series: SonarrSeries?,
        seasonNumber: Int,
        episodes: [SonarrEpisode],
        bazarrEpisodes: [BazarrEpisode] = [],
        bazarrClient: BazarrAPIClient? = nil,
        onBazarrEpisodesUpdated: @escaping ([BazarrEpisode]) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.series = series
        self.seasonNumber = seasonNumber
        self.initialEpisodes = episodes
        self.initialBazarrEpisodes = bazarrEpisodes
        self.bazarrClient = bazarrClient
        self.onBazarrEpisodesUpdated = onBazarrEpisodesUpdated
    }

    private var title: String {
        seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    }

    private var seriesId: Int? {
        series?.id ?? initialEpisodes.first?.seriesId
    }

    private var sortedEpisodes: [SonarrEpisode] {
        let latestEpisodes = seriesId.flatMap { viewModel.episodes[$0] } ?? []
        let source = latestEpisodes.isEmpty ? initialEpisodes : latestEpisodes
        return source
            .filter { $0.seasonNumber == seasonNumber }
            .sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private var activeBazarrEpisodes: [BazarrEpisode] {
        refreshedBazarrEpisodes ?? initialBazarrEpisodes
    }

    private var missingBazarrEpisodes: [BazarrEpisode] {
        activeBazarrEpisodes.filter { !$0.missingSubtitles.isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 20) {
                seasonSearchHero

                VStack(spacing: 14) {
                    automaticSearchSection
                    interactiveSearchButton
                }

                if !missingBazarrEpisodes.isEmpty {
                    VStack(spacing: 14) {
                        bazarrAutomaticSearchButton(missingBazarrEpisodes)
                        bazarrInteractiveSearchButton(missingBazarrEpisodes)
                    }
                }

                seasonSearchInfoCard(title: "Episodes", icon: "list.bullet") {
                    episodesCardContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 44)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background {
            ArrArtworkView(url: series?.posterURL ?? series?.fanartURL, contentMode: .fill) {
                Rectangle().fill(Color.purple.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .saturation(1.6)
            .overlay(Color.black.opacity(0.55))
            .ignoresSafeArea()
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: episodesAnimationValue)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: queueAnimationValue)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: automaticSearchFeedback)
        .sheet(isPresented: $showInteractiveSearchSheet) {
            if let series {
                SonarrInteractiveSearchSheet(viewModel: viewModel, series: series, seasonNumber: seasonNumber)
            }
        }
        .sheet(item: $bazarrInteractiveSearchTarget) { bEp in
            BazarrInteractiveSearchSheet(
                seriesId: bEp.sonarrSeriesId,
                episode: bEp,
                client: bazarrClient,
                viewModel: BazarrViewModel(serviceManager: serviceManager),
                onDownloaded: {
                    await refreshBazarrSeasonEpisodes(seriesId: bEp.sonarrSeriesId, client: bazarrClient)
                }
            )
        }
        .onDisappear {
            automaticSearchMonitorTask?.cancel()
        }
        .task(id: seriesId) {
            await monitorSeasonState()
        }
    }

    private var episodesAnimationValue: [String] {
        sortedEpisodes.map { "\($0.id)-\($0.hasFile == true)" }
    }

    private var queueAnimationValue: [String] {
        viewModel.queue.map { "\($0.id)-\($0.normalizedState)-\($0.progress)" }
    }

    @ViewBuilder
    private var rowsContent: some View {
        let lastId = sortedEpisodes.last?.id
        ForEach(sortedEpisodes) { episode in
            SonarrSeasonEpisodeRow(
                viewModel: viewModel,
                series: series,
                episode: episode,
                bazarrEpisodes: activeBazarrEpisodes,
                bazarrClient: bazarrClient,
                isLast: episode.id == lastId,
                formattedDate: formattedDate,
                onBazarrEpisodeUpdated: updateBazarrEpisode
            )
        }
    }

    private func refreshBazarrSeasonEpisodes(seriesId: Int, client: BazarrAPIClient?) async {
        guard let client else { return }
        do {
            let latestEpisodes = try await client.getEpisodes(seriesIds: [seriesId])
            let seasonEpisodes = latestEpisodes.filter { $0.season == seasonNumber }
            await MainActor.run {
                refreshedBazarrEpisodes = seasonEpisodes
                onBazarrEpisodesUpdated(seasonEpisodes)
                if let target = bazarrInteractiveSearchTarget {
                    bazarrInteractiveSearchTarget = seasonEpisodes.first { $0.sonarrEpisodeId == target.sonarrEpisodeId }
                }
            }
        } catch {
            InAppNotificationCenter.shared.showError(title: "Refresh Failed", message: error.localizedDescription)
        }
    }

    private func updateBazarrEpisode(_ episode: BazarrEpisode?) {
        var seasonEpisodes = activeBazarrEpisodes
        if let episode {
            seasonEpisodes.removeAll { $0.sonarrEpisodeId == episode.sonarrEpisodeId }
            seasonEpisodes.append(episode)
            seasonEpisodes.sort { $0.episode < $1.episode }
        }
        refreshedBazarrEpisodes = seasonEpisodes
        onBazarrEpisodesUpdated(seasonEpisodes)
    }

    private func refreshSeasonState() async {
        guard let seriesId else { return }
        await viewModel.loadQueue()
        await viewModel.loadEpisodes(for: seriesId)
        await viewModel.loadEpisodeFiles(for: seriesId)
        await viewModel.loadSeries()
    }

    private func monitorSeasonState() async {
        guard let seriesId else { return }
        var knownQueueIDs = Set<Int>()
        var hadRelevantQueueItems = false

        do {
            while true {
                try Task.checkCancellation()

                await viewModel.loadQueue()
                try Task.checkCancellation()

                let episodeIDs = Set(sortedEpisodes.map(\.id))
                let relevantQueueItems = viewModel.queue.filter { item in
                    guard let episodeId = item.episodeId else { return false }
                    return episodeIDs.contains(episodeId)
                }
                let currentQueueIDs = Set(relevantQueueItems.map(\.id))
                let hasRelevantQueueItems = !relevantQueueItems.isEmpty

                await viewModel.loadEpisodes(for: seriesId)
                try Task.checkCancellation()
                await viewModel.loadEpisodeFiles(for: seriesId)
                try Task.checkCancellation()

                if currentQueueIDs != knownQueueIDs || hasRelevantQueueItems || hadRelevantQueueItems {
                    await viewModel.loadSeries()
                    try Task.checkCancellation()
                }

                knownQueueIDs = currentQueueIDs
                hadRelevantQueueItems = hasRelevantQueueItems

                try await Task.sleep(for: .seconds(hasRelevantQueueItems ? 2 : 15))
            }
        } catch is CancellationError {
            // Task was cancelled because navigation moved away from this season.
        } catch {
            // Ignore transient refresh failures; the next loop can recover.
        }
    }

    @ViewBuilder
    private var episodesCardContent: some View {
        if sortedEpisodes.isEmpty {
            ContentUnavailableView(
                "No Episodes",
                systemImage: "tv.slash",
                description: Text("This season does not have any loaded episodes yet.")
            )
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                rowsContent
            }
        }
    }

    private func bazarrAutomaticSearchButton(_ missingEps: [BazarrEpisode]) -> some View {
        Button {
            guard !isDispatchingBazarrSearch, let first = missingEps.first else { return }
            isDispatchingBazarrSearch = true
            Task {
                if let client = bazarrClient {
                    do {
                        try await client.runSeriesAction(seriesId: first.sonarrSeriesId, action: .searchMissing)
                        InAppNotificationCenter.shared.showSuccess(title: "Search Queued", message: "Bazarr is searching for subtitles.")
                    } catch {
                        InAppNotificationCenter.shared.showError(title: "Search Failed", message: error.localizedDescription)
                    }
                }
                isDispatchingBazarrSearch = false
            }
        } label: {
            seasonSearchActionRow(
                title: "Queue Series Subtitle Search",
                subtitle: "Queue Bazarr's series-wide missing subtitle search.",
                systemImage: ServiceIdentity.bazarr.systemImage,
                isLoading: isDispatchingBazarrSearch,
                accentColor: ServiceIdentity.bazarr.brandColor
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func bazarrInteractiveSearchButton(_ missingEps: [BazarrEpisode]) -> some View {
        Button {
            bazarrInteractiveSearchTarget = missingEps.first
        } label: {
            seasonSearchActionRow(
                title: "Interactive Subtitle Search",
                subtitle: "Open interactive search for a missing episode.",
                systemImage: "person.fill",
                trailingSystemImage: "arrow.up.forward.square",
                accentColor: .teal
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private static let waterfallDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func formattedDate(_ string: String?) -> String {
        guard let string, !string.isEmpty else { return "TBA" }
        guard let date = Self.waterfallDateFormatter.date(from: string) else { return string }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var seasonSearchHero: some View {
        VStack(spacing: 14) {
            ArrArtworkView(url: series?.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.purple.opacity(0.3))
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: hSizeClass == .regular ? 220 : 160, height: hSizeClass == .regular ? 330 : 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(series?.title ?? "Series")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var automaticSearchButton: some View {
        Button {
            guard !isDispatchingAutomaticSearch, let seriesId = series?.id else { return }
            isDispatchingAutomaticSearch = true
            // Set feedback immediately so the info card replaces this button before the Task runs,
            // ensuring the interactive search button is never visually affected by a loading state.
            withAnimation(.snappy) {
                automaticSearchFeedback = AutomaticSearchFeedback(
                    kind: .searching,
                    message: "Sonarr is searching indexers for monitored episodes in \(title)."
                )
            }
            Task {
                let episodeIDs = Set(sortedEpisodes.map(\.id))
                let baselineQueueIDs = Set(viewModel.queue.filter { item in
                    guard let episodeId = item.episodeId else { return false }
                    return episodeIDs.contains(episodeId)
                }.map(\.id))

                let didStart = await viewModel.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
                isDispatchingAutomaticSearch = false

                if !didStart {
                    withAnimation(.snappy) { automaticSearchFeedback = nil }
                    let message = viewModel.error ?? "Could not start search."
                    InAppNotificationCenter.shared.showError(title: "Search Failed", message: message)
                } else {
                    InAppNotificationCenter.shared.showSuccess(
                        title: "Search Queued",
                        message: "\(title) was sent to Sonarr for automatic search."
                    )

                    automaticSearchMonitorTask?.cancel()
                    automaticSearchMonitorTask = Task {
                        for _ in 0..<6 {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            await refreshSeasonState()

                            let currentQueueIDs = Set(viewModel.queue.filter { item in
                                guard let episodeId = item.episodeId else { return false }
                                return episodeIDs.contains(episodeId)
                            }.map(\.id))
                            if !currentQueueIDs.subtracting(baselineQueueIDs).isEmpty {
                                await MainActor.run {
                                    withAnimation(.snappy) {
                                        automaticSearchFeedback = AutomaticSearchFeedback(
                                            kind: .found,
                                            message: "A result was queued in Sonarr. Check this season's episodes or queue status for progress."
                                        )
                                    }
                                }
                                return
                            }
                        }

                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(.snappy) {
                                automaticSearchFeedback = AutomaticSearchFeedback(
                                    kind: .noResults,
                                    message: "No queued result showed up for this automatic search. Try Interactive Search if you want to inspect releases manually."
                                )
                            }
                        }
                    }
                }
            }
        } label: {
            seasonSearchActionRow(
                title: "Automatic Search",
                subtitle: "Let Sonarr search indexers for every monitored episode in this season.",
                systemImage: "magnifyingglass",
                isLoading: isDispatchingAutomaticSearch
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var automaticSearchSection: some View {
        if let automaticSearchFeedback {
            seasonSearchInfoCard(title: automaticSearchFeedback.title, icon: automaticSearchFeedback.icon) {
                Text(automaticSearchFeedback.message)
                    .font(.subheadline)
                    .foregroundStyle(automaticSearchFeedback.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            automaticSearchButton
                .frame(maxWidth: .infinity)
        }
    }

    private var interactiveSearchButton: some View {
        Button {
            showInteractiveSearchSheet = true
        } label: {
            seasonSearchActionRow(
                title: "Interactive Search",
                subtitle: "Browse releases episode-by-episode in a manual search sheet.",
                systemImage: "person.fill",
                trailingSystemImage: "arrow.up.forward.square"
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(series == nil || sortedEpisodes.isEmpty)
    }

    private func seasonSearchActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right",
        accentColor: Color = .purple
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(12)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func seasonSearchInfoCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.white)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SonarrSeasonEpisodeRow: View {
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries?
    let episode: SonarrEpisode
    let bazarrEpisodes: [BazarrEpisode]
    let bazarrClient: BazarrAPIClient?
    let isLast: Bool
    let formattedDate: (String?) -> String
    let onBazarrEpisodeUpdated: (BazarrEpisode?) -> Void

    private var queueItem: ArrQueueItem? {
        viewModel.queue.first { $0.episodeId == episode.id }
    }

    private var bazarrEpisode: BazarrEpisode? {
        bazarrEpisodes.first { $0.sonarrEpisodeId == episode.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                SonarrEpisodeSearchView(
                    viewModel: viewModel,
                    series: series,
                    episode: episode,
                    bazarrEpisode: bazarrEpisode,
                    bazarrClient: bazarrClient,
                    onBazarrEpisodeUpdated: onBazarrEpisodeUpdated
                )
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(episode.episodeIdentifier)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(formattedDate(episode.airDate))
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.8))
                        }

                        Text(episode.title ?? "Untitled Episode")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    if let q = queueItem {
                        if q.isImportIssueQueueItem {
                            Text("Import Issue")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.2))
                                .clipShape(Capsule())
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.orange)
                                        .offset(x: 3, y: -3)
                                }
                        } else {
                            episodeQueueProgressIndicator(q)
                        }
                    } else if episode.hasFile == true {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            if let bEp = bazarrEpisode {
                                Image(systemName: "captions.bubble.fill")
                                    .foregroundStyle(bEp.missingSubtitles.isEmpty ? .teal : .secondary)
                                    .font(.caption)
                            }
                        }
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider().padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private func episodeQueueProgressIndicator(_ item: ArrQueueItem) -> some View {
        HStack(spacing: 6) {
            if item.progress > 0 {
                ProgressView(value: item.progress)
                    .progressViewStyle(.circular)
                    .tint(.purple)
                    .frame(width: 18, height: 18)
                Text("\(Int((item.progress * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.purple)
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, item.progress > 0 ? 8 : 6)
        .padding(.vertical, 4)
        .background(Color.purple.opacity(0.18))
        .clipShape(Capsule())
        .accessibilityLabel(item.status?.capitalized ?? "Downloading")
    }
}

struct SonarrEpisodeSearchView: View {
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries?
    let episode: SonarrEpisode
    private let initialBazarrEpisode: BazarrEpisode?
    private let bazarrClient: BazarrAPIClient?
    private let onBazarrEpisodeUpdated: (BazarrEpisode?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private static let waterfallDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    @Environment(SyncService.self) private var syncService

    @State private var isDispatchingAutomaticSearch = false
    @State private var showInteractiveSearchSheet = false
    @State private var episodeFileToDelete: SonarrEpisodeFile?
    @State private var showDeleteFileAlert = false
    @State private var isTogglingMonitored = false

    @State private var isDispatchingBazarrSearch = false
    @State private var showBazarrInteractiveSearchSheet = false
    @State private var refreshedBazarrEpisode: BazarrEpisode??

    init(
        viewModel: SonarrViewModel,
        series: SonarrSeries?,
        episode: SonarrEpisode,
        bazarrEpisode: BazarrEpisode? = nil,
        bazarrClient: BazarrAPIClient? = nil,
        onBazarrEpisodeUpdated: @escaping (BazarrEpisode?) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.series = series
        self.episode = episode
        self.initialBazarrEpisode = bazarrEpisode
        self.bazarrClient = bazarrClient
        self.onBazarrEpisodeUpdated = onBazarrEpisodeUpdated
    }

    private var episodeHistory: [ArrHistoryRecord] {
        viewModel.history
            .filter { $0.episodeId == currentEpisode.id }
            .sorted {
                SonarrEpisodeHistoryDateParser.parse($0.date) ?? .distantPast >
                SonarrEpisodeHistoryDateParser.parse($1.date) ?? .distantPast
            }
    }

    private var seriesId: Int? {
        series?.id ?? episode.seriesId
    }

    private var currentEpisode: SonarrEpisode {
        guard let seriesId,
              let latestEpisode = viewModel.episodes[seriesId]?.first(where: { $0.id == episode.id }) else {
            return episode
        }
        return latestEpisode
    }

    private var queueItem: ArrQueueItem? {
        viewModel.queue.first { $0.episodeId == currentEpisode.id }
    }

    private var activeBazarrEpisode: BazarrEpisode? {
        refreshedBazarrEpisode ?? initialBazarrEpisode
    }

    private var episodeFiles: [SonarrEpisodeFile] {
        guard let seriesId, let episodeFileId = currentEpisode.episodeFileId else { return [] }
        return viewModel.episodeFiles[seriesId]?.filter { $0.id == episodeFileId } ?? []
    }

    private func handleDeleteEpisodeFile(file: SonarrEpisodeFile) async {
        let success = await viewModel.deleteEpisodeFile(id: file.id)
        if success {
            InAppNotificationCenter.shared.showSuccess(title: "File Deleted", message: "Episode file has been removed.")
        } else if let error = viewModel.error {
            InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 20) {
                episodeSearchHero

                VStack(spacing: 14) {
                    episodeAutomaticSearchButton
                    episodeInteractiveSearchButton
                }

                if let bEp = activeBazarrEpisode, !bEp.missingSubtitles.isEmpty {
                    VStack(spacing: 14) {
                        bazarrAutomaticSearchButton
                        bazarrInteractiveSearchButton
                    }
                }

                if let q = queueItem {
                    ArrDetailQueueCard(items: [q]) { item in
                        ArrDetailQueueItemRow(item: item)
                    }
                }

                episodeSearchInfoCard(title: "Episode", icon: "text.justify.left") {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aired \(formattedDate(currentEpisode.airDate))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            if let overview = currentEpisode.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 12) {
                            statusBadges
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !episodeFiles.isEmpty {
                    episodeSearchInfoCard(title: "Files", icon: "doc.fill") {
                        VStack(spacing: 0) {
                            ForEach(Array(episodeFiles.enumerated()), id: \.element.id) { index, file in
                                ArrMediaFileRow(config: file.arrMediaFileConfig(
                                    onDelete: {
                                        episodeFileToDelete = file
                                        showDeleteFileAlert = true
                                    }
                                ))

                                if index < episodeFiles.count - 1 {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }
                }

                if viewModel.isLoadingHistory || !episodeHistory.isEmpty {
                    episodeSearchInfoCard(title: "History", icon: "clock.arrow.circlepath") {
                        if viewModel.isLoadingHistory && episodeHistory.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView("Loading history...")
                                Spacer()
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(episodeHistory) { record in
                                    SonarrEpisodeHistoryRow(record: record)

                                    if record.id != episodeHistory.last?.id {
                                        Divider().padding(.leading, 14)
                                    }
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 44)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background {
            ArrArtworkView(url: series?.posterURL ?? series?.fanartURL, contentMode: .fill) {
                Rectangle().fill(Color.purple.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .saturation(1.6)
            .overlay(Color.black.opacity(0.55))
            .ignoresSafeArea()
        }
        .navigationTitle(currentEpisode.episodeIdentifier)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: currentEpisode.hasFile)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: currentEpisode.monitored)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: queueAnimationValue)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: episodeFilesAnimationValue)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: episodeHistoryAnimationValue)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.isLoadingHistory)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard !isTogglingMonitored else { return }
                    isTogglingMonitored = true
                    Task {
                        await viewModel.toggleEpisodeMonitored(currentEpisode)
                        isTogglingMonitored = false
                    }
                } label: {
                    if isTogglingMonitored {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: currentEpisode.monitored == true ? "bookmark.fill" : "bookmark.slash")
                    }
                }
                .disabled(isTogglingMonitored)
            }
        }
        .alert("Delete Episode File?", isPresented: $showDeleteFileAlert) {
            Button("Delete", role: .destructive) {
                if let file = episodeFileToDelete {
                    Task { await handleDeleteEpisodeFile(file: file) }
                }
            }
            Button("Cancel", role: .cancel) {
                episodeFileToDelete = nil
            }
        } message: {
            Text("This removes the selected episode file from Sonarr.")
        }
        .sheet(isPresented: $showInteractiveSearchSheet) {
            if let series {
                SonarrInteractiveSearchSheet(viewModel: viewModel, series: series, episode: currentEpisode)
            }
        }
        .sheet(isPresented: $showBazarrInteractiveSearchSheet) {
            if let bEp = activeBazarrEpisode {
                BazarrInteractiveSearchSheet(
                    seriesId: bEp.sonarrSeriesId,
                    episode: bEp,
                    client: bazarrClient,
                    viewModel: BazarrViewModel(serviceManager: serviceManager),
                    onDownloaded: {
                        await refreshBazarrEpisode()
                    }
                )
            }
        }
        .task(id: currentEpisode.id) {
            await monitorEpisodeState()
        }
    }

    @ViewBuilder
    private var statusBadges: some View {
        episodeStatusBadge(currentEpisode.hasFile == true ? "Downloaded" : "Missing", tint: currentEpisode.hasFile == true ? .green : .orange, systemImage: currentEpisode.hasFile == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        episodeStatusBadge(currentEpisode.monitored == true ? "Monitored" : "Unmonitored", tint: .blue, systemImage: currentEpisode.monitored == true ? "bookmark.fill" : "bookmark.slash")

        if let q = queueItem {
            let isIssue = q.isImportIssueQueueItem
            episodeStatusBadge(
                isIssue ? "Import Issue" : (q.status?.capitalized ?? "Downloading"),
                tint: isIssue ? .orange : .purple,
                systemImage: isIssue ? "exclamationmark.triangle.fill" : (q.isDownloadingQueueItem ? "arrow.down.circle.fill" : "clock.arrow.circlepath")
            )
        }

        if let bEp = activeBazarrEpisode {
            let allComplete = bEp.missingSubtitles.isEmpty
            episodeStatusBadge(
                allComplete ? "Complete" : "None",
                tint: allComplete ? .teal : .secondary,
                systemImage: "captions.bubble.fill"
            )
        }
    }

    private var episodeFilesAnimationValue: [Int] {
        episodeFiles.map(\.id)
    }

    private var episodeHistoryAnimationValue: [Int] {
        episodeHistory.map(\.id)
    }

    private var queueAnimationValue: String {
        if let queueItem {
            return "\(queueItem.id)-\(queueItem.normalizedState)-\(queueItem.progress)"
        }
        return "none"
    }

    private var bazarrAutomaticSearchButton: some View {
        Button {
            guard !isDispatchingBazarrSearch, let bEp = activeBazarrEpisode else { return }
            isDispatchingBazarrSearch = true
            Task {
                if let client = bazarrClient {
                    do {
                        try await client.runSeriesAction(seriesId: bEp.sonarrSeriesId, action: .searchMissing)
                        InAppNotificationCenter.shared.showSuccess(title: "Search Queued", message: "Bazarr is searching for subtitles.")
                    } catch {
                        InAppNotificationCenter.shared.showError(title: "Search Failed", message: error.localizedDescription)
                    }
                }
                isDispatchingBazarrSearch = false
            }
        } label: {
            episodeSearchActionRow(
                title: "Queue Series Subtitle Search",
                subtitle: "Queue Bazarr's series-wide missing subtitle search.",
                systemImage: ServiceIdentity.bazarr.systemImage,
                isLoading: isDispatchingBazarrSearch,
                accentColor: ServiceIdentity.bazarr.brandColor
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func refreshBazarrEpisode() async {
        guard let client = bazarrClient else { return }
        do {
            let latestEpisodes = try await client.getEpisodes(episodeIds: [currentEpisode.id])
            await MainActor.run {
                refreshedBazarrEpisode = latestEpisodes.first
                onBazarrEpisodeUpdated(latestEpisodes.first)
            }
        } catch {
            InAppNotificationCenter.shared.showError(title: "Refresh Failed", message: error.localizedDescription)
        }
    }

    private var bazarrInteractiveSearchButton: some View {
        Button {
            showBazarrInteractiveSearchSheet = true
        } label: {
            episodeSearchActionRow(
                title: "Interactive Subtitle Search",
                subtitle: "Open the Bazarr interactive search sheet.",
                systemImage: "person.fill",
                trailingSystemImage: "arrow.up.forward.square",
                accentColor: .teal
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var episodeSearchHero: some View {
        VStack(spacing: 14) {
            ArrArtworkView(url: series?.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.purple.opacity(0.3))
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: hSizeClass == .regular ? 220 : 160, height: hSizeClass == .regular ? 330 : 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)

            VStack(spacing: 6) {
                Text(currentEpisode.title ?? currentEpisode.episodeIdentifier)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(series?.title ?? "Series") · \(currentEpisode.episodeIdentifier)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var episodeAutomaticSearchButton: some View {
        Button {
            guard !isDispatchingAutomaticSearch else { return }
            isDispatchingAutomaticSearch = true
            Task {
                await viewModel.searchEpisode(currentEpisode)
                isDispatchingAutomaticSearch = false

                if let error = viewModel.error, !error.isEmpty {
                    InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
                } else {
                    InAppNotificationCenter.shared.showSuccess(
                        title: "Search Queued",
                        message: "\(currentEpisode.title ?? currentEpisode.episodeIdentifier) was sent to Sonarr for automatic search."
                    )
                }
            }
        } label: {
            episodeSearchActionRow(
                title: "Automatic Search",
                subtitle: "Ask Sonarr to search indexers for this single episode.",
                systemImage: "magnifyingglass",
                isLoading: isDispatchingAutomaticSearch
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var episodeInteractiveSearchButton: some View {
        Button {
            showInteractiveSearchSheet = true
        } label: {
            episodeSearchActionRow(
                title: "Interactive Search",
                subtitle: "Open the manual release picker for this episode.",
                systemImage: "person.fill",
                trailingSystemImage: "arrow.up.forward.square"
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .disabled(series == nil)
    }

    private func episodeSearchActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right",
        accentColor: Color = .purple
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func episodeSearchInfoCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.white)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func episodeStatusBadge(_ text: String, tint: Color, systemImage: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14))
        .clipShape(Capsule())
    }

    private func formattedDate(_ string: String?) -> String {
        guard let string, !string.isEmpty else { return "TBA" }
        guard let date = Self.waterfallDateFormatter.date(from: string) else { return string }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func refreshEpisodeState() async {
        await viewModel.loadQueue()
        if let seriesId {
            await viewModel.loadEpisodes(for: seriesId)
            await viewModel.loadEpisodeFiles(for: seriesId)
            await viewModel.loadSeries()
        }
        await viewModel.loadHistory(page: 1)
    }

    private func monitorEpisodeState() async {
        var knownQueueID: Int?
        var hadQueueItem = false

        do {
            while true {
                try Task.checkCancellation()

                await viewModel.loadQueue()
                try Task.checkCancellation()

                let currentQueueID = queueItem?.id
                let hasQueueItem = currentQueueID != nil

                if let seriesId {
                    await viewModel.loadEpisodes(for: seriesId)
                    try Task.checkCancellation()
                    await viewModel.loadEpisodeFiles(for: seriesId)
                    try Task.checkCancellation()
                }

                if currentQueueID != knownQueueID || hasQueueItem || hadQueueItem {
                    await viewModel.loadSeries()
                    try Task.checkCancellation()
                    await viewModel.loadHistory(page: 1)
                    try Task.checkCancellation()
                }

                knownQueueID = currentQueueID
                hadQueueItem = hasQueueItem

                try await Task.sleep(for: .seconds(hasQueueItem ? 2 : 15))
            }
        } catch is CancellationError {
            // Task was cancelled because navigation moved away from this episode.
        } catch {
            // Ignore transient refresh failures; the next loop can recover.
        }
    }

}

struct SonarrEpisodeHistoryRow: View {
    let record: ArrHistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.sourceTitle ?? "Unknown")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let quality = record.quality?.quality?.name, !quality.isEmpty {
                        Text(quality)
                    }
                    Text(timeLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(eventLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(iconColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(iconColor.opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var eventType: String {
        record.eventType?.lowercased() ?? ""
    }

    private var eventLabel: String {
        if eventType.contains("grabbed") { return "Grabbed" }
        if eventType.contains("import") { return "Imported" }
        if eventType.contains("upgrade") { return "Upgraded" }
        if eventType.contains("delete") { return "Deleted" }
        if eventType.contains("download") { return "Downloaded" }
        return "Event"
    }

    private var iconColor: Color {
        if eventType.contains("delete") { return .red }
        if eventType.contains("upgrade") { return .blue }
        if eventType.contains("import") { return .green }
        if eventType.contains("grabbed") { return .orange }
        return .secondary
    }

    private var timeLabel: String {
        let date = SonarrEpisodeHistoryDateParser.parse(record.date) ?? .distantPast
        return date == .distantPast ? "Unknown Time" : date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum SonarrEpisodeHistoryDateParser {
    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let fallbackFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        if let date = fractionalISO.date(from: value) {
            return date
        }

        if let date = iso.date(from: value) {
            return date
        }

        return fallbackFormatter.date(from: value)
    }
}
