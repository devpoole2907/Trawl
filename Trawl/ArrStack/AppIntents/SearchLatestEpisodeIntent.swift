import AppIntents
import Foundation

/// Searches for the newest aired episode of a show already in Sonarr.
///
/// Made for a personal automation: "every other Thursday, look for the new South
/// Park". The same decision as the Series list's long-press and Up Next
/// (`SonarrEpisodeProgress.latestEpisodeAction`), so it leaves a downloaded or
/// already-downloading episode alone and says so rather than grabbing it twice.
///
/// Not an `AppShortcut`: Trawl already declares Apple's maximum of ten. It is still
/// offered as an action in the Shortcuts app, which is where an automation is built.
struct SearchLatestEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Search for Latest Episode"
    static let description = IntentDescription(
        "Search Sonarr for the newest episode of a show in your library, unless it's already downloaded or downloading.",
        categoryName: "Status"
    )

    @Parameter(title: "Series")
    var series: ArrSeriesEntity?

    @Parameter(title: "Title", requestValueDialog: "Which show?")
    var title: String?

    @Parameter(title: "Sonarr Service")
    var service: ArrServiceEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Search for the latest episode of \(\.$series)") {
            \.$title
            \.$service
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.sonarr])
        let client = try await ArrIntentSupport.makeSonarrClient(service)

        let library: [SonarrSeries]
        do {
            library = try await client.getSeries()
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }
        let match = try await resolveMatch(in: library)

        let action: SonarrEpisodeProgress.LatestEpisodeAction
        do {
            action = try await SonarrEpisodeProgress.searchLatestEpisode(seriesId: match.id, client: client)
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        let message: String
        switch action {
        case .nothingAired:
            message = "No episode of \(match.title) has aired yet."
        case .alreadyOnDisk(let episode):
            message = "\(match.title) \(episode.episodeIdentifier) is already downloaded."
        case .alreadyQueued(let episode):
            message = "\(match.title) \(episode.episodeIdentifier) is already downloading."
        case .search(let episode):
            message = "Searching for \(match.title) \(episode.episodeIdentifier)."
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }

    /// The library copy the user meant: by Sonarr ID when the entity came from this
    /// server's library, then TVDB ID, then title.
    private func resolveMatch(in library: [SonarrSeries]) async throws -> SonarrSeries {
        if let payload = series?.payload {
            if let libraryId = payload.libraryId,
               let hit = library.first(where: { $0.id == libraryId && (payload.tvdbId == nil || $0.tvdbId == payload.tvdbId) }) {
                return hit
            }
            if let tvdbId = payload.tvdbId, let hit = library.first(where: { $0.tvdbId == tvdbId }) {
                return hit
            }
        }
        let wanted = (title ?? series?.payload.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            throw $title.needsValueError("Which show?")
        }
        if let hit = Self.bestMatch(in: library, title: wanted) { return hit }
        throw ArrIntentError.requestFailed("\(wanted) isn't in your Sonarr library.")
    }

    /// Exact title first, then a contained match, preferring the newest year - the
    /// same rule `SearchExistingArrItemIntent` uses.
    static func bestMatch(in library: [SonarrSeries], title: String) -> SonarrSeries? {
        let exact = library.filter { $0.title.caseInsensitiveCompare(title) == .orderedSame }
        let candidates = exact.isEmpty ? library.filter { $0.title.localizedCaseInsensitiveContains(title) } : exact
        return candidates.max { ($0.year ?? 0) < ($1.year ?? 0) }
    }
}
