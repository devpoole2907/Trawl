import SwiftUI
import SwiftData

struct SonarrSeriesListView: View {
    /// Forwarded to `ArrMediaListView`. Present only when this list is the content
    /// column of the iPad split view; `nil` on iPhone, where rows stay links.
    var detailSelection: Binding<ArrMergeKey?>?

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager

    private let session: ArrLibraryRootSession<SonarrViewModel>
    /// The iPhone Library tab's scope switch; see `ArrMediaListView.libraryScope`.
    private var libraryScope: Binding<LibraryScope>? = nil
    @State private var showSetupSheet = false

    init(
        detailSelection: Binding<ArrMergeKey?>? = nil,
        session: ArrLibraryRootSession<SonarrViewModel>? = nil,
        libraryScope: Binding<LibraryScope>? = nil
    ) {
        self.detailSelection = detailSelection
        self.libraryScope = libraryScope
        self.session = session ?? ArrLibraryRootSession()
    }

    private var viewModel: SonarrViewModel? {
        get { session.viewModel }
        nonmutating set { session.viewModel = newValue }
    }

    private var viewModelLifecycleKey: String? {
        get { session.lifecycleKey }
        nonmutating set { session.lifecycleKey = newValue }
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                ArrMediaListView(
                    viewModel: vm,
                    serviceType: .sonarr,
                    nounSingular: "Series",
                    nounPlural: "Series",
                    emptyIcon: "tv",
                    row: { entry, _ in
                        SonarrSeriesRow(
                            entry: entry,
                            // An import issue on either server is an issue with
                            // this title. Queue rows carry the server that owns
                            // them, so the match is on (server, series).
                            hasIssue: vm.queueRecords.contains { record in
                                record.value.isImportIssueQueueItem
                                    && entry.copies.contains {
                                        $0.instanceID == record.instance.id && $0.id == record.value.seriesId
                                    }
                            },
                            subtitleCoverage: serviceManager.subtitleCoverage(for: entry.primary),
                            instances: serviceManager.badgeRefs(for: entry)
                        )
                        // The fortnightly "is the new one out yet" visit, without
                        // opening the show at all.
                        .contextMenu {
                            SonarrSeriesQuickActions(
                                entry: entry,
                                refs: serviceManager.badgeRefs(for: entry),
                                viewModel: vm
                            )
                        }
                    },
                    detailSelection: detailSelection,
                    detailDestination: { key in
                        SonarrSeriesDetailView(mergeKey: key, viewModel: vm)
                    },
                    session: session.list,
                    libraryScope: libraryScope
                )
            } else {
                sonarrUnavailableContent
                    .navigationTitle(libraryScope == nil ? "Series" : "")
                    .libraryScopeTitleMenu(libraryScope)
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            ArrSetupSheet(initialServiceType: .sonarr, onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
        .background(backgroundGradient)
        .task(id: viewModelLoadKey) {
            let lifecycleKey = viewModelLoadKey
            guard serviceManager.hasAnyConnectedSonarrInstance else {
                viewModel = nil
                viewModelLifecycleKey = nil
                return
            }
            if viewModel == nil || viewModelLifecycleKey != lifecycleKey {
                viewModel = SonarrViewModel(serviceManager: serviceManager, jellyfinManager: jellyfinManager)
                viewModelLifecycleKey = lifecycleKey
            }
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [ServiceIdentity.sonarr.brandColor.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [ServiceIdentity.sonarr.brandColor.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var sonarrUnavailableContent: some View {
        if !serviceManager.hasSonarrInstance {
            ServiceSetupView(title: "Sonarr Not Set Up", message: "Add a Sonarr server in Settings to manage your series.", systemImage: ServiceIdentity.sonarr.tabSystemImage, actionTitle: "Add Server", onSetup: { showSetupSheet = true })
            .scrollableUnavailableState()
        } else if serviceManager.sonarrIsConnecting || serviceManager.isInitializing {
            ArrServiceConnectionStatusView(
                serviceType: .sonarr,
                title: "Connecting to Sonarr",
                message: "Checking your configured Sonarr server."
            )
        } else {
            ArrServiceConnectionStatusView(
                serviceType: .sonarr,
                title: "Sonarr Unreachable",
                message: serviceManager.sonarrConnectionError ?? "Unable to reach your Sonarr server."
            )
        }
    }

    /// Rebuilds when the *set* of connected servers changes, not just when one
    /// nominated server does - either half of a pair joining or leaving changes
    /// what the blended library contains.
    private var viewModelLoadKey: String {
        serviceManager.connectedSonarr
            .map { "\($0.ref.id.uuidString):\($0.ref.ordinal)" }
            .joined(separator: "|")
    }
}

// MARK: - Series Row

struct SonarrSeriesRow: View {
    let entry: ArrLibraryEntry<SonarrSeries>
    let hasIssue: Bool
    var subtitleCoverage: SubtitleCoverage = .unknown
    var showTypeLabel: Bool = false
    /// The servers holding this title. Empty when only one Sonarr is configured,
    /// which suppresses the badges entirely.
    var instances: [ArrInstanceRef] = []

    /// Shared metadata - title, year, artwork, network - is identical on both
    /// servers, so the row reads it from the first copy.
    private var series: SonarrSeries { entry.primary }

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: series.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(series.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    // One row per title, badged with every server that holds it.
                    // Filled means that server has a file; hollow means the title is
                    // in its library with nothing downloaded yet.
                    ArrInstanceBadgeRow(refs: instances, downloadedTiers: availableTiers)
                }

                HStack(spacing: 4) {
                    ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Text("•")
                                .foregroundStyle(.secondary)
                        }
                        Text(item.title)
                            .foregroundStyle(item.color)
                    }
                    .font(.caption2)
                }

                HStack(spacing: 6) {
                    if let stats = series.statistics {
                        let fileCount = stats.episodeFileCount ?? 0
                        let totalCount = stats.episodeCount ?? 0
                        ProgressView(value: totalCount > 0 ? Double(fileCount) / Double(totalCount) : 0)
                            .tint(fileCount == totalCount ? .green : .blue)
                            .frame(width: 40)
                        Text("\(fileCount)/\(totalCount) eps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Only when the badges cannot say it. With a pair configured
                    // they carry availability themselves, so the pill would just be
                    // the same fact in words - it earns its place only when nothing
                    // is downloaded anywhere and there is a status to report, or on
                    // a single-server setup where there are no badges at all.
                    if instances.isEmpty || availableTiers.isEmpty {
                        ArrAvailabilityPill(
                            availableTiers: availableTiers,
                            showsTiers: !instances.isEmpty,
                            unavailableStatus: unavailableStatus
                        )
                    }

                    if subtitleCoverage.hasIndicator {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: "captions.bubble.fill")
                            .font(.caption2)
                            .foregroundStyle(subtitleCoverage.iconTint)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if hasIssue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ArrMonitorBadge(
                    monitoredCount: entry.copies.filter { $0.monitored == true }.count,
                    totalCount: entry.copies.count
                )
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    /// A series counts as available on a server once that server has any episode
    /// file. "Available 4K" on a show with one 2160p episode is the honest
    /// reading - the 4K library has started it - and the episode counter beside
    /// the pill carries how far along it is.
    private var availableTiers: [ArrQualityTier] {
        entry.availableTiers(from: instances) { ($0.statistics?.episodeFileCount ?? 0) > 0 }
    }

    /// Sonarr's series `status` is "continuing"/"ended", which describes the show
    /// rather than the library, so an undownloaded series says so plainly.
    private var unavailableStatus: String { "Not downloaded" }

    private var metadataItems: [SeriesRowMetadataItem] {
        var items: [SeriesRowMetadataItem] = []
        if let year = series.year {
            items.append(.init(title: String(year), color: .secondary))
        }
        if showTypeLabel {
            items.append(.init(title: "Series", color: .secondary))
        }
        if let network = series.network, !network.isEmpty {
            items.append(.init(title: network, color: .secondary))
        }
        if let next = SonarrSeriesQuickActions.nextAiring(of: series) {
            // Says when to come back, which "Continuing" never did.
            items.append(.init(
                title: String(localized: "Next \(SonarrSeriesQuickActions.shortDay(next))"),
                color: .green
            ))
        } else if let status = series.status, !status.isEmpty {
            items.append(.init(
                title: status.capitalized,
                color: status == "continuing" ? .green : .secondary
            ))
        }
        return items
    }
}

/// The Series list's long-press menu.
///
/// "Search Latest Episode" is the one action people come back for every week or
/// two; it used to sit five taps and two scrolls deep. The menu names the server
/// when there are two, because HD and 4K want different releases.
struct SonarrSeriesQuickActions: View {
    let entry: ArrLibraryEntry<SonarrSeries>
    let refs: [ArrInstanceRef]
    @Bindable var viewModel: SonarrViewModel

    var body: some View {
        if entry.copies.count > 1, refs.count == entry.copies.count {
            Menu {
                ForEach(Array(zip(refs, entry.copies)), id: \.0.id) { ref, copy in
                    Button(ref.shortLabel) { searchLatest(copy) }
                }
            } label: {
                Label("Search Latest Episode", systemImage: "sparkle.magnifyingglass")
            }
        } else {
            Button {
                searchLatest(entry.primary)
            } label: {
                Label("Search Latest Episode", systemImage: "sparkle.magnifyingglass")
            }
        }
    }

    private func searchLatest(_ series: SonarrSeries) {
        let title = series.title
        Task {
            let outcome = await viewModel.searchLatestEpisode(seriesId: series.id, instanceID: series.instanceID)
            Self.announce(outcome, title: title)
        }
    }

    /// One banner per outcome, worded for someone who has not opened the show.
    static func announce(_ outcome: SonarrViewModel.LatestEpisodeSearchOutcome, title: String) {
        switch outcome {
        case .searched(_, let identifier):
            InAppNotificationCenter.shared.showSuccess(
                title: "Search Queued",
                message: "\(title) \(identifier) was sent to Sonarr."
            )
        case .alreadyOnDisk(let identifier):
            InAppNotificationCenter.shared.showSuccess(
                title: "Already Downloaded",
                message: "\(title) \(identifier) is already on disk."
            )
        case .alreadyQueued(let identifier):
            InAppNotificationCenter.shared.showSuccess(
                title: "Already Downloading",
                message: "\(title) \(identifier) is already in the queue."
            )
        case .nothingAired:
            InAppNotificationCenter.shared.showError(
                title: "Nothing to Search",
                message: "No episode of \(title) has aired yet."
            )
        case .failed(let message):
            InAppNotificationCenter.shared.showError(title: "Search Failed", message: message)
        }
    }

    /// The soonest upcoming air time across the series' seasons. Sonarr reports it
    /// per season; the series object Trawl decodes does not carry its own.
    static func nextAiring(of series: SonarrSeries, now: Date = .now) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (series.seasons ?? [])
            .compactMap { $0.statistics?.nextAiring }
            .compactMap { fractional.date(from: $0) ?? formatter.date(from: $0) }
            .filter { $0 > now }
            .min()
    }

    /// "Today", "Tomorrow", a weekday within the week, otherwise "3 Dec".
    static func shortDay(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "today") }
        if calendar.isDateInTomorrow(date) { return String(localized: "tomorrow") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

private struct SeriesRowMetadataItem {
    let title: String
    let color: Color
}

#if DEBUG
extension SonarrSeriesListView {
    init(previewViewModel: SonarrViewModel) {
        self.init(session: ArrLibraryRootSession(viewModel: previewViewModel))
    }
}

#Preview("Loaded") {
    SonarrPreviewHost { manager in
        NavigationStack {
            SonarrSeriesListView(previewViewModel: SonarrViewModel(
                previewSeries: SonarrSeries.previewList,
                serviceManager: manager
            ))
        }
    }
}

#Preview("Loaded Heavy") {
    SonarrPreviewHost { manager in
        NavigationStack {
            SonarrSeriesListView(previewViewModel: SonarrViewModel(
                previewSeries: SonarrSeries.previewHeavyList,
                serviceManager: manager
            ))
        }
    }
}

#Preview("Empty") {
    SonarrPreviewHost { manager in
        NavigationStack {
            SonarrSeriesListView(previewViewModel: SonarrViewModel(
                previewSeries: [],
                serviceManager: manager
            ))
        }
    }
}

#Preview("Loading") {
    SonarrPreviewHost { manager in
        NavigationStack {
            SonarrSeriesListView(previewViewModel: SonarrViewModel(
                previewSeries: [],
                isLoading: true,
                serviceManager: manager
            ))
        }
    }
}

#Preview("Error") {
    SonarrPreviewHost(state: .sonarrConnectionError("The server returned 500 Internal Server Error.")) { _ in
        NavigationStack {
            SonarrSeriesListView()
        }
    }
}

#Preview("Connection Issue") {
    SonarrPreviewHost(state: .sonarrConnectionError("Unable to reach 192.168.1.50:8989.")) { _ in
        NavigationStack {
            SonarrSeriesListView()
        }
    }
}
#endif
