import SwiftUI

/// Per-episode Jellyfin availability card used on the Sonarr episode detail
/// screen. Reuses `JellyfinAvailabilityResolver`'s series cache (the series
/// detail card primes it) and the new episode cache, then surfaces just the
/// matching episode item - path, file size, runtime, refresh - instead of the
/// whole series.
struct JellyfinEpisodeAvailabilityCard: View {
    let media: JellyfinMediaAvailabilityCard.Media
    let seasonNumber: Int
    let episodeNumber: Int

    @Environment(JellyfinServiceManager.self) private var serviceManager
    @State private var isExpanded = false
    @State private var didRefresh = false
    @State private var isRescanning = false

    private var seriesKey: JellyfinAvailabilityResolver.Key? {
        serviceManager.activeProfileID.map { .init(profileID: $0, mediaTaskKey: media.taskKey) }
    }

    private var seriesState: JellyfinAvailabilityResolver.State {
        seriesKey.map { serviceManager.availability.state(for: $0) } ?? .idle
    }

    /// Every Jellyfin Series item that represents this show. Two libraries can
    /// legitimately expose the same TVDB series (for example Default and 4K),
    /// and the requested episode may exist in only one of them.
    private var matchedSeriesItemIDs: [String] {
        guard case .resolved(let items) = seriesState else { return [] }
        return items.map(\.id)
    }

    private var episodesKeys: [JellyfinAvailabilityResolver.EpisodesKey] {
        guard let profileID = serviceManager.activeProfileID else { return [] }
        return matchedSeriesItemIDs.map {
            .init(profileID: profileID, seriesItemID: $0)
        }
    }

    private var episodesStates: [JellyfinAvailabilityResolver.State] {
        episodesKeys.map { serviceManager.availability.episodesState(for: $0) }
    }

