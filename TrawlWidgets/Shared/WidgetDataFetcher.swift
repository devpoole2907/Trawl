import Foundation
import OSLog
import SwiftData

/// One-shot data helpers for WidgetKit timeline providers.
/// Follows the same SwiftData + Keychain pattern as the Share extension.
enum WidgetDataFetcher {
    private static let logger = Logger(subsystem: "com.poole.james.Trawl", category: "WidgetDataFetcher")

    enum WidgetError: LocalizedError {
        case noServerConfigured
        case noArrServicesConfigured
        case missingCredentials

        var errorDescription: String? {
            switch self {
            case .noServerConfigured: "No qBittorrent server configured."
            case .noArrServicesConfigured: "No Sonarr or Radarr services configured."
            case .missingCredentials: "Server credentials not found in keychain."
            }
        }
    }

    // MARK: - Sendable snapshots (safe to cross actor boundaries)

    struct ServerSnapshot: Sendable {
        let displayName: String
        let hostURL: String
        let allowsUntrustedTLS: Bool
        let usernameKey: String
        let passwordKey: String
        let serverID: UUID
    }

    struct ArrProfileSnapshot: Sendable {
        let hostURL: String
        let allowsUntrustedTLS: Bool
        let apiKeyKeychainKey: String
        let serviceType: ArrServiceType
    }

    // MARK: - Container

    nonisolated static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([ServerProfile.self, ArrServiceProfile.self])
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(AppGroup.identifier)
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Speed (qBittorrent)

    /// Fetches global transfer info from the specified server (or the active/first server).
    static func fetchTransferInfo(serverID: String? = nil) async throws -> (info: TransferInfo, serverName: String) {
        let container = try makeModelContainer()

        let snapshot: ServerSnapshot = try await MainActor.run {
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<ServerProfile>())
            let server: ServerProfile?
            if let serverID, let id = UUID(uuidString: serverID) {
                server = all.first(where: { $0.id == id })
                guard server != nil else { throw WidgetError.noServerConfigured }
            } else {
                server = all.first(where: { $0.isActive }) ?? all.first
            }
            guard let s = server else { throw WidgetError.noServerConfigured }
            return ServerSnapshot(
                displayName: s.displayName,
                hostURL: s.hostURL,
                allowsUntrustedTLS: s.allowsUntrustedTLS,
                usernameKey: s.usernameKey,
                passwordKey: s.passwordKey,
                serverID: s.id
            )
        }

        let username = try await KeychainHelper.shared.read(key: snapshot.usernameKey) ?? ""
        let password = try await KeychainHelper.shared.read(key: snapshot.passwordKey) ?? ""

        guard !username.isEmpty, !password.isEmpty else {
            throw WidgetError.missingCredentials
        }

        let authService = AuthService(serverProfileID: snapshot.serverID, allowsUntrustedTLS: snapshot.allowsUntrustedTLS)
        let client = QBittorrentAPIClient(
            baseURL: snapshot.hostURL,
            authService: authService,
            allowsUntrustedTLS: snapshot.allowsUntrustedTLS
        )
        try await client.login(username: username, password: password)
        return (try await client.getTransferInfo(), snapshot.displayName)
    }

    // MARK: - Calendar (Sonarr + Radarr)

    /// Fetches upcoming episodes and movie releases for the next `days` days.
    static func fetchUpcomingReleases(days: Int = 14) async throws -> [WidgetCalendarEvent] {
        let container = try makeModelContainer()

        let profiles: [ArrProfileSnapshot] = try await MainActor.run {
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<ArrServiceProfile>())
            return all
                .filter { $0.isEnabled }
                .compactMap { profile -> ArrProfileSnapshot? in
                    guard let type = profile.resolvedServiceType,
                          type == .sonarr || type == .radarr else { return nil }
                    return ArrProfileSnapshot(
                        hostURL: profile.hostURL,
                        allowsUntrustedTLS: profile.allowsUntrustedTLS,
                        apiKeyKeychainKey: profile.apiKeyKeychainKey,
                        serviceType: type
                    )
                }
        }

        guard !profiles.isEmpty else { throw WidgetError.noArrServicesConfigured }

        let apiStart = Date()
        let filterStart = Calendar.current.startOfDay(for: apiStart)
        let end = Calendar.current.date(byAdding: .day, value: days, to: apiStart) ?? apiStart
        var events: [WidgetCalendarEvent] = []

        await withTaskGroup(of: [WidgetCalendarEvent].self) { group in
            for profile in profiles {
                group.addTask { await fetchArrEvents(profile: profile, apiStart: apiStart, filterStart: filterStart, end: end) }
            }
            for await batch in group {
                events.append(contentsOf: batch)
            }
        }

        return events.sorted { $0.date < $1.date }
    }

    // MARK: - Private helpers

    private static func fetchArrEvents(
        profile: ArrProfileSnapshot,
        apiStart: Date,
        filterStart: Date,
        end: Date
    ) async -> [WidgetCalendarEvent] {
        do {
            guard let apiKey = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey),
                  !apiKey.isEmpty else {
                logger.error("Missing ARR API key for service=\(String(describing: profile.serviceType), privacy: .public) host=\(profile.hostURL, privacy: .public)")
                return []
            }

            let profileQualifier = profile.hostURL.replacingOccurrences(of: "://", with: "-").replacingOccurrences(of: "/", with: "-")

            switch profile.serviceType {
            case .sonarr:
                let client = SonarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                let episodes = try await client.getCalendar(start: apiStart, end: end, unmonitored: false, includeSeries: true)
                return episodes.compactMap { ep -> WidgetCalendarEvent? in
                    guard let date = parseISO(ep.airDateUtc) ?? parseDayDate(ep.airDate),
                          date >= filterStart else { return nil }
                    return WidgetCalendarEvent(
                        id: "ep-\(profileQualifier)-\(ep.id)",
                        date: date,
                        title: ep.series?.title ?? "Unknown Series",
                        subtitle: ep.episodeIdentifier,
                        posterURL: ep.series?.posterURL,
                        placeholderIcon: "tv",
                        accentColorName: "purple",
                        badgeLabel: nil,
                        isDownloaded: ep.hasFile == true
                    )
                }

            case .radarr:
                let client = RadarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                let movies = try await client.getCalendar(start: apiStart, end: end, unmonitored: false)
                return movies.flatMap { movie -> [WidgetCalendarEvent] in
                    let releases: [(String?, String, String)] = [
                        (movie.digitalRelease, "Digital", "blue"),
                        (movie.physicalRelease, "Physical", "indigo"),
                        (movie.inCinemas, "Cinema", "orange")
                    ]
                    return releases.compactMap { (dateStr, label, color) in
                        guard let dateStr,
                              let date = parseISO(dateStr),
                              date >= filterStart else { return nil }
                        return WidgetCalendarEvent(
                            id: "movie-\(profileQualifier)-\(movie.id)-\(label)",
                            date: date,
                            title: movie.title,
                            subtitle: movie.year.map(String.init),
                            posterURL: movie.posterURL,
                            placeholderIcon: "film",
                            accentColorName: color,
                            badgeLabel: label,
                            isDownloaded: movie.hasFile == true
                        )
                    }
                }

            case .prowlarr, .bazarr:
                return []
            }
        } catch {
            logger.error("ARR fetch failed for service=\(String(describing: profile.serviceType), privacy: .public) host=\(profile.hostURL, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Date parsing (mirrors ArrDateParser from the main app)

    private static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    private static func parseDayDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f.date(from: string)
    }
}
