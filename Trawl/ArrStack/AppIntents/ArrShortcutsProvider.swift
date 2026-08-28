import AppIntents

/// Exposes Trawl's *arr App Intents to Shortcuts and Siri. Entity-bearing phrases give Siri
/// examples of both the action and its typed title slot, while the corresponding
/// `EntityStringQuery` implementations resolve naturally spoken movie and show names.
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
                "Add a movie to Radarr in \(.applicationName)",
                "Get a movie in \(.applicationName)",
                "Get \(\.$movie) in \(.applicationName)",
                "Add \(\.$movie) to \(.applicationName)"
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
                "Add a show to Sonarr in \(.applicationName)",
                "Get a show in \(.applicationName)",
                "Get \(\.$series) in \(.applicationName)",
                "Add \(\.$series) to \(.applicationName)"
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
                "What's coming up in \(.applicationName)",
                "What's upcoming in \(.applicationName)"
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

        AppShortcut(
            intent: CheckArrLibraryIntent(),
            phrases: [
                "Check my library in \(.applicationName)",
                "Do I have \(\.$item) in \(.applicationName)",
                "Do we have \(\.$item) in \(.applicationName)",
                "Is \(\.$item) in \(.applicationName)",
                "Check \(.applicationName) for \(\.$item)"
            ],
            shortTitle: "Check Library",
            systemImageName: "checkmark.magnifyingglass"
        )
    }
}
