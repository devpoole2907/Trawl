import SwiftUI

struct RadarrMovieDetailView: View {
    @Bindable var viewModel: RadarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(\.dismiss) private var dismiss

    // Library mode: look up movie by ID from viewModel
    private let movieId: Int?
    // Discover mode: movie object passed directly
    private let discoverMovie: RadarrMovie?
    private let onAdded: (() async -> Void)?

    @State private var showRenameFilesAlert = false
    @State private var isRenamingFiles = false
    @State private var showDeleteAlert = false
    @State private var deleteFiles = false
    @State private var showEditSheet = false
    @State private var showDeleteFileAlert = false
    @State private var movieFileToDelete: Int?
    @State private var isFilesExpanded = false
    @State private var showAddSheet = false
    @State private var importIssueResolution: ArrQueueImportIssueResolution?
    @State private var didAdd = false
    @State private var showInteractiveSearchSheet = false
    @State private var isDispatchingAutomaticSearch = false
    @State private var queueActionInFlightIDs: Set<Int> = []
    @State private var pendingQueueAction: ArrDetailPendingQueueAction?
    @State private var bazarrMovieSubtitles: [BazarrSubtitle]?

    /// Library init — movie lives in the ViewModel's loaded library.
    init(movieId: Int, viewModel: RadarrViewModel) {
        self.movieId = movieId
        self.discoverMovie = nil
        self.viewModel = viewModel
        self.onAdded = nil
    }

    /// Discover init — movie comes from a lookup result, may or may not be in library.
    init(movie: RadarrMovie, viewModel: RadarrViewModel, onAdded: (() async -> Void)? = nil) {
        self.discoverMovie = movie
        // If it's already in the library, use its library ID
        let libraryMatch = viewModel.movies.first { $0.tmdbId == movie.tmdbId }
        self.movieId = libraryMatch?.id
        self.viewModel = viewModel
        self.onAdded = onAdded
    }

    /// The resolved movie: prefer library version (by ID or TMDb ID), fall back to discover object.
    private var movie: RadarrMovie? {
        if let movieId, let found = viewModel.movies.first(where: { $0.id == movieId }) {
            return found
        }
        // After adding, the movie may be in the library under a new ID
        if let tmdbId = discoverMovie?.tmdbId,
           let found = viewModel.movies.first(where: { $0.tmdbId == tmdbId }) {
            return found
        }
        return discoverMovie
    }

