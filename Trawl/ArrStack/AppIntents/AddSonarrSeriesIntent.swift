import AppIntents
import Foundation

/// Adds a series to Sonarr using safe, live-fetched defaults (root folder + quality profile).
///
/// Accepts either a series entity (e.g. chained from `SearchSonarrSeriesIntent`) or a title.
/// A fresh Sonarr lookup is always performed at add time so the add body carries the correct
/// TVDb id, title slug, images and seasons, and the library is checked first to avoid duplicates.
struct AddSonarrSeriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Series to Sonarr"
    static let description = IntentDescription(
        "Add a TV series to Sonarr using its default root folder and a 1080p-style quality profile when available.",
        categoryName: "Sonarr"
    )

    @Parameter(title: "Series")
    var series: ArrSeriesEntity?

    @Parameter(title: "Title")
    var title: String?

    @Parameter(title: "Sonarr Service")
    var service: ArrServiceEntity?

    @Parameter(title: "Monitor", default: true)
    var monitored: Bool

    @Parameter(title: "Season Folders", default: true)
    var seasonFolder: Bool

    @Parameter(title: "Start Search", default: true)
    var startSearch: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Sonarr") {
            \.$series
            \.$service
            \.$monitored
            \.$seasonFolder
            \.$startSearch
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = try await ArrIntentSupport.resolveService(preferred: service, ofTypes: [.sonarr])
        let client = try await ArrIntentSupport.makeSonarrClient(service)

        // Resolve via a fresh lookup so we have title slug, images and seasons for the add body.
        let lookup: SonarrSeries
        do {
            if let tvdbId = series?.payload.tvdbId {
                lookup = try await client.lookupSeriesByTvdb(tvdbId: tvdbId)
            } else {
                let term = try await resolvedTitle()
                guard let best = try await client.lookupSeries(term: term).first else {
                    throw ArrIntentError.noResults(term)
                }
                lookup = best
            }
        } catch let error as ArrIntentError {
            throw error
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        guard let tvdbId = lookup.tvdbId, let titleSlug = lookup.titleSlug else {
            throw ArrIntentError.requestFailed("That series is missing the details Sonarr needs to add it.")
        }

        // Duplicate guard.
        let existing = (try? await client.getSeries()) ?? []
        if existing.contains(where: { $0.tvdbId == tvdbId }) {
            return .result(dialog: IntentDialog(stringLiteral: ArrIntentError.itemAlreadyExists(lookup.title).message))
        }

        // Live defaults — never hardcoded.
        let profiles = try await client.getQualityProfiles()
        let qualityProfileId = try ArrIntentSupport.defaultQualityProfileId(from: profiles)
        let rootFolders = try await client.getRootFolders()
        let rootFolderPath = try ArrIntentSupport.defaultRootFolderPath(from: rootFolders)

        let addSeasons = (lookup.seasons ?? []).map {
            SonarrAddSeason(seasonNumber: $0.seasonNumber, monitored: $0.monitored ?? true)
        }
        let willSearch = monitored && startSearch
        let body = SonarrAddSeriesBody(
            tvdbId: tvdbId,
            title: lookup.title,
            qualityProfileId: qualityProfileId,
            languageProfileId: nil,
            titleSlug: titleSlug,
            images: lookup.images ?? [],
            seasons: addSeasons,
            rootFolderPath: rootFolderPath,
            monitored: monitored,
            seasonFolder: seasonFolder,
            seriesType: lookup.seriesType ?? "standard",
            addOptions: SonarrAddOptions(
                monitor: monitored ? "all" : "none",
                searchForMissingEpisodes: willSearch,
                searchForCutoffUnmetEpisodes: false
            ),
            tags: nil
        )

        do {
            _ = try await client.addSeries(body)
        } catch {
            throw ArrIntentError.requestFailed(ArrIntentSupport.describe(error))
        }

        let profileName = profiles.first(where: { $0.id == qualityProfileId })?.name ?? "the default profile"
        let searchNote = willSearch ? " and started a search" : ""
        let message = "Added \(lookup.title) to Sonarr using \(profileName)\(searchNote)."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }

    private func resolvedTitle() async throws -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let entityTitle = series?.payload.title, !entityTitle.isEmpty {
            return entityTitle
        }
        let entered = try await $title.requestValue("What TV show do you want to add?")
        guard !entered.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ArrIntentError.noResults("")
        }
        return entered
    }
}
