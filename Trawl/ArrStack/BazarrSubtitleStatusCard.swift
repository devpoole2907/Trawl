import SwiftUI

struct BazarrSubtitleStatusCard: View {
    enum Media {
        /// `embeddedSubtitles` is the Radarr `mediaInfo.subtitles` string (embedded tracks only).
        case movie(radarrId: Int, title: String, embeddedSubtitles: String?, hasFile: Bool)
        /// `embeddedLanguages` is the union of embedded subtitle languages across Sonarr episode files.
        case series(seriesId: Int, title: String, embeddedLanguages: [String], episodeFileCount: Int)
        /// Season-level coverage summary across the season's downloaded episodes ("3/12 episodes").
        case season(seriesId: Int, title: String, seasonNumber: Int)
        /// Single-episode subtitle status.
        case episode(seriesId: Int, sonarrEpisodeId: Int, title: String)
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

    // MARK: - Media accessors

    private var mediaRadarrId: Int? {
        if case .movie(let id, _, _, _) = media { return id }
        return nil
    }

    private var embeddedMovieSubtitles: String? {
        if case .movie(_, _, let subs, _) = media { return subs }
        return nil
    }

    private var movieHasFile: Bool {
        if case .movie(_, _, _, let hasFile) = media { return hasFile }
        return false
    }

    private var seriesEmbeddedLanguages: [String] {
        if case .series(_, _, let langs, _) = media { return langs }
        return []
    }

    private var seriesEpisodeFileCount: Int {
        if case .series(_, _, _, let count) = media { return count }
        return 0
    }

    private var taskID: String {
        let connectionKey = "\(serviceManager.hasAnyConnectedBazarrInstance)-\(serviceManager.activeBazarrProfileID?.uuidString ?? "none")"
        switch media {
        case .movie(let id, _, _, _): return "movie-\(id)-\(connectionKey)"
        case .series(let id, _, _, _): return "series-\(id)-\(connectionKey)"
        case .season(let id, _, let n): return "season-\(id)-\(n)-\(connectionKey)"
        case .episode(_, let eid, _): return "episode-\(eid)-\(connectionKey)"
        }
    }

    private var title: String { "Subtitles" }

    // MARK: - Coverage

    /// Unified coverage merging Bazarr (when it has a profile) with embedded Arr media info.
    private var coverage: SubtitleCoverage {
        switch media {
        case .movie:
            return SubtitleCoverage.coverage(
                bazarrMovie: movie,
                embeddedSubtitles: embeddedMovieSubtitles,
                hasFile: movieHasFile
            )
        case .series:
            return SubtitleCoverage.coverage(
                bazarrSeries: series,
                embeddedSubtitleFileCount: seriesEpisodeFileCount == 0 ? nil : (seriesEmbeddedLanguages.isEmpty ? 0 : seriesEpisodeFileCount),
                episodeFileCount: seriesEpisodeFileCount
            )
        case .season:
            let total = downloadedScopedEpisodes.count
            guard total > 0 else { return .unknown }
            if isTrackedByBazarr {
                return .tracked(missing: seasonMissingCount)
            }
            return scopedEpisodesWithSubs > 0 ? .presentUntracked : .noneFound
        case .episode:
            guard let episode = scopedEpisodes.first, episodeHasFile(episode) else { return .unknown }
            if isTrackedByBazarr {
                return .tracked(missing: episode.missingSubtitles.count)
            }
            return episode.subtitles.isEmpty ? .noneFound : .presentUntracked
        }
    }

    // MARK: - Season / episode scoping

    /// Whether this card shows its own automatic/interactive search actions. Season
    /// and episode detail views already provide Bazarr search buttons of their own,
    /// so the card stays purely informational there.
    private var showsSearchActions: Bool {
        switch media {
        case .movie, .series: return true
        case .season, .episode: return false
        }
    }

    /// Episodes relevant to this card: all for series, the season's for `.season`,
    /// and the single matching episode for `.episode`.
    private var scopedEpisodes: [BazarrEpisode] {
        switch media {
        case .season(_, _, let seasonNumber):
            return episodes.filter { $0.season == seasonNumber }
        case .episode(_, let episodeId, _):
            return episodes.filter { $0.sonarrEpisodeId == episodeId }
        default:
            return episodes
        }
    }

    private func episodeHasFile(_ episode: BazarrEpisode) -> Bool {
        guard let path = episode.path else { return false }
        return !path.isEmpty
    }

    private var downloadedScopedEpisodes: [BazarrEpisode] {
        scopedEpisodes.filter(episodeHasFile)
    }

    private var scopedEpisodesWithSubs: Int {
        downloadedScopedEpisodes.filter { !$0.subtitles.isEmpty }.count
    }

    private var seasonMissingCount: Int {
        guard isTrackedByBazarr else { return 0 }
        return downloadedScopedEpisodes.reduce(0) { $0 + $1.missingSubtitles.count }
    }

