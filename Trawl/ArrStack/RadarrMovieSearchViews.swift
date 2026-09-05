import SwiftUI

// MARK: - Add to Library Sheet

struct RadarrAddToLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: RadarrViewModel
    let movie: RadarrMovie
    let onAdded: () async -> Void

    /// Quality profile and root folder per server, because both are per-server
    /// facts: an id issued by one Radarr means nothing on the other. Keeping a
    /// dictionary rather than one pair is what lets "Both Servers" show - and let
    /// you set - a real choice for each destination instead of applying one
    /// server's answer to a server that never offered it. It also means switching
    /// destination and switching back does not discard what you already picked.
    @State private var addState = ArrAddDestinationState(serviceType: .radarr)
    @State private var minimumAvailability = "released"
    @State private var monitorOption = "movieOnly"
    @State private var searchForMovie = true
    @State private var isAdding = false
    /// Optional because "not chosen yet" and "add to both" are different things.
    /// Using `.everyCandidate` as the unresolved value made adding to *both*
    /// servers the state the sheet sat in before its task ran - so a slow or failed
    /// configuration refresh left the most destructive option preselected.
    private var resolvedDestination: ArrAddDestination {
        addState.resolvedDestination(in: candidates)
    }
    @Environment(ArrServiceManager.self) private var serviceManager

    /// The servers that could still take this movie - every configured Radarr the
    /// library does not already show it on. With one server this is that server;
    /// opened from a detail screen where one of a pair already holds the film, it
    /// is the other one, and the sheet adds there without asking.
    private var candidates: [ArrInstanceRef] {
        serviceManager.connectedRadarr.map(\.ref).filter { ref in
            !serviceManager.movieLibrary.items(for: ref.id).contains { $0.tmdbId == movie.tmdbId }
        }
    }

    /// The servers this add will actually touch - one, or both.
    private var targets: [ArrInstanceRef] {
        addState.targets(in: candidates)
    }

    var body: some View {
        AppSheetShell(
            title: "Add to Radarr",
            confirmTitle: "Add",
            isConfirmDisabled: !canAdd,
            isConfirmLoading: isAdding,
            onConfirm: { Task { await addMovie() } },
            confirmPlacement: .prominentBottom,
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
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
                    ArrAddDestinationPicker(
                        candidates: candidates,
                        selection: Binding(
                            get: { resolvedDestination },
                            set: { addState.destination = $0 }
                        ),
                        // "Both" is only meaningful while both servers are still
                        // candidates; opened for a film one of them already has,
                        // it would mean the same as the single remaining server.
                        allowsEveryCandidate: candidates.count > 1
                    )
                    .onChange(of: resolvedDestination) { _, _ in
                        seedDefaultsForEveryCandidate()
                    }

                    // One destination puts its two pickers inline, exactly as
                    // before. Two destinations get a labelled group each, because
                    // an unlabelled second pair would be indistinguishable from
                    // the first.
                    if targets.count == 1, let target = targets.first {
                        serverSettings(for: target)
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

                if targets.count > 1 {
                    ForEach(targets, id: \.id) { target in
                        Section(serviceManager.scopeLabel(for: target)) {
                            serverSettings(for: target)
                        }
                    }
                }

                if let error = addState.failureMessage ?? viewModel.error, !error.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.footnote)
                    }
                }
            }
            #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .task {
                await refreshConfigurationAndDefaults()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func serverSettings(for target: ArrInstanceRef) -> some View {
        ArrQualityProfilePicker(
            selection: Binding(
                get: { addState.profileByInstance[target.id] },
                set: { addState.profileByInstance[target.id] = $0 }
            ),
            profiles: viewModel.qualityProfiles(on: target.id),
            showInfoButton: false
        )

        ArrRootFolderPicker(
            selection: Binding(
                get: { addState.rootFolderByInstance[target.id] },
                set: { addState.rootFolderByInstance[target.id] = $0 }
            ),
            folders: viewModel.rootFolders(on: target.id)
        )
    }

    private var canAdd: Bool {
        guard !isAdding, movie.tmdbId != nil, !targets.isEmpty else { return false }
        // Every destination, not just the visible one: an add to both that is
        // missing the second server's root folder would half-succeed.
        return addState.isConfigured(targets)
    }

    private func refreshConfigurationAndDefaults() async {
        await viewModel.refreshConfiguration()
        seedDefaultsForEveryCandidate()
    }

    /// Seeds every candidate at once, not just the selected one, so switching to
    /// "Both Servers" never reveals an unset picker - and so a value the user has
    /// already chosen for one server survives switching away and back.
    ///
    /// A remembered value is used only while that server still offers it: a
    /// profile deleted in Radarr must not come back as a phantom preselection that
    /// then fails at the API.
    private func seedDefaultsForEveryCandidate() {
        addState.seedDefaults(
            for: candidates,
            profiles: { viewModel.qualityProfiles(on: $0) },
            folders: { viewModel.rootFolders(on: $0) }
        )
    }

    private func addMovie() async {
        guard !isAdding, let tmdbId = movie.tmdbId else { return }

        isAdding = true
        defer { isAdding = false }

        let success = await addState.execute(
            targets: targets,
            itemName: movie.title,
            failureReason: { viewModel.error }
        ) { target, profileID, folderPath in
            await viewModel.addMovie(
                title: movie.title,
                tmdbId: tmdbId,
                qualityProfileId: profileID,
                rootFolderPath: folderPath,
                minimumAvailability: minimumAvailability,
                monitorOption: monitorOption,
                searchForMovie: searchForMovie,
                instanceID: target.id,
                announcesResult: false
            )
        }

        if success {
            await onAdded()
            dismiss()
        }
    }

}

