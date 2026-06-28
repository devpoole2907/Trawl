import AppIntents
import Foundation

/// Adds a movie to Radarr using safe, live-fetched defaults (root folder + quality profile).
///
/// Accepts either a movie entity (e.g. chained from `SearchRadarrMoviesIntent` in Shortcuts)
/// or a title typed/spoken to Siri. A fresh Radarr lookup is always performed at add time so the
/// add body carries an accurate TMDb id, and the library is checked first to avoid duplicates.
struct AddRadarrMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Movie to Radarr"
    static let description = IntentDescription(
        "Add a movie to Radarr using its default root folder and a 1080p-style quality profile when available.",
        categoryName: "Radarr"
    )

    @Parameter(title: "Movie")
    var movie: ArrMovieEntity?

    @Parameter(title: "Title")
    var title: String?

    @Parameter(title: "Radarr Service")
    var service: ArrServiceEntity?

    @Parameter(title: "Monitor", default: true)
    var monitored: Bool

    @Parameter(title: "Start Search", default: true)
    var startSearch: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Radarr") {
            \.$movie
            \.$service
            \.$monitored
            \.$startSearch
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.radarr])
        let client = try await ArrIntentSupport.makeRadarrClient(service)

        // Resolve the movie via a fresh lookup so we have a complete, accurate add payload.
        let lookup: RadarrMovie
        do {
            if let tmdbId = movie?.payload.tmdbId {
                lookup = try await client.lookupMovieByTmdb(tmdbId: tmdbId)
            } else {
                let term = try await resolvedTitle()
                guard let best = try await client.lookupMovie(term: term).first else {
                    throw ArrIntentError.noResults(term)
                }
                lookup = best
            }
        } catch let error as ArrIntentError {
            throw error
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        guard let tmdbId = lookup.tmdbId else {
            throw ArrIntentError.requestFailed("That movie is missing a TMDb id and can't be added.")
        }

        // Duplicate guard.
        let existing = (try? await client.getMovies()) ?? []
        if existing.contains(where: { $0.tmdbId == tmdbId }) {
            return .result(dialog: IntentDialog(stringLiteral: ArrIntentError.itemAlreadyExists(lookup.title).message))
        }

        // Live defaults — never hardcoded.
        let profiles = try await client.getQualityProfiles()
        let qualityProfileId = try ArrIntentSupport.defaultQualityProfileId(from: profiles)
        let rootFolders = try await client.getRootFolders()
        let rootFolderPath = try ArrIntentSupport.defaultRootFolderPath(from: rootFolders)

        let willSearch = monitored && startSearch
        let body = RadarrAddMovieBody(
            title: lookup.title,
            tmdbId: tmdbId,
            qualityProfileId: qualityProfileId,
            rootFolderPath: rootFolderPath,
            monitored: monitored,
            minimumAvailability: "released",
            addOptions: RadarrAddOptions(
                searchForMovie: willSearch,
                monitor: monitored ? "movieOnly" : "none"
            ),
            tags: nil
        )

        do {
            _ = try await client.addMovie(body)
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        let profileName = profiles.first(where: { $0.id == qualityProfileId })?.name ?? "the default profile"
        let searchNote = willSearch ? " and started a search" : ""
        let message = "Added \(lookup.title) to Radarr using \(profileName)\(searchNote)."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }

    /// Returns the title to look up, prompting the user if neither an entity nor a title was given.
    private func resolvedTitle() async throws -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let entityTitle = movie?.payload.title, !entityTitle.isEmpty {
            return entityTitle
        }
        let entered = try await $title.requestValue("What movie do you want to add?")
        guard !entered.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ArrIntentError.noResults("")
        }
        return entered
    }
}
