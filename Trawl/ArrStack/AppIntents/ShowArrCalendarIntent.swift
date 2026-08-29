import AppIntents
import Foundation

/// Shows upcoming movie releases (Radarr) and episode air dates (Sonarr) within a day range.
/// Read-only.
struct ShowArrCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Upcoming Releases"
    static let description = IntentDescription(
        "Show upcoming movie releases and TV episodes from Radarr and Sonarr.",
        categoryName: "Status"
    )

    @Parameter(title: "Service", default: .all)
    var scope: ArrServiceScope

    @Parameter(title: "Days Ahead", default: 7, controlStyle: .field, inclusiveRange: (1, 60))
    var days: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$scope) releases in the next \(\.$days) days")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ArrCalendarItemEntity]> & ProvidesDialog {
        let services = try await ArrIntentSupport.loadServices(ofTypes: scope.serviceTypes)
        guard !services.isEmpty else {
            throw ArrIntentError.noServiceConfigured(ArrIntentSupport.serviceTypeDescription(for: scope.serviceTypes))
        }

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start

        var items: [(date: Date?, entity: ArrCalendarItemEntity)] = []
        for service in services {
            items.append(contentsOf: await calendarItems(for: service, start: start, end: end))
        }

        guard !items.isEmpty else {
            return .result(value: [], dialog: "Nothing is scheduled in the next \(days) day\(days == 1 ? "" : "s").")
        }

        let sorted = items.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        let entities = sorted.map(\.entity)
        let top = entities.prefix(3).map(\.payload.title)
        let summary = "\(entities.count) upcoming release\(entities.count == 1 ? "" : "s"): \(top.joined(separator: "; "))."
        return .result(value: entities, dialog: IntentDialog(stringLiteral: summary))
    }

    private func calendarItems(
        for service: ArrServiceSnapshot,
        start: Date,
        end: Date
    ) async -> [(date: Date?, entity: ArrCalendarItemEntity)] {
        do {
            switch service.serviceType {
            case .radarr:
                let client = try await ArrIntentSupport.makeRadarrClient(service)
                let movies = try await client.getCalendar(start: start, end: end)
                return movies.map { movie in
                    let dateString = movie.digitalRelease ?? movie.physicalRelease ?? movie.inCinemas
                    let title = movie.year.map { "\(movie.title) (\($0))" } ?? movie.title
                    return (ArrIntentSupport.parseDate(dateString),
                            ArrCalendarItemEntity(payload: .init(serviceName: service.displayName, title: title, dateISO: dateString)))
                }
            case .sonarr:
                let client = try await ArrIntentSupport.makeSonarrClient(service)
                let episodes = try await client.getCalendar(start: start, end: end)
                return episodes.map { episode in
                    let seriesTitle = episode.series?.title ?? "Series"
                    let epTitle = episode.title ?? ""
                    let code = String(format: "S%02dE%02d", episode.seasonNumber, episode.episodeNumber)
                    let title = "\(seriesTitle) - \(code)\(epTitle.isEmpty ? "" : " \(epTitle)")"
                    return (ArrIntentSupport.parseDate(episode.airDateUtc),
                            ArrCalendarItemEntity(payload: .init(serviceName: service.displayName, title: title, dateISO: episode.airDateUtc)))
                }
            default:
                return []
            }
        } catch {
            return []
        }
    }
}