#if DEBUG
extension RadarrAddToLibrarySheet {
    init(
        previewViewModel viewModel: RadarrViewModel,
        movie: RadarrMovie,
        isAdding: Bool = false,
        destination: ArrAddDestination? = nil
    ) {
        self.viewModel = viewModel
        self.movie = movie
        self.onAdded = {}
        // Seeded per server, the way `seedDefaultsForEveryCandidate` does at
        // runtime, so a preview of the pair shows each server's own settings
        // rather than one server's applied to both.
        var profiles: [UUID: Int] = [:]
        var folders: [UUID: String] = [:]
        for ref in viewModel.serviceManager.refs(for: .radarr) {
            profiles[ref.id] = viewModel.qualityProfiles(on: ref.id).first?.id
            let onServer = viewModel.rootFolders(on: ref.id)
            folders[ref.id] = onServer.first { $0.path.localizedCaseInsensitiveContains("movie") }?.path
                ?? onServer.first?.path
        }
        let state = ArrAddDestinationState(serviceType: .radarr)
        state.profileByInstance = profiles
        state.rootFolderByInstance = folders
        state.destination = destination
        _addState = State(initialValue: state)
        _isAdding = State(initialValue: isAdding)
    }
}
#endif

// MARK: - Supporting enums

enum RadarrDiscoverMinimumAvailability: String, CaseIterable, Identifiable {
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

enum RadarrDiscoverMonitorOption: String, CaseIterable, Identifiable {
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
    @State private var interactiveSearchSessionID = UUID()
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

                            let subtitleCoverage = serviceManager.subtitleCoverage(for: movie)
                            if subtitleCoverage.hasIndicator {
                                movieStatusBadge(
                                    subtitleCoverage.badgeLabel,
                                    tint: subtitleCoverage.badgeColor,
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
        .refreshable {
            await viewModel.loadMovies()
            await viewModel.loadQueue()
            await viewModel.loadMovieFiles(movieId: movie.id)
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
                .id(interactiveSearchSessionID)
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
            interactiveSearchSessionID = UUID()
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
                // `instanceID` is not optional context: both Radarr servers hand out
                // the same small integers, so dropping it sends `movieId` to whichever
                // server happens to be active and Radarr answers with a different film's
                // releases entirely.
                return try await viewModel.interactiveSearchMovie(
                    movieId: movie.id,
                    instanceID: movie.instanceID
                )
            },
            grabAction: { release in
                await viewModel.grabRelease(release)
            },
            currentErrorMessage: {
                viewModel.error
            },
            slowSearchDiagnostics: ArrIndexerLatencyProbe.diagnostics(
                using: viewModel.serviceManager,
                query: movie.title
            )
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

#if DEBUG
#Preview("Add To Library Ready") {
    let vm = RadarrViewModel(previewMovies: [])
    RadarrPreviewHost(arr: vm.serviceManager) {
        RadarrAddToLibrarySheet(previewViewModel: vm, movie: .previewAnnounced)
    }
}

/// One Radarr, one 4K Radarr, and a film on neither: the Server row appears and
/// offers both plus "Both Servers".
#Preview("Add To Library - Both Servers") {
    let vm = RadarrViewModel(previewMovies: [], serviceManager: .preview(.radarrPair))
    RadarrPreviewHost(arr: vm.serviceManager) {
        RadarrAddToLibrarySheet(previewViewModel: vm, movie: .previewAnnounced, destination: .everyCandidate)
    }
}

#Preview("Add To Library - Server Choice") {
    let vm = RadarrViewModel(previewMovies: [], serviceManager: .preview(.radarrPair))
    RadarrPreviewHost(arr: vm.serviceManager) {
        RadarrAddToLibrarySheet(previewViewModel: vm, movie: .previewAnnounced)
    }
}

#Preview("Add To Library Error") {
    let vm = RadarrViewModel(
        previewMovies: [],
        error: "Radarr rejected this movie because a matching TMDb ID already exists."
    )
    RadarrPreviewHost(arr: vm.serviceManager) {
        RadarrAddToLibrarySheet(previewViewModel: vm, movie: .previewAnnounced)
    }
}

#Preview("Search Missing Movie") {
    let movie = RadarrMovie.previewAnnounced
    let vm = RadarrViewModel(previewMovies: [movie])
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieSearchView(viewModel: vm, movie: movie)
        }
    }
}

#Preview("Search Downloaded Movie") {
    let movie = RadarrMovie.preview
    let vm = RadarrViewModel(previewMovies: [movie])
    RadarrPreviewHost(arr: vm.serviceManager) {
        NavigationStack {
            RadarrMovieSearchView(viewModel: vm, movie: movie)
        }
    }
}

#Preview("Interactive Search") {
    let movie = RadarrMovie.preview
    let vm = RadarrViewModel(previewMovies: [movie])
    RadarrPreviewHost(arr: vm.serviceManager) {
        RadarrInteractiveSearchSheet(viewModel: vm, movie: movie)
    }
}
#endif
