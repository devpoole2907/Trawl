import SwiftUI
import SwiftData

#if DEBUG
private enum RadarrMovieListPreviewPresentation {
    case error(String)
    case connectionIssue(String)
}
#endif

struct RadarrMovieListView: View {
    /// Forwarded to `ArrMediaListView`. Present only when this list is the content
    /// column of the iPad split view; `nil` on iPhone, where rows stay links.
    var detailSelection: Binding<ArrMergeKey?>?

    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager

    @State private var viewModel: RadarrViewModel?
    @State private var viewModelLifecycleKey: String?
    @State private var showSetupSheet = false
    #if DEBUG
    private var previewPresentation: RadarrMovieListPreviewPresentation?

    init(detailSelection: Binding<ArrMergeKey?>? = nil) {
        self.detailSelection = detailSelection
        previewPresentation = nil
    }

    init(previewViewModel: RadarrViewModel) {
        _viewModel = State(initialValue: previewViewModel)
        _viewModelLifecycleKey = State(initialValue: nil)
        previewPresentation = nil
    }

    fileprivate init(previewPresentation: RadarrMovieListPreviewPresentation) {
        _viewModel = State(initialValue: nil)
        _viewModelLifecycleKey = State(initialValue: nil)
        self.previewPresentation = previewPresentation
    }
    #endif

    var body: some View {
        Group {
            #if DEBUG
            if let previewPresentation {
                previewContent(previewPresentation)
            } else {
                mainContent
            }
            #else
            mainContent
            #endif
        }
        .sheet(isPresented: $showSetupSheet) {
            ArrSetupSheet(initialServiceType: .radarr, onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
        .background(backgroundGradient)
        .task(id: viewModelLoadKey) {
            #if DEBUG
            guard previewPresentation == nil else { return }
            #endif
            let lifecycleKey = viewModelLoadKey
            guard serviceManager.radarrConnected else {
                viewModel = nil
                viewModelLifecycleKey = nil
                return
            }
            if viewModel == nil || viewModelLifecycleKey != lifecycleKey {
                viewModel = RadarrViewModel(serviceManager: serviceManager, jellyfinManager: jellyfinManager)
                viewModelLifecycleKey = lifecycleKey
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let vm = viewModel {
            ArrMediaListView(
                viewModel: vm,
                serviceType: .radarr,
                nounSingular: "Movie",
                nounPlural: "Movies",
                emptyIcon: "film",
                row: { entry, _ in
                    RadarrMovieRow(
                        entry: entry,
                        // An import issue on either server is an issue with this
                        // title, and the queue rows carry the instance that owns
                        // them, so the match is on (server, movie) not movie alone.
                        hasIssue: vm.queueRecords.contains { record in
                            record.value.isImportIssueQueueItem
                                && entry.copies.contains {
                                    $0.instanceID == record.instance.id && $0.id == record.value.movieId
                                }
                        },
                        subtitleCoverage: serviceManager.subtitleCoverage(for: entry.primary),
                        instances: serviceManager.badgeRefs(for: entry)
                    )
                },
                // Forwarded, which it was not. `RadarrMovieListView` declared the
                // binding and took it in its initialiser but never handed it on, so
                // on iPad the movies list drove nothing and the detail column sat on
                // "Select a movie" no matter what was tapped. Series worked because
                // `SonarrSeriesListView` passes the same argument.
                detailSelection: detailSelection,
                detailDestination: { key in
                    RadarrMovieDetailView(mergeKey: key, viewModel: vm)
                }
            )
        } else {
            radarrUnavailableContent
                .navigationTitle("Movies")
        }
    }

    #if DEBUG
    @ViewBuilder
    private func previewContent(_ presentation: RadarrMovieListPreviewPresentation) -> some View {
        switch presentation {
        case .error(let message):
            ArrLibraryListView(
                items: [ArrLibraryEntry<RadarrMovie>](),
                isLoading: false,
                error: message,
                nounSingular: "Movie",
                nounPlural: "Movies",
                emptyIcon: "film",
                titleKeyPath: \.primary.title,
                selection: .constant([]),
                row: { entry, _ in
                    RadarrMovieRow(entry: entry, hasIssue: false)
                },
                retry: nil
            )
            .navigationTitle("Movies")
        case .connectionIssue(let message):
            ArrServiceConnectionStatusView(
                serviceType: .radarr,
                title: "Radarr Unreachable",
                message: message
            )
            .navigationTitle("Movies")
        }
    }
    #endif

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [ServiceIdentity.radarr.brandColor.opacity(0.18), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
            RadialGradient(
                colors: [ServiceIdentity.radarr.brandColor.opacity(0.14), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var radarrUnavailableContent: some View {
        if !serviceManager.hasRadarrInstance {
            ServiceSetupView(title: "Radarr Not Set Up", message: "Add a Radarr server in Settings to manage your movies.", systemImage: ServiceIdentity.radarr.tabSystemImage, actionTitle: "Add Server", onSetup: { showSetupSheet = true })
            .scrollableUnavailableState()
        } else if serviceManager.radarrIsConnecting || serviceManager.isInitializing {
            ArrServiceConnectionStatusView(
                serviceType: .radarr,
                title: "Connecting to Radarr",
                message: "Checking your configured Radarr server."
            )
        } else {
            ArrServiceConnectionStatusView(
                serviceType: .radarr,
                title: "Radarr Unreachable",
                message: serviceManager.radarrConnectionError ?? "Unable to reach your Radarr server."
            )
        }
    }

    /// Rebuilds the view model when the *set* of connected servers changes, not
    /// just when one nominated server does. Adding, losing or reconnecting either
    /// half of a pair changes what the blended library contains.
    private var viewModelLoadKey: String {
        serviceManager.connectedRadarr
            .map { "\($0.ref.id.uuidString):\($0.ref.ordinal)" }
            .joined(separator: "|")
    }
}

#if DEBUG
#Preview("Loaded") {
    let vm = RadarrViewModel(previewState: .loaded)
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieListView(previewViewModel: vm)
        }
    }
}

#Preview("Loaded Heavy") {
    let vm = RadarrViewModel(previewState: .heavy)
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieListView(previewViewModel: vm)
        }
    }
}

#Preview("Empty") {
    let vm = RadarrViewModel(previewState: .empty)
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieListView(previewViewModel: vm)
        }
    }
}

