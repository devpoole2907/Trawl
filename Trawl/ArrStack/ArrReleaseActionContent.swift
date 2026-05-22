import SwiftUI

struct ArrReleaseActionContent: View {
    let release: ArrRelease
    let artURL: URL?
    let accentColor: Color
    let isGrabbing: Bool
    let onGrab: () async -> Void

    @State private var grabInFlight = false

    private var canDownload: Bool {
        !isGrabbing && release.downloadAllowed != false
    }

    private var qualityScoreText: String? {
        guard let score = release.customFormatScore, score != 0 else { return nil }
        return score > 0 ? "+\(score)" : "\(score)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                heroHeader
                qualityBadgeRow
                statsGrid

                if let rejections = release.rejections, !rejections.isEmpty {
                    rejectionsCard(rejections)
                }

                downloadButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background {
            ArrArtworkView(url: artURL, contentMode: .fill) {
                Rectangle().fill(accentColor.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(1.4)
            .blur(radius: 60)
            .saturation(1.6)
            .overlay(
                LinearGradient(
                    colors: [Color.black.opacity(0.35), Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
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

    private var heroHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.25))
                    .frame(width: 78, height: 78)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            VStack(spacing: 6) {
                Text(release.title ?? "Unknown Release")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                    Text(release.indexer ?? "Unknown Indexer")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var qualityBadgeRow: some View {
        HStack(spacing: 8) {
            badge(text: release.qualityName, systemImage: "sparkles", tint: accentColor)
            badge(text: release.protocolName, systemImage: "network", tint: .blue)
            if let score = qualityScoreText {
                badge(text: score, systemImage: "star.fill", tint: .yellow)
            }
            if release.approved == true {
                badge(text: "Approved", systemImage: "checkmark.seal.fill", tint: .green)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statsGrid: some View {
        let cells: [StatCell] = [
            release.size.map { StatCell(systemImage: "externaldrive.fill", label: "Size", value: ByteFormatter.format(bytes: $0), tint: .cyan) },
            release.ageDescription.map { StatCell(systemImage: "clock.fill", label: "Age", value: $0, tint: .pink) },
            release.seeders.map { StatCell(systemImage: "arrow.up.circle.fill", label: "Seeders", value: "\($0)", tint: seederColor(for: $0)) },
            release.leechers.map { StatCell(systemImage: "arrow.down.circle.fill", label: "Leechers", value: "\($0)", tint: .orange) }
        ].compactMap { $0 }

        if !cells.isEmpty {
            let columns = [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ]
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(cells) { cell in
                    statCellView(cell)
                }
            }
        }
    }

    private func statCellView(_ cell: StatCell) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(cell.tint.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: cell.systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(cell.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(cell.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(cell.value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
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

    private var downloadButton: some View {
        Button {
            guard !grabInFlight else { return }
            Task {
                grabInFlight = true
                defer { grabInFlight = false }
                await onGrab()
            }
        } label: {
            HStack(spacing: 12) {
                if isGrabbing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Download Release")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)

                    Text(release.indexer ?? release.qualityName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!canDownload)
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.18), in: Capsule())
        .overlay(
            Capsule().stroke(tint.opacity(0.4), lineWidth: 1)
        )
    }

    private func seederColor(for seeders: Int) -> Color {
        switch seeders {
        case 50...: .green
        case 10...: .mint
        case 1...: .orange
        default: .red
        }
    }

    private struct StatCell: Identifiable {
        let id = UUID()
        let systemImage: String
        let label: String
        let value: String
        let tint: Color
    }
}

struct ArrReleaseInfoChip: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
    let isProminent: Bool

    init(_ label: String, color: Color, isProminent: Bool = false) {
        self.label = label
        self.color = color
        self.isProminent = isProminent
    }
}

struct ArrInfoRowView: View {
    let icon: (systemImage: String, color: Color)?
    let title: String
    let subtitleLeading: String
    let subtitleLeadingColor: Color
    let subtitleTrailing: String?
    let chips: [ArrReleaseInfoChip]
    let message: (text: String, color: Color)?

    init(
        icon: (systemImage: String, color: Color)? = nil,
        title: String,
        subtitleLeading: String,
        subtitleLeadingColor: Color = .secondary,
        subtitleTrailing: String? = nil,
        chips: [ArrReleaseInfoChip] = [],
        message: (text: String, color: Color)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitleLeading = subtitleLeading
        self.subtitleLeadingColor = subtitleLeadingColor
        self.subtitleTrailing = subtitleTrailing
        self.chips = chips
        self.message = message
    }

    init(release: ArrRelease) {
        self.icon = nil
        self.title = release.title ?? "Unknown Release"
        self.subtitleLeading = release.indexer ?? "Unknown Indexer"
        self.subtitleLeadingColor = .secondary
        self.subtitleTrailing = release.ageDescription
        self.chips = Self.releaseChips(from: release)
        self.message = nil
    }

    init(blocklistItem item: ArrBlocklistItem, source: ArrServiceType) {
        self.icon = (
            systemImage: source == .sonarr ? "tv" : "film",
            color: source == .sonarr ? .purple : .orange
        )
        self.title = item.sourceTitle ?? "Unknown Release"
        self.subtitleLeading = item.indexer ?? "Unknown Indexer"
        self.subtitleLeadingColor = .secondary
        self.subtitleTrailing = item.date.flatMap { Self.parseBlocklistDate($0) }
        var chips: [ArrReleaseInfoChip] = []
        if let quality = item.quality?.quality?.name, !quality.isEmpty {
            chips.append(ArrReleaseInfoChip(quality, color: .primary))
        }
        self.chips = chips
        if let msg = item.message, !msg.isEmpty {
            self.message = (msg, .orange)
        } else {
            self.message = nil
        }
    }

    init(queueItem item: ArrQueueItem, source: ArrServiceType, linkedTorrent: Torrent? = nil) {
        let progress = linkedTorrent?.progress ?? item.progress
        let primaryStatus = linkedTorrent?.state.displayName ?? item.trackedDownloadState ?? item.status ?? "queued"

        self.init(
            icon: Self.queueIcon(for: source),
            title: Self.queueTitle(for: item),
            subtitleLeading: Self.displayStatus(primaryStatus),
            subtitleLeadingColor: Self.queueStatusColor(for: item),
            subtitleTrailing: Self.nonBlank(item.downloadClient),
            chips: Self.queueChips(for: item, linkedTorrent: linkedTorrent, progress: progress),
            message: item.primaryStatusMessage.map { ($0, Self.queueStatusColor(for: item)) }
        )
    }

    private static func parseBlocklistDate(_ value: String) -> String? {
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractionalISO.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(Date.FormatStyle.dateTime.day(.twoDigits).month(.abbreviated).year(.defaultDigits))
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon.systemImage)
                    .foregroundStyle(icon.color)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                subtitleRow

                if let message {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(message.color)
                        .lineLimit(2)
                }

                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips) { chip in
                                releaseChip(chip.label, color: chip.color, isProminent: chip.isProminent)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitleRow: some View {
        HStack(spacing: 6) {
            Text(subtitleLeading)
                .foregroundStyle(subtitleLeadingColor)
            if let trailing = subtitleTrailing {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(trailing)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func releaseChip(_ label: String, color: Color, isProminent: Bool = false) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(isProminent ? 0.22 : 0.1))
            .clipShape(Capsule())
    }

    private static func releaseChips(from release: ArrRelease) -> [ArrReleaseInfoChip] {
        var chips: [ArrReleaseInfoChip] = []
        if release.approved != true {
            chips.append(ArrReleaseInfoChip(release.rejected == true ? "Rejected" : "Not Approved", color: .orange))
        }
        chips.append(ArrReleaseInfoChip(release.qualityName, color: .primary))
        if let size = release.size, size > 0 {
            chips.append(ArrReleaseInfoChip(ByteFormatter.format(bytes: size), color: .secondary))
        }
        chips.append(ArrReleaseInfoChip(release.protocolName, color: .secondary))
        if let seederLabel = ArrInfoRowView.seederLabel(for: release) {
            chips.append(ArrReleaseInfoChip(seederLabel, color: ArrInfoRowView.seederColor(for: release.seeders ?? 0), isProminent: true))
        }
        return chips
    }

    private static func seederLabel(for release: ArrRelease) -> String? {
        switch (release.seeders, release.leechers) {
        case let (seeders?, leechers?):
            "S:\(seeders) L:\(leechers)"
        case let (seeders?, nil):
            "S:\(seeders)"
        case let (nil, leechers?):
            "L:\(leechers)"
        case (nil, nil):
            nil
        }
    }

    private static func seederColor(for seeders: Int) -> Color {
        switch seeders {
        case 50...: .green
        case 10...: .mint
        case 1...: .orange
        default: .red
        }
    }

    private static func queueIcon(for source: ArrServiceType) -> (systemImage: String, color: Color) {
        switch source {
        case .sonarr:
            ("tv", .purple)
        case .radarr:
            ("film", .orange)
        case .prowlarr:
            ("magnifyingglass.circle", .yellow)
        case .bazarr:
            ("captions.bubble", .teal)
        }
    }

    private static func queueTitle(for item: ArrQueueItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        if let statusTitle = item.statusMessages?.first?.title, !statusTitle.isEmpty { return statusTitle }
        return "Unknown"
    }

    private static func displayStatus(_ status: String) -> String {
        status
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    private static func queueETA(for item: ArrQueueItem, linkedTorrent: Torrent?) -> String? {
        if let linkedTorrent,
           !linkedTorrent.state.isCompleted,
           linkedTorrent.eta > 0,
           linkedTorrent.eta < 8_640_000 {
            return ByteFormatter.formatETA(seconds: linkedTorrent.eta)
        }

        guard let timeleft = item.timeleft, !timeleft.isEmpty, timeleft != "00:00:00" else { return nil }
        let parts = timeleft.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return timeleft }
        let hours = Int(parts[0]) ?? 0
        let minutes = parts[1]
        let seconds = parts[2]
        if hours > 0 { return "\(hours)h \(minutes)m" }
        let minuteValue = Int(minutes) ?? 0
        if minuteValue > 0 { return "\(minuteValue)m \(seconds)s" }
        return "\(seconds)s"
    }

    private static func queueChips(for item: ArrQueueItem, linkedTorrent: Torrent?, progress: Double) -> [ArrReleaseInfoChip] {
        var chips: [ArrReleaseInfoChip] = [
            ArrReleaseInfoChip(
                "\(Int(progress * 100))%",
                color: queueProgressColor(for: item, progress: progress),
                isProminent: true
            )
        ]

        if let linkedTorrent {
            chips.append(ArrReleaseInfoChip(
                ByteFormatter.formatSpeed(bytesPerSecond: linkedTorrent.dlspeed),
                color: .blue,
                isProminent: linkedTorrent.dlspeed > 0
            ))
        }

        if let eta = queueETA(for: item, linkedTorrent: linkedTorrent) {
            chips.append(ArrReleaseInfoChip("ETA \(eta)", color: .secondary))
        }

        if let sizeChip = queueSizeChip(for: item, linkedTorrent: linkedTorrent) {
            chips.append(ArrReleaseInfoChip(sizeChip, color: .secondary))
        }

        if let protocolName = nonBlank(item.protocol_) {
            chips.append(ArrReleaseInfoChip(protocolName.capitalized, color: .secondary))
        }

        return chips
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func queueSizeChip(for item: ArrQueueItem, linkedTorrent: Torrent?) -> String? {
        if let linkedTorrent, linkedTorrent.totalSize > 0 {
            let downloaded = max(0, linkedTorrent.totalSize - linkedTorrent.amountLeft)
            return "\(ByteFormatter.format(bytes: downloaded)) / \(ByteFormatter.format(bytes: linkedTorrent.totalSize))"
        }

        guard let size = item.size, size > 0 else { return nil }
        let total = Int64(size)
        if let sizeleft = item.sizeleft {
            let downloaded = max(0, total - Int64(sizeleft))
            return "\(ByteFormatter.format(bytes: downloaded)) / \(ByteFormatter.format(bytes: total))"
        }
        return ByteFormatter.format(bytes: total)
    }

    private static func queueStatusColor(for item: ArrQueueItem) -> Color {
        switch item.trackedDownloadStatus {
        case "warning":
            .orange
        case "error":
            .red
        default:
            .secondary
        }
    }

    private static func queueProgressColor(for item: ArrQueueItem, progress: Double) -> Color {
        switch item.trackedDownloadStatus {
        case "warning":
            .orange
        case "error":
            .red
        default:
            progress >= 1 ? .green : .primary
        }
    }
}

struct ArrInteractiveSearchBrowser<Destination: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService

    let title: String
    let emptyDescription: String
    let loadingDescription: String
    let supportsSeasonPackFiltering: Bool
    let loadAction: () async throws -> [ArrRelease]
    let grabAction: (ArrRelease) async -> Bool
    let currentErrorMessage: () -> String?
    @ViewBuilder let destination: (ArrRelease, Bool, @escaping () async -> Void) -> Destination

    @State private var releases: [ArrRelease] = []
    @State private var isLoading = false
    @State private var grabbingReleaseID: String?
    @State private var hasLoaded = false
    @State private var searchText = ""
    @State private var releaseSort: ArrReleaseSort
    @State private var searchError: String?
    @State private var replacementCandidate: ExistingTorrentReplacementCandidate?

    init(
        title: String,
        emptyDescription: String,
        loadingDescription: String,
        supportsSeasonPackFiltering: Bool = false,
        initialSort: ArrReleaseSort = ArrReleaseSort(),
        loadAction: @escaping () async throws -> [ArrRelease],
        grabAction: @escaping (ArrRelease) async -> Bool,
        currentErrorMessage: @escaping () -> String?,
        @ViewBuilder destination: @escaping (ArrRelease, Bool, @escaping () async -> Void) -> Destination
    ) {
        self.title = title
        self.emptyDescription = emptyDescription
        self.loadingDescription = loadingDescription
        self.supportsSeasonPackFiltering = supportsSeasonPackFiltering
        self.loadAction = loadAction
        self.grabAction = grabAction
        self.currentErrorMessage = currentErrorMessage
        self.destination = destination
        self._releaseSort = State(initialValue: initialSort)
    }

    private var availableIndexers: [String] {
        Array(Set(releases.compactMap(\.indexer))).sorted()
    }

    private var availableQualities: [String] {
        Array(Set(releases.map(\.qualityName))).sorted()
    }

    private var sortedFilteredReleases: [ArrRelease] {
        let filtered = releases.filter { release in
            let matchesIndexer = releaseSort.indexer.isEmpty || releaseSort.indexer == release.indexer
            let matchesQuality = releaseSort.quality.isEmpty || releaseSort.quality == release.qualityName
            let matchesApproved = !releaseSort.approvedOnly || release.approved == true
            let matchesSeasonPack = matchesSeasonPack(for: release)
            return matchesIndexer && matchesQuality && matchesApproved && matchesSeasonPack
        }
        guard releaseSort.option != .default else { return filtered }
        return filtered.sorted { lhs, rhs in
            let asc = releaseSort.isAscending
            switch releaseSort.option {
            case .default: return false
            case .age:
                let lhsAge = lhs.ageHours ?? Double(lhs.age ?? 0) * 24
                let rhsAge = rhs.ageHours ?? Double(rhs.age ?? 0) * 24
                return asc ? lhsAge < rhsAge : lhsAge > rhsAge
            case .quality:
                return asc ? lhs.qualityName < rhs.qualityName : lhs.qualityName > rhs.qualityName
            case .size:
                return asc ? (lhs.size ?? 0) < (rhs.size ?? 0) : (lhs.size ?? 0) > (rhs.size ?? 0)
            case .seeders:
                return asc ? (lhs.seeders ?? 0) < (rhs.seeders ?? 0) : (lhs.seeders ?? 0) > (rhs.seeders ?? 0)
            }
        }
    }

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

    private var qualityFilterItems: [TrawlSegmentBarItem<String>] {
        [TrawlSegmentBarItem("All", value: "")]
            + availableQualities.map { TrawlSegmentBarItem($0, value: $0) }
    }

    private var releaseCountSubtitle: String {
        guard !releases.isEmpty else { return "" }
        let shown = displayedReleases.count
        let total = releases.count
        if shown == total {
            return total == 1 ? "\(total) release" : "\(total) releases"
        }
        return total == 1 ? "\(shown) of \(total) release" : "\(shown) of \(total) releases"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = searchError, !error.isEmpty {
                    ContentUnavailableView {
                        Label("Search Failed", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            searchError = nil
                            hasLoaded = false
                            Task { await loadReleases() }
                        }
                    }
                } else if releases.isEmpty && hasLoaded {
                    ContentUnavailableView(
                        "No Releases Found",
                        systemImage: "magnifyingglass",
                        description: Text(emptyDescription)
                    )
                } else if !releases.isEmpty && displayedReleases.isEmpty {
                    ContentUnavailableView {
                        Label("No Releases", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Some releases are hidden by the selected filters.")
                    } actions: {
                        Button("Clear Filters") { clearFilters() }
                    }
                } else {
                    releaseList
                }
            }
            .searchable(text: $searchText, prompt: "Search releases…")
            .safeAreaInset(edge: .top) {
                if !releases.isEmpty {
                    qualityFilterBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(releaseCountSubtitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { browserToolbar }
            .task {
                await loadReleases()
            }
            .onChange(of: releaseSort.option) { _, _ in
                releaseSort.isAscending = false
            }
            .alert(
                "Replace Existing Torrent?",
                isPresented: Binding(
                    get: { replacementCandidate != nil },
                    set: { if !$0 { replacementCandidate = nil } }
                ),
                presenting: replacementCandidate
            ) { candidate in
                Button("Remove Job and Retry", role: .destructive) {
                    Task { await removeExistingTorrentAndRetry(candidate) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { candidate in
                Text("qBittorrent already has \"\(candidate.torrent.name)\". Trawl can remove that qBittorrent job without deleting files, then retry this grab.")
            }
        }
    }

    private var releaseList: some View {
        List {
            loadingSection

            ForEach(displayedReleases) { release in
                releaseNavigationLink(for: release)
            }
            .animation(.default, value: displayedReleases.count)

            hiddenReleasesFooter
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    @ViewBuilder
    private var loadingSection: some View {
        if isLoading && releases.isEmpty {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Searching indexers…")
                            .font(.subheadline.weight(.semibold))
                        Text(loadingDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func releaseNavigationLink(for release: ArrRelease) -> some View {
        NavigationLink {
            destination(
                release,
                grabbingReleaseID == release.id,
                { await grab(release: release) }
            )
        } label: {
            ArrInfoRowView(release: release)
        }
    }

    @ViewBuilder
    private var hiddenReleasesFooter: some View {
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

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }

        ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
            sortMenu
            filterMenu
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
            Image(systemName: releaseSort.option != .default ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down")
        }
    }

    private var qualityFilterBar: some View {
        TrawlSegmentBar(
            "Quality",
            selection: Binding(
                get: { releaseSort.quality },
                set: { quality in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        releaseSort.quality = quality
                    }
                }
            ),
            items: qualityFilterItems
        )
    }

    private var filterMenu: some View {
        Menu {
            if supportsSeasonPackFiltering {
                Picker("Type", selection: $releaseSort.seasonPack) {
                    ForEach(ArrSeasonPackFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.inline)
                .menuIndicator(.hidden)
            }

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

            Toggle("Approved Only", isOn: $releaseSort.approvedOnly)
        } label: {
            Image(systemName: releaseSort.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private func matchesSeasonPack(for release: ArrRelease) -> Bool {
        guard supportsSeasonPackFiltering else { return true }
        switch releaseSort.seasonPack {
        case .any:
            return true
        case .season:
            return release.fullSeason == true
        case .episode:
            return release.fullSeason != true
        }
    }

    private func clearFilters() {
        releaseSort.indexer = ""
        releaseSort.quality = ""
        releaseSort.approvedOnly = false
        releaseSort.seasonPack = .any
    }

    private func loadReleases() async {
        guard !hasLoaded else { return }
        isLoading = true
        releases = []
        searchError = nil
        do {
            let results = try await loadAction()
            isLoading = false
            let batchSize = results.count > 30 ? 6 : 3
            for batch in results.chunked(into: batchSize) {
                guard !Task.isCancelled else { break }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    releases.append(contentsOf: batch)
                }
                try? await Task.sleep(for: .milliseconds(18))
            }
            hasLoaded = true
        } catch is CancellationError {
            hasLoaded = false
            isLoading = false
        } catch {
            searchError = interactiveSearchErrorMessage(error)
            hasLoaded = true
            isLoading = false
        }
    }

    private func grab(release: ArrRelease) async {
        guard grabbingReleaseID == nil else { return }
        grabbingReleaseID = release.id
        let didGrab = await grabAction(release)
        grabbingReleaseID = nil

        if didGrab {
            dismiss()
        } else if let error = currentErrorMessage(),
                  shouldOfferExistingTorrentReplacement(for: error),
                  let torrent = matchingExistingTorrent(for: release) {
            replacementCandidate = ExistingTorrentReplacementCandidate(
                release: release,
                torrent: torrent
            )
        }
    }

    private func interactiveSearchErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription)\n\nCode: \(nsError.domain) \(nsError.code)"
    }

    private func shouldOfferExistingTorrentReplacement(for error: String) -> Bool {
        let normalized = error.lowercased()
        return normalized.contains("download client rejected this release") ||
            normalized.contains("download client failed to add torrent")
    }

    private func matchingExistingTorrent(for release: ArrRelease) -> Torrent? {
        guard let hash = release.torrentInfoHash?.lowercased() else { return nil }
        if let direct = syncService.torrents[hash] { return direct }
        return syncService.torrents.first { key, torrent in
            key.lowercased() == hash || torrent.hash.lowercased() == hash
        }?.value
    }

    private func removeExistingTorrentAndRetry(_ candidate: ExistingTorrentReplacementCandidate) async {
        guard grabbingReleaseID == nil else { return }
        replacementCandidate = nil
        grabbingReleaseID = candidate.release.id
        defer { grabbingReleaseID = nil }

        do {
            try await torrentService.deleteTorrents(hashes: [candidate.torrent.hash], deleteFiles: false)
            await syncService.refreshNow()
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Replace Failed",
                message: error.localizedDescription
            )
            return
        }

        let didGrab = await grabAction(candidate.release)
        if didGrab {
            dismiss()
        }
    }
}

private struct ExistingTorrentReplacementCandidate: Identifiable {
    let release: ArrRelease
    let torrent: Torrent

    var id: String { "\(release.id)|\(torrent.hash)" }
}
