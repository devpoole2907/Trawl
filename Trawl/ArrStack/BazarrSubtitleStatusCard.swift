import SwiftUI

struct BazarrSubtitleStatusCard: View {
    enum Media {
        case movie(radarrId: Int, title: String)
        case series(seriesId: Int, title: String)
    }

    let media: Media
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var movie: BazarrMovie?
    @State private var series: BazarrSeries?
    @State private var episodes: [BazarrEpisode] = []
    @State private var isSearching = false
    @State private var isUpdatingProfile = false
    @State private var showInteractiveSearch = false
    @State private var showProfilePicker = false
    @State private var selectedProfileId: Int?
    @State private var isExpanded = false

    private var accent: Color { .teal }

    var body: some View {
        if serviceManager.hasBazarrInstance {
            cardContent
                .task(id: taskID) {
                    isExpanded = false
                    movie = nil
                    series = nil
                    episodes = []
                    await load()
                }
                .sheet(isPresented: $showInteractiveSearch) {
                    if let movie {
                        BazarrInteractiveSearchSheet(
                            radarrId: movie.radarrId,
                            missingLanguages: movie.missingSubtitles,
                            viewModel: BazarrViewModel(serviceManager: serviceManager),
                            onDownloaded: {
                                await serviceManager.refreshActiveBazarrSubtitleCache()
                                await load(force: true)
                            }
                        )
                    }
                }
                .sheet(isPresented: $showProfilePicker) {
                    profilePickerSheet
                }
        }
    }

    private var taskID: String {
        let connectionKey = "\(serviceManager.hasAnyConnectedBazarrInstance)-\(serviceManager.activeBazarrProfileID?.uuidString ?? "none")"
        switch media {
        case .movie(let id, _): return "movie-\(id)-\(connectionKey)"
        case .series(let id, _): return "series-\(id)-\(connectionKey)"
        }
    }

