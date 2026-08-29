import SwiftUI

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
    @State private var queueActionInFlightIDs: Set<Int> = []
    @State private var pendingQueueAction: ArrDetailPendingQueueAction?
    @State private var bazarrMovieSubtitles: [BazarrSubtitle]?
    @State private var castMembers: [TMDbCastMember]?
    @State private var selectedCastMember: CastPersonRoute?
    /// Filmography tap captured while the cast sheet is up; navigation runs after
    /// the sheet dismisses so the push doesn't race the dismissal animation.
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
        self.discoverMovie = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Library init - movie lives in the ViewModel's loaded library. Kept for the
    /// entry points that only have a library ID: widgets, Siri intents, Seerr
    /// deep links, calendar and wanted rows.
    init(movieId: Int, viewModel: RadarrViewModel) {
        self.movieId = movieId
        self.mergeKey = nil
        self.discoverMovie = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Discover init - movie comes from a lookup result, may or may not be in library.
    init(movie: RadarrMovie, viewModel: RadarrViewModel, onAdded: (() async -> Void)? = nil) {
        self.discoverMovie = movie
        self.mergeKey = nil
        // If it's already in the library, use its library ID
        let libraryMatch = viewModel.movies.first { $0.tmdbId == movie.tmdbId }
        self.movieId = libraryMatch?.id
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
        let merged = viewModel.movies.mergedByTitle()
        if let mergeKey {
            return merged.first { $0.id == mergeKey }
        }
        if let movieId, let match = merged.first(where: { $0.copy(withLibraryID: movieId) != nil }) {
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
        .task(id: fileLoadKey) {
            #if DEBUG
            guard !disablesPreviewLoadingTasks else { return }
            #endif
            guard let id = resolvedLibraryId else { return }
            // Both servers' files, so the card can show what each one holds.
            if let entry, entry.isOnMultipleInstances {
                await viewModel.loadMovieFiles(for: entry)
            } else {
                await viewModel.loadMovieFiles(movieId: id)
            }
            // Appear-time only, so the shared cache serves it - opening a movie
            // shouldn't re-download the whole library the list already has. Pull to
            // refresh and the queue-driven reloads below still force a fetch.
            await viewModel.loadMovies(maxAge: ArrLibraryCachePolicy.appearMaxAge)
            var knownQueueIds = Set(viewModel.queue.map(\.id))
            do {
                while true {
                    try Task.checkCancellation()
                    await viewModel.loadQueue()
                    try Task.checkCancellation()

                    let currentIds = Set(viewModel.queue.map(\.id))
                    let hasActive = viewModel.queue.contains { $0.movieId == id && isActiveQueueItem($0) }
                    if currentIds != knownQueueIds || hasActive {
                        if let entry, entry.isOnMultipleInstances {
                            await viewModel.loadMovieFiles(for: entry)
                        } else {
                            await viewModel.loadMovieFiles(movieId: id)
                        }
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
                    castCreditMovie = resolved
                } else {
                    InAppNotificationCenter.shared.showError(
                        title: "Couldn't Open Title",
                        message: "Radarr couldn't find \"\(credit.displayTitle)\"."
                    )
                }
            } else {
                if let resolved = await resolver.resolveSeries(tmdbId: credit.id) {
                    castCreditSeries = resolved
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

    private func refreshMovieDetailState() async {
        guard let id = resolvedLibraryId else {
            await viewModel.loadMovies()
            return
        }
        await viewModel.loadQueue()
        if let entry, entry.isOnMultipleInstances {
            await viewModel.loadMovieFiles(for: entry)
        } else {
            await viewModel.loadMovieFiles(movieId: id)
        }
        await viewModel.loadMovies()
    }

    private var queueItems: [ArrQueueItem] {
        guard let id = resolvedLibraryId else { return [] }
        return viewModel.queue
            .filter { $0.movieId == id }
            .sorted { $0.progress > $1.progress }
    }

    private var activeQueueItems: [ArrQueueItem] {
        queueItems.filter(isActiveQueueItem)
    }

    private var importIssueQueueItems: [ArrQueueItem] {
        queueItems.filter { !isActiveQueueItem($0) && $0.isImportIssueQueueItem }
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
                    item: item,
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
