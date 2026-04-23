import SwiftUI

struct SonarrSeriesDetailView: View {
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

    @Bindable var viewModel: SonarrViewModel
    @Environment(SyncService.self) private var syncService

    // Library mode: look up series by ID from viewModel
    private let seriesId: Int?
    // Discover mode: series object passed directly
    private let discoverSeries: SonarrSeries?
    private let onAdded: (() async -> Void)?

    @State private var isFilesExpanded = false
    @State private var isAlternateTitlesExpanded = false
    @State private var isQueueExpanded = false
    @State private var isImportIssuesExpanded = false
    @State private var showEditSheet = false
    @State private var selectedEpisodeFileForDeletion: SonarrEpisodeFile?
    @State private var showAddSheet = false
    @State private var didAdd = false
    @State private var queueActionInFlightIDs: Set<Int> = []
    @State private var pendingQueueAction: PendingQueueAction?

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

    private var importIssueQueueItems: [ArrQueueItem] {
        queueItems.filter { !isActiveQueueItem($0) && $0.isImportIssueQueueItem }
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
                while !Task.isCancelled {
                    await viewModel.loadQueue()
                    try? await Task.sleep(for: .seconds(2))
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

        if let certification = series.certification, !certification.isEmpty {
            badges.append(DetailBadge(icon: "shield", label: certification, color: .white.opacity(0.8)))
        }

        if isInLibrary && series.monitored == true {
            badges.append(DetailBadge(icon: "bookmark.fill", label: "Monitored", color: .blue))
        }

        let seriesQueue = viewModel.queue.filter { $0.seriesId == series.id }
        if !seriesQueue.isEmpty {
            let issues = seriesQueue.filter { $0.isImportIssueQueueItem }.count
            let downloading = seriesQueue.filter { $0.isDownloadingQueueItem }.count
            let total = seriesQueue.count
            
            if issues > 0 {
                badges.append(DetailBadge(
                    icon: "exclamationmark.triangle.fill",
                    label: issues == total ? "\(total) Import Issue\(total == 1 ? "" : "s")" : "\(issues) Import Issue\(issues == 1 ? "" : "s")",
                    color: .orange
                ))
            } else if downloading > 0 {
                badges.append(DetailBadge(
                    icon: "arrow.down.circle.fill",
                    label: downloading == total ? "\(total) Downloading" : "\(downloading) of \(total) Downloading",
                    color: .purple
                ))
            } else {
                let status = seriesQueue.first?.status?.capitalized ?? "In Queue"
                badges.append(DetailBadge(
                    icon: "clock.arrow.circlepath",
                    label: total == 1 ? status : "\(total) \(status)",
                    color: .purple
                ))
            }
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

        if !activeQueueItems.isEmpty {
            queueCard(activeQueueItems)
        }

        if !importIssueQueueItems.isEmpty {
            importIssuesCard(importIssueQueueItems)
        }

        if let genres = series.genres, !genres.isEmpty {
            genreChips(genres)
        }

        if let ratings = series.ratings {
            ratingsCard(ratings)
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

            HStack(spacing: 10) {
                Button {
                    showEditSheet = true
                } label: {
                    importIssueActionIcon(systemName: "slider.horizontal.3", tint: .blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Series")
                .disabled(isRemoving || !isInLibrary)

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

            Text("Use Edit Series to change the root folder or other import-related settings before retrying.")
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

        return NavigationLink {
            SonarrSeasonSearchView(
                viewModel: viewModel,
                series: series ?? discoverSeries,
                seasonNumber: seasonNum,
                episodes: seasonEpisodes.sorted { $0.episodeNumber < $1.episodeNumber }
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
                        Task { try? await viewModel.refreshSeries() }
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

struct SonarrInteractiveSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries
    let episode: SonarrEpisode?
    let seasonNumber: Int?

    @State private var releases: [ArrRelease] = []
    @State private var isLoading = false
    @State private var grabbingReleaseID: String?
    @State private var hasLoaded = false
    @State private var searchText = ""
    @State private var releaseSort = ArrReleaseSort()

    init(viewModel: SonarrViewModel, series: SonarrSeries, episode: SonarrEpisode? = nil, seasonNumber: Int? = nil) {
        self.viewModel = viewModel
        self.series = series
        self.episode = episode
        self.seasonNumber = seasonNumber
        
        var initialSort = ArrReleaseSort()
        initialSort.seasonPack = episode != nil ? .episode : .season
        self._releaseSort = State(initialValue: initialSort)
    }

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
            let matchesSeasonPack: Bool
            switch releaseSort.seasonPack {
            case .any: matchesSeasonPack = true
            case .season: matchesSeasonPack = release.fullSeason == true
            case .episode: matchesSeasonPack = release.fullSeason != true
            }
            return matchesIndexer && matchesQuality && matchesApproved && matchesSeasonPack
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
                } else if releases.isEmpty && hasLoaded {
                    ContentUnavailableView(
                        "No Releases Found",
                        systemImage: "magnifyingglass",
                        description: Text("Sonarr didn't return any manual search results.")
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
                                SonarrReleaseActionView(
                                    release: release,
                                    artURL: series.posterURL ?? series.fanartURL,
                                    isGrabbing: grabbingReleaseID == release.id,
                                    onGrab: { await grab(release: release) }
                                )
                            } label: {
                                SonarrReleaseRowView(release: release)
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
            .navigationTitle(titleString)
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
            Picker("Type", selection: $releaseSort.seasonPack) {
                ForEach(ArrSeasonPackFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.inline)
            .menuIndicator(.hidden)

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

    private var titleString: String {
        if let episode {
            return "\(series.title) · \(episode.episodeIdentifier)"
        } else if let seasonNumber {
            return "\(series.title) · Season \(seasonNumber)"
        } else {
            return series.title
        }
    }

    private func loadReleases() async {
        guard !hasLoaded else { return }
        isLoading = true
        releases = []
        releases = await viewModel.interactiveSearch(episodeId: episode?.id, seriesId: series.id, seasonNumber: seasonNumber)
        isLoading = false
        hasLoaded = true
    }

    private func grab(release: ArrRelease) async {
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

struct SonarrReleaseRowView: View {
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

struct SonarrReleaseActionView: View {
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
                .tint(.purple)
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
                Rectangle().fill(Color.purple.opacity(0.5))
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

struct SonarrSeasonSearchView: View {
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries?
    let seasonNumber: Int
    let episodes: [SonarrEpisode]

    @State private var isDispatchingAutomaticSearch = false
    @State private var showInteractiveSearchSheet = false

    private var title: String {
        seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)"
    }

    private var sortedEpisodes: [SonarrEpisode] {
        episodes.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 20) {
                seasonSearchHero

                VStack(spacing: 14) {
                    automaticSearchButton
                    interactiveSearchButton
                }

                seasonSearchInfoCard(title: "Episodes", icon: "list.bullet") {
                    if sortedEpisodes.isEmpty {
                        ContentUnavailableView(
                            "No Episodes",
                            systemImage: "tv.slash",
                            description: Text("This season does not have any loaded episodes yet.")
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(sortedEpisodes) { episode in
                                let queueItem = viewModel.queue.first { $0.episodeId == episode.id }
                                NavigationLink {
                                    SonarrEpisodeSearchView(viewModel: viewModel, series: series, episode: episode)
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
                                            let isIssue = q.isImportIssueQueueItem
                                            let status = isIssue ? "Import Issue" : (q.status?.capitalized ?? "Downloading")
                                            Text(status)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(isIssue ? .orange : .purple)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background((isIssue ? Color.orange : Color.purple).opacity(0.2))
                                                .clipShape(Capsule())
                                                .overlay(alignment: .topTrailing) {
                                                    if isIssue {
                                                        Image(systemName: "exclamationmark.circle.fill")
                                                            .font(.system(size: 8))
                                                            .foregroundStyle(.orange)
                                                            .offset(x: 3, y: -3)
                                                    }
                                                }
                                        } else if episode.hasFile == true {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
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

                                if episode.id != sortedEpisodes.last?.id {
                                    Divider().padding(.leading, 14)
                                }
                            }
                        }
                    }
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
        .sheet(isPresented: $showInteractiveSearchSheet) {
            if let series {
                SonarrInteractiveSearchSheet(viewModel: viewModel, series: series, seasonNumber: seasonNumber)
            }
        }
    }

    private func formattedDate(_ string: String?) -> String {
        guard let string, !string.isEmpty else { return "TBA" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: string) else { return string }
        f.dateStyle = .medium; f.dateFormat = nil
        return f.string(from: date)
    }

    private var seasonSearchHero: some View {
        VStack(spacing: 14) {
            ArrArtworkView(url: series?.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.purple.opacity(0.3))
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 160, height: 240)
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
            Task {
                await viewModel.searchSeason(seriesId: seriesId, seasonNumber: seasonNumber)
                isDispatchingAutomaticSearch = false

                if let error = viewModel.error, !error.isEmpty {
                    InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
                } else {
                    InAppNotificationCenter.shared.showSuccess(
                        title: "Search Queued",
                        message: "\(title) was sent to Sonarr for automatic search."
                    )
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
        .disabled(series == nil || sortedEpisodes.isEmpty)
    }

    private func seasonSearchActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right"
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.purple)
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

struct SonarrEpisodeSearchView: View {
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries?
    let episode: SonarrEpisode
    @Environment(\.dismiss) private var dismiss

    @State private var isDispatchingAutomaticSearch = false
    @State private var showInteractiveSearchSheet = false
    @State private var episodeFileToDelete: SonarrEpisodeFile?
    @State private var showDeleteFileAlert = false

    private var episodeHistory: [ArrHistoryRecord] {
        viewModel.history
            .filter { $0.episodeId == episode.id }
            .sorted {
                SonarrEpisodeHistoryDateParser.parse($0.date) ?? .distantPast >
                SonarrEpisodeHistoryDateParser.parse($1.date) ?? .distantPast
            }
    }

    private var queueItem: ArrQueueItem? {
        viewModel.queue.first { $0.episodeId == episode.id }
    }

    private var episodeFiles: [SonarrEpisodeFile] {
        guard let seriesId = series?.id else { return [] }
        return viewModel.episodeFiles[seriesId]?.filter { $0.id == episode.episodeFileId } ?? []
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

                episodeSearchInfoCard(title: "Episode", icon: "text.justify.left") {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Aired \(formattedDate(episode.airDate))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            if let overview = episode.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 12) {
                            episodeStatusBadge(episode.hasFile == true ? "Downloaded" : "Missing", tint: episode.hasFile == true ? .green : .orange, systemImage: episode.hasFile == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            episodeStatusBadge(episode.monitored == true ? "Monitored" : "Unmonitored", tint: .blue, systemImage: episode.monitored == true ? "bookmark.fill" : "bookmark.slash")
                            
                            if let q = queueItem {
                                let isIssue = q.isImportIssueQueueItem
                                episodeStatusBadge(
                                    isIssue ? "Import Issue" : (q.status?.capitalized ?? "Downloading"),
                                    tint: isIssue ? .orange : .purple,
                                    systemImage: isIssue ? "exclamationmark.triangle.fill" : (q.isDownloadingQueueItem ? "arrow.down.circle.fill" : "clock.arrow.circlepath")
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !episodeFiles.isEmpty {
                    episodeSearchInfoCard(title: "Files", icon: "doc.fill") {
                        VStack(spacing: 0) {
                            ForEach(Array(episodeFiles.enumerated()), id: \.element.id) { index, file in
                                episodeFileRow(file)

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
        .navigationTitle(episode.episodeIdentifier)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .environment(\.colorScheme, .dark)
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
                SonarrInteractiveSearchSheet(viewModel: viewModel, series: series, episode: episode)
            }
        }
        .task {
            await viewModel.loadHistory(page: 1)
        }
    }

    private var episodeSearchHero: some View {
        VStack(spacing: 14) {
            ArrArtworkView(url: series?.posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(Color.purple.opacity(0.3))
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 160, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)

            VStack(spacing: 6) {
                Text(episode.title ?? episode.episodeIdentifier)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(series?.title ?? "Series") · \(episode.episodeIdentifier)")
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
                await viewModel.searchEpisode(episode)
                isDispatchingAutomaticSearch = false

                if let error = viewModel.error, !error.isEmpty {
                    InAppNotificationCenter.shared.showError(title: "Search Failed", message: error)
                } else {
                    InAppNotificationCenter.shared.showSuccess(
                        title: "Search Queued",
                        message: "\(episode.title ?? episode.episodeIdentifier) was sent to Sonarr for automatic search."
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
        .disabled(series == nil)
    }

    private func episodeSearchActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right"
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.purple)
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
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: string) else { return string }
        f.dateStyle = .medium; f.dateFormat = nil
        return f.string(from: date)
    }

    @ViewBuilder
    private func episodeFileRow(_ file: SonarrEpisodeFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.quality?.quality?.name ?? "Unknown Quality")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(ByteFormatter.format(bytes: file.size ?? 0))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Menu {
                    Button(role: .destructive) {
                        episodeFileToDelete = file
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

            if let path = file.path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                episodeFileToDelete = file
                showDeleteFileAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct SonarrEpisodeHistoryRow: View {
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

private enum SonarrEpisodeHistoryDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalISO.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
