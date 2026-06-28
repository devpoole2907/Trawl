import AppIntents
import Foundation

/// Searches Radarr's lookup endpoint for movies matching a search term.
/// Read-only. Returns movie entities (usable by `AddRadarrMovieIntent`) plus a spoken summary.
struct SearchRadarrMoviesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Radarr Movies"
    static let description = IntentDescription(
        "Search Radarr for movies by title.",
        categoryName: "Radarr"
    )

    @Parameter(title: "Search", requestValueDialog: "What movie do you want to search for?")
    var query: String

    @Parameter(title: "Radarr Service")
    var service: ArrServiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Search Radarr for \(\.$query)") {
            \.$service
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ArrMovieEntity]> & ProvidesDialog {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.radarr])
        let client = try await ArrIntentSupport.makeRadarrClient(service)

        let results: [RadarrMovie]
        do {
            results = try await client.lookupMovie(term: query)
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        guard !results.isEmpty else {
            return .result(value: [], dialog: "No Radarr results for \(query).")
        }

        let top = Array(results.prefix(10))
        let entities = top.map { ArrMovieEntity(serviceID: service.id.uuidString, movie: $0) }

        // Make these results discoverable later by Spotlight / Apple Intelligence.
        await ArrSpotlightIndexer.index(movies: entities)

        let names = top.prefix(3).map { movie in
            movie.year.map { "\(movie.title) (\($0))" } ?? movie.title
        }
        let summary = "Found \(results.count) result\(results.count == 1 ? "" : "s"): \(names.joined(separator: ", "))."
        return .result(value: entities, dialog: IntentDialog(stringLiteral: summary))
    }
}
