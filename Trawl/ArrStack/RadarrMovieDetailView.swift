import SwiftUI

struct RadarrMovieDetailView: View {
    private struct DetailBadge: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let color: Color
    }

    @Bindable var viewModel: RadarrViewModel
    @Environment(SyncService.self) private var syncService

    // Library mode: look up movie by ID from viewModel
    private let movieId: Int?
    // Discover mode: movie object passed directly
    private let discoverMovie: RadarrMovie?
    private let onAdded: (() async -> Void)?

    @State private var showDeleteAlert = false
    @State private var deleteFiles = false
    @State private var showEditSheet = false
    @State private var showDeleteFileAlert = false
    @State private var isAlternateTitlesExpanded = false
    @State private var showAddSheet = false
    @State private var didAdd = false

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
            Toggle("Also delete files", isOn: $deleteFiles)
            Button("Delete", role: .destructive) {
                if let id = resolvedLibraryId {
                    Task { await viewModel.deleteMovie(id: id, deleteFiles: deleteFiles) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete File?", isPresented: $showDeleteFileAlert) {
            Button("Delete", role: .destructive) {
                if let fileId = movie?.movieFile?.id {
                    Task { await viewModel.deleteMovieFile(id: fileId) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the current movie file from Radarr.")
        }
        .sheet(isPresented: $showEditSheet) {
            if let movie, isInLibrary {
                RadarrEditMovieSheet(viewModel: viewModel, movie: movie)
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
        .task(id: resolvedLibraryId) {
            guard resolvedLibraryId != nil else { return }
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
    private var queueItems: [ArrQueueItem] {
        guard let id = resolvedLibraryId else { return [] }
        return viewModel.queue
            .filter { $0.movieId == id }
            .sorted { $0.progress > $1.progress }
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

        return badges
    }

    // MARK: - Cards section

    @ViewBuilder
    private func cardsSection(_ movie: RadarrMovie) -> some View {
        if let overview = movie.overview, !overview.isEmpty {
            overviewCard(overview)
        }

        statsCard(movie)

        if !queueItems.isEmpty {
            queueCard(queueItems)
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

        if let alternateTitles = movie.alternateTitles, !alternateTitles.isEmpty {
            alternateTitlesCard(alternateTitles)
        }

        // Library-only: file card
        if isInLibrary, let file = movie.movieFile {
            fileCard(file)
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
            if let popularity = movie.popularity {
                statCell(value: String(format: "%.1f", popularity), label: "Popularity")
                cardDivider
            }
            statCell(value: movie.displayStatus, label: "Status")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
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
                    VStack(spacing: 2) {
                        Text(item.1).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Text(item.0).font(.caption2).foregroundStyle(.secondary)
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
            sectionLabel(items.count == 1 ? "Current Download" : "Current Downloads", icon: "arrow.down.circle")
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                queueItemRow(item)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                if index < items.count - 1 {
                    Divider().padding(.leading, 16)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
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

    private func linkedTorrent(for downloadId: String?) -> Torrent? {
        guard let downloadId, !downloadId.isEmpty else { return nil }
        let normalized = downloadId.lowercased()
        if let direct = syncService.torrents[downloadId] { return direct }
        if let normalizedMatch = syncService.torrents[normalized] { return normalizedMatch }
        return syncService.torrents.first { $0.key.caseInsensitiveCompare(downloadId) == .orderedSame }?.value
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

    // MARK: - File card

    @ViewBuilder
    private func fileCard(_ file: RadarrMovieFile) -> some View {
        let rows: [(String, String, String)] = ([
            file.relativePath.map { ("doc", "File", $0) },
            file.size.map { ("externaldrive", "Size", ByteFormatter.format(bytes: $0)) },
            file.mediaInfo?.videoCodec.map { ("video", "Video", $0) },
            file.mediaInfo?.videoDynamicRangeType.map { ("sun.max", "Dynamic Range", $0) },
            file.mediaInfo?.resolution.map { ("aspectratio", "Resolution", $0) },
            file.mediaInfo?.audioCodec.map { ("waveform", "Audio", $0) },
            file.mediaInfo?.audioLanguages.map { ("globe", "Languages", $0) }
        ] as [(String, String, String)?]).compactMap { $0 }.filter { !$0.2.isEmpty }

        if !rows.isEmpty {
            rowsCard(
                header: "File",
                icon: "doc.fill",
                rows: rows,
                footer: {
                    Button(role: .destructive) {
                        showDeleteFileAlert = true
                    } label: {
                        Label("Delete File", systemImage: "trash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    showDeleteFileAlert = true
                } label: {
                    Label("Delete File", systemImage: "trash")
                }
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

                        if movie.hasFile != true {
                            Button {
                                Task { await viewModel.searchMovie(movieId: movie.id) }
                            } label: {
                                Label("Search", systemImage: "magnifyingglass")
                            }
                        }

                        Button {
                            Task { await viewModel.refreshMovies() }
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
        guard let tmdbId = movie.tmdbId,
              let qualityProfileId = selectedQualityProfileId,
              let rootFolderPath = selectedRootFolderPath else { return }

        isAdding = true
        let success = await viewModel.addMovie(
            title: movie.title,
            tmdbId: tmdbId,
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath,
            minimumAvailability: minimumAvailability,
            monitorOption: monitorOption,
            searchForMovie: searchForMovie
        )
        isAdding = false

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
