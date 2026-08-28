import Foundation

/// Resolves a TMDb media identifier to the corresponding library entity (Radarr movie
/// or Sonarr series), and vice versa. Mirrors the lookup logic inlined in
/// `SearchView` (trending card tap handling) so it can be reused by other features
/// (e.g. cast/credits) without duplicating the tmdbId <-> tvdbId bridging.
///
/// Deliberately not fanned out across an HD/4K pair. These are *catalog* lookups
/// used to open a cast member's other work, and both servers proxy the same TMDb
/// metadata — asking the second one costs a round trip and returns the same
/// answer. This is the one place an instance-scoped client is left alone on
/// purpose rather than by omission.
@MainActor
struct ArrMediaLookupResolver {
    let serviceManager: ArrServiceManager

    /// Looks up a Radarr movie by TMDb ID. Returns `nil` if Radarr isn't configured
    /// or the lookup fails.
    func resolveMovie(tmdbId: Int) async -> RadarrMovie? {
        guard let radarrClient = serviceManager.radarrClient else { return nil }
        return try? await radarrClient.lookupMovieByTmdb(tmdbId: tmdbId)
    }

    /// Looks up a Sonarr series by TMDb ID. Bridges TMDb -> TVDb via TMDb's external
    /// IDs endpoint, then looks up the series in Sonarr by TVDb ID. Returns `nil` if
    /// Sonarr isn't configured, TMDb has no TVDb mapping, or the lookup fails.
    func resolveSeries(tmdbId: Int) async -> SonarrSeries? {
        guard let sonarrClient = serviceManager.sonarrClient else { return nil }
        guard let tvdbId = try? await TMDbClient().tvExternalIds(tmdbId: tmdbId).tvdbId else { return nil }
        return try? await sonarrClient.lookupSeriesByTvdb(tvdbId: tvdbId)
    }

    /// Reverse direction: resolves the TMDb ID for a Sonarr series via its TVDb ID.
    /// Returns `nil` if the series has no TVDb ID or TMDb has no match.
    func tmdbId(forSeries series: SonarrSeries) async -> Int? {
        guard let tvdbId = series.tvdbId else { return nil }
        return try? await TMDbClient().findByTvdbId(tvdbId).tvResults?.first?.id
    }
}
