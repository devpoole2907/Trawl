import Foundation

// How the blended library decides that two servers are holding the same title.
//
// Both merge policies live here rather than next to their models so the rule is
// reviewable in one place: get it wrong in the loose direction and two different
// films collapse into one row; get it wrong in the strict direction and the HD
// and 4K copies of the same film sit next to each other as unrelated entries.

nonisolated extension RadarrMovie: ArrMergeableLibraryItem {
    /// TMDb first — it is the ID Radarr itself keys a movie on, so two servers
    /// that added the same film agree on it. IMDb is the fallback for the rare
    /// entry added before a TMDb match existed, and title+year the last resort
    /// for lookup results that carry no external ID at all.
    var mergeKey: ArrMergeKey {
        .external(
            serviceType: .radarr,
            databaseName: "tmdb",
            databaseID: tmdbId,
            imdbID: imdbId,
            title: title,
            year: year
        )
    }
}

nonisolated extension SonarrSeries: ArrMergeableLibraryItem {
    /// TVDb is Sonarr's primary series key, so it plays the role TMDb plays for
    /// movies. A series' `year` is its first-aired year, which both servers get
    /// from the same metadata source, so the title fallback stays safe.
    var mergeKey: ArrMergeKey {
        .external(
            serviceType: .sonarr,
            databaseName: "tvdb",
            databaseID: tvdbId,
            imdbID: imdbId,
            title: title,
            year: year
        )
    }
}
