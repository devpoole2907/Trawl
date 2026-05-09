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

    var body: some View {
        ArrItemDetailView(
            item: movie,
            title: movie?.title ?? "Movie",
            backgroundURL: movie?.posterURL ?? movie?.fanartURL
        ) {
            if let movie {
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
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: movie?.hasFile)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: movie?.monitored)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isInLibrary)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.queue.map(\.id))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.movieFiles.map(\.id))
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
        .sheet(isPresented: $showInteractiveSearchSheet) {
            if let movie, isInLibrary {
                RadarrInteractiveSearchSheet(viewModel: viewModel, movie: movie)
            }
        }
        .task(id: resolvedLibraryId) {
            guard let id = resolvedLibraryId else { return }
            await viewModel.loadMovieFiles(movieId: id)
            var knownQueueIds = Set(viewModel.queue.map(\.id))
            while !Task.isCancelled {
                await viewModel.loadQueue()
                let currentIds = Set(viewModel.queue.map(\.id))
                if currentIds != knownQueueIds {
                    await viewModel.loadMovieFiles(movieId: id)
                }
                knownQueueIds = currentIds
                try? await Task.sleep(for: .seconds(2))
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

    // MARK: - Background

    private func artBackground(url: URL?) -> some View {
        ArrArtworkView(url: url, contentMode: .fill) {
            Rectangle().fill(Color.orange.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(1.4)
        .blur(radius: 60)
        .saturation(1.6)
        .overlay(Color.black.opacity(0.55))
        .ignoresSafeArea()
    }

    // MARK: - Scroll content

    private func scrollContent(_ movie: RadarrMovie) -> some View {
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
        .environment(\.colorScheme, .dark)
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
            badges: movieBadges(movie)
        )
    }

    private func movieBadges(_ movie: RadarrMovie) -> [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        let hasFile = movie.hasFile == true

        badges.append(
            ArrDetailBadge(
                icon: hasFile ? "checkmark.circle.fill" : "clock",
                label: movie.displayStatus,
                color: hasFile ? .green : .orange
            )
        )

        if let cert = movie.certification, !cert.isEmpty {
            badges.append(ArrDetailBadge(icon: "shield", label: cert, color: .white.opacity(0.8)))
        }

        if isInLibrary && movie.monitored == true {
            badges.append(ArrDetailBadge(icon: "bookmark.fill", label: "Monitored", color: .blue))
        }

        if let q = viewModel.queue.first(where: { $0.movieId == movie.id }) {
            let isIssue = q.isImportIssueQueueItem
            let isDownloading = q.isDownloadingQueueItem
            badges.append(ArrDetailBadge(
                icon: isIssue ? "exclamationmark.triangle.fill" : (isDownloading ? "arrow.down.circle.fill" : "clock.arrow.circlepath"),
                label: isIssue ? "Import Issue" : (q.status?.capitalized ?? "Downloading"),
                color: isIssue ? .orange : .purple
            ))
        }

        if serviceManager.hasAnyConnectedBazarrInstance,
           let status = serviceManager.bazarrSubtitleStatus(forRadarrId: movie.id) {
            badges.append(ArrDetailBadge(
                icon: "captions.bubble.fill",
                label: status == .allPresent ? "Complete" : "None",
                color: status == .allPresent ? .teal : .white.opacity(0.6)
            ))
        }

        return badges
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

        if let overview = movie.overview, !overview.isEmpty {
            ArrDetailOverviewCard(text: overview)
        }

        statsCard(movie)

        if isInLibrary {
            searchActionsCard(movie)
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

        if let genres = movie.genres, !genres.isEmpty {
            ArrDetailGenreChips(genres: genres)
        }

        if let ratings = movie.ratings {
            ratingsCard(ratings)
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
        .padding(12)
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
                        fileRow(file, subtitles: bazarrMovieSubtitles)
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

    private func fileRow(_ file: RadarrMovieFile, subtitles: [BazarrSubtitle]?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.relativePath ?? "Unknown File")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ByteFormatter.format(bytes: file.size ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button(role: .destructive) {
                        movieFileToDelete = file.id
                        showDeleteFileAlert = true
                    } label: {
                        Label("Delete File", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }

            let info: [String] = [
                file.mediaInfo?.resolution,
                file.mediaInfo?.videoCodec,
                file.mediaInfo?.videoDynamicRangeType,
                file.mediaInfo?.audioCodec,
                file.edition
            ].compactMap { $0 }.filter { !$0.isEmpty }

            if !info.isEmpty {
                Text(info.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let subtitles, !subtitles.isEmpty {
                subtitleFilesView(subtitles)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                movieFileToDelete = file.id
                showDeleteFileAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func subtitleFilesView(_ subtitles: [BazarrSubtitle]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(.teal)
                ForEach(subtitles, id: \.self) { sub in
                    HStack(spacing: 3) {
                        Text(sub.code2)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.teal)
                        if sub.hi {
                            Text("HI")
                                .font(.system(size: 7).weight(.bold))
                                .foregroundStyle(.blue)
                        }
                        if sub.forced {
                            Text("Forced")
                                .font(.system(size: 7).weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        if let size = sub.fileSize {
                            Text(ByteFormatter.format(bytes: Int64(size)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.teal.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.teal.opacity(0.25)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func formatDateString(_ string: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        if let date = df.date(from: string) {
            df.dateStyle = .medium; df.dateFormat = nil
            return df.string(from: date)
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
                        Divider()
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

// MARK: - Add to Library Sheet

private struct RadarrAddToLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: RadarrViewModel
    let movie: RadarrMovie
    let onAdded: () async -> Void

    @State private var selectedQualityProfileId: Int?
    @State private var selectedRootFolderPath: String?
    @State private var minimumAvailability = "released"
    @State private var monitorOption = "movieOnly"
    @State private var searchForMovie = true
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ArrArtworkView(url: movie.posterURL) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.3))
                                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                        }
                        .frame(width: 52, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(movie.title)
                                .font(.headline)
                                .lineLimit(2)
                            HStack(spacing: 4) {
                                if let year = movie.year { Text(String(year)) }
                                if let runtime = movie.runtime, runtime > 0 { Text("· \(runtime)m") }
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Library Settings") {
                    ArrQualityProfilePicker(
                        selection: $selectedQualityProfileId,
                        profiles: viewModel.qualityProfiles,
                        showInfoButton: false
                    )

                    ArrRootFolderPicker(
                        selection: $selectedRootFolderPath,
                        folders: viewModel.rootFolders
                    )

                    Picker("Minimum Availability", selection: $minimumAvailability) {
                        ForEach(RadarrDiscoverMinimumAvailability.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }

                    Picker("Monitor", selection: $monitorOption) {
                        ForEach(RadarrDiscoverMonitorOption.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }

                    Toggle("Search Immediately", isOn: $searchForMovie)
                }

                if let error = viewModel.error, !error.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Add to Radarr")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await addMovie() }
                    } label: {
                        if isAdding {
                            ProgressView()
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(!canAdd)
                }
            }
            .task {
                await refreshConfigurationAndDefaults()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var canAdd: Bool {
        !isAdding &&
        selectedQualityProfileId != nil &&
        selectedRootFolderPath != nil &&
        movie.tmdbId != nil
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

    private func addMovie() async {
        guard !isAdding else { return }
        guard let tmdbId = movie.tmdbId,
              let qualityProfileId = selectedQualityProfileId,
              let rootFolderPath = selectedRootFolderPath else { return }

        isAdding = true
        defer { isAdding = false }
        let success = await viewModel.addMovie(
            title: movie.title,
            tmdbId: tmdbId,
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath,
            minimumAvailability: minimumAvailability,
            monitorOption: monitorOption,
            searchForMovie: searchForMovie
        )

        if success {
            await onAdded()
            dismiss()
        }
    }
}

// MARK: - Supporting enums

private enum RadarrDiscoverMinimumAvailability: String, CaseIterable, Identifiable {
    case announced, inCinemas, released
    case preDB = "preDB"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .announced: "Announced"
        case .inCinemas: "In Cinemas"
        case .released: "Released"
        case .preDB: "Predb"
        }
    }
}

private enum RadarrDiscoverMonitorOption: String, CaseIterable, Identifiable {
    case movieOnly, movieAndCollection, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movieOnly: "Movie Only"
        case .movieAndCollection: "Movie and Collection"
        case .none: "None"
        }
    }
}

struct RadarrMovieSearchView: View {
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

    @Bindable var viewModel: RadarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    let movie: RadarrMovie

    @State private var isDispatchingAutomaticSearch = false
    @State private var showInteractiveSearchSheet = false
    @State private var automaticSearchFeedback: AutomaticSearchFeedback?
    @State private var automaticSearchMonitorTask: Task<Void, Never>?

    private var queueItem: ArrQueueItem? {
        viewModel.queue.first { $0.movieId == movie.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 20) {
                movieSearchHero

                VStack(spacing: 14) {
                    automaticSearchSection
                    interactiveSearchButton
                }

                movieSearchInfoCard(title: "Status", icon: "info.circle") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            movieStatusBadge(movie.hasFile == true ? "Downloaded" : "Missing", tint: movie.hasFile == true ? .green : .orange, systemImage: movie.hasFile == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            movieStatusBadge(movie.monitored == true ? "Monitored" : "Unmonitored", tint: .blue, systemImage: movie.monitored == true ? "bookmark.fill" : "bookmark.slash")

                            if let q = queueItem {
                                let isIssue = q.isImportIssueQueueItem
                                movieStatusBadge(
                                    isIssue ? "Import Issue" : (q.status?.capitalized ?? "Downloading"),
                                    tint: isIssue ? .orange : .purple,
                                    systemImage: isIssue ? "exclamationmark.triangle.fill" : (q.isDownloadingQueueItem ? "arrow.down.circle.fill" : "clock.arrow.circlepath")
                                )
                            }

                            if serviceManager.hasAnyConnectedBazarrInstance,
                               let status = serviceManager.bazarrSubtitleStatus(forRadarrId: movie.id) {
                                movieStatusBadge(
                                    status == .allPresent ? "Complete" : "None",
                                    tint: status == .allPresent ? .teal : .secondary,
                                    systemImage: "captions.bubble.fill"
                                )
                            }
                        }

                        if let overview = movie.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 44)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background {
            ArrArtworkView(url: movie.posterURL ?? movie.fanartURL, contentMode: .fill) {
                Rectangle().fill(Color.orange.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .saturation(1.6)
            .overlay(Color.black.opacity(0.55))
            .ignoresSafeArea()
        }
        .navigationTitle("Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: movie.hasFile)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: movie.monitored)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: queueItem?.id)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: automaticSearchFeedback)
        .sheet(isPresented: $showInteractiveSearchSheet) {
            RadarrInteractiveSearchSheet(viewModel: viewModel, movie: movie)
        }
        .onDisappear {
            automaticSearchMonitorTask?.cancel()
        }
    }

    private var movieSearchHero: some View {
        VStack(spacing: 14) {
            ArrArtworkView(url: movie.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.3))
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 160, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)

            VStack(spacing: 6) {
                Text(movie.title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(movie.year.map(String.init) ?? movie.displayStatus)
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
            guard !isDispatchingAutomaticSearch else { return }
            isDispatchingAutomaticSearch = true
            Task {
                let baselineQueueIDs = Set(viewModel.queue.filter { $0.movieId == movie.id }.map(\.id))
                withAnimation(.snappy) {
                    automaticSearchFeedback = AutomaticSearchFeedback(
                        kind: .searching,
                        message: "Radarr is searching indexers for \(movie.title)."
                    )
                }

                let didStart = await viewModel.searchMovie(movieId: movie.id)
                isDispatchingAutomaticSearch = false

                if !didStart {
                    withAnimation(.snappy) { automaticSearchFeedback = nil }
                    let message = viewModel.error ?? "Could not start search."
                    InAppNotificationCenter.shared.showError(title: "Search Failed", message: message)
                } else {
                    InAppNotificationCenter.shared.showSuccess(
                        title: "Search Queued",
                        message: "\(movie.title) was sent to Radarr for automatic search."
                    )

                    automaticSearchMonitorTask?.cancel()
                    automaticSearchMonitorTask = Task {
                        for _ in 0..<6 {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            await viewModel.loadQueue()

                            let currentQueueIDs = Set(viewModel.queue.filter { $0.movieId == movie.id }.map(\.id))
                            if !currentQueueIDs.subtracting(baselineQueueIDs).isEmpty {
                                await MainActor.run {
                                    withAnimation(.snappy) {
                                        automaticSearchFeedback = AutomaticSearchFeedback(
                                            kind: .found,
                                            message: "A result was queued in Radarr. Check the queue or import status for progress."
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
            movieSearchActionRow(
                title: "Automatic Search",
                subtitle: "Ask Radarr to search indexers using its normal rules.",
                systemImage: "magnifyingglass",
                isLoading: isDispatchingAutomaticSearch
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var automaticSearchSection: some View {
        if let automaticSearchFeedback {
            movieSearchInfoCard(title: automaticSearchFeedback.title, icon: automaticSearchFeedback.icon) {
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
            movieSearchActionRow(
                title: "Interactive Search",
                subtitle: "Browse releases yourself and choose exactly what to grab.",
                systemImage: "person.fill",
                trailingSystemImage: "arrow.up.forward.square"
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func movieSearchActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right"
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
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

    private func movieSearchInfoCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func movieStatusBadge(_ text: String, tint: Color, systemImage: String? = nil) -> some View {
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
}

struct RadarrInteractiveSearchSheet: View {
    @Bindable var viewModel: RadarrViewModel
    let movie: RadarrMovie

    var body: some View {
        ArrInteractiveSearchBrowser(
            title: movie.title,
            emptyDescription: "Radarr didn't return any manual search results for this movie.",
            loadingDescription: "Results will appear here as soon as Radarr returns them.",
            loadAction: {
                guard movie.id > 0 else { return [] }
                return try await viewModel.interactiveSearchMovie(movieId: movie.id)
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
                artURL: movie.posterURL ?? movie.fanartURL,
                accentColor: .orange,
                isGrabbing: isGrabbing,
                onGrab: onGrab
            )
        }
    }
}
