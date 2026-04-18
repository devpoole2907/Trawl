import SwiftUI

struct SonarrSeriesDetailView: View {
    private struct DetailBadge: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let color: Color
    }

    @Bindable var viewModel: SonarrViewModel
    @Environment(SyncService.self) private var syncService

    // Library mode: look up series by ID from viewModel
    private let seriesId: Int?
    // Discover mode: series object passed directly
    private let discoverSeries: SonarrSeries?
    private let onAdded: (() async -> Void)?

    @State private var expandedSeasons: Set<Int> = []
    @State private var isFilesExpanded = false
    @State private var isAlternateTitlesExpanded = false
    @State private var showEditSheet = false
    @State private var selectedEpisodeFileForDeletion: SonarrEpisodeFile?
    @State private var showAddSheet = false
    @State private var didAdd = false

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
    private var seasonNumbers: [Int] {
        Set(episodes.map(\.seasonNumber)).sorted(by: >)
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

    var body: some View {
        Group {
            if let series {
                scrollContent(series)
                    .background {
                        artBackground(url: series.posterURL ?? series.fanartURL)
                    }
            } else {
                ContentUnavailableView("Series Not Found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(series?.title ?? "Series")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar { toolbarContent }
        .task(id: resolvedSeriesId) {
            if let id = resolvedSeriesId {
                await viewModel.loadEpisodes(for: id)
                await viewModel.loadEpisodeFiles(for: id)
                await viewModel.loadQueue()
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let series, isInLibrary {
                SonarrEditSeriesSheet(viewModel: viewModel, series: series)
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
                    Task { await viewModel.deleteEpisodeFile(id: file.id) }
                }
                selectedEpisodeFileForDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                selectedEpisodeFileForDeletion = nil
            }
        } message: {
            Text("This removes the selected episode file from Sonarr.")
        }
    }

    // MARK: - Background

    private func artBackground(url: URL?) -> some View {
        ArrArtworkView(url: url, contentMode: .fill) {
            Rectangle().fill(Color.purple.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(1.4)
        .blur(radius: 60)
        .saturation(1.6)
        .overlay(Color.black.opacity(0.55))
        .ignoresSafeArea()
    }

    // MARK: - Scroll content

    private func scrollContent(_ series: SonarrSeries) -> some View {
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
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Hero

    private func heroSection(_ series: SonarrSeries) -> some View {
        let badges = seriesBadges(series)

        return VStack(spacing: 14) {
            ArrArtworkView(url: series.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.purple.opacity(0.3))
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 160, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)

            VStack(spacing: 6) {
                Text(series.title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    if let network = series.network { Text(network) }
                    if let year = series.year { Text("·"); Text(String(year)) }
                    if let runtime = series.runtime, runtime > 0 { Text("·"); Text("\(runtime)m") }
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

    private func seriesBadges(_ series: SonarrSeries) -> [DetailBadge] {
        var badges: [DetailBadge] = []
        let isContinuing = series.status == "continuing"

        badges.append(
            DetailBadge(
                icon: isContinuing ? "circle.fill" : "checkmark.circle.fill",
                label: isContinuing ? "Continuing" : (series.status?.capitalized ?? "Unknown"),
                color: isContinuing ? .green : .white.opacity(0.6)
            )
        )

        if isInLibrary && series.monitored == true {
            badges.append(DetailBadge(icon: "bookmark.fill", label: "Monitored", color: .blue))
        }

        if let certification = series.certification, !certification.isEmpty {
            badges.append(DetailBadge(icon: "shield", label: certification, color: .white.opacity(0.8)))
        }

        return badges
    }

    // MARK: - Cards section

    @ViewBuilder
    private func cardsSection(_ series: SonarrSeries) -> some View {
        if let overview = series.overview, !overview.isEmpty {
            overviewCard(overview)
        }

        if isInLibrary {
            statsCard(series)
        }

        if !queueItems.isEmpty {
            queueCard(queueItems)
        }

        if let genres = series.genres, !genres.isEmpty {
            genreChips(genres)
        }

        if let ratings = series.ratings {
            ratingsCard(ratings)
        }

        if let alternateTitles = series.alternateTitles, !alternateTitles.isEmpty {
            alternateTitlesCard(alternateTitles)
        }

        // Library-only: episodes and files
        if isInLibrary {
            if episodes.isEmpty && viewModel.isLoadingEpisodes {
                loadingCard
            } else if !episodes.isEmpty {
                ForEach(seasonNumbers, id: \.self) { seasonNum in
                    seasonCard(seasonNum: seasonNum)
                }
            }

            if !episodeFiles.isEmpty {
                episodeFilesCard
            }
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
        let linkedTorrent = item.downloadId.flatMap { syncService.torrents[$0] }
        let percent = Int(item.progress * 100)
        let downloadedBytes = item.size.map { total in
            Int64(max(0, total - (item.sizeleft ?? total)))
        }
        let totalBytes = item.size.map { Int64($0) }
        let primaryStatus = item.trackedDownloadState ?? item.status ?? "queued"

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? "Download")
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

            ProgressView(value: item.progress)
                .tint(linkedTorrent == nil ? .orange : .blue)

            HStack(spacing: 12) {
                Text("\(percent)%")
                if let downloadedBytes, let totalBytes {
                    Text("·")
                    Text("\(ByteFormatter.format(bytes: downloadedBytes)) / \(ByteFormatter.format(bytes: totalBytes))")
                }
                if let timeleft = item.timeleft, !timeleft.isEmpty {
                    Text("·")
                    Text("ETA \(timeleft)")
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
                            Text("Open In qBittorrent")
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

    private func alternateTitlesCard(_ alternateTitles: [SonarrAlternateTitle]) -> some View {
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
                        if let seasonNumber = title.seasonNumber {
                            Text(seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)")
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
        let seasonEpisodes = episodes
            .filter { $0.seasonNumber == seasonNum }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        let filesCount = seasonEpisodes.filter { $0.hasFile == true }.count
        let isExpanded = expandedSeasons.contains(seasonNum)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if isExpanded { expandedSeasons.remove(seasonNum) }
                    else { expandedSeasons.insert(seasonNum) }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seasonNum == 0 ? "Specials" : "Season \(seasonNum)")
                            .font(.subheadline.weight(.semibold))
                        Text("\(filesCount) of \(seasonEpisodes.count) episodes")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 48, height: 4)
                        if seasonEpisodes.count > 0 {
                            Capsule()
                                .fill(filesCount == seasonEpisodes.count ? Color.green : Color.purple)
                                .frame(
                                    width: 48 * CGFloat(filesCount) / CGFloat(seasonEpisodes.count),
                                    height: 4
                                )
                        }
                    }

                    if let id = resolvedSeriesId {
                        Button {
                            Task { await viewModel.searchSeason(seriesId: id, seasonNumber: seasonNum) }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(7)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                ForEach(seasonEpisodes) { episode in
                    EpisodeRow(episode: episode) {
                        Task { await viewModel.toggleEpisodeMonitored(episode) }
                    } onSearch: {
                        Task { await viewModel.searchEpisode(episode) }
                    }
                    if episode.id != seasonEpisodes.last?.id {
                        Divider().padding(.leading, 38)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
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
                    EpisodeFileRow(file: file) {
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
                        Task { await viewModel.refreshSeries() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
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

private struct SonarrAddToLibrarySheet: View {
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
        NavigationStack {
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
                                if let year = series.year { Text("· \(year)") }
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
            .navigationTitle("Add to Sonarr")
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
                        Task { await addSeries() }
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

    private func seasonBinding(for seasonNumber: Int, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { seasonMonitored[seasonNumber] ?? defaultValue },
            set: { seasonMonitored[seasonNumber] = $0 }
        )
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
        guard let tvdbId = series.tvdbId,
              let titleSlug = series.titleSlug,
              let qualityProfileId = selectedQualityProfileId,
              let rootFolderPath = selectedRootFolderPath else { return }

        isAdding = true
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
        isAdding = false

        if success {
            await onAdded()
            dismiss()
        }
    }
}

// MARK: - Episode Row

private struct EpisodeFileRow: View {
    let file: SonarrEpisodeFile
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let seasonNumber = file.seasonNumber {
                    Text(seasonNumber == 0 ? "Specials" : "S\(seasonNumber)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.18))
                        .clipShape(Capsule())
                }

                Text(file.relativePath ?? "Unknown File")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete File")
            }

            HStack(spacing: 10) {
                if let size = file.size, size > 0 {
                    Label(ByteFormatter.format(bytes: size), systemImage: "externaldrive")
                }
                if let videoCodec = file.mediaInfo?.videoCodec, !videoCodec.isEmpty {
                    Label(videoCodec, systemImage: "video")
                }
                if let resolution = file.mediaInfo?.resolution, !resolution.isEmpty {
                    Label(resolution, systemImage: "aspectratio")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let audio = audioDescription, !audio.isEmpty {
                Label(audio, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete File", systemImage: "trash")
            }
        }
    }

    private var audioDescription: String? {
        let codec = file.mediaInfo?.audioCodec
        let languages = file.mediaInfo?.audioLanguages

        switch (codec, languages) {
        case let (.some(codec), .some(languages)) where !codec.isEmpty && !languages.isEmpty:
            return "\(codec) • \(languages)"
        case let (.some(codec), _) where !codec.isEmpty:
            return codec
        case let (_, .some(languages)) where !languages.isEmpty:
            return languages
        default:
            return nil
        }
    }
}

private struct EpisodeRow: View {
    let episode: SonarrEpisode
    let onToggleMonitor: () -> Void
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.leading, 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(episode.episodeIdentifier)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.2))
                        .clipShape(Capsule())

                    Text(episode.title ?? "TBA")
                        .font(.subheadline)
                        .lineLimit(1)
                }

                if let airDate = episode.airDate {
                    Text(formattedDate(airDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Group {
                if episode.hasFile == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if episode.monitored == true {
                    Image(systemName: "clock.badge").foregroundStyle(.orange)
                } else {
                    Image(systemName: "minus.circle").foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .padding(.trailing, 14)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onToggleMonitor()
            } label: {
                Label(
                    episode.monitored == true ? "Unmonitor" : "Monitor",
                    systemImage: episode.monitored == true ? "bookmark.slash" : "bookmark.fill"
                )
            }
            Button { onSearch() } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
    }

    private var statusColor: Color {
        if episode.hasFile == true { return .green }
        if episode.monitored == true { return .orange }
        return .secondary.opacity(0.4)
    }

    private func formattedDate(_ string: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: string) else { return string }
        f.dateStyle = .medium; f.dateFormat = nil
        return f.string(from: date)
    }
}
