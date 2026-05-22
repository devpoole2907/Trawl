import SwiftUI

/// Per-episode Jellyfin availability card used on the Sonarr episode detail
/// screen. Reuses `JellyfinAvailabilityResolver`'s series cache (the series
/// detail card primes it) and the new episode cache, then surfaces just the
/// matching episode item — path, file size, runtime, refresh — instead of the
/// whole series.
struct JellyfinEpisodeAvailabilityCard: View {
    let media: JellyfinMediaAvailabilityCard.Media
    let seasonNumber: Int
    let episodeNumber: Int

    @Environment(JellyfinServiceManager.self) private var serviceManager
    @State private var isExpanded = false
    @State private var didRefresh = false

    private var seriesKey: JellyfinAvailabilityResolver.Key? {
        serviceManager.activeProfileID.map { .init(profileID: $0, mediaTaskKey: media.taskKey) }
    }

    private var seriesState: JellyfinAvailabilityResolver.State {
        seriesKey.map { serviceManager.availability.state(for: $0) } ?? .idle
    }

    private var matchedSeriesItemID: String? {
        if case .resolved(let items) = seriesState, let first = items.first {
            return first.id
        }
        return nil
    }

    private var episodesKey: JellyfinAvailabilityResolver.EpisodesKey? {
        guard let profileID = serviceManager.activeProfileID,
              let seriesItemID = matchedSeriesItemID
        else { return nil }
        return .init(profileID: profileID, seriesItemID: seriesItemID)
    }

    private var episodesState: JellyfinAvailabilityResolver.State {
        episodesKey.map { serviceManager.availability.episodesState(for: $0) } ?? .idle
    }

    private var matchedEpisode: JellyfinLibraryItem? {
        guard case .resolved(let episodes) = episodesState else { return nil }
        return episodes.first {
            $0.parentIndexNumber == seasonNumber && $0.indexNumber == episodeNumber
        }
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
            switch episodesState {
            case .idle, .loading: return .loadingEpisodes
            case .failed(let msg): return .failed(msg)
            case .resolved:
                if let episode = matchedEpisode {
                    return .present(episode)
                }
                return .episodeMissing
            }
        }
    }

    var body: some View {
        if serviceManager.isConnected || serviceManager.connectionError != nil || serviceManager.isConnecting {
            cardContent
                .task(id: "\(media.taskKey)-\(serviceManager.activeProfileID?.uuidString ?? "none")") {
                    isExpanded = false
                    didRefresh = false
                    guard let seriesKey, let client = serviceManager.activeClient else { return }
                    serviceManager.availability.ensureLoaded(seriesKey, media: media, client: client)
                }
                .task(id: episodesKey?.seriesItemID) {
                    guard let episodesKey, let client = serviceManager.activeClient else { return }
                    serviceManager.availability.ensureEpisodesLoaded(episodesKey, client: client)
                }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                switch stage {
                case .connecting:
                    loadingRow("Connecting to Jellyfin...")
                case .loadingSeries:
                    loadingRow("Checking series in Jellyfin...")
                case .loadingEpisodes:
                    loadingRow("Checking episode in Jellyfin...")
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
            Spacer(minLength: 0)
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
                if let episodesKey {
                    serviceManager.availability.invalidateEpisodes(episodesKey)
                    serviceManager.availability.ensureEpisodesLoaded(episodesKey, client: client)
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
            if let episodesKey {
                serviceManager.availability.invalidateEpisodes(episodesKey)
                serviceManager.availability.ensureEpisodesLoaded(episodesKey, client: client)
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
}
