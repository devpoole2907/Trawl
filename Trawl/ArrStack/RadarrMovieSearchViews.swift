import SwiftUI

// MARK: - Add to Library Sheet

struct RadarrAddToLibrarySheet: View {
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
        AppSheetShell(
            title: "Add to Radarr",
            confirmTitle: "Add",
            isConfirmDisabled: !canAdd,
            isConfirmLoading: isAdding,
            onConfirm: { Task { await addMovie() } },
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
                    ArrQualityProfilePicker(
                        selection: $selectedQualityProfileId,
                        profiles: viewModel.qualityProfiles,
                        showInfoButton: false
                    )

                    ArrRootFolderPicker(
                        selection: $selectedRootFolderPath,
                        folders: viewModel.rootFolders
                    )

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

    private var canAdd: Bool {
        !isAdding &&
        selectedQualityProfileId != nil &&
        selectedRootFolderPath != nil &&
        movie.tmdbId != nil
    }

    private func refreshConfigurationAndDefaults() async {
        await viewModel.refreshConfiguration()
        if selectedQualityProfileId == nil {
            selectedQualityProfileId = viewModel.qualityProfiles.first?.id
        }
        if selectedRootFolderPath == nil {
            selectedRootFolderPath = viewModel.rootFolders.first?.path
        }
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

                            if serviceManager.hasAnyConnectedBazarrInstance,
                               let status = serviceManager.bazarrSubtitleStatus(forRadarrId: movie.id) {
                                movieStatusBadge(
                                    status == .allPresent ? "Complete" : "None",
                                    tint: status == .allPresent ? .teal : .secondary,
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
                return try await viewModel.interactiveSearchMovie(movieId: movie.id)
            },
            grabAction: { release in
                await viewModel.grabRelease(release)
            },
            currentErrorMessage: {
                viewModel.error
            }
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
