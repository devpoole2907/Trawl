import SwiftUI

struct BazarrMovieDetailView: View {
    let radarrId: Int
    @State private var viewModel: BazarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var movie: BazarrMovie?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showProfilePicker = false
    @State private var selectedProfileId: Int?
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    init(radarrId: Int, viewModel: BazarrViewModel) {
        self.radarrId = radarrId
        _viewModel = State(wrappedValue: viewModel)
    }

    var body: some View {
        ArrItemDetailView(
            item: movie,
            title: movie?.title ?? "Movie",
            backgroundURL: movie?.poster.flatMap(URL.init(string:))
        ) { _ in
            ArrLoadingErrorEmptyView(
                isLoading: isLoading,
                error: error,
                isEmpty: movie == nil,
                emptyTitle: "Movie Not Found",
                emptyIcon: "film",
                emptyDescription: "This movie is not tracked in Bazarr.",
                onRetry: { await load() }
            ) {
                contentView
            }
        }
        .toolbar {
            if movie != nil {
                ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                    Menu {
                        ForEach(BazarrSeriesAction.allCases, id: \.self) { action in
                            Button {
                                Task { await performAction(action) }
                            } label: {
                                Label(action.displayName, systemImage: action.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Subtitle Actions")
                }
            }
        }
        .task { await load() }
    }

    private var contentView: some View {
        List {
            if let movie {
                Section {
                    HStack(spacing: 16) {
                        ArrArtworkView(url: movie.poster.flatMap(URL.init(string:)), contentMode: .fill) {
                            Image(systemName: "film")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(movie.title)
                                .font(.title3.weight(.semibold))
                            if let year = movie.year {
                                Text(year)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let overview = movie.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                    }
                }

                Section("Info") {
                    LabeledContent("Status", value: statusText)
                    if !movie.audioLanguages.isEmpty {
                        LabeledContent("Audio", value: movie.audioLanguages.map(\.name).joined(separator: ", "))
                    }
                    let profile = serviceManager.activeBazarrEntry?.languageProfiles.first { $0.profileId == movie.profileId }
                    Button {
                        selectedProfileId = movie.profileId
                        showProfilePicker = true
                    } label: {
                        LabeledContent("Language Profile", value: profile?.name ?? (movie.profileId == nil ? "None" : "Profile \(movie.profileId!)"))
                    }
                }

                if !movie.subtitles.isEmpty {
                    Section("Current Subtitles") {
                        ForEach(Array(movie.subtitles.enumerated()), id: \.offset) { _, sub in
                            BazarrSubtitleListRow(subtitle: sub)
                                .swipeActions(edge: .trailing) {
                                    if sub.path != nil {
                                        Button(role: .destructive) {
                                            Task { await deleteSubtitle(sub) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                }

                if !movie.missingSubtitles.isEmpty {
                    Section("Missing Languages") {
                        ForEach(Array(movie.missingSubtitles.enumerated()), id: \.offset) { _, lang in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lang.name)
                                    if lang.hi || lang.forced {
                                        HStack(spacing: 4) {
                                            if lang.hi { Text("HI").font(.caption2).foregroundStyle(.blue) }
                                            if lang.forced { Text("Forced").font(.caption2).foregroundStyle(.orange) }
                                        }
                                    }
                                }
                                Spacer()
                                Button("Download") {
                                    Task { await downloadSubtitle(lang) }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(.teal)
                            }
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .sheet(isPresented: $showProfilePicker) {
            let profiles = serviceManager.activeBazarrEntry?.languageProfiles ?? []
            AppSheetShell(
                title: "Language Profile",
                confirmTitle: "Save",
                onConfirm: { showProfilePicker = false; Task { await updateProfile() } },
                detents: [.medium]
            ) {
                List {
                    Picker("Profile", selection: $selectedProfileId) {
                        Text("None").tag(nil as Int?)
                        ForEach(profiles) { profile in
                            Text(profile.name).tag(profile.profileId as Int?)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
    }

    private var statusText: String {
        guard let movie else { return "" }
        return movie.missingSubtitles.isEmpty ? "All Subtitles Present" : "\(movie.missingSubtitles.count) Language(s) Missing"
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        error = nil
        let client = serviceManager.activeBazarrEntry?.client
        guard let client else {
            error = "No connected Bazarr instance"
            isLoading = false
            return
        }
        do {
            let page = try await client.getMovies(start: 0, length: 1, ids: [radarrId])
            movie = page.data.first
            if movie == nil {
                self.error = "Movie not found for id \(radarrId)"
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func performAction(_ action: BazarrSeriesAction) async {
        do {
            try await viewModel.runMovieAction(action, radarrId: radarrId)
            inAppNotificationCenter.showSuccess(title: "Action Started", message: "\(action.displayName) initiated for movie.")
        } catch {
            inAppNotificationCenter.showError(title: "Action Failed", message: error.localizedDescription)
        }
    }

    private func updateProfile() async {
        var apiError: Error?
        do {
            try await viewModel.setMovieProfile(radarrId: radarrId, profileId: selectedProfileId)
        } catch {
            apiError = error
        }

        await load()
        if let apiError {
            if case ArrError.serverError(500, _) = apiError {
                inAppNotificationCenter.showSuccess(title: "Updated", message: "Language profile updated (server hiccup — it's set).")
            } else {
                inAppNotificationCenter.showError(title: "Failed", message: apiError.localizedDescription)
            }
        } else {
            inAppNotificationCenter.showSuccess(title: "Updated", message: "Language profile updated.")
        }
    }

    private func downloadSubtitle(_ lang: BazarrSubtitleLanguage) async {
        do {
            try await viewModel.downloadMovieSubtitles(radarrId: radarrId, language: lang.code2, forced: lang.forced, hi: lang.hi)
            await load()
            inAppNotificationCenter.showSuccess(title: "Downloading", message: "\(lang.name) subtitles downloading...")
        } catch {
            inAppNotificationCenter.showError(title: "Download Failed", message: error.localizedDescription)
        }
    }

    private func deleteSubtitle(_ sub: BazarrSubtitle) async {
        guard let path = sub.path else { return }
        do {
            try await viewModel.deleteMovieSubtitles(radarrId: radarrId, language: sub.code2, forced: sub.forced, hi: sub.hi, path: path)
            await load()
            inAppNotificationCenter.showSuccess(title: "Deleted", message: "\(sub.name) subtitles removed.")
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}
