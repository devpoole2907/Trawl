import SwiftUI
import TipKit

struct RadarrMovieDetailView: View {
    @Bindable var viewModel: RadarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    /// Optional: this screen is also reachable from places that do not inject the
    /// SABnzbd manager, in which case Usenet grabs fall back to Arr's own numbers.
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    @Environment(\.dismiss) private var dismiss

    // Library mode: look up movie by ID from viewModel
    private let movieId: Int?
    /// Which server issued `movieId`. A Radarr library ID is only unique within one
    /// server - the pair hand out the same small integers - so an ID entry point that
    /// does not say which server it came from resolves to whichever film happens to
    /// hold that ID first. `nil` only for callers that genuinely have no server.
    private let movieInstanceID: UUID?
    // Blended-library mode: the title, resolved across every server holding it.
    private let mergeKey: ArrMergeKey?
    // Discover mode: movie object passed directly
    private let discoverMovie: RadarrMovie?
    private let onAdded: (() async -> Void)?
    #if DEBUG
    private var disablesPreviewLoadingTasks = false
    #endif

    @State private var showRenameFilesAlert = false
    @State private var showManualImport = false
    @State private var isRenamingFiles = false
    @State private var showDeleteAlert = false
    @State private var deleteFiles = false
    @State private var showEditSheet = false
    @State private var showRootFolderAlert = false
    @State private var rootFolderText = ""
    @State private var showDeleteFileAlert = false
    @State private var movieFileToDelete: Int?
    @State private var isFilesExpanded = false
    @State private var showAddSheet = false
    @State private var importIssueResolution: ArrQueueImportIssueResolution?
    @State private var didAdd = false
    /// Snapshot of the movie captured when the sheet opens. Holding a stable value here
    /// (instead of presenting against the live, poll-recomputed `movie`) keeps the
    /// interactive-search subtree from re-rendering every poll tick.
    @State private var interactiveSearchMovie: RadarrMovie?
    @State private var isDispatchingAutomaticSearch = false
    @State private var queueActionInFlightIDs: Set<String> = []
    @State private var pendingQueueAction: ArrDetailPendingQueueAction?
    @State private var bazarrMovieSubtitles: [BazarrSubtitle]?
    @State private var castMembers: [TMDbCastMember]?
    @State private var selectedCastMember: CastPersonRoute?
    /// Filmography tap captured while the cast sheet is up; navigation runs after
    /// the sheet dismisses so the push doesn't race the dismissal animation.
    /// Present only on the iPad three-column chrome. When it is, a title picked from
    /// the cast sheet changes what the detail pane is showing rather than stacking a
    /// third screen on top of the second one, with the list the user is picking from
    /// still beside it.
    @Environment(\.selectLibraryTitle) private var selectLibraryTitle
    @Environment(\.openMediaInSearch) private var openMediaInSearch
    @State private var pendingCastCredit: TMDbPersonCredit?
    @State private var castCreditMovie: RadarrMovie?
    @State private var castCreditSeries: SonarrSeries?
    /// Which server the server-specific actions act on. Only consulted when the
    /// title is on both; defaults to the first copy.
    @State private var actionInstanceID: UUID?
    /// Which search is waiting on the user to say which server it runs against.
    @State private var pendingServerAction: PendingServerAction?

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
    init(mergeKey: ArrMergeKey, viewModel: RadarrViewModel) {
        self.mergeKey = mergeKey
        self.movieId = nil
        self.movieInstanceID = nil
        self.discoverMovie = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Library init - movie lives in the ViewModel's loaded library. Kept for the
    /// entry points that only have a library ID: widgets, Siri intents, Seerr
    /// deep links, calendar and wanted rows.
    init(movieId: Int, instanceID: UUID? = nil, viewModel: RadarrViewModel) {
        self.movieId = movieId
        self.movieInstanceID = instanceID
        self.mergeKey = nil
        self.discoverMovie = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Discover init - movie comes from a lookup result, may or may not be in library.
    init(movie: RadarrMovie, viewModel: RadarrViewModel, onAdded: (() async -> Void)? = nil) {
        self.discoverMovie = movie
        self.mergeKey = nil
        // Deliberately no library ID: a Radarr library ID means nothing without
        // the server that issued it, and the tmdbId match below is instance-blind,
        // so it happily returned the 4K server's ID for a title the HD server also
        // holds under a different ID. `entry` resolves a discover result by TMDb ID
        // instead, which is the same film on every server.
        self.movieId = nil
        self.movieInstanceID = nil
        self.viewModel = viewModel
        self.onAdded = onAdded
    }

    #if DEBUG
    init(previewMovieId movieId: Int, viewModel: RadarrViewModel) {
        self.init(movieId: movieId, viewModel: viewModel)
        disablesPreviewLoadingTasks = true
    }

    init(previewMovie movie: RadarrMovie, viewModel: RadarrViewModel, onAdded: (() async -> Void)? = nil) {
        self.init(movie: movie, viewModel: viewModel, onAdded: onAdded)
        disablesPreviewLoadingTasks = true
    }
    #endif

    /// Every server's copy of this title.
    ///
    /// A library ID identifies a row on one server, so an ID-based entry point is
    /// resolved to its copy first and then widened to the whole merged entry -
    /// arriving from a widget or a Siri intent lands on the same screen as
    /// tapping the row in the library.
    private var entry: ArrLibraryEntry<RadarrMovie>? {
        let merged = viewModel.mergedEntries()
        if let mergeKey {
            return merged.first { $0.id == mergeKey }
        }
        if let movieId, let match = merged.first(where: { entry in
            entry.copies.contains {
                $0.id == movieId && (movieInstanceID == nil || $0.instanceID == movieInstanceID)
            }
        }) {
            return match
        }
        if let tmdbId = discoverMovie?.tmdbId {
            return merged.first { $0.copies.contains { $0.tmdbId == tmdbId } }
        }
        return nil
    }

    /// The copy the shared parts of the screen render from. Title, overview,
    /// artwork, cast, ratings and release dates are the same metadata on both
    /// servers, so any copy will do.
    private var movie: RadarrMovie? {
        entry?.primary ?? discoverMovie
    }

    /// The servers holding this title, empty when there is nothing to distinguish.
    private var instanceRefs: [ArrInstanceRef] {
        guard let entry else { return [] }
        return serviceManager.badgeRefs(for: entry)
    }

    /// The copy that server-specific actions act on: search, interactive search,
    /// edit, rename, manual import. Defaults to the first server holding the
    /// title, and is switchable when both do.
    private var actionCopy: RadarrMovie? {
        guard let entry else { return discoverMovie }
        if let actionInstanceID, let copy = entry.copy(on: actionInstanceID) { return copy }
        return entry.primary
    }

    /// Whether this movie is present in the library, on any server.
    private var isInLibrary: Bool {
        if entry != nil { return true }
        guard let tmdbId = (discoverMovie?.tmdbId ?? movie?.tmdbId) else {
            return movieId != nil || mergeKey != nil
        }
        return viewModel.movies.contains { $0.tmdbId == tmdbId }
    }

    private var layoutAnimationKey: Int {
        var hasher = Hasher()
        hasher.combine(movie?.hasFile)
        hasher.combine(movie?.monitored)
        hasher.combine(isInLibrary)
        hasher.combine(viewModel.queue.count)
        hasher.combine(viewModel.movieFiles.count)
        return hasher.finalize()
    }

    var body: some View {
        ArrItemDetailView(
            item: movie,
            title: movie?.title ?? "Movie",
            backgroundURL: movie?.posterURL ?? movie?.fanartURL
        ) { movie in
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    heroSection(movie)
                    cardsSection(movie)
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
            #if DEBUG
            guard !disablesPreviewLoadingTasks else { return }
            #endif
            guard let sabnzbdServiceManager else { return }
            await sabnzbdServiceManager.refresh()
            sabnzbdServiceManager.startPolling()
        }
        .task(id: movie?.id) {
            #if DEBUG
            guard !disablesPreviewLoadingTasks else { return }
            #endif
            bazarrMovieSubtitles = nil
            guard let movie, let client = serviceManager.activeBazarrEntry?.client else { return }
            if let page = try? await client.getMovies(ids: [movie.id]),
               let fetched = page.data.first,
               !fetched.subtitles.isEmpty {
                bazarrMovieSubtitles = fetched.subtitles
            }
        }
        .task(id: movie?.tmdbId) {
            #if DEBUG
            guard !disablesPreviewLoadingTasks else { return }
            #endif
            castMembers = nil
            guard let tmdbId = movie?.tmdbId else { return }
            castMembers = try? await TMDbClient().movieCredits(tmdbId: tmdbId).cast
        }
        .refreshable {
            await refreshMovieDetailState()
            await sabnzbdServiceManager?.refresh()
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
                        case .interactiveSearch: interactiveSearchMovie = choice.copy
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Change Root Folder", isPresented: $showRootFolderAlert) {
            TextField("Root folder", text: $rootFolderText)
            Button("Move Existing Files") {
                if let movie = actionCopy {
                    Task { await updateMovieRootFolder(movie, moveFiles: true) }
                }
            }
            Button("Update Only") {
                if let movie = actionCopy {
                    Task { await updateMovieRootFolder(movie, moveFiles: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the root folder Radarr should use for this movie.")
        }
        .alert("Delete Movie?", isPresented: $showDeleteAlert) {
            Button("Delete & Remove Files", role: .destructive) {
                deleteFiles = true
                Task { await handleDeleteMovie() }
            }
            Button(removeOnlyButtonTitle, role: .destructive) {
                deleteFiles = false
                Task { await handleDeleteMovie() }
            }
            Button("Cancel", role: .cancel) {
                showDeleteAlert = false
            }
        } message: {
            Text(deleteAlertMessage)
        }
        .alert("Delete File?", isPresented: $showDeleteFileAlert) {
            Button("Delete", role: .destructive) {
                if let fileId = movieFileToDelete {
                    Task { await handleDeleteMovieFile(id: fileId) }
                }
            }
            Button("Cancel", role: .cancel) {
                movieFileToDelete = nil
            }
        } message: {
            Text("This removes the current movie file from Radarr.")
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
                    await handleQueueIssueAction(
                        id: action.itemID,
                        instanceID: action.instanceID,
                        blocklist: action.blocklist
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                pendingQueueAction = nil
            }
        } message: {
            Text(
                pendingQueueAction?.blocklist == true
                    ? "This will remove \"\(pendingQueueAction?.title ?? "this item")\" from the queue and add it to Radarr's blocklist."
                    : "This will remove \"\(pendingQueueAction?.title ?? "this item")\" from the Radarr queue."
            )
        }
        .sheet(isPresented: $showEditSheet) {
            if let movie = actionCopy, isInLibrary {
                RadarrEditMovieSheet(viewModel: viewModel, movie: movie)
            }
        }
        .sheet(item: $importIssueResolution) { resolution in
            ArrQueueImportIssueResolutionSheet(
                resolution: resolution,
                serviceManager: serviceManager,
                onImportCompleted: {
                    await viewModel.loadQueue()
                    await viewModel.loadMovies()
                }
            )
        }
        .sheet(isPresented: $showManualImport, onDismiss: { Task { await refreshMovieDetailState() } }) {
            if let movie = actionCopy, let path = movie.path {
                NavigationStack {
                    LibraryImportScanView(
                        path: path,
                        service: .radarr,
                        serviceManager: serviceManager,
                        instanceID: movie.instanceID,
                        libraryItemID: movie.id,
                        showsCloseButton: true,
                        kind: .manual
                    )
                }
                .macSheetSizing()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            if let movie {
                RadarrAddToLibrarySheet(
                    viewModel: viewModel,
                    movie: movie,
                    onAdded: {
                        didAdd = true
                        await onAdded?()
                    }
                )
            }
        }
        .sheet(
            item: $interactiveSearchMovie,
            onDismiss: {
                Task { await refreshMovieDetailState() }
            }
        ) { movie in
            RadarrInteractiveSearchSheet(viewModel: viewModel, movie: movie)
        }
        .sheet(item: $selectedCastMember, onDismiss: completeCastCreditNavigation) { route in
            CastPersonSheet(route: route, onSelectCredit: { pendingCastCredit = $0 })
        }
        .navigationDestination(item: $castCreditMovie) { creditMovie in
            RadarrMovieDetailView(movie: creditMovie, viewModel: viewModel)
                .environment(syncService)
        }
        .navigationDestination(item: $castCreditSeries) { creditSeries in
            SonarrSeriesDetailView(series: creditSeries, viewModel: SonarrViewModel(serviceManager: serviceManager))
                .environment(syncService)
        }
        .task(id: detailPollKey) {
            #if DEBUG
            guard !disablesPreviewLoadingTasks else { return }
            #endif
            // The library comes first: a film added moments ago is not in the
            // preloaded copy yet, and until it lands there is no library ID to
            // load files for and nothing to match the queue against.
            //
            // Appear-time max age, so the shared cache serves it - opening a movie
            // shouldn't re-download the whole library the list already has. Pull to
            // refresh and the queue-driven reloads below still force a fetch.
            await viewModel.loadMovies(maxAge: ArrLibraryCachePolicy.appearMaxAge)
            await loadMovieFilesForResolvedCopies()
            var knownQueueIds = Set(viewModel.queueRecords.map(\.id))
            do {
                while true {
                    try Task.checkCancellation()
                    await viewModel.loadQueue()
                    try Task.checkCancellation()

                    let currentIds = Set(viewModel.queueRecords.map(\.id))
                    let hasActive = queueItems.contains { isActiveQueueItem($0.value) }
                    if currentIds != knownQueueIds || hasActive {
                        await loadMovieFilesForResolvedCopies()
                        try Task.checkCancellation()
                        await viewModel.loadMovies()
                        try Task.checkCancellation()
                    }
                    knownQueueIds = currentIds

                    // Adaptive polling: fast (2s) if active queue items, slow (30s) otherwise
                    let pollInterval = hasActive ? 2 : 30
                    try await Task.sleep(for: .seconds(pollInterval))
                }
            } catch is CancellationError {
                // task was cancelled - exit cleanly
            } catch {
                // ignore transient errors
            }
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
                        if viewModel.movies.contains(where: { $0.tmdbId == resolved.tmdbId }) {
                            selectLibraryTitle(resolved.mergeKey)
                        } else {
                            openMediaInSearch?(.movieLookup(resolved))
                        }
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
                    // Check if it exists in Sonarr (we don't have SonarrViewModel here, so we check if its ID is > 0 or if ArrServiceManager's cache has it)
                    if let selectLibraryTitle {
                        if serviceManager.calendarViewModel?.sonarrSeries.contains(where: { $0.tvdbId == resolved.tvdbId }) == true {
                            selectLibraryTitle(resolved.mergeKey)
                        } else {
                            openMediaInSearch?(.seriesLookup(resolved))
                        }
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

    /// The library ID of the copy the server-specific work targets. Follows the
    /// action picker, so file loads and queue matching stay on the same server the
    /// buttons act on.
    private var resolvedLibraryId: Int? {
        if let copy = actionCopy, entry != nil { return copy.id }
        if let movieId { return movieId }
        guard let tmdbId = movie?.tmdbId else { return nil }
        return viewModel.movies.first { $0.tmdbId == tmdbId }?.id
    }

    /// Re-runs when the target server changes as well as when the title does.
    private var fileLoadKey: String {
        "\(resolvedLibraryId ?? -1):\(entry?.instanceIDs.map(\.uuidString).joined(separator: ",") ?? "")"
    }

    /// Identity of the *screen*, built only from the immutable init inputs.
    ///
    /// The load-and-poll task used to key on `fileLoadKey`, which is derived from
    /// the loaded library. That made the poll loop restart every time the library
    /// reloaded and, worse, stop dead whenever the title was momentarily absent
    /// from it - the task's `guard let id = resolvedLibraryId else { return }`
    /// exited and nothing polled the queue again. A film added minutes earlier
    /// therefore showed its download only for the second between a manual refresh
    /// resolving the id and the next library load dropping it. This key never
    /// changes while the screen is on screen, so the loop runs for its lifetime.
    private var detailPollKey: String {
        [
            mergeKey.map(String.init(describing:)) ?? "-",
            movieId.map(String.init) ?? "-",
            movieInstanceID?.uuidString ?? "-",
            discoverMovie?.tmdbId.map(String.init) ?? "-"
        ].joined(separator: "|")
    }

    /// Names the servers when a title is on both, so the confirmation can't hide
    /// that it removes the film from two libraries.
    private var removeOnlyButtonTitle: String {
        guard instanceRefs.count > 1 else { return "Remove from Radarr Only" }
        return "Remove from \(instanceRefs.map(\.shortLabel).joined(separator: " and ")) Only"
    }

    private var deleteAlertMessage: String {
        guard instanceRefs.count > 1 else {
            return "Remove from Radarr, or also delete the files from disk?"
        }
        let names = instanceRefs.map(\.displayName).joined(separator: " and ")
        return "This removes the movie from \(names). Remove it from both, or also delete the files from disk?"
    }

    /// Deletes every server's copy: the screen shows one title, so leaving one
    /// server's copy behind would look like the delete silently failed.
    private func handleDeleteMovie() async {
        defer { deleteFiles = false }
        let title = movie?.title ?? "Movie"
        let shouldDeleteFiles = deleteFiles

        if let entry {
            await viewModel.deleteEntries([entry], deleteFiles: shouldDeleteFiles)
            if viewModel.error == nil {
                dismiss()
            }
            return
        }

        guard let id = resolvedLibraryId else { return }
        let didDelete = await viewModel.deleteMovie(id: id, deleteFiles: shouldDeleteFiles)
        if didDelete {
            dismiss()
            InAppNotificationCenter.shared.showSuccess(
                title: "Movie Deleted",
                message: shouldDeleteFiles ? "\(title) and its files have been removed." : "\(title) has been removed from Radarr."
            )
            return
        }
        guard let error = viewModel.error else { return }
        InAppNotificationCenter.shared.showError(
            title: shouldDeleteFiles ? "Couldn't Delete Movie and Files" : "Couldn't Delete Movie",
            message: error
        )
    }

    private func handleDeleteMovieFile(id: Int) async {
        let didDelete = await viewModel.deleteMovieFile(id: id)
        if didDelete {
            InAppNotificationCenter.shared.showSuccess(title: "File Deleted", message: "The movie file has been removed.")
            return
        }
        guard let error = viewModel.error else { return }
        InAppNotificationCenter.shared.showError(title: "Couldn't Delete Movie File", message: error)
    }

    private func updateMovieRootFolder(_ movie: RadarrMovie, moveFiles: Bool) async {
        let rootFolderPath = rootFolderText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootFolderPath.isEmpty else { return }
        guard let qualityProfileId = movie.qualityProfileId else {
            InAppNotificationCenter.shared.showError(title: "Update Failed", message: "Movie quality profile is missing.")
            return
        }

        _ = await viewModel.updateMovie(
            movie,
            monitored: movie.monitored ?? false,
            qualityProfileId: qualityProfileId,
            minimumAvailability: movie.minimumAvailability ?? "released",
            rootFolderPath: rootFolderPath,
            tags: movie.tags ?? [],
            moveFiles: moveFiles
        )
    }

    private func renameMovieFiles() async {
        guard let movie = actionCopy,
              let client = serviceManager.radarrClient(owning: movie) else { return }
        isRenamingFiles = true
        defer { isRenamingFiles = false }
        do {
            _ = try await client.renameMovieFiles(movieId: movie.id)
            InAppNotificationCenter.shared.showSuccess(
                title: "Rename Queued",
                message: "Radarr is renaming the movie file in the background."
            )
        } catch {
            InAppNotificationCenter.shared.showError(title: "Rename Failed", message: error.localizedDescription)
        }
    }

    /// Loads media files for whichever copies are currently resolved, and does
    /// nothing when the title has not landed in the library yet. Separate from the
    /// poll loop so a missing library ID skips the file load rather than the whole
    /// task - the queue still needs polling either way.
    private func loadMovieFilesForResolvedCopies() async {
        if let entry, entry.isOnMultipleInstances {
            await viewModel.loadMovieFiles(for: entry)
        } else if let id = resolvedLibraryId {
            await viewModel.loadMovieFiles(movieId: id)
        }
    }

    private func refreshMovieDetailState() async {
        // Library first, so a title added moments ago resolves an ID before the
        // file load below asks for one. The queue is loaded either way: it is what
        // the download card renders from and it does not depend on that ID.
        await viewModel.loadMovies()
        await viewModel.loadQueue()
        await loadMovieFilesForResolvedCopies()
    }

    /// Every server's downloads for this title, matched on `(server, library ID)`.
    ///
    /// Matching on `movieId` alone is instance-blind - the pair reuse the same
    /// integers, so the HD server's download for its id 211 would surface on the
    /// 4K server's film with that id. Keying off `resolvedLibraryId` also tied the
    /// card to the action picker, hiding a running download whenever that moved.
    /// Ask each copy for its own server's rows instead.
    private var queueItems: [ArrInstanced<ArrQueueItem>] {
        arrDetailQueueItems(
            for: entry,
            fallbackLibraryID: resolvedLibraryId,
            queueRecords: viewModel.queueRecords,
            libraryID: \.movieId
        )
    }

    private var activeQueueItems: [ArrInstanced<ArrQueueItem>] {
        queueItems.filter { isActiveQueueItem($0.value) }
    }

    private var importIssueQueueItems: [ArrInstanced<ArrQueueItem>] {
        queueItems.filter { !isActiveQueueItem($0.value) && $0.value.isImportIssueQueueItem }
    }

    // MARK: - Hero

    private func heroSection(_ movie: RadarrMovie) -> some View {
        ArrDetailHeaderView(
            title: movie.title,
            posterURL: movie.posterURL,
            iconName: "film",
            iconColor: .orange,
            networkOrStudio: movie.studio,
            year: movie.year,
            runtime: movie.runtime,
            badges: movie.detailBadges(context: ArrBadgeContext(
                queue: viewModel.queue,
                isInLibrary: isInLibrary,
                hasBazarr: serviceManager.hasAnyConnectedBazarrInstance,
                subtitleCoverage: serviceManager.subtitleCoverage(for: movie)
            )),
            genres: movie.genres ?? []
        )
        .overlay(alignment: .topTrailing) {
            // Says at a glance which servers hold this title, before any card is
            // read. Absent entirely when only one Radarr is configured.
            ArrInstanceBadgeRow(refs: instanceRefs, style: .prominent)
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
    }

    // MARK: - Cards section

    @ViewBuilder
    private func cardsSection(_ movie: RadarrMovie) -> some View {
        if !isInLibrary {
            Button {
                showAddSheet = true
            } label: {
                Label("Add to Radarr", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }

        if isInLibrary {
            searchActionsCard(movie)
            addToOtherServerCard
        }

        if !activeQueueItems.isEmpty {
            ArrDetailQueueCard(items: activeQueueItems) { item in
                ArrDetailQueueItemRow(
                    item: item.value,
                    instanceID: item.instance.id,
                    isRemoving: queueActionInFlightIDs.contains(item.id),
                    onSetPendingAction: { pendingQueueAction = $0 }
                )
            }
        }

        if let ratings = movie.ratings {
            ratingsCard(ratings)
        }

        if let overview = movie.overview, !overview.isEmpty {
            ArrDetailOverviewCard(text: overview)
        }

        if let castMembers, !castMembers.isEmpty {
            CastShelfView(
                items: castMembers.prefix(20).map(CastShelfItem.init),
                onSelect: { selectedCastMember = $0.destination }
            )
        }

        statsCard(movie)

        JellyfinMediaAvailabilityCard(
            media: .movie(
                title: movie.title,
                year: movie.year,
                tmdbId: movie.tmdbId,
                imdbId: movie.imdbId
            )
        )

        if let tmdbId = movie.tmdbId {
            SeerrMediaRequestCard(media: .movie(tmdbId: tmdbId, title: movie.title))
        }

        if isInLibrary {
            BazarrSubtitleStatusCard(media: .movie(
                radarrId: movie.id,
                title: movie.title,
                embeddedSubtitles: movie.movieFile?.mediaInfo?.subtitles,
                hasFile: movie.hasFile == true || movie.movieFile != nil
            ))
        }

        if !importIssueQueueItems.isEmpty {
            ArrDetailImportIssuesCard(items: importIssueQueueItems) { item in
                ArrDetailQueueIssueRow(
                    item: item.value,
                    instanceID: item.instance.id,
                    rootFolderPath: movie.rootFolderPath,
                    service: .radarr,
                    libraryItemID: resolvedLibraryId,
                    editNoun: "Movie",
                    isRemoving: queueActionInFlightIDs.contains(item.id),
                    isInLibrary: isInLibrary,
                    onEdit: { showEditSheet = true },
                    onSetResolution: { importIssueResolution = $0 },
                    onSetPendingAction: { pendingQueueAction = $0 }
                )
            }
        }

        releaseDatesCard(movie)
        infoCard(movie)
        collectionCard(movie)
        trailerCard(movie)

        // Library-only: file card
        if isInLibrary {
            filesCard
        }
        
        if let alternateTitles = movie.alternateTitles, !alternateTitles.isEmpty {
            ArrDetailAlternateTitlesCard(titles: alternateTitles.map { title in
                (
                    title: title.title ?? "Untitled",
                    subtitle: title.sourceType.flatMap { $0.isEmpty ? nil : $0 }
                )
            })
        }
    }

    // MARK: - Overview card

    // MARK: - Stats card

    /// Runtime is metadata and identical on both servers; disk usage is not. On a
    /// pair each server gets its own "On Disk" cell, because "68 GB" for a film
    /// that is 68 GB in 4K and 14 GB in HD describes neither server.
    ///
    /// Status is an availability pill rather than a stat cell - it is the one
    /// thing here that answers "do I have this, and in what", so it reads as a
    /// state and not as another number.
    private func statsCard(_ movie: RadarrMovie) -> some View {
        let perInstance = perInstanceSizes
        return HStack(spacing: 0) {
            if let runtime = movie.runtime, runtime > 0 {
                statCell(value: "\(runtime)m", label: "Runtime")
                cardDivider
            }
            if perInstance.count > 1 {
                ForEach(perInstance, id: \.ref.id) { entryPair in
                    statCell(
                        value: entryPair.size > 0 ? ByteFormatter.format(bytes: entryPair.size) : "-",
                        label: "\(entryPair.ref.shortLabel) on Disk"
                    )
                    cardDivider
                }
            } else if let size = movie.sizeOnDisk, size > 0 {
                statCell(value: ByteFormatter.format(bytes: size), label: "On Disk")
                cardDivider
            }
            VStack(spacing: 4) {
                ArrAvailabilityPill(
                    availableTiers: availableTiers,
                    showsTiers: !instanceRefs.isEmpty,
                    unavailableStatus: movie.displayStatus
                )
                Text("Status")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Natural width, so the numeric cells share the remainder instead of
            // every cell taking an equal share and squeezing the longest label.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var availableTiers: [ArrQualityTier] {
        entry?.availableTiers(from: instanceRefs) { $0.hasFile == true } ?? []
    }

    private var perInstanceSizes: [(ref: ArrInstanceRef, size: Int64)] {
        guard let entry, instanceRefs.count == entry.copies.count else { return [] }
        return zip(instanceRefs, entry.copies).map { (ref: $0, size: $1.sizeOnDisk ?? 0) }
    }

    /// A search runs on one server and grabs into that server's library, so when
    /// a title is on a pair the card first asks which one. Without that the
    /// buttons would silently pick a server, and "search for this film" would
    /// fetch a 4K release into the HD library as often as not.
    /// Extracted so the direct (one server) and chosen-server paths cannot drift.
    private func performAutomaticSearch(_ target: RadarrMovie) {
        guard !isDispatchingAutomaticSearch else { return }
        isDispatchingAutomaticSearch = true
        Task {
            await viewModel.searchMovie(movieId: target.id, instanceID: target.instanceID)
            isDispatchingAutomaticSearch = false

            if let error = viewModel.error, !error.isEmpty {
                InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
            } else {
                InAppNotificationCenter.shared.showSuccess(
                    title: "Search Queued",
                    message: searchQueuedMessage(for: target)
                )
            }
        }
    }

    @ViewBuilder
    private func searchActionsCard(_ movie: RadarrMovie) -> some View {
        let target = actionCopy ?? movie
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    // HD and 4K want different releases into different root folders,
                    // so with a pair the server is chosen here rather than inherited
                    // from a mode set elsewhere on the page.
                    if serverChoices.isEmpty {
                        performAutomaticSearch(target)
                    } else {
                        pendingServerAction = .automaticSearch
                    }
                } label: {
                    detailSearchButtonLabel(
                        title: "Automatic",
                        subtitle: "Normal search",
                        systemImage: "magnifyingglass",
                        isLoading: isDispatchingAutomaticSearch
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button {
                    if serverChoices.isEmpty {
                        interactiveSearchMovie = target
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
    }

    /// Offers the server that does not have this title yet.
    ///
    /// `isInLibrary` is true when *any* server holds the film, which is what used
    /// to hide the add button entirely: with a pair configured and the film on one
    /// of them, there was no way to put it on the other from anywhere in the app.
    /// Named rather than generic, because there is exactly one candidate here - a
    /// title on neither server takes the plain "Add to Radarr" button above, where
    /// the sheet does the choosing.
    @ViewBuilder
    private var addToOtherServerCard: some View {
        // At most one: reaching this means some server already holds the title, and
        // a service is capped at two.
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

    /// The configured servers that do not hold this title. Empty with one server,
    /// and empty when both already have it.
    private var missingInstances: [ArrInstanceRef] {
        guard let entry else { return [] }
        let refs = serviceManager.refs(for: .radarr)
        guard refs.count > 1 else { return [] }
        return entry.instancesMissingThis(from: refs)
    }

    /// The servers this title is on, paired with the copy each one holds. Empty
    /// when there is nothing to choose between.
    private var serverChoices: [(ref: ArrInstanceRef, copy: RadarrMovie)] {
        guard let entry, entry.isOnMultipleInstances, instanceRefs.count == entry.copies.count else { return [] }
        return Array(zip(instanceRefs, entry.copies)).map { (ref: $0.0, copy: $0.1) }
    }

    /// Points the server-scoped state at one copy and then runs the action, so the
    /// sheet or alert that follows opens against the server just chosen.
    private func act(on copy: RadarrMovie, _ perform: () -> Void) {
        actionInstanceID = copy.instanceID
        perform()
    }

    /// A toolbar item that has to name a server when there are two. With one
    /// server it stays a plain button - nothing to disambiguate, and a submenu
    /// would be a tap for nothing.
    @ViewBuilder
    private func serverScopedMenuItem(
        title: String,
        systemImage: String,
        choiceLabel: @escaping (ArrInstanceRef, RadarrMovie) -> String = { ref, _ in ref.shortLabel },
        isEnabled: Bool = true,
        perform: @escaping (RadarrMovie) -> Void
    ) -> some View {
        let choices = serverChoices
        if choices.isEmpty {
            if let movie = actionCopy {
                Button {
                    act(on: movie) { perform(movie) }
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

    private func searchQueuedMessage(for target: RadarrMovie) -> String {
        guard let ref = instanceRefs.first(where: { $0.id == target.instanceID }),
              instanceRefs.count > 1 else {
            return "\(target.title) was sent to Radarr for automatic search."
        }
        return "\(target.title) was sent to \(ref.displayName) for automatic search."
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
                .foregroundStyle(.orange)
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

    // MARK: - Genre chips

    // MARK: - Ratings card

    @ViewBuilder
    private func ratingsCard(_ ratings: RadarrRatings) -> some View {
        let items: [(String, String)] = [
            ratings.imdb?.value.map { ("IMDb", String(format: "%.1f", $0)) },
            ratings.tmdb?.value.map { ("TMDb", String(format: "%.0f%%", $0 * 10)) },
            ratings.rottenTomatoes?.value.map { ("RT", String(format: "%.0f%%", $0)) },
            ratings.metacritic?.value.map { ("MC", String(format: "%.0f", $0)) }
        ].compactMap { $0 }

        if !items.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Group {
                        if item.0 == "IMDb", let imdbId = movie?.imdbId, !imdbId.isEmpty,
                           let url = URL(string: "https://www.imdb.com/title/\(imdbId)/") {
                            Link(destination: url) {
                                VStack(spacing: 2) {
                                    Text(item.1).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                    HStack(spacing: 3) {
                                        Text(item.0)
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.system(size: 8))
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            VStack(spacing: 2) {
                                Text(item.1).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                Text(item.0).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
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

    private func handleQueueIssueAction(id: Int, instanceID: UUID?, blocklist: Bool) async {
        let actionID = "\(instanceID?.uuidString ?? "unscoped"):\(id)"
        queueActionInFlightIDs.insert(actionID)
        defer { queueActionInFlightIDs.remove(actionID) }

        let wasRemoved = await viewModel.removeQueueItem(id: id, instanceID: instanceID, blocklist: blocklist)

        if wasRemoved {
            if blocklist {
                await serviceManager.loadBlocklist()
            }
            InAppNotificationCenter.shared.showSuccess(
                title: blocklist ? "Blocked" : "Removed",
                message: blocklist
                    ? "The queue item was removed and blocklisted."
                    : "The queue item was removed from Radarr."
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

    // MARK: - Release dates card

    @ViewBuilder
    private func releaseDatesCard(_ movie: RadarrMovie) -> some View {
        let dates: [(String, String, String)] = [
            ("popcorn", "In Cinemas", movie.inCinemas ?? ""),
            ("wifi", "Digital", movie.digitalRelease ?? ""),
            ("opticaldiscdrive", "Physical", movie.physicalRelease ?? "")
        ].filter { !$0.2.isEmpty }

        if !dates.isEmpty {
            rowsCard(header: "Release Dates", icon: "calendar", rows: dates.map { ($0.0, $0.1, formatDateString($0.2)) })
        }
    }

    // MARK: - Info card

    /// One path row per server. Each server has its own root folder - an HD and a
    /// 4K library in the same folder is the setup this pair exists to avoid - so a
    /// single "Path" row would show one server's location and quietly withhold the
    /// other's. The identifiers below are metadata and identical on both, so they
    /// stay single.
    private func pathRows(_ movie: RadarrMovie) -> [(String, String, String)] {
        guard isInLibrary else { return [] }
        let choices = serverChoices
        guard !choices.isEmpty else {
            return movie.path.map { [("folder", "Path", $0)] } ?? []
        }
        return choices.compactMap { choice in
            choice.copy.path.map { ("folder", "\(choice.ref.shortLabel) Path", $0) }
        }
    }

    @ViewBuilder
    private func infoCard(_ movie: RadarrMovie) -> some View {
        let rows: [(String, String, String)] = pathRows(movie) + [
            movie.imdbId.flatMap { $0.isEmpty ? nil : ("number", "IMDb", $0) },
            movie.tmdbId.map { ("number.circle", "TMDb", String($0)) }
        ].compactMap { $0 }

        if !rows.isEmpty {
            rowsCard(header: "Details", icon: "info.circle", rows: rows)
        }
    }

    @ViewBuilder
    private func collectionCard(_ movie: RadarrMovie) -> some View {
        if let collection = movie.collection {
            let rows: [(String, String, String)] = [
                ("square.stack.3d.up", "Collection", collection.name ?? ""),
                ("number.circle", "TMDb", collection.tmdbId.map { String($0) } ?? "")
            ].filter { !$0.2.isEmpty }

            if !rows.isEmpty {
                rowsCard(header: "Collection", icon: "square.stack.3d.up.fill", rows: rows)
            }
        }
    }

    @ViewBuilder
    private func trailerCard(_ movie: RadarrMovie) -> some View {
        if let trailerId = movie.youTubeTrailerId, !trailerId.isEmpty,
           let url = URL(string: "https://www.youtube.com/watch?v=\(trailerId)") {
            Link(destination: url) {
                Label("Watch Trailer", systemImage: "play.rectangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Files card

    /// Files, grouped by the server holding them.
    ///
    /// This is the card the whole HD/4K setup exists for: seeing that the 4K
    /// server has the 2160p remux and the HD server has the 1080p encode, side by
    /// side, without switching screens. With one server configured it collapses
    /// back to a plain file list.
    @ViewBuilder
    private var filesCard: some View {
        if let entry, entry.isOnMultipleInstances, instanceRefs.count == entry.copies.count {
            perInstanceFilesCard(entry: entry)
        } else {
            singleInstanceFilesCard
        }
    }

    private func perInstanceFilesCard(entry: ArrLibraryEntry<RadarrMovie>) -> some View {
        let groups = zip(instanceRefs, entry.copies).map { ref, copy in
            (ref: ref, files: viewModel.movieFilesByInstance[copy.instanceID ?? UUID()] ?? [])
        }
        let total = groups.reduce(0) { $0 + $1.files.count }

        return Group {
            if total > 0 {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isFilesExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                sectionLabel(total == 1 ? "File" : "Files", icon: "doc.fill")
                                Text("\(total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: isFilesExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, isFilesExpanded ? 8 : 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isFilesExpanded {
                        ForEach(groups, id: \.ref.id) { group in
                            HStack(spacing: 6) {
                                ArrInstanceBadge(label: group.ref.shortLabel, ordinal: group.ref.ordinal)
                                if group.files.isEmpty {
                                    Text("No file on this server")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)

                            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                                ArrMediaFileRow(config: file.arrMediaFileConfig(
                                    subtitles: bazarrMovieSubtitles,
                                    onDelete: {
                                        movieFileToDelete = file.id
                                        showDeleteFileAlert = true
                                    }
                                ))
                                if index < group.files.count - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private var singleInstanceFilesCard: some View {
        let files = viewModel.movieFiles
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isFilesExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            sectionLabel(files.count == 1 ? "File" : "Files", icon: "doc.fill")
                            Text("\(files.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isFilesExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, isFilesExpanded ? 8 : 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isFilesExpanded {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        ArrMediaFileRow(config: file.arrMediaFileConfig(
                            subtitles: bazarrMovieSubtitles,
                            onDelete: {
                                movieFileToDelete = file.id
                                showDeleteFileAlert = true
                            }
                        ))
                        if index < files.count - 1 {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Shared rows card

    private func rowsCard<Footer: View>(
        header: String,
        icon: String,
        rows: [(String, String, String)],
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(header, icon: icon)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 10) {
                    Image(systemName: row.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .center)

                    Text(row.1)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Text(row.2)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                if index < rows.count - 1 {
                    Divider().padding(.leading, 42)
                }
            }

            footer()
            Color.clear.frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.white)
    }

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let standardISOFormatter = ISO8601DateFormatter()

    private static let fallbackDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func formatDateString(_ string: String) -> String {
        if let date = Self.fractionalISOFormatter.date(from: string) ?? Self.standardISOFormatter.date(from: string) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let df = Self.fallbackDateFormatter
        if let date = df.date(from: string) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateStyle = .medium
            outputFormatter.timeStyle = .none
            return outputFormatter.string(from: date)
        }
        return string
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        // macOS shares one toolbar between the split view's list and detail
        // columns. Keep this movie's actions in a separate trailing group.
        ToolbarSpacer(.flexible, placement: .primaryAction)
        #endif
        ToolbarItem(placement: .primaryAction) {
            if isInLibrary {
                if let movie = actionCopy {
                    Menu {
                        // Each of these edits one server's copy, so with a pair
                        // they nest a server choice rather than inheriting a mode
                        // set on a part of the page the toolbar cannot show.
                        serverScopedMenuItem(title: "Edit", systemImage: "slider.horizontal.3") { _ in
                            showEditSheet = true
                        }

                        serverScopedMenuItem(title: "Change Root Folder", systemImage: "folder") { copy in
                            rootFolderText = copy.rootFolderPath ?? ""
                            showRootFolderAlert = true
                        }

                        serverScopedMenuItem(
                            title: movie.monitored == true ? "Unmonitor" : "Monitor",
                            systemImage: movie.monitored == true ? "bookmark.slash" : "bookmark.fill",
                            choiceLabel: { ref, copy in
                                "\(ref.shortLabel) - \(copy.monitored == true ? "Unmonitor" : "Monitor")"
                            }
                        ) { copy in
                            Task { await viewModel.toggleMovieMonitored(copy) }
                        }

                        // Refreshes the library, not one copy, so it stays a plain
                        // button.
                        Button {
                            Task { try? await viewModel.refreshMovies() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        serverScopedMenuItem(
                            title: "Rename Files",
                            systemImage: "pencil.and.list.clipboard",
                            isEnabled: !isRenamingFiles
                        ) { _ in
                            showRenameFilesAlert = true
                        }

                        if movie.path != nil {
                            serverScopedMenuItem(title: "Manual Import", systemImage: "tray.and.arrow.down.fill") { _ in
                                showManualImport = true
                            }
                        }

                        Divider()
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .alert("Rename Movie File?", isPresented: $showRenameFilesAlert) {
                        Button("Rename") { Task { await renameMovieFiles() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The movie file will be renamed on disk to match the current naming format configured in Radarr.")
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Downloaded Detail") {
    let movie = RadarrMovie.preview
    let vm = RadarrViewModel(
        previewMovies: [movie],
        movieFiles: [.makePreview(movieId: movie.id)]
    )
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieDetailView(previewMovieId: movie.id, viewModel: vm)
        }
    }
}

#Preview("Sparse Detail") {
    let movie = RadarrMovie.previewSparse
    let vm = RadarrViewModel(previewMovies: [movie])
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieDetailView(previewMovieId: movie.id, viewModel: vm)
        }
    }
}

#Preview("Discover Detail") {
    let movie = RadarrMovie.previewAnnounced
    let vm = RadarrViewModel(previewMovies: [])
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieDetailView(previewMovie: movie, viewModel: vm)
        }
    }
}
#endif
