import SwiftUI

/// Compact Jellyfin presence badge shown inline in episode rows next to the
/// downloaded checkmark / subtitle icons. Renders nothing unless the series
/// has resolved in Jellyfin AND its episode list contains a matching
/// season + episode number - keeping the row free of noise for shows that
/// aren't in Jellyfin at all.
struct JellyfinEpisodePresenceIcon: View {
    let media: JellyfinMediaAvailabilityCard.Media
    let seasonNumber: Int
    let episodeNumber: Int

    @Environment(JellyfinServiceManager.self) private var serviceManager

    private var seriesKey: JellyfinAvailabilityResolver.Key? {
        serviceManager.activeProfileID.map { .init(profileID: $0, mediaTaskKey: media.taskKey) }
    }

    private var matchedSeriesItemIDs: [String] {
        guard let seriesKey,
              case .resolved(let items) = serviceManager.availability.state(for: seriesKey)
        else { return [] }
        return items.map(\.id)
    }

    private var episodesKeys: [JellyfinAvailabilityResolver.EpisodesKey] {
        guard let profileID = serviceManager.activeProfileID else { return [] }
        return matchedSeriesItemIDs.map {
            .init(profileID: profileID, seriesItemID: $0)
        }
    }

    private var isInJellyfin: Bool {
        let states = episodesKeys.map {
            serviceManager.availability.episodesState(for: $0)
        }
        return JellyfinEpisodeAvailabilityAggregate.matchingEpisode(
            in: states,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        ) != nil
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
        .task(id: episodesKeys) {
            guard serviceManager.isConnected,
                  let client = serviceManager.activeClient
            else { return }
            for key in episodesKeys {
                serviceManager.availability.ensureEpisodesLoaded(key, client: client)
            }
        }
    }
}