#Preview("Loading") {
    let vm = RadarrViewModel(previewState: .loading)
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieListView(previewViewModel: vm)
        }
    }
}

#Preview("Error") {
    RadarrPreviewHost {
        NavigationStack {
            RadarrMovieListView(previewPresentation: .error("Radarr returned a 500 while loading the movie library."))
        }
    }
}

#Preview("Connection Issue") {
    RadarrPreviewHost {
        NavigationStack {
            RadarrMovieListView(previewPresentation: .connectionIssue("Connection refused at http://192.168.1.50:7878. Check the host URL and API key."))
        }
    }
}
#endif

// MARK: - Movie Row

struct RadarrMovieRow: View {
    let entry: ArrLibraryEntry<RadarrMovie>
    let hasIssue: Bool
    var subtitleCoverage: SubtitleCoverage = .unknown
    var showTypeLabel: Bool = false
    /// The servers holding this title. Empty when only one Radarr is configured,
    /// which suppresses the badges entirely.
    var instances: [ArrInstanceRef] = []

    /// Shared metadata - title, year, artwork, runtime - is identical on both
    /// servers, so the row reads it from the first copy.
    private var movie: RadarrMovie { entry.primary }

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: movie.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(movie.title)
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
                        }
                        Text(item)
                    }
                    .font(.caption2)
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    // Only when the badges cannot say it. With a pair configured
                    // they carry availability themselves, so the pill would just be
                    // the same fact in words - it earns its place only when nothing
                    // is downloaded anywhere and there is a status to report, or on
                    // a single-server setup where there are no badges at all.
                    if instances.isEmpty || availableTiers.isEmpty {
                        ArrAvailabilityPill(
                            availableTiers: availableTiers,
                            showsTiers: !instances.isEmpty,
                            unavailableStatus: movie.displayStatus
                        )
                    }

                    if totalSizeOnDisk > 0 {
                        Text(ByteFormatter.format(bytes: totalSizeOnDisk))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

    /// The tiers that actually hold the film - the whole point of a pair.
    private var availableTiers: [ArrQualityTier] {
        entry.availableTiers(from: instances) { $0.hasFile == true }
    }

    /// Size summed across servers: a film held in both HD and 4K really is using
    /// both, and reporting one copy's size would understate it.
    private var totalSizeOnDisk: Int64 {
        entry.copies.reduce(Int64(0)) { $0 + ($1.sizeOnDisk ?? 0) }
    }

    private var metadataItems: [String] {
        var items: [String] = []
        if let year = movie.year {
            items.append(String(year))
        }
        if showTypeLabel {
            items.append("Movie")
        }
        if let runtime = movie.runtime, runtime > 0 {
            items.append("\(runtime)m")
        }
        return items
    }
}
