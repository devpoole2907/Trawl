import AppIntents

/// Exposes Trawl's *arr App Intents to Shortcuts and Siri with fixed phrases.
///
/// v1 relies only on standard `AppShortcutsProvider` phrase matching (iOS 16+ App Intents),
/// not the newer Siri AI natural-language / entity-schema APIs. Every phrase includes the
/// `\(.applicationName)` token as required.
// TODO (future Siri AI): when targeting the newer SDK, adopt App Entity schemas, Spotlight
// semantic indexing, action/content donation, and view annotations ("add this movie") so users
// can act conversationally without these fixed phrases.
struct ArrShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchRadarrMoviesIntent(),
            phrases: [
                "Search Radarr in \(.applicationName)",
                "Search \(.applicationName) for a movie"
            ],
            shortTitle: "Search Radarr",
            systemImageName: "film"
        )

        AppShortcut(
            intent: AddRadarrMovieIntent(),
            phrases: [
                "Add a movie in \(.applicationName)",
                "Add a movie to Radarr in \(.applicationName)"
            ],
            shortTitle: "Add Movie",
            systemImageName: "plus.rectangle.on.folder"
        )

        AppShortcut(
            intent: SearchSonarrSeriesIntent(),
            phrases: [
                "Search Sonarr in \(.applicationName)",
                "Search \(.applicationName) for a show"
            ],
            shortTitle: "Search Sonarr",
            systemImageName: "tv"
        )

        AppShortcut(
            intent: AddSonarrSeriesIntent(),
            phrases: [
                "Add a series in \(.applicationName)",
                "Add a show to Sonarr in \(.applicationName)"
            ],
            shortTitle: "Add Series",
            systemImageName: "plus.rectangle.on.folder"
        )

        AppShortcut(
            intent: SearchProwlarrIntent(),
            phrases: [
                "Search Prowlarr in \(.applicationName)",
                "Search indexers in \(.applicationName)"
            ],
            shortTitle: "Search Prowlarr",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: ShowArrQueueIntent(),
            phrases: [
                "Show the \(.applicationName) queue",
                "What's downloading in \(.applicationName)"
            ],
            shortTitle: "Download Queue",
            systemImageName: "arrow.down.circle"
        )

        AppShortcut(
            intent: ShowArrCalendarIntent(),
            phrases: [
                "Show the \(.applicationName) calendar",
                "What's coming up in \(.applicationName)"
            ],
            shortTitle: "Upcoming Releases",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: SearchExistingArrItemIntent(),
            phrases: [
                "Search for an existing item in \(.applicationName)",
                "Find a release in \(.applicationName)"
            ],
            shortTitle: "Search Existing Item",
            systemImageName: "sparkle.magnifyingglass"
        )

        AppShortcut(
            intent: ShowArrServiceStatusIntent(),
            phrases: [
                "Check \(.applicationName) service status",
                "Check \(.applicationName) health"
            ],
            shortTitle: "Service Status",
            systemImageName: "heart.text.square"
        )
    }
}