    private var title: String {
        switch media {
        case .movie: "Subtitles"
        case .series: "Subtitles"
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                if !serviceManager.hasAnyConnectedBazarrInstance {
                    disconnectedContent
                } else if isLoading && movie == nil && series == nil {
                    loadingContent
                } else if let errorMessage {
                    errorContent(errorMessage)
                } else {
                    loadedContent
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(accent)
                    .frame(width: 24, alignment: .leading)
                Text(title)
                    .font(.headline)
                Spacer()
                statusBadge
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else if missingCount > 0 {
            Text("\(missingCount) missing")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.16), in: Capsule())
                .foregroundStyle(.red)
        } else if hasLoadedMedia {
            Text("Complete")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent.opacity(0.16), in: Capsule())
                .foregroundStyle(accent)
        }
    }

    private var disconnectedContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Bazarr is configured but not connected.")
                    .font(.subheadline.weight(.semibold))
                if let error = serviceManager.bazarrConnectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Retry") {
                Task { await serviceManager.retry(.bazarr) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
        }
    }

    private var loadingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Checking Bazarr...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await load(force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if hasLoadedMedia {
            VStack(alignment: .leading, spacing: 12) {
                profileButton

                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !presentSubtitleKeys.isEmpty {
                    languageChipsView(
                        keys: presentSubtitleKeys,
                        label: "Present",
                        foreground: .teal
                    )
                }

                if !missingLanguageKeys.isEmpty {
                    languageChipsView(
                        keys: missingLanguageKeys,
                        label: "Missing",
                        foreground: .red
                    )
                }

                if missingCount > 0 {
                    HStack(spacing: 12) {
                        Button {
                            Task { await searchMissing() }
                        } label: {
                            searchButtonLabel(
                                title: "Automatic",
                                subtitle: "Search for missing",
                                systemImage: "magnifyingglass",
                                isLoading: isSearching
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .disabled(isSearching)

                        if case .movie = media {
                            Button {
                                showInteractiveSearch = true
                            } label: {
                                searchButtonLabel(
                                    title: "Interactive",
                                    subtitle: "Pick a release",
                                    systemImage: "person.fill",
                                    trailingSystemImage: "arrow.up.forward.square"
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        } else {
            Text("Bazarr has not imported this item yet. Make sure Bazarr is connected to the matching Sonarr/Radarr library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var profileButton: some View {
        if hasLoadedMedia {
            Button {
                selectedProfileId = currentProfileId
                showProfilePicker = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Language Profile")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(currentProfileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if isUpdatingProfile {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(activeLanguageProfiles.isEmpty || isUpdatingProfile)
        }
    }

    private func searchButtonLabel(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right"
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(12)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private func languageChipsView(
        keys: [SubtitleKey],
        label: String,
        foreground: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(foreground)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        HStack(spacing: 3) {
                            Text(key.code2)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(foreground)
                            if key.hi {
                                Text("HI")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.blue)
                            }
                            if key.forced {
                                Text("Forced")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(foreground.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(foreground.opacity(0.25)))
                    }
                }
            }
        }
    }

    private var hasLoadedMedia: Bool {
        movie != nil || series != nil
    }

    private var activeLanguageProfiles: [BazarrLanguageProfile] {
        serviceManager.activeBazarrEntry?.languageProfiles ?? []
    }

    private var currentProfileId: Int? {
        if let movie {
            return movie.profileId
        }
        return series?.profileId
    }

    private var currentProfileName: String {
        guard let currentProfileId else { return activeLanguageProfiles.isEmpty ? "No Bazarr profiles available" : "None" }
        return activeLanguageProfiles.first(where: { $0.profileId == currentProfileId })?.name ?? "Profile \(currentProfileId)"
    }

    private var missingCount: Int {
        if let movie {
            return movie.missingSubtitles.count
        }
        if let series {
            return series.episodeMissingCount
        }
        return 0
    }

    private var summaryText: String {
        if let movie {
            if movie.missingSubtitles.isEmpty {
                return movie.subtitles.isEmpty ? "Bazarr is tracking this movie. No missing subtitles are reported." : "\(movie.subtitles.count) subtitle file\(movie.subtitles.count == 1 ? "" : "s") available."
            }
            return "\(movie.missingSubtitles.count) language\(movie.missingSubtitles.count == 1 ? "" : "s") missing for this movie."
        }
        if let series {
            if series.episodeMissingCount == 0 {
                return "Bazarr reports all tracked episode subtitles are present."
            }
            return "\(series.episodeMissingCount) missing subtitle\(series.episodeMissingCount == 1 ? "" : "s") across \(series.episodeFileCount) episode file\(series.episodeFileCount == 1 ? "" : "s")."
        }
        return ""
    }

    private typealias SubtitleKey = (code2: String, hi: Bool, forced: Bool)

    private var presentSubtitleKeys: [SubtitleKey] {
        if let movie {
            return uniqueSubtitleKeys(movie.subtitles.map { ($0.code2, $0.hi, $0.forced) })
        }
        return uniqueSubtitleKeys(episodes.flatMap { episode in
            episode.subtitles.map { ($0.code2, $0.hi, $0.forced) }
        })
    }

    private var missingLanguageKeys: [SubtitleKey] {
        if let movie {
            return uniqueSubtitleKeys(movie.missingSubtitles.map { ($0.code2, $0.hi, $0.forced) })
        }
        return uniqueSubtitleKeys(episodes.flatMap { episode in
            episode.missingSubtitles.map { ($0.code2, $0.hi, $0.forced) }
        })
    }

    private func uniqueSubtitleKeys(_ keys: [SubtitleKey]) -> [SubtitleKey] {
        var seen = Set<String>()
        var result: [SubtitleKey] = []
        for key in keys {
            let id = "\(key.code2):\(key.hi):\(key.forced)"
            if seen.insert(id).inserted {
                result.append(key)
            }
        }
        return result
    }

    private var profilePickerSheet: some View {
        NavigationStack {
            List {
                Picker("Profile", selection: $selectedProfileId) {
                    Text("None").tag(nil as Int?)
                    ForEach(activeLanguageProfiles) { profile in
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
                    .disabled(isUpdatingProfile)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showProfilePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func load(force: Bool = false) async {
        if isLoading { return }
        guard serviceManager.hasAnyConnectedBazarrInstance else { return }
        guard force || !hasLoadedMedia else { return }
        guard let client = serviceManager.activeBazarrEntry?.client else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            switch media {
            case .movie(let radarrId, _):
                let page = try await client.getMovies(ids: [radarrId])
                movie = page.data.first
            case .series(let seriesId, _):
                let page = try await client.getSeries(ids: [seriesId])
                series = page.data.first
                if let s = series {
                    episodes = (try? await client.getEpisodes(seriesIds: [s.sonarrSeriesId])) ?? []
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func searchMissing() async {
        guard let client = serviceManager.activeBazarrEntry?.client else { return }
        isSearching = true
        defer { isSearching = false }

        do {
            switch media {
            case .movie(let radarrId, let title):
                try await client.runMovieAction(radarrId: radarrId, action: .searchMissing)
                InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(title) was sent to Bazarr.")
            case .series(let seriesId, let title):
                try await client.runSeriesAction(seriesId: seriesId, action: .searchMissing)
                InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(title) was sent to Bazarr.")
            }
            movie = nil
            series = nil
            episodes = []
            await serviceManager.refreshActiveBazarrSubtitleCache()
            await load(force: true)
        } catch {
            InAppNotificationCenter.shared.showError(title: "Subtitle Search Failed", message: error.localizedDescription)
        }
    }

    private func updateProfile() async {
        guard let client = serviceManager.activeBazarrEntry?.client else { return }
        isUpdatingProfile = true
        defer { isUpdatingProfile = false }

        var apiError: Error?
        do {
            switch media {
            case .movie(let radarrId, _):
                try await client.updateMovieProfile(
                    radarrIds: [radarrId],
                    profileIds: [selectedProfileId.map(String.init)]
                )
            case .series(let seriesId, _):
                try await client.updateSeriesProfile(
                    seriesIds: [seriesId],
                    profileIds: [selectedProfileId.map(String.init)]
                )
            }
        } catch {
            apiError = error
        }

        movie = nil
        series = nil
        episodes = []
        await serviceManager.refreshActiveBazarrSubtitleCache()
        await load(force: true)
        if let apiError {
            let isMovie500: Bool = {
                if case .movie = media, case ArrError.serverError(500, _) = apiError { return true }
                return false
            }()
            if isMovie500 {
                InAppNotificationCenter.shared.showSuccess(title: "Updated", message: "Language profile updated.")
            } else {
                InAppNotificationCenter.shared.showError(title: "Failed", message: apiError.localizedDescription)
            }
        } else {
            InAppNotificationCenter.shared.showSuccess(title: "Updated", message: "Language profile updated.")
        }
    }
}

// MARK: - Shared subtitle list row

struct BazarrSubtitleListRow: View {
    let subtitle: BazarrSubtitle

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle.name).font(.body)
                if let path = subtitle.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if subtitle.hi {
                    Text("HI")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.15)))
                }
                if subtitle.forced {
                    Text("Forced")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.15)))
                }
            }
        }
    }
}

// MARK: - Shared subtitle file chips (used in Radarr/Sonarr file rows)

struct BazarrSubtitleFilesView: View {
    let subtitles: [BazarrSubtitle]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(.teal)
                ForEach(Array(subtitles.enumerated()), id: \.offset) { _, sub in
                    HStack(spacing: 3) {
                        Text(sub.code2)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.teal)
                        if sub.hi {
                            Text("HI")
                                .font(.system(size: 7).weight(.bold))
                                .foregroundStyle(.blue)
                        }
                        if sub.forced {
                            Text("Forced")
                                .font(.system(size: 7).weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        if let size = sub.fileSize {
                            Text(ByteFormatter.format(bytes: Int64(size)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.teal.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.teal.opacity(0.25)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
