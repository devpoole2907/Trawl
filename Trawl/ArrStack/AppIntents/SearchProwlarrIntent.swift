import AppIntents
import Foundation

/// Runs a read-only Prowlarr indexer search and returns a concise summary of the top results.
///
/// v1 is intentionally read-only: it does not grab or download releases from Siri. A safe
/// confirmation flow for grabbing releases is a deliberate future-design item.
struct SearchProwlarrIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Prowlarr"
    static let description = IntentDescription(
        "Search Prowlarr indexers for releases. Read-only - results are summarised, not downloaded.",
        categoryName: "Prowlarr"
    )

    @Parameter(title: "Search", requestValueDialog: "What do you want to search indexers for?")
    var query: String

    @Parameter(title: "Prowlarr Service")
    var service: ArrServiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Search Prowlarr for \(\.$query)") {
            \.$service
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.prowlarr])
        let client = try await ArrIntentSupport.makeProwlarrClient(service)

        let results: [ProwlarrSearchResult]
        do {
            results = try await client.search(query: query, type: .search, limit: 50)
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        guard !results.isEmpty else {
            let message = "No indexer results for \(query)."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }

        // Surface the best-seeded releases first.
        let ranked = results.sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
        let lines = ranked.prefix(3).map { result -> String in
            var parts: [String] = [result.title ?? "Untitled release"]
            if let seeders = result.seeders { parts.append("\(seeders) seeders") }
            if let size = ArrIntentSupport.byteText(result.size) { parts.append(size) }
            if let indexer = result.indexer { parts.append("on \(indexer)") }
            return parts.joined(separator: ", ")
        }
        let summary = "Found \(results.count) release\(results.count == 1 ? "" : "s"). Top: " + lines.joined(separator: "; ") + "."
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}
