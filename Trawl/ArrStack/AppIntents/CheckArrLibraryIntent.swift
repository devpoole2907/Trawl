import AppIntents
import Foundation

/// Answers conversational questions about whether a movie or series is already in Trawl's
/// configured Radarr/Sonarr libraries. This intent is deliberately read-only: unlike
/// `SearchExistingArrItemIntent`, it never starts a release search.
struct CheckArrLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Trawl Library"
    static let description = IntentDescription(
        "Check whether a movie or TV series is in your Radarr or Sonarr library and whether it has downloaded.",
        categoryName: "Library"
    )

    @Parameter(title: "Movie or Show", requestValueDialog: "What movie or show should I check?")
    var item: ArrLibraryTitleEntity

    @Parameter(title: "Media Type")
    var kind: ArrMediaKind?

    static var parameterSummary: some ParameterSummary {
        Summary("Check whether \(\.$item) is in my library") {
            \.$kind
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let message = try await response()
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }

    /// Kept separate from the App Intents result wrapper so the complete Siri answer can be
    /// contract-tested against real loopback Radarr/Sonarr responses.
    func response() async throws -> String {
        try await Self.response(for: item.title, kind: kind)
    }

    /// Shared by the App Intent result wrapper and focused contract tests.
    static func response(for title: String, kind: ArrMediaKind?) async throws -> String {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ArrIntentError.noResults("")
        }

        let requestedTypes: Set<ArrServiceType> = switch kind {
        case .movie: [.radarr]
        case .series: [.sonarr]
        case nil: [.radarr, .sonarr]
        }
        let services = try await ArrIntentSupport.loadServices(ofTypes: requestedTypes)
        guard !services.isEmpty else {
            throw ArrIntentError.noServiceConfigured(
                ArrIntentSupport.serviceTypeDescription(for: requestedTypes)
            )
        }

        var matches: [LibraryMatch] = []
        var failures: [String] = []
        for service in services {
            do {
                switch service.serviceType {
                case .radarr:
                    let client = try await ArrIntentSupport.makeRadarrClient(service)
                    let movies = try await client.getMovies()
                    if let movie = Self.bestMatch(in: movies, query: query, title: \.title, year: \.year) {
                        matches.append(.movie(movie, serviceName: service.displayName))
                    }
                case .sonarr:
                    let client = try await ArrIntentSupport.makeSonarrClient(service)
                    let series = try await client.getSeries()
                    if let series = Self.bestMatch(in: series, query: query, title: \.title, year: \.year) {
                        matches.append(.series(series, serviceName: service.displayName))
                    }
                default:
                    break
                }
            } catch {
                failures.append("\(service.displayName): \(ArrIntentSupport.describe(error))")
            }
        }

        let message: String
        if !matches.isEmpty {
            message = matches.map(\.spokenDescription).joined(separator: " ")
        } else if !failures.isEmpty {
            throw ArrIntentError.requestFailed(failures.joined(separator: " "))
        } else {
            let libraryName = switch kind {
            case .movie: "Radarr library"
            case .series: "Sonarr library"
            case nil: "Radarr or Sonarr libraries"
            }
            message = "No, I couldn't find \(query) in your \(libraryName)."
        }

        return message
    }

    private static func bestMatch<Item>(
        in items: [Item],
        query: String,
        title: KeyPath<Item, String>,
        year: KeyPath<Item, Int?>
    ) -> Item? {
        let exact = items.filter {
            $0[keyPath: title].compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let candidates = exact.isEmpty
            ? items.filter { $0[keyPath: title].localizedStandardContains(query) }
            : exact
        return candidates.max { ($0[keyPath: year] ?? 0) < ($1[keyPath: year] ?? 0) }
    }
}

private nonisolated enum LibraryMatch {
    case movie(RadarrMovie, serviceName: String)
    case series(SonarrSeries, serviceName: String)

    var spokenDescription: String {
        switch self {
        case .movie(let movie, let serviceName):
            let year = movie.year.map { " from \($0)" } ?? ""
            let state = movie.hasFile == true
                ? "and it has downloaded"
                : movie.monitored == true ? "and it is monitored but not downloaded yet" : "but it is not monitored"
            return "Yes. \(movie.title)\(year) is in \(serviceName), \(state)."
        case .series(let series, let serviceName):
            let year = series.year.map { " from \($0)" } ?? ""
            let state = series.monitored == true ? "and it is monitored" : "but it is not monitored"
            return "Yes. \(series.title)\(year) is in \(serviceName), \(state)."
        }
    }
}
