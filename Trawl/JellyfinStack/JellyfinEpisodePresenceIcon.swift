import SwiftUI

/// Compact Jellyfin presence badge shown inline in episode rows next to the
/// downloaded checkmark / subtitle icons. Renders nothing unless the series
/// has resolved in Jellyfin AND its episode list contains a matching
/// season + episode number — keeping the row free of noise for shows that
/// aren't in Jellyfin at all.
struct JellyfinEpisodePresenceIcon: View {
    let media: JellyfinMediaAvailabilityCard.Media
    let seasonNumber: Int
    let episodeNumber: Int

    @Environment(JellyfinServiceManager.self) private var serviceManager

    private var seriesKey: JellyfinAvailabilityResolver.Key? {
        serviceManager.activeProfileID.map { .init(profileID: $0, mediaTaskKey: media.taskKey) }
    }

    private var matchedSeriesItemID: String? {
        guard let seriesKey,
              case .resolved(let items) = serviceManager.availability.state(for: seriesKey),
              let first = items.first
        else { return nil }
        return first.id
    }

    private var episodesKey: JellyfinAvailabilityResolver.EpisodesKey? {
        guard let profileID = serviceManager.activeProfileID,
              let seriesItemID = matchedSeriesItemID
        else { return nil }
        return .init(profileID: profileID, seriesItemID: seriesItemID)
    }

    private var isInJellyfin: Bool {
        guard let episodesKey,
              case .resolved(let episodes) = serviceManager.availability.episodesState(for: episodesKey)
        else { return false }
        return episodes.contains {
            $0.parentIndexNumber == seasonNumber && $0.indexNumber == episodeNumber
        }
    }

    var body: some View {
        Group {
            if serviceManager.isConnected && isInJellyfin {
                Image(systemName: "play.tv.fill")
                    .foregroundStyle(.indigo)
                    .font(.caption)
                    .accessibilityLabel("In Jellyfin")
            }
        }
        .task(id: "\(media.taskKey)-\(serviceManager.activeProfileID?.uuidString ?? "none")") {
            guard serviceManager.isConnected,
                  let seriesKey,
                  let client = serviceManager.activeClient
            else { return }
            serviceManager.availability.ensureLoaded(seriesKey, media: media, client: client)
        }
        .task(id: episodesKey?.seriesItemID) {
            guard serviceManager.isConnected,
                  let episodesKey,
                  let client = serviceManager.activeClient
            else { return }
            serviceManager.availability.ensureEpisodesLoaded(episodesKey, client: client)
        }
    }
}
