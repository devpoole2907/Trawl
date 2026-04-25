import SwiftUI

struct RadarrMovieDetailView: View {
    private struct DetailBadge: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let color: Color
    }

    private struct PendingQueueAction: Identifiable {
        let itemID: Int
        let title: String
        let blocklist: Bool

        var id: String { "\(itemID)-\(blocklist)" }
    }

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
    @State private var isAlternateTitlesExpanded = false
    @State private var isFilesExpanded = false
    @State private var showAddSheet = false
    @State private var manualImportPath: String?
    @State private var didAdd = false
    @State private var showInteractiveSearchSheet = false
    @State private var isDispatchingAutomaticSearch = false
    @State private var isImportIssuesExpanded = false
    @State private var isQueueExpanded = false
    @State private var queueActionInFlightIDs: Set<Int> = []
    @State private var pendingQueueAction: PendingQueueAction?

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
        Group {
            if let movie {
                scrollContent(movie)
                    .background {
                        artBackground(url: movie.posterURL ?? movie.fanartURL)
                    }
            } else {
                ContentUnavailableView("Movie Not Found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(movie?.title ?? "Movie")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
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
        .sheet(isPresented: manualImportPresented) {
            if let manualImportPath {
                ManualImportScanView(
                    path: manualImportPath,
                    service: .radarr,
                    serviceManager: serviceManager,
                    libraryItemID: resolvedLibraryId,
                    showsCloseButton: true
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
        .sheet(isPresented: $showInteractiveSearchSheet) {
            if let movie, isInLibrary {
                RadarrInteractiveSearchSheet(viewModel: viewModel, movie: movie)
            }
        }
        .task(id: resolvedLibraryId) {
            guard let id = resolvedLibraryId else { return }
            await viewModel.loadMovieFiles(movieId: id)
            while !Task.isCancelled {
                await viewModel.loadQueue()
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
        let badges = movieBadges(movie)

        return VStack(spacing: 14) {
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

                HStack(spacing: 4) {
                    if let year = movie.year { Text(String(year)) }
                    if let studio = movie.studio, !studio.isEmpty { Text("·"); Text(studio) }
                    if let runtime = movie.runtime, runtime > 0 { Text("·"); Text("\(runtime)m") }
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                badgeSection(badges)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private func pill(icon: String, label: String, color: Color) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder
    private func badgeSection(_ badges: [DetailBadge]) -> some View {
        if !badges.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(badges) { badge in
                        pill(icon: badge.icon, label: badge.label, color: badge.color)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(badges) { badge in
                        pill(icon: badge.icon, label: badge.label, color: badge.color)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func movieBadges(_ movie: RadarrMovie) -> [DetailBadge] {
        var badges: [DetailBadge] = []
        let hasFile = movie.hasFile == true

        badges.append(
            DetailBadge(
                icon: hasFile ? "checkmark.circle.fill" : "clock",
                label: movie.displayStatus,
                color: hasFile ? .green : .orange
            )
        )

        if let cert = movie.certification, !cert.isEmpty {
            badges.append(DetailBadge(icon: "shield", label: cert, color: .white.opacity(0.8)))
        }

        if isInLibrary && movie.monitored == true {
            badges.append(DetailBadge(icon: "bookmark.fill", label: "Monitored", color: .blue))
        }

        if let q = viewModel.queue.first(where: { $0.movieId == movie.id }) {
            let isIssue = q.isImportIssueQueueItem
            let isDownloading = q.isDownloadingQueueItem
            badges.append(DetailBadge(
                icon: isIssue ? "exclamationmark.triangle.fill" : (isDownloading ? "arrow.down.circle.fill" : "clock.arrow.circlepath"),
                label: isIssue ? "Import Issue" : (q.status?.capitalized ?? "Downloading"),
                color: isIssue ? .orange : .purple
            ))
        }

        return badges
    }

    // MARK: - Cards section

    @ViewBuilder
    private func cardsSection(_ movie: RadarrMovie) -> some View {
        if let overview = movie.overview, !overview.isEmpty {
            overviewCard(overview)
        }

        statsCard(movie)

        if isInLibrary {
            searchActionsCard(movie)
        }

        if !activeQueueItems.isEmpty {
            queueCard(activeQueueItems)
        }

        if !importIssueQueueItems.isEmpty {
            importIssuesCard(importIssueQueueItems)
        }

        if let genres = movie.genres, !genres.isEmpty {
            genreChips(genres)
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
            alternateTitlesCard(alternateTitles)
        }
    }

    // MARK: - Overview card

    private func overviewCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Overview", icon: "text.alignleft")
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

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
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
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

    private func genreChips(_ genres: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres.prefix(8), id: \.self) { genre in
                    Text(genre)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

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

    private func queueCard(_ items: [ArrQueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isQueueExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        sectionLabel(items.count == 1 ? "Current Download" : "Current Downloads", icon: "arrow.down.circle")
                        Text("\(items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isQueueExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isQueueExpanded ? 8 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isQueueExpanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    queueItemRow(item)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    if index < items.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func importIssuesCard(_ items: [ArrQueueItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isImportIssuesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        sectionLabel(items.count == 1 ? "Import Issue" : "Import Issues", icon: "exclamationmark.triangle")
                        Text("\(items.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: isImportIssuesExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isImportIssuesExpanded ? 8 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isImportIssuesExpanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    queueIssueRow(item)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                    if index < items.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func queueItemRow(_ item: ArrQueueItem) -> some View {
        let linkedTorrent = linkedTorrent(for: item.downloadId)
        let progress = linkedTorrent?.progress ?? item.progress
        let percent = Int(progress * 100)
        let downloadedBytes = linkedTorrent.map { max(0, $0.totalSize - $0.amountLeft) } ?? item.size.map { total in
            Int64(max(0, total - (item.sizeleft ?? total)))
        }
        let totalBytes = linkedTorrent.map(\.totalSize).flatMap { $0 > 0 ? $0 : nil } ?? item.size.map { Int64($0) }
        let primaryStatus = linkedTorrent?.state.displayName ?? item.trackedDownloadState ?? item.status ?? "queued"
        let title = linkedTorrent?.name ?? item.title ?? "Download"
        let etaText = linkedTorrent.flatMap(formattedETA(for:)) ?? item.timeleft

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(primaryStatus.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let downloadClient = item.downloadClient, !downloadClient.isEmpty {
                    Text(downloadClient)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                }
            }

            ProgressView(value: progress)
                .tint(linkedTorrent == nil ? .orange : .blue)

            HStack(spacing: 12) {
                Text("\(percent)%")
                if let downloadedBytes, let totalBytes {
                    Text("·")
                    Text("\(ByteFormatter.format(bytes: downloadedBytes)) / \(ByteFormatter.format(bytes: totalBytes))")
                }
                if let etaText, !etaText.isEmpty {
                    Text("·")
                    Text("ETA \(etaText)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let torrent = linkedTorrent {
                NavigationLink {
                    TorrentDetailView(torrentHash: torrent.hash)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("View Live Torrent")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(torrent.state.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if torrent.dlspeed > 0 {
                            Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed), systemImage: "arrow.down")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else if let outputPath = item.outputPath, !outputPath.isEmpty {
                LabeledContent("Destination") {
                    Text(outputPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            }

            if let messages = item.statusMessages?.compactMap(\.messages).flatMap({ $0 }),
               let message = messages.first,
               !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func queueIssueRow(_ item: ArrQueueItem) -> some View {
        let linkedTorrent = linkedTorrent(for: item.downloadId)
        let primaryStatus = linkedTorrent?.state.displayName ?? item.trackedDownloadState ?? item.status ?? "Issue"
        let message = item.primaryStatusMessage ?? "This item is blocked before import completes."
        let isRemoving = queueActionInFlightIDs.contains(item.id)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(linkedTorrent?.name ?? item.title ?? "Queue Item")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(primaryStatus.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 8)

                Text(item.trackedDownloadStatus?.capitalized ?? "Issue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.16))
                    .clipShape(Capsule())
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let rootFolder = movie?.rootFolderPath, !rootFolder.isEmpty {
                LabeledContent("Library Root") {
                    Text(rootFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let outputPath = item.outputPath, !outputPath.isEmpty {
                LabeledContent("Import Destination") {
                    Text(outputPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    showEditSheet = true
                } label: {
                    importIssueActionIcon(systemName: "slider.horizontal.3", tint: .blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Movie")
                .disabled(isRemoving || !isInLibrary)

                if let outputPath = item.outputPath, !outputPath.isEmpty {
                    Button {
                        manualImportPath = outputPath
                    } label: {
                        importIssueActionIcon(systemName: "tray.and.arrow.down.fill", tint: .teal)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Manual Import")
                    .disabled(isRemoving)
                }

                Button {
                    pendingQueueAction = PendingQueueAction(
                        itemID: item.id,
                        title: linkedTorrent?.name ?? item.title ?? "Queue Item",
                        blocklist: false
                    )
                } label: {
                    importIssueActionIcon(systemName: "trash", tint: .red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove from Queue")
                .disabled(isRemoving)

                Button {
                    pendingQueueAction = PendingQueueAction(
                        itemID: item.id,
                        title: linkedTorrent?.name ?? item.title ?? "Queue Item",
                        blocklist: true
                    )
                } label: {
                    importIssueActionIcon(systemName: "hand.raised.fill", tint: .orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Blocklist")
                .disabled(isRemoving)
            }

            Text("Use Edit Movie to change the root folder or other import-related settings before retrying.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let torrent = linkedTorrent {
                NavigationLink {
                    TorrentDetailView(torrentHash: torrent.hash)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("View Torrent")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(torrent.state.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func linkedTorrent(for downloadId: String?) -> Torrent? {
        guard let downloadId, !downloadId.isEmpty else { return nil }
        let normalized = downloadId.lowercased()
        if let direct = syncService.torrents[downloadId] { return direct }
        if let normalizedMatch = syncService.torrents[normalized] { return normalizedMatch }
        return syncService.torrents.first { $0.key.caseInsensitiveCompare(downloadId) == .orderedSame }?.value
    }

    @ViewBuilder
    private func importIssueActionIcon(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(8)
            .glassEffect(.regular.interactive(), in: Circle())
    }

    private func formattedETA(for torrent: Torrent) -> String? {
        guard torrent.eta > 0, torrent.eta < 8_640_000 else { return nil }
        let hours = torrent.eta / 3600
        let minutes = (torrent.eta % 3600) / 60
        let seconds = torrent.eta % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private func isActiveQueueItem(_ item: ArrQueueItem) -> Bool {
        if let torrent = linkedTorrent(for: item.downloadId) {
            return torrent.state.filterCategory == .downloading
        }

        return item.isDownloadingQueueItem
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

    private var manualImportPresented: Binding<Bool> {
        Binding(
            get: { manualImportPath != nil },
            set: { if !$0 { manualImportPath = nil } }
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

    private func alternateTitlesCard(_ alternateTitles: [RadarrAlternateTitle]) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isAlternateTitlesExpanded.toggle()
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alternative Titles")
                            .font(.subheadline.weight(.semibold))
                        Text("\(alternateTitles.count) titles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isAlternateTitlesExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isAlternateTitlesExpanded {
                Divider()
                ForEach(Array(alternateTitles.enumerated()), id: \.offset) { index, title in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title.title ?? "Untitled")
                            .font(.subheadline)
                        if let sourceType = title.sourceType, !sourceType.isEmpty {
                            Text(sourceType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if index < alternateTitles.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
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
                        fileRow(file)
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

    private func fileRow(_ file: RadarrMovieFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.relativePath ?? "Unknown File")
                        .font(.subheadline.weight(.medium))
                    Text(ByteFormatter.format(bytes: file.size ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                movieFileToDelete = file.id
                showDeleteFileAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
            } else {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
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
                if selectedQualityProfileId == nil {
                    selectedQualityProfileId = viewModel.qualityProfiles.first?.id
                }
                if selectedRootFolderPath == nil {
                    selectedRootFolderPath = viewModel.rootFolders.first?.path
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
    }

    private var canAdd: Bool {
        !isAdding &&
        selectedQualityProfileId != nil &&
        selectedRootFolderPath != nil &&
        movie.tmdbId != nil
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
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
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
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: RadarrViewModel
    let movie: RadarrMovie

    @State private var releases: [ArrRelease] = []
    @State private var isLoading = false
    @State private var grabbingReleaseID: String?
    @State private var hasLoadedReleases = false
    @State private var searchText = ""
    @State private var releaseSort = ArrReleaseSort()

    private var availableIndexers: [String] {
        Array(Set(releases.compactMap(\.indexer))).sorted()
    }
    private var availableQualities: [String] {
        Array(Set(releases.map(\.qualityName))).sorted()
    }

    /// Releases after applying sort/filter (no search text). Used for "N hidden" count.
    private var sortedFilteredReleases: [ArrRelease] {
        let filtered = releases.filter { release in
            let matchesIndexer = releaseSort.indexer.isEmpty || releaseSort.indexer == release.indexer
            let matchesQuality = releaseSort.quality.isEmpty || releaseSort.quality == release.qualityName
            let matchesApproved = !releaseSort.approvedOnly || release.approved == true
            return matchesIndexer && matchesQuality && matchesApproved
        }
        guard releaseSort.option != .default else { return filtered }
        return filtered.sorted { lhs, rhs in
            let asc = releaseSort.isAscending
            switch releaseSort.option {
            case .default: return false
            case .age:
                let l = lhs.ageHours ?? Double(lhs.age ?? 0) * 24
                let r = rhs.ageHours ?? Double(rhs.age ?? 0) * 24
                return asc ? l < r : l > r
            case .quality:
                return asc ? lhs.qualityName < rhs.qualityName : lhs.qualityName > rhs.qualityName
            case .size:
                return asc ? (lhs.size ?? 0) < (rhs.size ?? 0) : (lhs.size ?? 0) > (rhs.size ?? 0)
            case .seeders:
                return asc ? (lhs.seeders ?? 0) < (rhs.seeders ?? 0) : (lhs.seeders ?? 0) > (rhs.seeders ?? 0)
            }
        }
    }

    /// Releases shown in the list (after search text applied on top of sort/filter).
    private var displayedReleases: [ArrRelease] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return sortedFilteredReleases }
        return sortedFilteredReleases.filter { release in
            release.title?.localizedCaseInsensitiveContains(text) == true ||
            release.indexer?.localizedCaseInsensitiveContains(text) == true
        }
    }

    private var hiddenByFiltersCount: Int {
        releases.count - sortedFilteredReleases.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Searching indexers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.error, !error.isEmpty {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle.fill")
                } else if releases.isEmpty && hasLoadedReleases {
                    ContentUnavailableView(
                        "No Releases Found",
                        systemImage: "magnifyingglass",
                        description: Text("Radarr didn't return any manual search results for this movie.")
                    )
                } else if !releases.isEmpty && displayedReleases.isEmpty {
                    ContentUnavailableView {
                        Label("No Releases", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Some releases are hidden by the selected filters.")
                    } actions: {
                        Button("Clear Filters") { clearFilters() }
                    }
                } else if !releases.isEmpty {
                    List {
                        ForEach(displayedReleases) { release in
                            NavigationLink {
                                RadarrReleaseActionView(
                                    release: release,
                                    artURL: movie.posterURL ?? movie.fanartURL,
                                    isGrabbing: grabbingReleaseID == release.id,
                                    onGrab: { await grab(release: release) }
                                )
                            } label: {
                                RadarrReleaseRowView(release: release)
                            }
                        }

                        if releaseSort.isFiltered && hiddenByFiltersCount > 0 {
                            Section {
                                EmptyView()
                            } footer: {
                                Label(
                                    "\(hiddenByFiltersCount) release\(hiddenByFiltersCount == 1 ? "" : "s") hidden by filters",
                                    systemImage: "line.3.horizontal.decrease.circle"
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .searchable(text: $searchText, prompt: "Search releases…")
            .navigationTitle(movie.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .status) {
                    if !releases.isEmpty {
                        let shown = displayedReleases.count
                        let total = releases.count
                        Text(shown == total ? "\(total) releases" : "\(shown) of \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    sortMenu
                    filterMenu
                }
            }
            .task {
                await loadReleases()
            }
            .onChange(of: releaseSort.option) { _, _ in
                releaseSort.isAscending = false
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $releaseSort.option) {
                ForEach(ArrReleaseSortKey.allCases) { key in
                    Label(key.rawValue, systemImage: key.systemImage).tag(key)
                }
            }
            .pickerStyle(.inline)
            .menuIndicator(.hidden)

            if releaseSort.option != .default {
                Picker("Direction", selection: $releaseSort.isAscending) {
                    Label("Descending", systemImage: "arrow.down").tag(false)
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                }
                .pickerStyle(.inline)
                .menuIndicator(.hidden)
            }
        } label: {
            Image(systemName: releaseSort.option != .default
                  ? "arrow.up.arrow.down.circle.fill"
                  : "arrow.up.arrow.down")
        }
    }

    private var filterMenu: some View {
        Menu {
            if !availableIndexers.isEmpty {
                Picker("Indexer", selection: $releaseSort.indexer) {
                    Text("All Indexers").tag("")
                    ForEach(availableIndexers, id: \.self) { indexer in
                        Text(indexer).tag(indexer)
                    }
                }
                .pickerStyle(.inline)
                .menuIndicator(.hidden)
            }

            if !availableQualities.isEmpty {
                Picker("Quality", selection: $releaseSort.quality) {
                    Text("All Qualities").tag("")
                    ForEach(availableQualities, id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                .pickerStyle(.inline)
                .menuIndicator(.hidden)
            }

            Toggle("Approved Only", isOn: $releaseSort.approvedOnly)
        } label: {
            Image(systemName: releaseSort.isFiltered
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
    }

    private func clearFilters() {
        releaseSort.indexer = ""
        releaseSort.quality = ""
        releaseSort.approvedOnly = false
        releaseSort.seasonPack = .any
    }

    private func loadReleases() async {
        guard movie.id > 0 else { return }
        guard !hasLoadedReleases else { return }
        isLoading = true
        releases = []
        releases = await viewModel.interactiveSearchMovie(movieId: movie.id)
        isLoading = false
        hasLoadedReleases = true
    }

    private func grab(release: ArrRelease) async {
        guard grabbingReleaseID == nil else { return }
        grabbingReleaseID = release.id
        let didGrab = await viewModel.grabRelease(release)
        grabbingReleaseID = nil

        if didGrab {
            InAppNotificationCenter.shared.showSuccess(
                title: "Release Sent",
                message: release.title ?? "The selected release was sent to the download client."
            )
            dismiss()
        } else if let error = viewModel.error, !error.isEmpty {
            InAppNotificationCenter.shared.showError(title: "Grab Failed", message: error)
        }
    }
}

struct RadarrReleaseRowView: View {
    let release: ArrRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(release.title ?? "Unknown Release")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(release.indexer ?? "Unknown Indexer")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let age = release.ageDescription {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(age)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if release.approved != true {
                        releaseChip(release.rejected == true ? "Rejected" : "Not Approved", color: .orange)
                    }
                    releaseChip(release.qualityName, color: .primary)
                    if let size = release.size, size > 0 {
                        releaseChip(ByteFormatter.format(bytes: size), color: .secondary)
                    }
                    releaseChip(release.protocolName, color: .secondary)
                    if let seeders = release.seeders, seeders > 0 {
                        let leechers = release.leechers ?? 0
                        releaseChip("S:\(seeders) L:\(leechers)", color: .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func releaseChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }
}

struct RadarrReleaseActionView: View {
    let release: ArrRelease
    let artURL: URL?
    let isGrabbing: Bool
    let onGrab: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 20) {
                // Header
                VStack(spacing: 6) {
                    Text(release.title ?? "Unknown Release")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(release.indexer ?? "Unknown Indexer")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

                // Details card
                detailsCard

                // Rejections card
                if let rejections = release.rejections, !rejections.isEmpty {
                    rejectionsCard(rejections)
                }

                // Download button
                Button {
                    Task { await onGrab() }
                } label: {
                    if isGrabbing {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Download Release", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .disabled(isGrabbing || release.downloadAllowed == false)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 44)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background {
            ArrArtworkView(url: artURL, contentMode: .fill) {
                Rectangle().fill(Color.orange.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .saturation(1.6)
            .overlay(Color.black.opacity(0.55))
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .navigationTitle("Release")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var detailsCard: some View {
        let rows: [(String, String, String)] = [
            ("sparkles", "Quality", release.qualityName),
            release.size.map { ("externaldrive", "Size", ByteFormatter.format(bytes: $0)) },
            ("antenna.radiowaves.left.and.right", "Protocol", release.protocolName),
            release.ageDescription.map { ("clock", "Age", $0) },
            release.seeders.map { s in ("arrow.up.circle", "Seeders", "\(s)") },
            release.leechers.map { l in ("arrow.down.circle", "Leechers", "\(l)") },
            release.customFormatScore.map { ("star", "Custom Score", "\($0)") }
        ].compactMap { $0 }.filter { !$0.2.isEmpty }

        return VStack(alignment: .leading, spacing: 0) {
            Label("Details", systemImage: "shippingbox")
                .font(.headline)
                .foregroundStyle(.white)
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                if index < rows.count - 1 {
                    Divider().padding(.leading, 42)
                }
            }

            Color.clear.frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func rejectionsCard(_ rejections: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Alerts", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(rejections, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.orange.opacity(0.8))
                            .padding(.top, 5)
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}
