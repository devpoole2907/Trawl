import SwiftUI
import TipKit

struct SonarrSeriesDetailView: View {
    @Bindable var viewModel: SonarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    /// Optional: this screen is also reachable from places that do not inject the
    /// SABnzbd manager, in which case Usenet grabs fall back to Arr's own numbers.
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?

    // Library mode: look up series by ID from viewModel
    private let seriesId: Int?
    // Blended-library mode: the title, resolved across every server holding it.
    private let mergeKey: ArrMergeKey?
    // Discover mode: series object passed directly
    private let discoverSeries: SonarrSeries?
    private let onAdded: (() async -> Void)?

    @State private var isFilesExpanded = false
    @State private var showEditSheet = false
    @State private var showRootFolderAlert = false
    @State private var rootFolderText = ""
    @State private var selectedEpisodeFileForDeletion: SonarrEpisodeFile?
    @State private var showAddSheet = false
    @State private var importIssueResolution: ArrQueueImportIssueResolution?
    @State private var didAdd = false
    @State private var queueActionInFlightIDs: Set<Int> = []
    @State private var pendingQueueAction: ArrDetailPendingQueueAction?
    @State private var showRenameFilesAlert = false
    @State private var showManualImport = false
    @State private var isRenamingFiles = false
    @State private var isDispatchingSeriesSearch = false
    /// Snapshot of the series captured when the sheet opens. Holding a stable value here
    /// (instead of presenting against the live, poll-recomputed `series`) keeps the
    /// interactive-search subtree from re-rendering every poll tick.
    @State private var interactiveSearchSeries: SonarrSeries?
    @State private var bazarrEpisodes: [BazarrEpisode] = []
    @State private var bazarrClientForEpisodes: BazarrAPIClient?
    @State private var castMembers: [TMDbCastMember]?
    @State private var selectedCastMember: CastPersonRoute?
    /// Filmography tap captured while the cast sheet is up; navigation runs after
    /// the sheet dismisses so the push doesn't race the dismissal animation.
    /// Present only on the iPad three-column chrome. When it is, a title picked from
    /// the cast sheet changes what the detail pane is showing rather than stacking a
    /// third screen on top of the second one, with the list the user is picking from
    /// still beside it.
    @Environment(\.selectLibraryTitle) private var selectLibraryTitle
    @State private var pendingCastCredit: TMDbPersonCredit?
    @State private var castCreditMovie: RadarrMovie?
    @State private var castCreditSeries: SonarrSeries?
    /// Which server the server-specific actions act on. Only consulted when the
    /// title is on both; defaults to the first copy.
    @State private var actionInstanceID: UUID?
    /// Which search is waiting on the user to say which server it runs against.
    @State private var pendingServerAction: PendingServerAction?

    /// The two search actions that cannot be sent to both servers at once: HD and
    /// 4K want different releases, into different root folders.
    private enum PendingServerAction: String, Identifiable {
        case automaticSearch
        case interactiveSearch

        var id: String { rawValue }

        var prompt: String {
            switch self {
            case .automaticSearch: "Search which server?"
            case .interactiveSearch: "Pick a release for which server?"
            }
        }
    }