    /// Whether this movie is present in the library.
    private var isInLibrary: Bool {
        guard let tmdbId = (discoverMovie?.tmdbId ?? movie?.tmdbId) else {
            return movieId != nil
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
        .task(id: movie?.id) {
            bazarrMovieSubtitles = nil
            guard let movie, let client = serviceManager.activeBazarrEntry?.client else { return }
            if let page = try? await client.getMovies(ids: [movie.id]),
               let fetched = page.data.first,
               !fetched.subtitles.isEmpty {
                bazarrMovieSubtitles = fetched.subtitles
            }
        }
        .toolbar { toolbarContent }
        .alert("Delete Movie?", isPresented: $showDeleteAlert) {
            Button("Delete & Remove Files", role: .destructive) {
                if let id = resolvedLibraryId {
                    deleteFiles = true
                    Task { await handleDeleteMovie(id: id) }
                }
            }
            Button("Remove from Radarr Only", role: .destructive) {
                if let id = resolvedLibraryId {
                    deleteFiles = false
                    Task { await handleDeleteMovie(id: id) }
                }
            }
            Button("Cancel", role: .cancel) {
                showDeleteAlert = false
            }
        } message: {
            Text("Remove from Radarr, or also delete the files from disk?")
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
            if let movie, isInLibrary {
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
            isPresented: $showInteractiveSearchSheet,
            onDismiss: {
                Task { await refreshMovieDetailState() }
            }
        ) {
            if let movie, isInLibrary {
                RadarrInteractiveSearchSheet(viewModel: viewModel, movie: movie)
            }
        }
        .task(id: resolvedLibraryId) {
            guard let id = resolvedLibraryId else { return }
            await viewModel.loadMovieFiles(movieId: id)
            await viewModel.loadMovies()
            var knownQueueIds = Set(viewModel.queue.map(\.id))
            do {
                while true {
                    try Task.checkCancellation()
                    await viewModel.loadQueue()
                    try Task.checkCancellation()

                    let currentIds = Set(viewModel.queue.map(\.id))
                    let hasActive = viewModel.queue.contains { $0.movieId == id && isActiveQueueItem($0) }
                    if currentIds != knownQueueIds || hasActive {
                        await viewModel.loadMovieFiles(movieId: id)
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
                // task was cancelled — exit cleanly
            } catch {
                // ignore transient errors
            }
        }
    }

    private var resolvedLibraryId: Int? {
        if let movieId { return movieId }
        guard let tmdbId = movie?.tmdbId else { return nil }
        return viewModel.movies.first { $0.tmdbId == tmdbId }?.id
    }

    private func handleDeleteMovie(id: Int) async {
        defer { deleteFiles = false }
        let title = movie?.title ?? "Movie"
        let didDelete = await viewModel.deleteMovie(id: id, deleteFiles: deleteFiles)
        if didDelete {
            dismiss()
            InAppNotificationCenter.shared.showSuccess(
                title: "Movie Deleted",
                message: deleteFiles ? "\(title) and its files have been removed." : "\(title) has been removed from Radarr."
            )
            return
        }
        guard let error = viewModel.error else { return }
        InAppNotificationCenter.shared.showError(
            title: deleteFiles ? "Couldn't Delete Movie and Files" : "Couldn't Delete Movie",
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

    private func renameMovieFiles() async {
        guard let id = resolvedLibraryId,
              let client = serviceManager.radarrClient else { return }
        isRenamingFiles = true
        defer { isRenamingFiles = false }
        do {
            try await client.renameMovieFiles(movieId: id)
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
        await viewModel.loadMovieFiles(movieId: id)
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
                radarrBazarrStatus: serviceManager.bazarrSubtitleStatus(forRadarrId: movie.id)
            )),
            genres: movie.genres ?? []
        )
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

        if let ratings = movie.ratings {
            ratingsCard(ratings)
        }

        if let overview = movie.overview, !overview.isEmpty {
            ArrDetailOverviewCard(text: overview)
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
            BazarrSubtitleStatusCard(media: .movie(radarrId: movie.id, title: movie.title))
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

    private func statsCard(_ movie: RadarrMovie) -> some View {
        HStack(spacing: 0) {
            if let runtime = movie.runtime, runtime > 0 {
                statCell(value: "\(runtime)m", label: "Runtime")
                cardDivider
            }
            if let size = movie.sizeOnDisk, size > 0 {
                statCell(value: ByteFormatter.format(bytes: size), label: "On Disk")
                cardDivider
            }
            statCell(value: movie.displayStatus, label: "Status")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func searchActionsCard(_ movie: RadarrMovie) -> some View {
        HStack(spacing: 12) {
            Button {
                guard !isDispatchingAutomaticSearch else { return }
                isDispatchingAutomaticSearch = true
                Task {
                    await viewModel.searchMovie(movieId: movie.id)
                    isDispatchingAutomaticSearch = false

                    if let error = viewModel.error, !error.isEmpty {
                        InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
                    } else {
                        InAppNotificationCenter.shared.showSuccess(
                            title: "Search Queued",
                            message: "\(movie.title) was sent to Radarr for automatic search."
                        )
                    }
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
                showInteractiveSearchSheet = true
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

    @ViewBuilder
    private func infoCard(_ movie: RadarrMovie) -> some View {
        let rows: [(String, String, String)] = [
            isInLibrary ? movie.path.map { ("folder", "Path", $0) } : nil,
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

    @ViewBuilder
    private var filesCard: some View {
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
            df.dateStyle = .medium; df.dateFormat = nil
            let result = df.string(from: date)
            df.dateFormat = "yyyy-MM-dd"
            return result
        }
        return string
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if isInLibrary {
                if let movie {
                    Menu {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }

                        Button {
                            Task { await viewModel.toggleMovieMonitored(movie) }
                        } label: {
                            Label(
                                movie.monitored == true ? "Unmonitor" : "Monitor",
                                systemImage: movie.monitored == true ? "bookmark.slash" : "bookmark.fill"
                            )
                        }

                        Button {
                            Task { try? await viewModel.refreshMovies() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button {
                            showRenameFilesAlert = true
                        } label: {
                            Label("Rename Files", systemImage: "pencil.and.list.clipboard")
                        }
                        .disabled(isRenamingFiles)

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
