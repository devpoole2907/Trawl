import SwiftUI

struct SonarrSeriesDetailView: View {
    @Bindable var viewModel: SonarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService

    // Library mode: look up series by ID from viewModel
    private let seriesId: Int?
    // Discover mode: series object passed directly
    private let discoverSeries: SonarrSeries?
    private let onAdded: (() async -> Void)?

    @State private var isFilesExpanded = false
    @State private var showEditSheet = false
    @State private var selectedEpisodeFileForDeletion: SonarrEpisodeFile?
    @State private var showAddSheet = false
    @State private var importIssueResolution: ArrQueueImportIssueResolution?
    @State private var didAdd = false
    @State private var queueActionInFlightIDs: Set<Int> = []
    @State private var pendingQueueAction: ArrDetailPendingQueueAction?
    @State private var isDispatchingSeriesSearch = false
    @State private var showSeriesInteractiveSearchSheet = false
    @State private var bazarrEpisodes: [BazarrEpisode] = []
    @State private var bazarrClientForEpisodes: BazarrAPIClient?

    /// Library init — series lives in the ViewModel's loaded library.
    init(seriesId: Int, viewModel: SonarrViewModel) {
        self.seriesId = seriesId
        self.discoverSeries = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Discover init — series comes from a lookup result, may or may not be in library.
    init(series: SonarrSeries, viewModel: SonarrViewModel, onAdded: (() async -> Void)? = nil) {
        self.discoverSeries = series
        let libraryMatch = viewModel.series.first { $0.tvdbId == series.tvdbId }
        self.seriesId = libraryMatch?.id
        self.viewModel = viewModel
        self.onAdded = onAdded
    }

    /// The resolved series: prefer library version (by ID or TVDB ID), fall back to discover object.
    private var series: SonarrSeries? {
        if let seriesId, let found = viewModel.series.first(where: { $0.id == seriesId }) {
            return found
        }
        if let tvdbId = discoverSeries?.tvdbId,
           let found = viewModel.series.first(where: { $0.tvdbId == tvdbId }) {
            return found
        }
        return discoverSeries
    }

    /// Whether this series is present in the library.
    private var isInLibrary: Bool {
        guard let tvdbId = (discoverSeries?.tvdbId ?? series?.tvdbId) else {
            return seriesId != nil
        }
        return viewModel.series.contains { $0.tvdbId == tvdbId }
    }

    private var resolvedSeriesId: Int? {
        if let seriesId { return seriesId }
        guard let tvdbId = (discoverSeries?.tvdbId ?? series?.tvdbId) else { return nil }
        return viewModel.series.first { $0.tvdbId == tvdbId }?.id
    }

    private var episodes: [SonarrEpisode] {
        guard let id = resolvedSeriesId else { return [] }
        return viewModel.episodes[id] ?? []
    }

    private func bazarrEpisode(for file: SonarrEpisodeFile) -> BazarrEpisode? {
        guard let episode = episodes.first(where: { $0.episodeFileId == file.id }) else { return nil }
        return bazarrEpisodes.first { $0.sonarrEpisodeId == episode.id }
    }

    private var seasonNumbers: [Int] {
        if let s = series?.seasons, !s.isEmpty {
            return s.map(\.seasonNumber).sorted(by: >)
        }
        return Set(episodes.map(\.seasonNumber)).sorted(by: >)
    }
    private var episodeFiles: [SonarrEpisodeFile] {
        guard let id = resolvedSeriesId else { return [] }
        return viewModel.episodeFiles[id] ?? []
    }
    private var queueItems: [ArrQueueItem] {
        guard let id = resolvedSeriesId else { return [] }
        return viewModel.queue
            .filter { $0.seriesId == id }
            .sorted { $0.progress > $1.progress }
    }

    private var activeQueueItems: [ArrQueueItem] {
        queueItems.filter(isActiveQueueItem)
    }

    private var layoutAnimationKey: Int {
        var hasher = Hasher()
        hasher.combine(series?.status)
        hasher.combine(series?.monitored)
        hasher.combine(isInLibrary)
        hasher.combine(viewModel.queue.count)
        hasher.combine(episodeFiles.count)
        hasher.combine(episodes.count)
        return hasher.finalize()
    }

    private var importIssueQueueItems: [ArrQueueItem] {
        queueItems.filter { !isActiveQueueItem($0) && $0.isImportIssueQueueItem }
    }

    var body: some View {
        ArrItemDetailView(
            item: series,
            title: series?.title ?? "Series",
            backgroundURL: series?.posterURL ?? series?.fanartURL
        ) { series in
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    heroSection(series)
                    cardsSection(series)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 44)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: layoutAnimationKey)
        .toolbar { toolbarContent }
        .task(id: "\(resolvedSeriesId?.description ?? "nil")-\(serviceManager.activeBazarrProfileID?.uuidString ?? "nil")") {
            if let id = resolvedSeriesId {
                bazarrEpisodes = []
                bazarrClientForEpisodes = serviceManager.activeBazarrEntry?.client
                if let bazarrClientForEpisodes {
                    bazarrEpisodes = (try? await bazarrClientForEpisodes.getEpisodes(seriesIds: [id])) ?? []
                }

                var currentViewModel = viewModel
                await currentViewModel.loadEpisodes(for: id)
                await currentViewModel.loadEpisodeFiles(for: id)
                var knownQueueIds = Set(currentViewModel.queue.map(\.id))
                do {
                    while true {
                        try Task.checkCancellation()

                        if viewModel !== currentViewModel {
                            currentViewModel = viewModel
                            knownQueueIds = Set(currentViewModel.queue.map(\.id))
                        }

                        await currentViewModel.loadQueue()
                        try Task.checkCancellation()

                        let currentIds = Set(currentViewModel.queue.map(\.id))
                        if currentIds != knownQueueIds {
                            await currentViewModel.loadEpisodes(for: id)
                            try Task.checkCancellation()
                            await currentViewModel.loadEpisodeFiles(for: id)
                            try Task.checkCancellation()
                        }
                        knownQueueIds = currentIds

                        // Adaptive polling: fast (2s) if active/import-issue items, slow (30s) otherwise
                        let hasActiveOrIssueItems = currentViewModel.queue.contains {
                            guard $0.seriesId == id else { return false }
                            return isActiveQueueItem($0) || $0.isImportIssueQueueItem
                        }
                        let pollInterval = hasActiveOrIssueItems ? 2 : 30

                        try await Task.sleep(for: .seconds(pollInterval))
                    }
                } catch is CancellationError {
                    // task was cancelled — exit cleanly
                } catch {
                    // ignore transient errors; the .task will restart if id changes
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let series, isInLibrary {
                SonarrEditSeriesSheet(viewModel: viewModel, series: series)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSeriesInteractiveSearchSheet) {
            if let series {
                SonarrInteractiveSearchSheet(viewModel: viewModel, series: series)
            }
        }
        .sheet(item: $importIssueResolution) { resolution in
            ArrQueueImportIssueResolutionSheet(
                resolution: resolution,
                serviceManager: serviceManager,
                onImportCompleted: {
                    if let id = resolvedSeriesId {
                        await viewModel.loadQueue()
                        await viewModel.loadEpisodes(for: id)
                        await viewModel.loadEpisodeFiles(for: id)
                    } else {
                        await viewModel.loadQueue()
                    }
                }
            )
        }
        .sheet(isPresented: $showAddSheet) {
            if let series {
                SonarrAddToLibrarySheet(
                    viewModel: viewModel,
                    series: series,
                    onAdded: {
                        didAdd = true
                        await onAdded?()
                    }
                )
            }
        }
        .alert("Delete Episode File?", isPresented: episodeFileDeleteBinding) {
            Button("Delete", role: .destructive) {
                if let file = selectedEpisodeFileForDeletion {
                    selectedEpisodeFileForDeletion = nil
                    Task {
                        let didDelete = await viewModel.deleteEpisodeFile(id: file.id)
                        if didDelete {
                            InAppNotificationCenter.shared.showSuccess(title: "File Deleted", message: "The episode file has been removed.")
                        } else if let error = viewModel.error, !error.isEmpty {
                            InAppNotificationCenter.shared.showError(title: "Delete Failed", message: error)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                selectedEpisodeFileForDeletion = nil
            }
        } message: {
            Text("This removes the selected episode file from Sonarr.")
        }
        .alert(
            pendingQueueAction?.blocklist == true ? "Blocklist Queue Item?" : "Remove Queue Item?",
            isPresented: pendingQueueActionPresented
        ) {
            Button(pendingQueueAction?.blocklist == true ? "Blocklist" : "Remove", role: .destructive) {
                guard let pendingQueueAction else { return }
                let action = pendingQueueAction
                self.pendingQueueAction = nil
                Task {
                    if let item = viewModel.queue.first(where: { $0.id == action.itemID }) {
                        await handleQueueIssueAction(for: item, blocklist: action.blocklist)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingQueueAction = nil
            }
        } message: {
            Text(
                pendingQueueAction?.blocklist == true
                    ? "This will remove \"\(pendingQueueAction?.title ?? "this item")\" from the queue and add it to Sonarr's blocklist."
                    : "This will remove \"\(pendingQueueAction?.title ?? "this item")\" from the Sonarr queue."
            )
        }
    }

    // MARK: - Hero

    private func heroSection(_ series: SonarrSeries) -> some View {
        ArrDetailHeaderView(
            title: series.title,
            posterURL: series.posterURL,
            iconName: "tv",
            iconColor: .purple,
            networkOrStudio: series.network,
            year: series.year,
            runtime: series.runtime,
            badges: series.detailBadges(context: ArrBadgeContext(
                queue: viewModel.queue,
                isInLibrary: isInLibrary,
                hasBazarr: serviceManager.hasAnyConnectedBazarrInstance,
                sonarrBazarrEpisodes: bazarrEpisodes
            )),
            genres: series.genres ?? []
        )
    }

    // MARK: - Cards section

    @ViewBuilder
    private func cardsSection(_ series: SonarrSeries) -> some View {
        if !isInLibrary {
            Button {
                showAddSheet = true
            } label: {
                Label("Add to Sonarr", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }

        if isInLibrary {
            seriesSearchCard(series)
        }

        if let ratings = series.ratings {
            ratingsCard(ratings)
        }

        if let overview = series.overview, !overview.isEmpty {
            ArrDetailOverviewCard(text: overview)
        }

        if isInLibrary {
            statsCard(series)
        }

        if !activeQueueItems.isEmpty {
            ArrDetailQueueCard(items: activeQueueItems) { item in
                ArrDetailQueueItemRow(item: item)
            }
        }

        if !importIssueQueueItems.isEmpty {
            ArrDetailImportIssuesCard(items: importIssueQueueItems) { item in
                ArrDetailQueueIssueRow(
                    item: item,
                    rootFolderPath: series.rootFolderPath,
                    service: .sonarr,
                    libraryItemID: resolvedSeriesId,
                    editNoun: "Series",
                    isRemoving: queueActionInFlightIDs.contains(item.id),
                    isInLibrary: isInLibrary,
                    onEdit: { showEditSheet = true },
                    onSetResolution: { importIssueResolution = $0 },
                    onSetPendingAction: { pendingQueueAction = $0 }
                )
            }
        }

        if let tvdbId = series.tvdbId {
            SeerrMediaRequestCard(media: .series(tvdbId: tvdbId, title: series.title))
        }

        JellyfinMediaAvailabilityCard(
            media: .series(
                title: series.title,
                year: series.year,
                tvdbId: series.tvdbId,
                tmdbId: nil,
                imdbId: series.imdbId
            )
        )

        if isInLibrary {
            BazarrSubtitleStatusCard(media: .series(seriesId: series.id, title: series.title))
        }

        // Library-only: episodes and files
        if isInLibrary {
            let numbers = seasonNumbers
            if numbers.isEmpty && viewModel.isLoadingEpisodes {
                loadingCard
            } else {
                ForEach(numbers, id: \.self) { seasonNum in
                    seasonCard(seasonNum: seasonNum)
                }
            }

            if !episodeFiles.isEmpty {
                episodeFilesCard
            }
        }
        
        if let alternateTitles = series.alternateTitles, !alternateTitles.isEmpty {
            ArrDetailAlternateTitlesCard(titles: alternateTitles.map { title in
                (
                    title: title.title ?? "Untitled",
                    subtitle: title.seasonNumber.map { n in n == 0 ? "Specials" : "Season \(n)" }
                )
            })
        }
    }

    // MARK: - Stats card

    private func statsCard(_ series: SonarrSeries) -> some View {
        HStack(spacing: 0) {
            if let stats = series.statistics {
                statCell(value: "\(stats.seasonCount ?? 0)", label: "Seasons")
                cardDivider
                let files = stats.episodeFileCount ?? 0
                let total = stats.episodeCount ?? 0
                statCell(value: "\(files)/\(total)", label: "Episodes")
                if let size = stats.sizeOnDisk, size > 0 {
                    cardDivider
                    statCell(value: ByteFormatter.format(bytes: size), label: "On Disk")
                }
                if total > 0 {
                    cardDivider
                    statCell(value: "\(Int(Double(files) / Double(total) * 100))%", label: "Complete")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Search card

    private func seriesSearchCard(_ series: SonarrSeries) -> some View {
        HStack(spacing: 12) {
            Button {
                guard !isDispatchingSeriesSearch else { return }
                let seriesId = series.id
                isDispatchingSeriesSearch = true
                Task {
                    let didStart = await viewModel.searchSeries(seriesId: seriesId)
                    isDispatchingSeriesSearch = false
                    if !didStart, let error = viewModel.error, !error.isEmpty {
                        InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
                    }
                }
            } label: {
                seriesSearchButtonLabel(
                    title: "Automatic",
                    subtitle: "Search all monitored",
                    systemImage: "magnifyingglass",
                    isLoading: isDispatchingSeriesSearch
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(isDispatchingSeriesSearch)

            Button {
                showSeriesInteractiveSearchSheet = true
            } label: {
                seriesSearchButtonLabel(
                    title: "Interactive",
                    subtitle: "Pick a release",
                    systemImage: "person.fill",
                    trailingSystemImage: "arrow.up.forward.square"
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
    }

    private func seriesSearchButtonLabel(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right"
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.purple)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private var cardDivider: some View {
        Rectangle().fill(.separator).frame(width: 0.5, height: 26)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func ratingsCard(_ ratings: ArrRatings) -> some View {
        let items: [(String, String)] = [
            ratings.value.map { ("Rating", String(format: "%.1f", $0)) },
            ratings.votes.map { ("Votes", "\($0)") }
        ].compactMap { $0 }

        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 2) {
                        Text(item.1)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(item.0)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    if index < items.count - 1 {
                        Rectangle().fill(.separator).frame(width: 0.5, height: 26)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func isActiveQueueItem(_ item: ArrQueueItem) -> Bool {
        let torrent = arrDetailLinkedTorrent(for: item.downloadId, in: syncService.torrents)
        return arrDetailIsActiveQueueItem(item, linkedTorrent: torrent)
    }

    private func handleQueueIssueAction(for item: ArrQueueItem, blocklist: Bool) async {
        queueActionInFlightIDs.insert(item.id)
        defer { queueActionInFlightIDs.remove(item.id) }

        await viewModel.removeQueueItem(id: item.id, blocklist: blocklist)
        let wasRemoved = !viewModel.queue.contains(where: { $0.id == item.id })

        if wasRemoved {
            InAppNotificationCenter.shared.showSuccess(
                title: blocklist ? "Blocked" : "Removed",
                message: blocklist
                    ? "The queue item was removed and blocklisted."
                    : "The queue item was removed from Sonarr."
            )
        } else if let error = viewModel.error, !error.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Queue Action Failed", message: error)
        }
    }

    private var pendingQueueActionPresented: Binding<Bool> {
        Binding(
            get: { pendingQueueAction != nil },
            set: { if !$0 { pendingQueueAction = nil } }
        )
    }

    // MARK: - Loading card

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading episodes…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Season card

    private func seasonCard(seasonNum: Int) -> some View {
        let seasonEpisodes = episodes.filter { $0.seasonNumber == seasonNum }
        
        let filesCount: Int
        let totalCount: Int
        
        if !seasonEpisodes.isEmpty {
            filesCount = seasonEpisodes.filter { $0.hasFile == true }.count
            totalCount = seasonEpisodes.count
        } else if let stat = series?.seasons?.first(where: { $0.seasonNumber == seasonNum })?.statistics {
            filesCount = stat.episodeFileCount ?? 0
            totalCount = stat.episodeCount ?? 0
        } else {
            filesCount = 0
            totalCount = 0
        }

        let bEps = bazarrEpisodes.filter { $0.season == seasonNum }
        let subtitleComplete = !bEps.isEmpty && bEps.allSatisfy { $0.missingSubtitles.isEmpty }

        return NavigationLink {
            SonarrSeasonSearchView(
                viewModel: viewModel,
                series: series ?? discoverSeries,
                seasonNumber: seasonNum,
                episodes: seasonEpisodes.sorted { $0.episodeNumber < $1.episodeNumber },
                bazarrEpisodes: bEps,
                bazarrClient: bazarrClientForEpisodes,
                onBazarrEpisodesUpdated: { updatedEpisodes in
                    replaceBazarrEpisodes(updatedEpisodes, forSeason: seasonNum)
                }
            )
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(seasonNum == 0 ? "Specials" : "Season \(seasonNum)")
                        .font(.subheadline.weight(.semibold))
                    Text("\(filesCount) of \(totalCount) episodes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 48, height: 4)
                    if totalCount > 0 {
                        Capsule()
                            .fill(filesCount == totalCount ? Color.green : Color.purple)
                            .frame(
                                width: 48 * CGFloat(filesCount) / CGFloat(totalCount),
                                height: 4
                            )
                    }
                }

                if !bEps.isEmpty {
                    Image(systemName: "captions.bubble.fill")
                        .font(.caption2)
                        .foregroundStyle(subtitleComplete ? .teal : .secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled((series ?? discoverSeries) == nil)
    }

    private func replaceBazarrEpisodes(_ updatedEpisodes: [BazarrEpisode], forSeason seasonNumber: Int) {
        bazarrEpisodes.removeAll { $0.season == seasonNumber }
        bazarrEpisodes.append(contentsOf: updatedEpisodes)
        bazarrEpisodes.sort {
            if $0.season == $1.season {
                return $0.episode < $1.episode
            }
            return $0.season < $1.season
        }
    }

    // MARK: - Search actions

    private func searchEpisodeWithFeedback(_ episode: SonarrEpisode) async {
        await viewModel.searchEpisode(episode)
        if let error = viewModel.error, !error.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
        } else {
            InAppNotificationCenter.shared.showSuccess(
                title: "Search Queued",
                message: "\(episode.title ?? episode.episodeIdentifier) – search sent to indexers."
            )
        }
    }

    private func searchSeasonWithFeedback(seriesId: Int, seasonNumber: Int, episodeCount: Int) async {
        await viewModel.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
        if let error = viewModel.error, !error.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
        } else {
            let label = seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
            InAppNotificationCenter.shared.showSuccess(
                title: "Search Queued",
                message: "\(label) (\(episodeCount) \(episodeCount == 1 ? "episode" : "episodes")) – search sent to indexers."
            )
        }
    }

    // MARK: - Helpers

    private var episodeFileDeleteBinding: Binding<Bool> {
        Binding(
            get: { selectedEpisodeFileForDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    selectedEpisodeFileForDeletion = nil
                }
            }
        )
    }

    private var episodeFilesCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isFilesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Files")
                            .font(.subheadline.weight(.semibold))
                        Text("\(episodeFiles.count) episode files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isFilesExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isFilesExpanded {
                Divider()
                ForEach(Array(episodeFiles.enumerated()), id: \.element.id) { index, file in
                    let bEp = bazarrEpisode(for: file)
                    EpisodeFileRow(
                        file: file,
                        subtitles: bEp?.subtitles.isEmpty == false ? bEp?.subtitles : nil
                    ) {
                        selectedEpisodeFileForDeletion = file
                    }
                    if index < episodeFiles.count - 1 {
                        Divider().padding(.leading, 42)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.white)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if isInLibrary {
                Menu {
                    if series != nil {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }

                        if let series {
                            Button {
                                Task { await viewModel.toggleSeriesMonitored(series) }
                            } label: {
                                Label(
                                    series.monitored == true ? "Unmonitor" : "Monitor",
                                    systemImage: series.monitored == true ? "bookmark.slash" : "bookmark.fill"
                                )
                            }
                        }

                        Divider()
                    }
                    Button {
                        Task { try? await viewModel.refreshSeries() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
    }
}