    /// Blended-library init - the title, wherever it lives.
    init(mergeKey: ArrMergeKey, viewModel: SonarrViewModel) {
        self.mergeKey = mergeKey
        self.seriesId = nil
        self.discoverSeries = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Library init - series lives in the ViewModel's loaded library. Kept for
    /// the entry points that only have a library ID: widgets, Siri intents, Seerr
    /// deep links, calendar and wanted rows.
    init(seriesId: Int, viewModel: SonarrViewModel) {
        self.seriesId = seriesId
        self.mergeKey = nil
        self.discoverSeries = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Discover init - series comes from a lookup result, may or may not be in library.
    init(series: SonarrSeries, viewModel: SonarrViewModel, onAdded: (() async -> Void)? = nil) {
        self.discoverSeries = series
        self.mergeKey = nil
        let libraryMatch = viewModel.series.first { $0.tvdbId == series.tvdbId }
        self.seriesId = libraryMatch?.id
        self.viewModel = viewModel
        self.onAdded = onAdded
    }

    /// The resolved series: prefer library version (by ID or TVDB ID), fall back to discover object.
    /// Every server's copy of this title.
    ///
    /// A library ID identifies a row on one server, so an ID-based entry point is
    /// resolved to its copy first and then widened to the whole merged entry -
    /// arriving from a widget or a Siri intent lands on the same screen as
    /// tapping the row in the library.
    private var entry: ArrLibraryEntry<SonarrSeries>? {
        let merged = viewModel.mergedEntries()
        if let mergeKey {
            return merged.first { $0.id == mergeKey }
        }
        if let seriesId, let match = merged.first(where: { $0.copy(withLibraryID: seriesId) != nil }) {
            return match
        }
        if let tvdbId = discoverSeries?.tvdbId {
            return merged.first { $0.copies.contains { $0.tvdbId == tvdbId } }
        }
        return nil
    }

    /// The copy the shared parts of the screen render from. Title, overview,
    /// artwork, cast, network and genres are the same metadata on both servers.
    private var series: SonarrSeries? {
        entry?.primary ?? discoverSeries
    }

    /// The servers holding this title, empty when there is nothing to distinguish.
    private var instanceRefs: [ArrInstanceRef] {
        guard let entry else { return [] }
        return serviceManager.badgeRefs(for: entry)
    }

    /// The copy that server-specific actions act on: search, interactive search,
    /// edit, rename, manual import, episode files.
    private var actionCopy: SonarrSeries? {
        guard let entry else { return discoverSeries }
        if let actionInstanceID, let copy = entry.copy(on: actionInstanceID) { return copy }
        return entry.primary
    }

    /// Whether this series is present in the library, on any server.
    private var isInLibrary: Bool {
        if entry != nil { return true }
        guard let tvdbId = (discoverSeries?.tvdbId ?? series?.tvdbId) else {
            return seriesId != nil || mergeKey != nil
        }
        return viewModel.series.contains { $0.tvdbId == tvdbId }
    }

    /// The library ID of the copy the server-specific work targets. Follows the
    /// action picker, so episodes, files and queue matching stay on the same
    /// server the buttons act on.
    private var resolvedSeriesId: Int? {
        if let copy = actionCopy, entry != nil { return copy.id }
        if let seriesId { return seriesId }
        guard let tvdbId = (discoverSeries?.tvdbId ?? series?.tvdbId) else { return nil }
        return viewModel.series.first { $0.tvdbId == tvdbId }?.id
    }

    /// The server whose copy this view is showing. Everything episode-shaped is
    /// read and loaded against it: episodes belong to one server's series, and the
    /// two servers number theirs from the same sequence.
    private var resolvedInstanceID: UUID? {
        actionCopy?.instanceID ?? series?.instanceID
    }

    private var episodes: [SonarrEpisode] {
        guard let id = resolvedSeriesId else { return [] }
        return viewModel.episodes(forSeries: id, on: resolvedInstanceID)
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
        return viewModel.episodeFiles(forSeries: id, on: resolvedInstanceID)
    }
    /// Unified subtitle coverage: Bazarr when it has a profile, otherwise the
    /// embedded subtitle tracks reported by the loaded Sonarr episode files.
    private var seriesSubtitleCoverage: SubtitleCoverage {
        let cachedBazarr = resolvedSeriesId.flatMap { serviceManager.cachedBazarrSeries(forSonarrSeriesId: $0) }
        let files = episodeFiles
        let withSubs = files.filter { !SubtitleCoverage.embeddedLanguages(from: $0.mediaInfo?.subtitles).isEmpty }.count
        return SubtitleCoverage.coverage(
            bazarrSeries: cachedBazarr,
            embeddedSubtitleFileCount: files.isEmpty ? nil : withSubs,
            episodeFileCount: files.count
        )
    }
    /// Union of embedded subtitle languages across the loaded Sonarr episode files.
    private var embeddedSubtitleLanguages: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for file in episodeFiles {
            for lang in SubtitleCoverage.embeddedLanguages(from: file.mediaInfo?.subtitles) where seen.insert(lang).inserted {
                result.append(lang)
            }
        }
        return result
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
        .task(id: "trawl-tip-detail-opened") {
            // Previews render this view repeatedly while you edit them; counting
            // those would hand the quick-actions tip its three openings without a
            // user ever opening anything.
            guard !ArrPreviewRuntime.isActive else { return }
            await TrawlTipEvents.libraryDetailOpened.donate()
        }
        .task(id: sabnzbdServiceManager?.activeProfileID) {
            guard let sabnzbdServiceManager else { return }
            await sabnzbdServiceManager.refresh()
            sabnzbdServiceManager.startPolling()
        }
        .task(id: series?.tvdbId) {
            castMembers = nil
            guard let series else { return }
            let resolver = ArrMediaLookupResolver(serviceManager: serviceManager)
            guard let tmdbId = await resolver.tmdbId(forSeries: series) else { return }
            castMembers = try? await TMDbClient().tvCredits(tmdbId: tmdbId).cast
        }
        .sheet(item: $selectedCastMember, onDismiss: completeCastCreditNavigation) { route in
            CastPersonSheet(route: route, onSelectCredit: { pendingCastCredit = $0 })
        }
        .navigationDestination(item: $castCreditMovie) { creditMovie in
            RadarrMovieDetailView(movie: creditMovie, viewModel: RadarrViewModel(serviceManager: serviceManager))
                .environment(syncService)
        }
        .navigationDestination(item: $castCreditSeries) { creditSeries in
            SonarrSeriesDetailView(series: creditSeries, viewModel: viewModel)
                .environment(syncService)
        }
        .refreshable {
            await refreshSeriesDetailState()
            await sabnzbdServiceManager?.refresh()
            if let bazarrClientForEpisodes, let id = resolvedSeriesId {
                bazarrEpisodes = (try? await bazarrClientForEpisodes.getEpisodes(seriesIds: [id])) ?? []
            }
        }
        .toolbar { toolbarContent }
        .confirmationDialog(
            pendingServerAction?.prompt ?? "",
            isPresented: Binding(
                get: { pendingServerAction != nil },
                set: { if !$0 { pendingServerAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingServerAction
        ) { action in
            ForEach(serverChoices, id: \.ref.id) { choice in
                Button(serviceManager.scopeLabel(for: choice.ref)) {
                    act(on: choice.copy) {
                        switch action {
                        case .automaticSearch: performAutomaticSearch(choice.copy)
                        case .interactiveSearch: interactiveSearchSeries = choice.copy
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Change Root Folder", isPresented: $showRootFolderAlert) {
            TextField("Root folder", text: $rootFolderText)
            Button("Move Existing Files") {
                if let series = actionCopy {
                    Task { await updateSeriesRootFolder(series, moveFiles: true) }
                }
            }
            Button("Update Only") {
                if let series = actionCopy {
                    Task { await updateSeriesRootFolder(series, moveFiles: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the root folder Sonarr should use for this series.")
        }
        .task(id: "\(resolvedSeriesId?.description ?? "nil")-\(serviceManager.activeBazarrProfileID?.uuidString ?? "nil")") {
            if let id = resolvedSeriesId {
                bazarrEpisodes = []
                bazarrClientForEpisodes = serviceManager.activeBazarrEntry?.client
                if let bazarrClientForEpisodes {
                    bazarrEpisodes = (try? await bazarrClientForEpisodes.getEpisodes(seriesIds: [id])) ?? []
                }

                var currentViewModel = viewModel
                await currentViewModel.loadEpisodes(for: id, instanceID: resolvedInstanceID)
                await currentViewModel.loadEpisodeFiles(for: id, instanceID: resolvedInstanceID)
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
                        let hasActiveOrIssueItems = currentViewModel.queue.contains {
                            guard $0.seriesId == id else { return false }
                            return isActiveQueueItem($0) || $0.isImportIssueQueueItem
                        }

                        if currentIds != knownQueueIds || hasActiveOrIssueItems {
                            await currentViewModel.loadEpisodes(for: id, instanceID: resolvedInstanceID)
                            try Task.checkCancellation()
                            await currentViewModel.loadEpisodeFiles(for: id, instanceID: resolvedInstanceID)
                            try Task.checkCancellation()
                            await currentViewModel.loadSeries()
                            try Task.checkCancellation()
                        }
                        knownQueueIds = currentIds

                        // Adaptive polling: fast (2s) if active/import-issue items, slow (30s) otherwise
                        let pollInterval = hasActiveOrIssueItems ? 2 : 30

                        try await Task.sleep(for: .seconds(pollInterval))
                    }
                } catch is CancellationError {
                    // task was cancelled - exit cleanly
                } catch {
                    // ignore transient errors; the .task will restart if id changes
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let series = actionCopy, isInLibrary {
                SonarrEditSeriesSheet(viewModel: viewModel, series: series)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(
            item: $interactiveSearchSeries,
            onDismiss: {
                Task { await refreshSeriesDetailState() }
            }
        ) { series in
            SonarrInteractiveSearchSheet(viewModel: viewModel, series: series)
        }
        .sheet(item: $importIssueResolution) { resolution in
            ArrQueueImportIssueResolutionSheet(
                resolution: resolution,
                serviceManager: serviceManager,
                onImportCompleted: {
                    if let id = resolvedSeriesId {
                        await viewModel.loadQueue()
                        await viewModel.loadEpisodes(for: id, instanceID: resolvedInstanceID)
                        await viewModel.loadEpisodeFiles(for: id, instanceID: resolvedInstanceID)
                    } else {
                        await viewModel.loadQueue()
                    }
                }
            )
        }
        .sheet(isPresented: $showManualImport, onDismiss: { Task { await refreshSeriesDetailState() } }) {
            if let series = actionCopy, let path = series.path {
                NavigationStack {
                    LibraryImportScanView(
                        path: path,
                        service: .sonarr,
                        serviceManager: serviceManager,
                        instanceID: series.instanceID,
                        libraryItemID: series.id,
                        showsCloseButton: true,
                        kind: .manual
                    )
                }
            }
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
                        let didDelete = await viewModel.deleteEpisodeFile(id: file.id, instanceID: resolvedInstanceID)
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
                subtitleCoverage: seriesSubtitleCoverage
            )),
            genres: series.genres ?? []
        )
        .overlay(alignment: .topTrailing) {
            // Says at a glance which servers hold this title, before any card is
            // read. Absent entirely when only one Sonarr is configured.
            ArrInstanceBadgeRow(refs: instanceRefs, style: .prominent)
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
    }

    /// The servers this title is on, paired with the copy each one holds. Empty
    /// when there is nothing to choose between, which is what every call site
    /// below uses to decide whether to ask at all.
    private var serverChoices: [(ref: ArrInstanceRef, copy: SonarrSeries)] {
        guard let entry, entry.isOnMultipleInstances, instanceRefs.count == entry.copies.count else { return [] }
        return Array(zip(instanceRefs, entry.copies)).map { (ref: $0.0, copy: $0.1) }
    }

    /// Points the server-scoped state at one copy and then runs the action, so the
    /// sheet or alert that follows opens against the server just chosen.
    private func act(on copy: SonarrSeries, _ perform: () -> Void) {
        actionInstanceID = copy.instanceID
        perform()
    }

    /// A toolbar item that has to name a server when there are two. With one
    /// server it stays a plain button - there is nothing to disambiguate and a
    /// submenu would be a tap for nothing.
    @ViewBuilder
    private func serverScopedMenuItem(
        title: String,
        systemImage: String,
        choiceLabel: @escaping (ArrInstanceRef, SonarrSeries) -> String = { ref, _ in ref.shortLabel },
        isEnabled: Bool = true,
        perform: @escaping (SonarrSeries) -> Void
    ) -> some View {
        let choices = serverChoices
        if choices.isEmpty {
            if let series = actionCopy {
                Button {
                    act(on: series) { perform(series) }
                } label: {
                    Label(title, systemImage: systemImage)
                }
                .disabled(!isEnabled)
            }
        } else {
            Menu {
                ForEach(choices, id: \.ref.id) { choice in
                    Button(choiceLabel(choice.ref, choice.copy)) {
                        act(on: choice.copy) { perform(choice.copy) }
                    }
                }
            } label: {
                Label(title, systemImage: systemImage)
            }
            .disabled(!isEnabled)
        }
    }

    private func completeCastCreditNavigation() {
        guard let credit = pendingCastCredit else { return }
        pendingCastCredit = nil
        Task {
            let resolver = ArrMediaLookupResolver(serviceManager: serviceManager)
            if credit.isMovie {
                if let resolved = await resolver.resolveMovie(tmdbId: credit.id) {
                    if let selectLibraryTitle {
                        selectLibraryTitle(resolved.mergeKey)
                    } else {
                        castCreditMovie = resolved
                    }
                } else {
                    InAppNotificationCenter.shared.showError(
                        title: "Couldn't Open Title",
                        message: "Radarr couldn't find \"\(credit.displayTitle)\"."
                    )
                }
            } else {
                if let resolved = await resolver.resolveSeries(tmdbId: credit.id) {
                    if let selectLibraryTitle {
                        selectLibraryTitle(resolved.mergeKey)
                    } else {
                        castCreditSeries = resolved
                    }
                } else {
                    InAppNotificationCenter.shared.showError(
                        title: "Couldn't Open Title",
                        message: "Sonarr couldn't find \"\(credit.displayTitle)\"."
                    )
                }
            }
        }
    }

    /// Offers the server that does not have this series yet - the Sonarr twin of
    /// `RadarrMovieDetailView.addToOtherServerCard`, and there for the same reason:
    /// `isInLibrary` is true when *any* server holds the show, so with a pair
    /// configured there was no route to put it on the other one.
    @ViewBuilder
    private var addToOtherServerCard: some View {
        ForEach(missingInstances, id: \.id) { ref in
            Button {
                showAddSheet = true
            } label: {
                Label("Add to \(serviceManager.scopeLabel(for: ref))", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var missingInstances: [ArrInstanceRef] {
        guard let entry else { return [] }
        let refs = serviceManager.refs(for: .sonarr)
        guard refs.count > 1 else { return [] }
        return entry.instancesMissingThis(from: refs)
    }

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
            addToOtherServerCard
        }

        if !activeQueueItems.isEmpty {
            ArrDetailQueueCard(items: activeQueueItems) { item in
                ArrDetailQueueItemRow(
                    item: item,
                    isRemoving: queueActionInFlightIDs.contains(item.id),
                    onSetPendingAction: { pendingQueueAction = $0 }
                )
            }
        }

        if let ratings = series.ratings {
            ratingsCard(ratings)
        }

        if let overview = series.overview, !overview.isEmpty {
            ArrDetailOverviewCard(text: overview)
        }

        if let castMembers, !castMembers.isEmpty {
            CastShelfView(
                items: castMembers.prefix(20).map(CastShelfItem.init),
                onSelect: { selectedCastMember = $0.destination }
            )
        }

        if isInLibrary {
            statsCard(series)
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
                imdbId: series.imdbId,
                totalEpisodes: series.statistics?.episodeCount
            )
        )

        if isInLibrary {
            BazarrSubtitleStatusCard(media: .series(
                seriesId: series.id,
                title: series.title,
                embeddedLanguages: embeddedSubtitleLanguages,
                episodeFileCount: episodeFiles.count
            ))
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

    /// Season count is metadata and identical on both servers; episode counts and
    /// disk usage are not. On a pair each server gets its own Episodes cell, so a
    /// series complete in HD and half-grabbed in 4K reads as exactly that instead
    /// of averaging into a number true of neither.
    @ViewBuilder
    private func statsCard(_ series: SonarrSeries) -> some View {
        if let entry, entry.isOnMultipleInstances, instanceRefs.count == entry.copies.count {
            // Two rows rather than one. A pair needs episode counts, disk usage and
            // completion *per server* - more cells than a single row can hold, and
            // dropping the last two would tell the user less about two servers than
            // this same card tells them about one.
            let pairs = Array(zip(instanceRefs, entry.copies))
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    statCell(value: "\(series.statistics?.seasonCount ?? 0)", label: "Seasons")
                    ForEach(pairs, id: \.0.id) { ref, copy in
                        cardDivider
                        let files = copy.statistics?.episodeFileCount ?? 0
                        let total = copy.statistics?.episodeCount ?? 0
                        statCell(value: "\(files)/\(total)", label: "\(ref.shortLabel) Episodes")
                    }
                    cardDivider
                    VStack(spacing: 4) {
                        ArrAvailabilityPill(
                            availableTiers: availableTiers,
                            showsTiers: !instanceRefs.isEmpty,
                            unavailableStatus: "Not downloaded"
                        )
                        Text("Library")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // Natural width, so the numeric cells share the remainder rather
                    // than every cell taking an equal share and clipping the longest
                    // label to "Available H...".
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                }
                Divider().padding(.horizontal, 12)
                HStack(spacing: 0) {
                    ForEach(pairs, id: \.0.id) { ref, copy in
                        let size = copy.statistics?.sizeOnDisk ?? 0
                        statCell(
                            value: size > 0 ? ByteFormatter.format(bytes: size) : "-",
                            label: "\(ref.shortLabel) on Disk"
                        )
                        cardDivider
                    }
                    ForEach(Array(pairs.enumerated()), id: \.element.0.id) { index, pair in
                        let files = pair.1.statistics?.episodeFileCount ?? 0
                        let total = pair.1.statistics?.episodeCount ?? 0
                        statCell(
                            value: total > 0 ? "\(Int(Double(files) / Double(total) * 100))%" : "-",
                            label: "\(pair.0.shortLabel) Complete"
                        )
                        if index < pairs.count - 1 { cardDivider }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
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
    }

    /// A series counts as available on a server once that server holds any
    /// episode file - the 4K library has started it, and the per-server episode
    /// cells beside the pill carry how far along each one is.
    private var availableTiers: [ArrQualityTier] {
        entry?.availableTiers(from: instanceRefs) { ($0.statistics?.episodeFileCount ?? 0) > 0 } ?? []
    }

    /// Summed across servers: a series held in both HD and 4K is using both.
    private var totalSeriesSizeOnDisk: Int64 {
        entry?.copies.reduce(Int64(0)) { $0 + ($1.statistics?.sizeOnDisk ?? 0) } ?? 0
    }

    // MARK: - Search card

    private func seriesSearchCard(_ series: SonarrSeries) -> some View {
        seriesSearchButtons(series)
    }


    /// Extracted so the direct (one server) and chosen-server paths cannot drift.
    private func performAutomaticSearch(_ series: SonarrSeries) {
        guard !isDispatchingSeriesSearch else { return }
        let seriesId = series.id
        if let loadedEpisodes = Optional(viewModel.episodes(forSeries: seriesId, on: series.instanceID)),
           !loadedEpisodes.isEmpty,
           !loadedEpisodes.contains(where: { $0.monitored == true }) {
            InAppNotificationCenter.shared.showError(
                title: "Nothing Monitored",
                message: "No episodes in \(series.title) are monitored, so Sonarr has nothing to search. Monitor episodes first or use Interactive Search."
            )
            return
        }
        isDispatchingSeriesSearch = true
        Task {
            let didStart = await viewModel.searchSeries(seriesId: seriesId)
            isDispatchingSeriesSearch = false
            if !didStart, let error = viewModel.error, !error.isEmpty {
                InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
            } else if didStart {
                // This flow has no in-view feedback card, so show the banner here -
                // the view model itself only logs silently now to avoid duplicate
                // banners for flows (like the season view) that do have a card.
                InAppNotificationCenter.shared.showSuccess(
                    title: "Search Queued",
                    message: "\(series.title) was sent to Sonarr for automatic search."
                )
            }
        }
    }

    private func seriesSearchButtons(_ series: SonarrSeries) -> some View {
        HStack(spacing: 12) {
            Button {
                // With two servers the choice is made here rather than held as a
                // mode: HD and 4K want different releases, and the answer is only
                // obvious at the moment of asking.
                if serverChoices.isEmpty {
                    performAutomaticSearch(series)
                } else {
                    pendingServerAction = .automaticSearch
                }
            } label: {
                detailSearchButtonLabel(
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
                if serverChoices.isEmpty {
                    interactiveSearchSeries = series
                } else {
                    pendingServerAction = .interactiveSearch
                }
            } label: {
                detailSearchButtonLabel(
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

    private func detailSearchButtonLabel(
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
        let sabJob = arrDetailLinkedSABJob(for: item.downloadId, in: arrDetailSABJobs(from: sabnzbdServiceManager))
        return arrDetailIsActiveQueueItem(item, linkedTorrent: torrent, linkedSABJob: sabJob)
    }

    private func handleQueueIssueAction(for item: ArrQueueItem, blocklist: Bool) async {
        queueActionInFlightIDs.insert(item.id)
        defer { queueActionInFlightIDs.remove(item.id) }

        let wasRemoved = await viewModel.removeQueueItem(id: item.id, blocklist: blocklist)

        if wasRemoved {
            if blocklist {
                await serviceManager.loadBlocklist()
            }
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

    private func updateSeriesRootFolder(_ series: SonarrSeries, moveFiles: Bool) async {
        let rootFolderPath = rootFolderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootFolderPath.isEmpty else { return }
        guard let qualityProfileId = series.qualityProfileId else {
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: "Series quality profile is missing.")
            return
        }

        _ = await viewModel.updateSeries(
            series,
            monitored: series.monitored ?? false,
            qualityProfileId: qualityProfileId,
            seriesType: series.seriesType ?? "standard",
            seasonFolder: series.seasonFolder ?? true,
            rootFolderPath: rootFolderPath,
            tags: series.tags ?? [],
            moveFiles: moveFiles
        )
    }

    private func renameSeriesFiles() async {
        guard let series = actionCopy,
              let client = serviceManager.sonarrClient(owning: series) else { return }
        isRenamingFiles = true
        defer { isRenamingFiles = false }
        do {
            _ = try await client.renameSeriesFiles(seriesId: series.id)
            InAppNotificationCenter.shared.showSuccess(
                title: "Rename Queued",
                message: "Sonarr is renaming the episode files in the background."
            )
        } catch {
            InAppNotificationCenter.shared.showError(title: "Rename Failed", message: error.localizedDescription)
        }
    }

    private func refreshSeriesDetailState() async {
        guard let id = resolvedSeriesId else {
            await viewModel.loadQueue()
            return
        }
        await viewModel.loadQueue()
        await viewModel.loadEpisodes(for: id, instanceID: resolvedInstanceID)
        await viewModel.loadEpisodeFiles(for: id, instanceID: resolvedInstanceID)
        await viewModel.loadSeries()
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
                    ArrMediaFileRow(config: file.arrMediaFileConfig(
                        showSeasonBadge: true,
                        subtitles: bEp?.subtitles.isEmpty == false ? bEp?.subtitles : nil,
                        onDelete: { selectedEpisodeFileForDeletion = file }
                    ))
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
                    if let series = actionCopy {
                        // Each of these edits one server's copy. With a pair they
                        // nest a server choice rather than inheriting a mode set
                        // further down a page the toolbar cannot see.
                        serverScopedMenuItem(title: "Edit", systemImage: "slider.horizontal.3") { _ in
                            showEditSheet = true
                        }

                        serverScopedMenuItem(title: "Change Root Folder", systemImage: "folder") { copy in
                            rootFolderText = copy.rootFolderPath ?? ""
                            showRootFolderAlert = true
                        }

                        serverScopedMenuItem(
                            title: series.monitored == true ? "Unmonitor" : "Monitor",
                            systemImage: series.monitored == true ? "bookmark.slash" : "bookmark.fill",
                            choiceLabel: { ref, copy in
                                "\(ref.shortLabel) - \(copy.monitored == true ? "Unmonitor" : "Monitor")"
                            }
                        ) { copy in
                            Task { await viewModel.toggleSeriesMonitored(copy) }
                        }

                        serverScopedMenuItem(
                            title: "Rename Files",
                            systemImage: "pencil.and.list.clipboard",
                            isEnabled: !isRenamingFiles
                        ) { _ in
                            showRenameFilesAlert = true
                        }

                        if series.path != nil {
                            serverScopedMenuItem(title: "Manual Import", systemImage: "tray.and.arrow.down.fill") { _ in
                                showManualImport = true
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
                .alert("Rename All Episode Files?", isPresented: $showRenameFilesAlert) {
                    Button("Rename") { Task { await renameSeriesFiles() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All episode files for this series will be renamed on disk to match the current naming format configured in Sonarr.")
                }
            }
        }
    }
}

#if DEBUG
#Preview("Library") {
    SonarrPreviewHost { manager in
        let viewModel = SonarrViewModel.previewDetail(serviceManager: manager)
        NavigationStack {
            SonarrSeriesDetailView(seriesId: SonarrSeries.preview.id, viewModel: viewModel)
        }
    }
}

#Preview("Missing Metadata") {
    SonarrPreviewHost { manager in
        let viewModel = SonarrViewModel.previewDetail(.previewMissingArt, serviceManager: manager)
        NavigationStack {
            SonarrSeriesDetailView(seriesId: SonarrSeries.previewMissingArt.id, viewModel: viewModel)
        }
    }
}

#Preview("Discover") {
    SonarrPreviewHost { manager in
        let viewModel = SonarrViewModel(previewSeries: [], serviceManager: manager)
        NavigationStack {
            SonarrSeriesDetailView(series: .previewDiscover, viewModel: viewModel)
        }
    }
}

#Preview("Loading Episodes") {
    SonarrPreviewHost { manager in
        let series = SonarrSeries.preview
        let viewModel = SonarrViewModel(
            previewSeries: [series],
            episodes: [series.id: []],
            isLoadingEpisodes: true,
            serviceManager: manager
        )
        NavigationStack {
            SonarrSeriesDetailView(seriesId: series.id, viewModel: viewModel)
        }
    }
}

#Preview("Error") {
    SonarrPreviewHost { manager in
        let viewModel = SonarrViewModel.previewDetail(
            serviceManager: manager,
            error: "Sonarr returned 500 Internal Server Error."
        )
        NavigationStack {
            SonarrSeriesDetailView(seriesId: SonarrSeries.preview.id, viewModel: viewModel)
        }
    }
}

#Preview("Connection Issue") {
    SonarrPreviewHost(state: .sonarrConnectionError("Unable to reach Sonarr - check host and port.")) { manager in
        let viewModel = SonarrViewModel(
            previewSeries: [.preview],
            error: "Unable to reach Sonarr - check host and port.",
            serviceManager: manager
        )
        NavigationStack {
            SonarrSeriesDetailView(seriesId: SonarrSeries.preview.id, viewModel: viewModel)
        }
    }
}
#endif
