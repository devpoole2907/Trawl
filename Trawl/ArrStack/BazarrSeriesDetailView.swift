import SwiftUI

struct BazarrSeriesDetailView: View {
    let seriesId: Int
    @State var viewModel: BazarrViewModel
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var series: BazarrSeries?
    @State private var episodes: [BazarrEpisode] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showProfilePicker = false
    @State private var selectedProfileId: Int?
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    private var episodesBySeason: [(Int, [BazarrEpisode])] {
        Dictionary(grouping: episodes, by: \.season)
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value.sorted { $0.episode < $1.episode }) }
    }

    var body: some View {
        Group {
            if isLoading && episodes.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, episodes.isEmpty {
                ContentUnavailableView {
                    Label("Failed to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                contentView
            }
        }
        .navigationTitle(series?.title ?? "Series")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if series != nil {
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
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await load() }
    }

    private var contentView: some View {
        List {
            if let series {
                Section {
                    HStack(spacing: 16) {
                        ArrArtworkView(url: series.poster.flatMap(URL.init(string:)), contentMode: .fill) {
                            Image(systemName: "tv")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(series.title)
                                .font(.title3.weight(.semibold))
                            if let year = series.year {
                                Text(year)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let overview = series.overview, !overview.isEmpty {
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
                    LabeledContent("Episodes", value: "\(series.episodeFileCount) (\(series.episodeMissingCount) missing)")
                    if !series.audioLanguages.isEmpty {
                        LabeledContent("Audio", value: series.audioLanguages.map(\.name).joined(separator: ", "))
                    }
                    if let profileId = series.profileId {
                        let profile = serviceManager.activeBazarrEntry?.languageProfiles.first { $0.profileId == profileId }
                        Button {
                            selectedProfileId = profileId
                            showProfilePicker = true
                        } label: {
                            LabeledContent("Language Profile", value: profile?.name ?? "Profile \(profileId)")
                        }
                    }
                }
            }

            if !episodesBySeason.isEmpty {
                Section("Seasons") {
                    ForEach(episodesBySeason, id: \.0) { season, eps in
                        NavigationLink {
                            BazarrSeasonView(
                                seriesId: seriesId,
                                season: season,
                                episodes: eps,
                                viewModel: viewModel,
                                onRefresh: { await load() }
                            )
                        } label: {
                            seasonRow(season: season, episodes: eps)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .sheet(isPresented: $showProfilePicker) {
            profilePickerSheet
        }
    }

    private func seasonRow(season: Int, episodes: [BazarrEpisode]) -> some View {
        let missing = episodes.filter { !$0.missingSubtitles.isEmpty }.count
        let total = episodes.count
        let isComplete = missing == 0 && total > 0
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(season == 0 ? "Specials" : "Season \(season)")
                    .font(.body.weight(.medium))
                Text("\(total) episode\(total == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if total > 0 {
                HStack(spacing: 4) {
                    if !isComplete {
                        Text("\(missing) missing")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: isComplete ? "checkmark.circle.fill" : (missing == total ? "xmark.circle.fill" : "exclamationmark.triangle.fill"))
                        .font(.caption)
                        .foregroundStyle(isComplete ? .green : (missing == total ? .red : .orange))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        guard let series else { return "" }
        let status = BazarrViewModel.subtitleStatus(for: series)
        switch status {
        case .allPresent: return "All Subtitles Present"
        case .partial: return "\(series.episodeMissingCount) Episode(s) Missing"
        case .none: return "No Subtitles"
        case .unknown: return "Unknown"
        }
    }

    private var profilePickerSheet: some View {
        NavigationStack {
            let profiles = serviceManager.activeBazarrEntry?.languageProfiles ?? []
            List {
                Picker("Profile", selection: $selectedProfileId) {
                    Text("None").tag(nil as Int?)
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.profileId as Int?)
                    }
                }
                .pickerStyle(.inline)
            }
            .navigationTitle("Language Profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        showProfilePicker = false
                        Task { await updateProfile() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showProfilePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
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
            let page = try await client.getSeries(start: 0, length: 1, ids: [seriesId])
            series = page.data.first
            let eps = try await client.getEpisodes(seriesIds: [seriesId])
            episodes = eps
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func performAction(_ action: BazarrSeriesAction) async {
        do {
            try await viewModel.runSeriesAction(action, seriesId: seriesId)
            inAppNotificationCenter.showSuccess(title: "Action Started", message: "\(action.displayName) initiated.")
        } catch {
            inAppNotificationCenter.showError(title: "Action Failed", message: error.localizedDescription)
        }
    }

    private func updateProfile() async {
        guard series != nil else { return }
        do {
            try await viewModel.setSeriesProfile(seriesId: seriesId, profileId: selectedProfileId)
            await load()
            inAppNotificationCenter.showSuccess(title: "Updated", message: "Language profile updated.")
        } catch {
            inAppNotificationCenter.showError(title: "Failed", message: error.localizedDescription)
        }
    }
}

// MARK: - Season View

private struct BazarrSeasonView: View {
    let seriesId: Int
    let season: Int
    let episodes: [BazarrEpisode]
    @State var viewModel: BazarrViewModel
    let onRefresh: () async -> Void

    @State private var isSearching = false
    @State private var interactiveSearchTarget: BazarrEpisode?
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    private var missingCount: Int {
        episodes.filter { !$0.missingSubtitles.isEmpty }.count
    }

    private var isComplete: Bool { missingCount == 0 }

    var body: some View {
        List {
            if !isComplete {
                Section {
                    searchActionRow(
                        title: "Automatic Search",
                        subtitle: "Ask Bazarr to find missing subtitles for this series.",
                        systemImage: "magnifyingglass",
                        isLoading: isSearching
                    ) {
                        Task { await runAutoSearch() }
                    }

                    searchActionRow(
                        title: "Interactive Search",
                        subtitle: "Browse subtitle providers for a specific episode.",
                        systemImage: "person.fill",
                        trailingImage: "arrow.up.forward.square"
                    ) {
                        interactiveSearchTarget = episodes.first(where: { !$0.missingSubtitles.isEmpty })
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.teal.opacity(0.08))
            }

            Section("Episodes") {
                ForEach(episodes) { episode in
                    NavigationLink {
                        BazarrEpisodeDetailView(
                            seriesId: seriesId,
                            episode: episode,
                            viewModel: viewModel,
                            onRefresh: onRefresh
                        )
                    } label: {
                        episodeRow(episode)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle(season == 0 ? "Specials" : "Season \(season)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $interactiveSearchTarget) { episode in
            BazarrInteractiveSearchSheet(
                seriesId: seriesId,
                episode: episode,
                viewModel: viewModel,
                onDownloaded: { await onRefresh() }
            )
        }
    }

    private func episodeRow(_ episode: BazarrEpisode) -> some View {
        let isComplete = episode.missingSubtitles.isEmpty
        return HStack(spacing: 12) {
            Text(episode.episodeLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.body)
                    .lineLimit(1)
                if !episode.subtitles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(episode.subtitles.prefix(4), id: \.self) { sub in
                            Text(sub.name)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.teal.opacity(0.15)))
                                .overlay(Capsule().strokeBorder(Color.teal.opacity(0.3)))
                        }
                        if episode.subtitles.count > 4 {
                            Text("+\(episode.subtitles.count - 4)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !episode.missingSubtitles.isEmpty {
                    Text(episode.missingSubtitles.map(\.name).joined(separator: ", ") + " missing")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Image(systemName: isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(isComplete ? .green : .orange)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func searchActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingImage: String = "arrow.right",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.teal)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isLoading {
                    ProgressView().frame(width: 16, height: 16)
                } else {
                    Image(systemName: trailingImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func runAutoSearch() async {
        isSearching = true
        do {
            try await viewModel.runSeriesAction(.searchMissing, seriesId: seriesId)
            inAppNotificationCenter.showSuccess(title: "Search Started", message: "Bazarr is searching for missing subtitles.")
        } catch {
            inAppNotificationCenter.showError(title: "Search Failed", message: error.localizedDescription)
        }
        isSearching = false
    }
}

// MARK: - Episode Detail View

private struct BazarrEpisodeDetailView: View {
    let seriesId: Int
    let episode: BazarrEpisode
    @State var viewModel: BazarrViewModel
    let onRefresh: () async -> Void

    @State private var isSearching = false
    @State private var showInteractiveSearch = false
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    private var isComplete: Bool { episode.missingSubtitles.isEmpty }

    var body: some View {
        List {
            if !isComplete {
                Section {
                    searchActionRow(
                        title: "Automatic Search",
                        subtitle: "Ask Bazarr to find subtitles automatically.",
                        systemImage: "magnifyingglass",
                        isLoading: isSearching
                    ) {
                        Task { await runAutoSearch() }
                    }

                    searchActionRow(
                        title: "Interactive Search",
                        subtitle: "Browse available subtitles from all providers.",
                        systemImage: "person.fill",
                        trailingImage: "arrow.up.forward.square"
                    ) {
                        showInteractiveSearch = true
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.teal.opacity(0.08))
            }

            if !episode.subtitles.isEmpty {
                Section("Current Subtitles") {
                    ForEach(episode.subtitles, id: \.self) { sub in
                        subtitleRow(sub)
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

            if !episode.missingSubtitles.isEmpty {
                Section("Missing Languages") {
                    ForEach(episode.missingSubtitles, id: \.code2) { lang in
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
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle(episode.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showInteractiveSearch) {
            BazarrInteractiveSearchSheet(
                seriesId: seriesId,
                episode: episode,
                viewModel: viewModel,
                onDownloaded: { await onRefresh() }
            )
        }
    }

    private func subtitleRow(_ sub: BazarrSubtitle) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.name).font(.body)
                if let path = sub.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if sub.hi {
                    Text("HI")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.15)))
                }
                if sub.forced {
                    Text("Forced")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.15)))
                }
            }
        }
    }

    @ViewBuilder
    private func searchActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingImage: String = "arrow.right",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.teal)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isLoading {
                    ProgressView().frame(width: 16, height: 16)
                } else {
                    Image(systemName: trailingImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func runAutoSearch() async {
        isSearching = true
        do {
            for lang in episode.missingSubtitles {
                try await viewModel.downloadEpisodeSubtitles(
                    seriesId: seriesId,
                    episodeId: episode.sonarrEpisodeId,
                    language: lang.code2,
                    forced: lang.forced,
                    hi: lang.hi
                )
            }
            await onRefresh()
            inAppNotificationCenter.showSuccess(title: "Searching", message: "Bazarr is searching for subtitles.")
        } catch {
            inAppNotificationCenter.showError(title: "Search Failed", message: error.localizedDescription)
        }
        isSearching = false
    }

    private func downloadSubtitle(_ lang: BazarrSubtitleLanguage) async {
        do {
            try await viewModel.downloadEpisodeSubtitles(
                seriesId: seriesId,
                episodeId: episode.sonarrEpisodeId,
                language: lang.code2,
                forced: lang.forced,
                hi: lang.hi
            )
            await onRefresh()
            inAppNotificationCenter.showSuccess(title: "Downloading", message: "\(lang.name) subtitles queued.")
        } catch {
            inAppNotificationCenter.showError(title: "Download Failed", message: error.localizedDescription)
        }
    }

    private func deleteSubtitle(_ sub: BazarrSubtitle) async {
        guard let path = sub.path else { return }
        do {
            try await viewModel.deleteEpisodeSubtitles(
                seriesId: seriesId,
                episodeId: episode.sonarrEpisodeId,
                language: sub.code2,
                forced: sub.forced,
                hi: sub.hi,
                path: path
            )
            await onRefresh()
            inAppNotificationCenter.showSuccess(title: "Deleted", message: "\(sub.name) removed.")
        } catch {
            inAppNotificationCenter.showError(title: "Delete Failed", message: error.localizedDescription)
        }
    }
}

// MARK: - Interactive Search Sheet

struct BazarrInteractiveSearchSheet: View {
    let seriesId: Int?
    let radarrId: Int?
    let episode: BazarrEpisode?
    @State var viewModel: BazarrViewModel
    let onDownloaded: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedLanguage: BazarrSubtitleLanguage?
    @State private var results: [BazarrInteractiveSearchResult] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var downloadingId: String?
    @State private var inAppNotificationCenter = InAppNotificationCenter.shared

    private var missingLanguages: [BazarrSubtitleLanguage] {
        episode?.missingSubtitles ?? []
    }

    init(seriesId: Int, episode: BazarrEpisode, viewModel: BazarrViewModel, onDownloaded: @escaping () async -> Void) {
        self.seriesId = seriesId
        self.radarrId = nil
        self.episode = episode
        _viewModel = State(wrappedValue: viewModel)
        self.onDownloaded = onDownloaded
    }

    init(radarrId: Int, missingLanguages: [BazarrSubtitleLanguage], viewModel: BazarrViewModel, onDownloaded: @escaping () async -> Void) {
        self.seriesId = nil
        self.radarrId = radarrId
        self.episode = nil
        _viewModel = State(wrappedValue: viewModel)
        self.onDownloaded = onDownloaded
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectedLanguage == nil && missingLanguages.count > 1 {
                    languagePicker
                } else {
                    resultsView
                }
            }
            .navigationTitle("Interactive Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if selectedLanguage != nil && missingLanguages.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { selectedLanguage = nil; results = []; error = nil }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if missingLanguages.count == 1 {
                selectedLanguage = missingLanguages.first
            }
        }
        .onChange(of: selectedLanguage) { _, lang in
            guard lang != nil else { return }
            Task { await fetchResults() }
        }
    }

    private var languagePicker: some View {
        List {
            Section("Choose a Language to Search") {
                ForEach(missingLanguages, id: \.code2) { lang in
                    Button {
                        selectedLanguage = lang
                    } label: {
                        HStack {
                            Text(lang.name)
                            if lang.hi { Spacer(); Text("HI").font(.caption2).foregroundStyle(.blue) }
                            if lang.forced { Spacer(); Text("Forced").font(.caption2).foregroundStyle(.orange) }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if isLoading {
            ProgressView("Searching providers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label("Search Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await fetchResults() } }
            }
        } else if results.isEmpty {
            ContentUnavailableView(
                "No Results",
                systemImage: "magnifyingglass",
                description: Text("No subtitles found for \(selectedLanguage?.name ?? "this language").")
            )
        } else {
            List {
                if let lang = selectedLanguage {
                    Section(header: Text("Results for \(lang.name)")) {
                        ForEach(results) { result in
                            resultRow(result, language: lang)
                        }
                    }
                }
            }
        }
    }

    private func resultRow(_ result: BazarrInteractiveSearchResult, language: BazarrSubtitleLanguage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.provider)
                    .font(.subheadline.weight(.semibold))
                if let info = result.releaseInfo, !info.isEmpty {
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if !result.matches.isEmpty {
                        Text(result.matches.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.teal)
                    }
                    if result.hearingImpaired {
                        Text("HI").font(.caption2).foregroundStyle(.blue)
                    }
                    if result.forcedSubtitle {
                        Text("Forced").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if let score = result.score {
                Text("\(Int(score))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(score >= 80 ? .green : score >= 50 ? .orange : .secondary)
                    .frame(width: 32)
            }

            if downloadingId == result.id {
                ProgressView().frame(width: 28)
            } else {
                Button {
                    Task { await download(result, language: language) }
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                }
                .buttonStyle(.plain)
                .disabled(downloadingId != nil)
            }
        }
        .padding(.vertical, 2)
    }

    private func fetchResults() async {
        guard let lang = selectedLanguage else { return }
        isLoading = true
        error = nil
        results = []
        do {
            if let episode {
                results = try await viewModel.interactiveSearchEpisode(
                    episodeId: episode.sonarrEpisodeId,
                    language: lang.code2,
                    hi: lang.hi,
                    forced: lang.forced
                )
            } else if let rid = radarrId {
                results = try await viewModel.interactiveSearchMovie(
                    radarrId: rid,
                    language: lang.code2,
                    hi: lang.hi,
                    forced: lang.forced
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func download(_ result: BazarrInteractiveSearchResult, language: BazarrSubtitleLanguage) async {
        guard let subtitle = result.subtitle else {
            inAppNotificationCenter.showError(title: "Download Failed", message: "No subtitle identifier in result.")
            return
        }
        downloadingId = result.id
        do {
            if let episode, let sid = seriesId {
                try await viewModel.downloadInteractiveEpisodeSubtitle(
                    episodeId: episode.sonarrEpisodeId,
                    seriesId: sid,
                    provider: result.provider,
                    subtitle: subtitle,
                    language: language.code2,
                    hi: language.hi,
                    forced: language.forced
                )
            } else if let rid = radarrId {
                try await viewModel.downloadInteractiveMovieSubtitle(
                    radarrId: rid,
                    provider: result.provider,
                    subtitle: subtitle,
                    language: language.code2,
                    hi: language.hi,
                    forced: language.forced
                )
            }
            await onDownloaded()
            inAppNotificationCenter.showSuccess(title: "Downloaded", message: "Subtitle from \(result.provider) queued.")
            dismiss()
        } catch {
            inAppNotificationCenter.showError(title: "Download Failed", message: error.localizedDescription)
        }
        downloadingId = nil
    }
}
