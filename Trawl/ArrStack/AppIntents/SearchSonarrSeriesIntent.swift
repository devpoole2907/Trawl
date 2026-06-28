import AppIntents
import Foundation

/// Searches Sonarr's lookup endpoint for series matching a search term.
/// Read-only. Returns series entities (usable by `AddSonarrSeriesIntent`) plus a spoken summary.
struct SearchSonarrSeriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Sonarr Series"
    static let description = IntentDescription(
        "Search Sonarr for TV series by title.",
        categoryName: "Sonarr"
    )

    @Parameter(title: "Search", requestValueDialog: "What TV show do you want to search for?")
    var query: String

    @Parameter(title: "Sonarr Service")
    var service: ArrServiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Search Sonarr for \(\.$query)") {
            \.$service
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ArrSeriesEntity]> & ProvidesDialog {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.sonarr])
        let client = try await ArrIntentSupport.makeSonarrClient(service)

        let results: [SonarrSeries]
        do {
            results = try await client.lookupSeries(term: query)
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        guard !results.isEmpty else {
            return .result(value: [], dialog: "No Sonarr results for \(query).")
        }

        let top = Array(results.prefix(10))
        let entities = top.map { ArrSeriesEntity(serviceID: service.id.uuidString, series: $0) }
        let names = top.prefix(3).map { series in
            series.year.map { "\(series.title) (\($0))" } ?? series.title
        }
        let summary = "Found \(results.count) result\(results.count == 1 ? "" : "s"): \(names.joined(separator: ", "))."
        return .result(value: entities, dialog: IntentDialog(stringLiteral: summary))
    }
}
