import SwiftUI
import SwiftData

#if DEBUG
private enum RadarrMovieListPreviewPresentation {
    case error(String)
    case connectionIssue(String)
}
#endif

struct RadarrMovieListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager

    @State private var viewModel: RadarrViewModel?
    @State private var viewModelInstanceID: UUID?
    #if DEBUG
    private var previewPresentation: RadarrMovieListPreviewPresentation?

    init() {
        previewPresentation = nil
    }

    init(previewViewModel: RadarrViewModel) {
        _viewModel = State(initialValue: previewViewModel)
        _viewModelInstanceID = State(initialValue: previewViewModel.serviceManager.activeRadarrInstanceID)
        previewPresentation = nil
    }

    fileprivate init(previewPresentation: RadarrMovieListPreviewPresentation) {
        _viewModel = State(initialValue: nil)
        _viewModelInstanceID = State(initialValue: nil)
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
        .background(backgroundGradient)
        .task(id: viewModelLoadKey) {
            #if DEBUG
            guard previewPresentation == nil else { return }
            #endif
            let activeID = serviceManager.activeRadarrInstanceID
            guard serviceManager.radarrConnected else {
                viewModel = nil
                viewModelInstanceID = nil
                return
            }
            if viewModel == nil || viewModelInstanceID != activeID {
                viewModel = RadarrViewModel(serviceManager: serviceManager, jellyfinManager: jellyfinManager)
                viewModelInstanceID = activeID
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
                row: { movie, _ in
                    RadarrMovieRow(
                        movie: movie,
                        hasIssue: vm.queue.contains {
                            $0.movieId == movie.id && $0.isImportIssueQueueItem
                        },
                        bazarrStatus: serviceManager.bazarrSubtitleStatus(forRadarrId: movie.id)
                    )
                },
                detailDestination: { movieId in
                    AnyView(RadarrMovieDetailView(movieId: movieId, viewModel: vm))
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
                items: [RadarrMovie](),
                isLoading: false,
                error: message,
                nounSingular: "Movie",
                nounPlural: "Movies",
                emptyIcon: "film",
                titleKeyPath: \.title,
                selectedIDs: [],
                row: { movie, _ in
                    RadarrMovieRow(movie: movie, hasIssue: false)
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
            ContentUnavailableView {
                Label("Radarr Not Set Up", systemImage: ServiceIdentity.radarr.tabSystemImage)
            } description: {
                Text("Add a Radarr server in Settings to manage your movies.")
            }
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

    private var viewModelLoadKey: String {
        "\(serviceManager.activeRadarrInstanceID?.uuidString ?? "none"):\(serviceManager.radarrConnected)"
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
    let movie: RadarrMovie
    let hasIssue: Bool
    var bazarrStatus: BazarrSubtitleStatus? = nil
    var showTypeLabel: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: movie.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(movie.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

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
                    Image(systemName: movie.hasFile == true ? "checkmark.circle.fill" : "clock")
                        .font(.caption2)
                        .foregroundStyle(movie.hasFile == true ? .green : .orange)
                    Text(movie.displayStatus)
                        .font(.caption2)
                        .foregroundStyle(movie.hasFile == true ? .green : .secondary)

                    if let size = movie.sizeOnDisk, size > 0 {
                        Text("• \(ByteFormatter.format(bytes: size))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let bazarrStatus {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: "captions.bubble.fill")
                            .font(.caption2)
                            .foregroundStyle(bazarrStatus == .allPresent ? .teal : .secondary)
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

                ArrMonitorBadge(isMonitored: movie.monitored == true)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
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
