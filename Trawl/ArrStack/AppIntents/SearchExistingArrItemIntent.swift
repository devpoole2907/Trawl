import AppIntents
import Foundation

/// Triggers a search for an item already in the library: a Radarr movie search or a
/// Sonarr series search. This explicitly tells the service to look for releases for
/// something you've already added — it does not add anything new.
struct SearchExistingArrItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Search for Existing Item"
    static let description = IntentDescription(
        "Trigger a search for a movie or series you've already added to Radarr or Sonarr.",
        categoryName: "Status"
    )

    @Parameter(title: "Type", default: .movie)
    var kind: ArrMediaKind

    @Parameter(title: "Title", requestValueDialog: "Which title should I search for?")
    var title: String

    @Parameter(title: "Service")
    var service: ArrServiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Search for the \(\.$kind) \(\.$title)") {
            \.$service
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message: String
        switch kind {
        case .movie:
            message = try await searchMovie()
        case .series:
            message = try await searchSeries()
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }

    private func searchMovie() async throws -> String {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.radarr])
        let client = try await ArrIntentSupport.makeRadarrClient(service)

        let library: [RadarrMovie]
        do {
            library = try await client.getMovies()
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }
        guard let match = bestMatch(in: library, title: { $0.title }, year: { $0.year }) else {
            throw ArrIntentError.requestFailed("\(title) isn't in your Radarr library yet.")
        }

        do {
            _ = try await client.searchMovie(movieIds: [match.id])
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }
        return "Started a Radarr search for \(match.title)."
    }

    private func searchSeries() async throws -> String {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.sonarr])
        let client = try await ArrIntentSupport.makeSonarrClient(service)

        let library: [SonarrSeries]
        do {
            library = try await client.getSeries()
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }
        guard let match = bestMatch(in: library, title: { $0.title }, year: { $0.year }) else {
            throw ArrIntentError.requestFailed("\(title) isn't in your Sonarr library yet.")
        }

        do {
            _ = try await client.searchSeries(seriesId: match.id)
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }
        return "Started a Sonarr search for \(match.title)."
    }

    /// Picks the best library match for `title`: prefers an exact (case-insensitive) title,
    /// then a contains match, breaking ties toward the most recent year.
    private func bestMatch<T>(
        in items: [T],
        title titleOf: (T) -> String,
        year yearOf: (T) -> Int?
    ) -> T? {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = items.filter { titleOf($0).caseInsensitiveCompare(needle) == .orderedSame }
        let candidates = exact.isEmpty
            ? items.filter { titleOf($0).localizedCaseInsensitiveContains(needle) }
            : exact
        return candidates.max { (yearOf($0) ?? 0) < (yearOf($1) ?? 0) }
    }
}
