import SwiftUI
import SwiftData

struct SonarrSeriesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager

    @State private var viewModel: SonarrViewModel?
    @State private var viewModelLifecycleKey: String?
    @State private var showSetupSheet = false

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
                    },
                    detailDestination: { key in
                        SonarrSeriesDetailView(mergeKey: key, viewModel: vm)
                    }
                )
            } else {
                sonarrUnavailableContent
                    .navigationTitle("Series")
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
            guard serviceManager.sonarrConnected else {
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
            ContentUnavailableView {
                Label("Sonarr Not Set Up", systemImage: ServiceIdentity.sonarr.tabSystemImage)
            } description: {
                Text("Add a Sonarr server in Settings to manage your series.")
            } actions: {
                Button {
                    showSetupSheet = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            }
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
    /// nominated server does — either half of a pair joining or leaving changes
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

    /// Shared metadata — title, year, artwork, network — is identical on both
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
                    ArrInstanceBadgeRow(refs: instances)
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

                    ArrAvailabilityPill(
                        availableTiers: availableTiers,
                        showsTiers: !instances.isEmpty,
                        unavailableStatus: unavailableStatus
                    )

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

                ArrMonitorBadge(isMonitored: entry.copies.contains { $0.monitored == true })
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    /// A series counts as available on a server once that server has any episode
    /// file. "Available 4K" on a show with one 2160p episode is the honest
    /// reading — the 4K library has started it — and the episode counter beside
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
        if let status = series.status, !status.isEmpty {
            items.append(.init(
                title: status.capitalized,
                color: status == "continuing" ? .green : .secondary
            ))
        }
        return items
    }
}

private struct SeriesRowMetadataItem {
    let title: String
    let color: Color
}

#if DEBUG
extension SonarrSeriesListView {
    init(previewViewModel: SonarrViewModel) {
        self.init()
        _viewModel = State(initialValue: previewViewModel)
        _viewModelLifecycleKey = State(initialValue: nil)
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