    private var matchedEpisode: JellyfinLibraryItem? {
        JellyfinEpisodeAvailabilityAggregate.matchingEpisode(
            in: episodesStates,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
    }

    private enum Stage {
        case connecting
        case loadingSeries
        case loadingEpisodes
        case seriesMissing
        case episodeMissing
        case present(JellyfinLibraryItem)
        case failed(String)
    }

    private var stage: Stage {
        if serviceManager.isConnecting { return .connecting }
        switch seriesState {
        case .idle, .loading: return .loadingSeries
        case .failed(let msg): return .failed(msg)
        case .resolved(let items):
            if items.isEmpty { return .seriesMissing }
            if let episode = matchedEpisode {
                return .present(episode)
            }
            if JellyfinEpisodeAvailabilityAggregate.isLoading(episodesStates) {
                return .loadingEpisodes
            }
            if let message = JellyfinEpisodeAvailabilityAggregate.firstFailure(in: episodesStates) {
                return .failed(message)
            }
            return .episodeMissing
        }
    }

    var body: some View {
        if serviceManager.isConnected || serviceManager.connectionError != nil || serviceManager.isConnecting {
            cardContent
                .task(id: "\(media.taskKey)-\(serviceManager.activeProfileID?.uuidString ?? "none")") {
                    isExpanded = false
                    didRefresh = false
                    isRescanning = false
                    guard let seriesKey, let client = serviceManager.activeClient else { return }
                    serviceManager.availability.ensureLoaded(seriesKey, media: media, client: client)
                }
                .task(id: episodesKeys) {
                    guard let client = serviceManager.activeClient else { return }
                    for key in episodesKeys {
                        serviceManager.availability.ensureEpisodesLoaded(key, client: client)
                    }
                }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                switch stage {
                case .connecting:
                    loadingRow("Connecting to Jellyfin…")
                case .loadingSeries:
                    loadingRow("Checking series in Jellyfin…")
                case .loadingEpisodes:
                    loadingRow("Checking episode in Jellyfin…")
                case .seriesMissing:
                    missingRow(title: "Series not in Jellyfin", detail: "The parent series for this episode wasn't found.")
                case .episodeMissing:
                    missingRow(title: "Episode not in Jellyfin", detail: "Jellyfin has the series but no file for this episode.")
                case .present(let episode):
                    episodeRow(episode)
                case .failed(let message):
                    errorRow(message)
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
                Image(systemName: iconName)
                    .foregroundStyle(tint)
                    .frame(width: 24, alignment: .leading)
                Text("Jellyfin")
                    .font(.headline)
                Spacer()
                switch stage {
                case .connecting, .loadingSeries, .loadingEpisodes:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                default:
                    Text(badgeText)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.16), in: Capsule())
                        .foregroundStyle(tint)
                }
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

    private var badgeText: String {
        switch stage {
        case .connecting, .loadingSeries, .loadingEpisodes: return "Checking"
        case .seriesMissing, .episodeMissing: return "Not Present"
        case .present: return "Present"
        case .failed: return "Error"
        }
    }

    private var iconName: String {
        switch stage {
        case .connecting, .loadingSeries, .loadingEpisodes: return "play.tv"
        case .present: return "play.tv.fill"
        case .seriesMissing, .episodeMissing: return "play.slash.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch stage {
        case .connecting, .loadingSeries, .loadingEpisodes: return .secondary
        case .present: return .green
        case .seriesMissing, .episodeMissing, .failed: return .orange
        }
    }

    private func episodeRow(_ episode: JellyfinLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.name ?? "Episode")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if let parent = episode.parentIndexNumber, let index = episode.indexNumber {
                            Text(String(format: "S%02dE%02d", parent, index))
                        }
                        if let runtimeMinutes = episode.runtimeMinutes {
                            Text("\(runtimeMinutes)m")
                        }
                        if let fileSize = episode.fileSize, fileSize > 0 {
                            Text(ByteFormatter.format(bytes: fileSize))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await refresh(episode) }
                } label: {
                    if didRefresh {
                        Image(systemName: "checkmark.circle.fill")
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(didRefresh)
                .accessibilityLabel("Refresh Jellyfin episode")
            }

            if let path = episode.path ?? episode.mediaSources?.compactMap(\.path).first, !path.isEmpty {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }

    private func missingRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await rescanLibrary() }
            } label: {
                if isRescanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRescanning)
            .accessibilityLabel("Rescan Jellyfin library")
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                guard let client = serviceManager.activeClient else { return }
                if let seriesKey {
                    serviceManager.availability.invalidate(seriesKey)
                    serviceManager.availability.ensureLoaded(seriesKey, media: media, client: client)
                }
                for key in episodesKeys {
                    serviceManager.availability.invalidateEpisodes(key)
                    serviceManager.availability.ensureEpisodesLoaded(key, client: client)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func refresh(_ episode: JellyfinLibraryItem) async {
        guard let client = serviceManager.activeClient else { return }
        do {
            try await client.refreshItem(id: episode.id)
            didRefresh = true
            for key in episodesKeys {
                serviceManager.availability.invalidateEpisodes(key)
                serviceManager.availability.ensureEpisodesLoaded(key, client: client)
            }
            InAppNotificationCenter.shared.showSuccess(
                title: "Jellyfin Refresh Started",
                message: "\(episode.name ?? "Episode") was sent for metadata refresh.",
                source: .inApp
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Jellyfin Refresh Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }

    /// Starts a Jellyfin library scan, then re-checks while that asynchronous
    /// scan catches up. The POST only queues work on Jellyfin; treating its 204 as
    /// "the new file is indexed now" races the scan and re-caches the stale answer.
    private func rescanLibrary() async {
        guard let client = serviceManager.activeClient else { return }
        isRescanning = true
        defer { isRescanning = false }

        do {
            try await client.refreshAllLibraries()
            InAppNotificationCenter.shared.showSuccess(
                title: "Jellyfin Library Scan Started",
                message: "Jellyfin is rescanning your libraries.",
                source: .inApp
            )

            // Re-query for roughly 30 seconds. A small library usually resolves on
            // the first few passes; a busy server still gets enough time to finish
            // the asynchronous scan instead of being sampled immediately.
            for attempt in 0..<12 {
                if attempt > 0 {
                    try await Task.sleep(for: .milliseconds(2500))
                }
                try Task.checkCancellation()

                if let seriesKey {
                    serviceManager.availability.invalidate(seriesKey)
                    serviceManager.availability.ensureLoaded(seriesKey, media: media, client: client)
                    await waitForSeriesLookupToSettle(seriesKey)
                }

                let currentKeys = episodesKeys
                for key in currentKeys {
                    serviceManager.availability.invalidateEpisodes(key)
                    serviceManager.availability.ensureEpisodesLoaded(key, client: client)
                }
                await waitForEpisodeLookupsToSettle(currentKeys)

                if matchedEpisode != nil {
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Jellyfin Scan Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }

    private func waitForSeriesLookupToSettle(_ key: JellyfinAvailabilityResolver.Key) async {
        for _ in 0..<100 {
            switch serviceManager.availability.state(for: key) {
            case .idle, .loading:
                try? await Task.sleep(for: .milliseconds(20))
            case .resolved, .failed:
                return
            }
        }
    }

    private func waitForEpisodeLookupsToSettle(
        _ keys: [JellyfinAvailabilityResolver.EpisodesKey]
    ) async {
        guard !keys.isEmpty else { return }
        for _ in 0..<100 {
            let states = keys.map { serviceManager.availability.episodesState(for: $0) }
            if !JellyfinEpisodeAvailabilityAggregate.isLoading(states) {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

}