    /// "3/12"-style badge for the season card; nil for every other media kind.
    private var customBadge: (label: String, color: Color)? {
        guard case .season = media else { return nil }
        let total = downloadedScopedEpisodes.count
        guard total > 0 else { return nil }
        let withSubs = scopedEpisodesWithSubs
        let color: Color = withSubs == total ? .teal : (withSubs == 0 ? .secondary : .orange)
        return ("\(withSubs)/\(total)", color)
    }

    /// Whether Bazarr is actively managing this item (connected + profile assigned).
    private var isTrackedByBazarr: Bool {
        serviceManager.hasAnyConnectedBazarrInstance && hasAssignedProfile
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                if serviceManager.hasBazarrInstance && !serviceManager.hasAnyConnectedBazarrInstance {
                    disconnectedContent
                } else if isLoading && movie == nil && series == nil && serviceManager.hasAnyConnectedBazarrInstance {
                    loadingContent
                } else if let errorMessage, serviceManager.hasAnyConnectedBazarrInstance {
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
        if isLoading && movie == nil && series == nil && serviceManager.hasAnyConnectedBazarrInstance {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else if let customBadge {
            Text(customBadge.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(customBadge.color.opacity(0.16), in: Capsule())
                .foregroundStyle(customBadge.color)
        } else if coverage.hasIndicator {
            Text(coverage.badgeLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(coverage.badgeColor.opacity(0.16), in: Capsule())
                .foregroundStyle(coverage.badgeColor)
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
        VStack(alignment: .leading, spacing: 12) {
            // Let users assign/change a Bazarr profile whenever Bazarr is connected
            // and tracking this item - this is how you start managing subtitles.
            if serviceManager.hasAnyConnectedBazarrInstance && hasLoadedMedia {
                profileButton
            }

            Text(summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !presentSubtitleKeys.isEmpty {
                languageChipsView(
                    keys: presentSubtitleKeys,
                    label: isTrackedByBazarr ? "Present" : "Present (not tracked)",
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

            if showsSearchActions && missingCount > 0 {
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

            if !serviceManager.hasBazarrInstance {
                Label("Add Bazarr to download and manage subtitles automatically.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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

    /// Whether Bazarr has a language profile assigned to this item. Without one
    /// Bazarr requests no languages, so "missing" counts are meaningless.
    private var hasAssignedProfile: Bool {
        currentProfileId != nil
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
        // Only meaningful when Bazarr is tracking (a profile is assigned).
        guard isTrackedByBazarr else { return 0 }
        if let movie {
            return movie.missingSubtitles.count
        }
        if let series {
            return series.episodeMissingCount
        }
        return 0
    }

    private var summaryText: String {
        switch media {
        case .season:
            let total = downloadedScopedEpisodes.count
            guard total > 0 else {
                return serviceManager.hasAnyConnectedBazarrInstance
                    ? "No downloaded episodes in this season yet."
                    : "No subtitle information is available for this season."
            }
            let withSubs = scopedEpisodesWithSubs
            let episodeWord = total == 1 ? "episode" : "episodes"
            if isTrackedByBazarr {
                let missing = seasonMissingCount
                if missing == 0 {
                    return "All \(total) downloaded \(episodeWord) in this season have their tracked subtitles."
                }
                return "\(withSubs) of \(total) \(episodeWord) have subtitles. \(missing) subtitle\(missing == 1 ? "" : "s") still missing."
            }
            return "\(withSubs) of \(total) downloaded \(episodeWord) have subtitles on disk."
        case .episode:
            guard let episode = scopedEpisodes.first, episodeHasFile(episode) else {
                return serviceManager.hasAnyConnectedBazarrInstance
                    ? "This episode hasn't been downloaded yet."
                    : "No subtitle information is available for this episode."
            }
            switch coverage {
            case .tracked(let missing):
                return missing == 0
                    ? "All tracked subtitle languages are present for this episode."
                    : "\(missing) subtitle language\(missing == 1 ? "" : "s") missing for this episode."
            case .presentUntracked:
                let count = episode.subtitles.count
                return "\(count) subtitle\(count == 1 ? "" : "s") present. Assign a Bazarr profile to track missing languages."
            case .noneFound:
                return "No subtitles found for this episode."
            case .unknown:
                return "No subtitle information is available for this episode."
            }
        case .movie, .series:
            break
        }
        switch coverage {
        case .tracked(let missing):
            if missing == 0 {
                if case .series = media {
                    return "Bazarr reports all tracked episode subtitles are present."
                }
                return movie?.subtitles.isEmpty == false
                    ? "\(movie!.subtitles.count) subtitle file\(movie!.subtitles.count == 1 ? "" : "s") available."
                    : "Bazarr is tracking this item. No missing subtitles are reported."
            }
            if case .series(_, _, _, _) = media, let series {
                return "\(series.episodeMissingCount) missing subtitle\(series.episodeMissingCount == 1 ? "" : "s") across \(series.episodeFileCount) episode file\(series.episodeFileCount == 1 ? "" : "s")."
            }
            return "\(missing) language\(missing == 1 ? "" : "s") missing."
        case .presentUntracked:
            let count = presentSubtitleKeys.count
            if serviceManager.hasAnyConnectedBazarrInstance {
                return "Subtitles are present but no language profile is assigned, so Bazarr isn't tracking them. Assign a profile to manage missing languages."
            }
            return "\(count) subtitle language\(count == 1 ? "" : "s") detected on disk. Not tracked by Bazarr."
        case .noneFound:
            if serviceManager.hasAnyConnectedBazarrInstance {
                return "No subtitles found, and no language profile is assigned."
            }
            return "No embedded subtitles detected on disk. External .srt sidecar files aren't visible without Bazarr."
        case .unknown:
            return serviceManager.hasAnyConnectedBazarrInstance
                ? "Bazarr has not imported this item yet. Make sure Bazarr is connected to the matching Sonarr/Radarr library."
                : "No subtitle information is available for this item."
        }
    }

    private typealias SubtitleKey = (code2: String, hi: Bool, forced: Bool)

    private var presentSubtitleKeys: [SubtitleKey] {
        // Prefer Bazarr's richer info (knows HI/forced and external sidecars).
        if let movie, !movie.subtitles.isEmpty {
            return uniqueSubtitleKeys(movie.subtitles.map { ($0.code2, $0.hi, $0.forced) })
        }
        let scoped = scopedEpisodes
        if !scoped.isEmpty {
            let keys = scoped.flatMap { episode in
                episode.subtitles.map { ($0.code2, $0.hi, $0.forced) }
            }
            if !keys.isEmpty { return uniqueSubtitleKeys(keys) }
        }
        // Fallback to embedded languages from Radarr/Sonarr media info (no HI/forced detail).
        switch media {
        case .movie:
            return uniqueSubtitleKeys(SubtitleCoverage.embeddedLanguages(from: embeddedMovieSubtitles).map { ($0, false, false) })
        case .series:
            return uniqueSubtitleKeys(seriesEmbeddedLanguages.map { ($0, false, false) })
        case .season, .episode:
            return []
        }
    }

    private var missingLanguageKeys: [SubtitleKey] {
        guard isTrackedByBazarr else { return [] }
        if let movie {
            return uniqueSubtitleKeys(movie.missingSubtitles.map { ($0.code2, $0.hi, $0.forced) })
        }
        return uniqueSubtitleKeys(scopedEpisodes.flatMap { episode in
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
        AppSheetShell(
            title: "Language Profile",
            confirmTitle: "Save",
            isConfirmDisabled: isUpdatingProfile,
            onConfirm: {
                showProfilePicker = false
                Task { await updateProfile() }
            },
            detents: [.medium]
        ) {
            List {
                Picker("Profile", selection: $selectedProfileId) {
                    Text("None").tag(nil as Int?)
                    ForEach(activeLanguageProfiles) { profile in
                        Text(profile.name).tag(profile.profileId as Int?)
                    }
                }
                .pickerStyle(.inline)
            }
        }
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
            case .movie(let radarrId, _, _, _):
                let page = try await client.getMovies(ids: [radarrId])
                movie = page.data.first
            case .series(let seriesId, _, _, _):
                let page = try await client.getSeries(ids: [seriesId])
                series = page.data.first
                if let s = series {
                    episodes = (try? await client.getEpisodes(seriesIds: [s.sonarrSeriesId])) ?? []
                }
            case .season(let seriesId, _, _):
                let page = try await client.getSeries(ids: [seriesId])
                series = page.data.first
                episodes = (try? await client.getEpisodes(seriesIds: [seriesId])) ?? []
            case .episode(let seriesId, let episodeId, _):
                let page = try await client.getSeries(ids: [seriesId])
                series = page.data.first
                episodes = (try? await client.getEpisodes(episodeIds: [episodeId])) ?? []
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
            case .movie(let radarrId, let title, _, _):
                try await client.runMovieAction(radarrId: radarrId, action: .searchMissing)
                InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(title) was sent to Bazarr.")
            case .series(let seriesId, let title, _, _):
                try await client.runSeriesAction(seriesId: seriesId, action: .searchMissing)
                InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(title) was sent to Bazarr.")
            case .season, .episode:
                // Season/episode cards are informational; they expose no search action.
                return
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
            case .movie(let radarrId, _, _, _):
                try await client.updateMovieProfile(
                    radarrIds: [radarrId],
                    profileIds: [selectedProfileId.map(String.init)]
                )
            case .series(let seriesId, _, _, _):
                try await client.updateSeriesProfile(
                    seriesIds: [seriesId],
                    profileIds: [selectedProfileId.map(String.init)]
                )
            case .season(let seriesId, _, _), .episode(let seriesId, _, _):
                // Bazarr language profiles are assigned per series; reuse the series endpoint.
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
