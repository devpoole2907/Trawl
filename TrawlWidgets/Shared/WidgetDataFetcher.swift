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
        case noSeerrServicesConfigured
        case missingCredentials

        var errorDescription: String? {
            switch self {
            case .noServerConfigured: "No qBittorrent server configured."
            case .noArrServicesConfigured: "No Sonarr or Radarr services configured."
            case .noSeerrServicesConfigured: "No Seerr server configured."
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
        let displayName: String
        let profileID: UUID
        let hostURL: String
        let allowsUntrustedTLS: Bool
        let apiKeyKeychainKey: String
        let serviceType: ArrServiceType
    }

    struct SeerrProfileSnapshot: Sendable {
        let displayName: String
        let profileID: UUID
        let hostURL: String
        let allowsUntrustedTLS: Bool
        let sessionCookieKey: String
    }

    struct WidgetSeerrItemSnapshot: Sendable {
        let title: String
        let subtitle: String?
        let kindLabel: String
        let serverName: String
        let createdAt: Date?
    }

    struct WidgetSeerrPendingSnapshot: Sendable {
        let totalPending: Int
        let topRequest: WidgetSeerrItemSnapshot?
        let serverLabel: String
        let checkedServerCount: Int
        let errorMessage: String?
    }

    struct WidgetSeerrIssuesSnapshot: Sendable {
        let totalOpen: Int
        let topIssue: WidgetSeerrItemSnapshot?
        let serverLabel: String
        let checkedServerCount: Int
        let errorMessage: String?
    }

    struct WidgetActiveTorrentSnapshot: Sendable {
        let name: String
        let progress: Double
        let dlspeed: Int64
        let etaText: String?
        let state: String
    }

    struct WidgetActiveTorrentsSnapshot: Sendable {
        let activeCount: Int
        let topTorrent: WidgetActiveTorrentSnapshot?
        let serverName: String
        let errorMessage: String?
    }

    enum WidgetLibraryHealthSeverity: Int, Sendable {
        case notice = 1
        case warning = 2
        case error = 3

        var title: String {
            switch self {
            case .notice: "Notice"
            case .warning: "Warning"
            case .error: "Error"
            }
        }
    }

    struct WidgetLibraryHealthOffender: Sendable {
        let serviceName: String
        let serviceType: String
        let title: String
        let detail: String
        let severity: WidgetLibraryHealthSeverity
    }

    struct WidgetLibraryHealthServiceSnapshot: Sendable, Identifiable {
        var id: String { "\(serviceType)-\(serviceName)" }
        let serviceName: String
        let serviceType: String
        let healthIssueCount: Int
        let queueIssueCount: Int
        let worstOffender: WidgetLibraryHealthOffender?

        var totalIssueCount: Int { healthIssueCount + queueIssueCount }
    }

    struct WidgetLibraryHealthSnapshot: Sendable {
        let totalIssueCount: Int
        let healthIssueCount: Int
        let queueIssueCount: Int
        let worstOffender: WidgetLibraryHealthOffender?
        let services: [WidgetLibraryHealthServiceSnapshot]
        let errorMessage: String?
    }

    // MARK: - Container

    nonisolated static func makeModelContainer() throws -> ModelContainer {
        let schema = TrawlModelSchema.full
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(AppGroup.identifier)
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Speed (qBittorrent)

    /// Fetches global transfer info from the specified server (or the active/first server).
    static func fetchTransferInfo(serverID: String? = nil) async throws -> (info: TransferInfo, serverName: String) {
        let snapshot = try await fetchServerSnapshot(serverID: serverID)
        let client = try await makeQBittorrentClient(from: snapshot)
        return (try await client.getTransferInfo(), snapshot.displayName)
    }

    static func fetchActiveTorrents(serverID: String? = nil) async throws -> WidgetActiveTorrentsSnapshot {
        let snapshot = try await fetchServerSnapshot(serverID: serverID)
        let client = try await makeQBittorrentClient(from: snapshot)
        let torrents = try await client.getTorrents()
        let active = torrents
            .filter(isActiveTorrent)
            .sorted { lhs, rhs in
                if lhs.dlspeed != rhs.dlspeed { return lhs.dlspeed > rhs.dlspeed }
                if lhs.progress != rhs.progress { return lhs.progress > rhs.progress }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        let top = active.first.map { torrent in
            WidgetActiveTorrentSnapshot(
                name: torrent.name,
                progress: max(0, min(1, torrent.progress)),
                dlspeed: torrent.dlspeed,
                etaText: widgetETAText(for: torrent.eta),
                state: torrent.state.displayName
            )
        }

        return WidgetActiveTorrentsSnapshot(
            activeCount: active.count,
            topTorrent: top,
            serverName: snapshot.displayName,
            errorMessage: nil
        )
    }

    // MARK: - Seerr

    static func fetchSeerrPendingRequests(profileID: String? = nil) async throws -> WidgetSeerrPendingSnapshot {
        let profiles = try await fetchSeerrProfiles(profileID: profileID)
        var snapshots: [WidgetSeerrPendingSnapshot] = []

        await withTaskGroup(of: WidgetSeerrPendingSnapshot?.self) { group in
            for profile in profiles {
                group.addTask { await fetchSeerrPendingRequests(for: profile) }
            }

            for await snapshot in group {
                if let snapshot {
                    snapshots.append(snapshot)
                }
            }
        }

        let serverLabel = profiles.count == 1 ? profiles[0].displayName : "\(profiles.count) Servers"
        guard !snapshots.isEmpty else {
            return WidgetSeerrPendingSnapshot(
                totalPending: 0,
                topRequest: nil,
                serverLabel: serverLabel,
                checkedServerCount: 0,
                errorMessage: "Unavailable"
            )
        }

        let topRequest = snapshots
            .compactMap(\.topRequest)
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }

        return WidgetSeerrPendingSnapshot(
            totalPending: snapshots.reduce(0) { $0 + $1.totalPending },
            topRequest: topRequest,
            serverLabel: serverLabel,
            checkedServerCount: snapshots.count,
            errorMessage: nil
        )
    }

    static func fetchSeerrOpenIssues() async throws -> WidgetSeerrIssuesSnapshot {
        let profiles = try await fetchSeerrProfiles(profileID: nil)
        var snapshots: [WidgetSeerrIssuesSnapshot] = []

        await withTaskGroup(of: WidgetSeerrIssuesSnapshot?.self) { group in
            for profile in profiles {
                group.addTask { await fetchSeerrOpenIssues(for: profile) }
            }

            for await snapshot in group {
                if let snapshot {
                    snapshots.append(snapshot)
                }
            }
        }

        let serverLabel = profiles.count == 1 ? profiles[0].displayName : "\(profiles.count) Servers"
        guard !snapshots.isEmpty else {
            return WidgetSeerrIssuesSnapshot(
                totalOpen: 0,
                topIssue: nil,
                serverLabel: serverLabel,
                checkedServerCount: 0,
                errorMessage: "Unavailable"
            )
        }

        let topIssue = snapshots
            .compactMap(\.topIssue)
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }

        return WidgetSeerrIssuesSnapshot(
            totalOpen: snapshots.reduce(0) { $0 + $1.totalOpen },
            topIssue: topIssue,
            serverLabel: serverLabel,
            checkedServerCount: snapshots.count,
            errorMessage: nil
        )
    }

    // MARK: - Library health

    static func fetchLibraryHealth() async throws -> WidgetLibraryHealthSnapshot {
        let profiles = try await fetchArrProfiles(serviceTypes: [.sonarr, .radarr])
        guard !profiles.isEmpty else { throw WidgetError.noArrServicesConfigured }

        var services: [WidgetLibraryHealthServiceSnapshot] = []
        await withTaskGroup(of: WidgetLibraryHealthServiceSnapshot.self) { group in
            for profile in profiles {
                group.addTask { await fetchArrLibraryHealth(for: profile) }
            }

            for await service in group {
                services.append(service)
            }
        }

        services.sort { lhs, rhs in
            if lhs.totalIssueCount != rhs.totalIssueCount { return lhs.totalIssueCount > rhs.totalIssueCount }
            return lhs.serviceName.localizedCaseInsensitiveCompare(rhs.serviceName) == .orderedAscending
        }

        let worstOffender = services
            .compactMap(\.worstOffender)
            .max { lhs, rhs in
                if lhs.severity.rawValue != rhs.severity.rawValue {
                    return lhs.severity.rawValue < rhs.severity.rawValue
                }
                return lhs.serviceName.localizedCaseInsensitiveCompare(rhs.serviceName) == .orderedDescending
            }

        let healthIssueCount = services.reduce(0) { $0 + $1.healthIssueCount }
        let queueIssueCount = services.reduce(0) { $0 + $1.queueIssueCount }

        return WidgetLibraryHealthSnapshot(
            totalIssueCount: healthIssueCount + queueIssueCount,
            healthIssueCount: healthIssueCount,
            queueIssueCount: queueIssueCount,
            worstOffender: worstOffender,
            services: services,
            errorMessage: nil
        )
    }

    // MARK: - Calendar (Sonarr + Radarr)

    /// Fetches upcoming episodes and movie releases for the next `days` days.
    static func fetchUpcomingReleases(days: Int = 14) async throws -> [WidgetCalendarEvent] {
        let profiles = try await fetchArrProfiles(serviceTypes: [.sonarr, .radarr])

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

    private static func fetchServerSnapshot(serverID: String? = nil) async throws -> ServerSnapshot {
        let container = try makeModelContainer()

        return try await MainActor.run {
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
    }

    private static func makeQBittorrentClient(from snapshot: ServerSnapshot) async throws -> QBittorrentAPIClient {
        let username = try await KeychainHelper.shared.read(key: snapshot.usernameKey) ?? ""
        let password = try await KeychainHelper.shared.read(key: snapshot.passwordKey) ?? ""

        guard !username.isEmpty, !password.isEmpty else {
            throw WidgetError.missingCredentials
        }

        return try await QBittorrentClientFactory.makeAndLogin(
            baseURL: snapshot.hostURL,
            serverProfileID: snapshot.serverID,
            allowsUntrustedTLS: snapshot.allowsUntrustedTLS,
            username: username,
            password: password
        )
    }

    private static func fetchArrProfiles(serviceTypes: Set<ArrServiceType>) async throws -> [ArrProfileSnapshot] {
        let container = try makeModelContainer()

        return try await MainActor.run {
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<ArrServiceProfile>())
            let enabled = all.filter(\.isEnabled)
            let candidates = enabled.isEmpty ? all : enabled

            return candidates
                .compactMap { profile -> ArrProfileSnapshot? in
                    guard let type = profile.resolvedServiceType,
                          serviceTypes.contains(type) else { return nil }
                    return ArrProfileSnapshot(
                        displayName: profile.displayName,
                        profileID: profile.id,
                        hostURL: profile.hostURL,
                        allowsUntrustedTLS: profile.allowsUntrustedTLS,
                        apiKeyKeychainKey: profile.apiKeyKeychainKey,
                        serviceType: type
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.serviceType.rawValue != rhs.serviceType.rawValue {
                        return lhs.serviceType.rawValue < rhs.serviceType.rawValue
                    }
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }
        }
    }

    private static func fetchSeerrProfiles(profileID: String?) async throws -> [SeerrProfileSnapshot] {
        let container = try makeModelContainer()

        return try await MainActor.run {
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<SeerrServiceProfile>())

            let candidates: [SeerrServiceProfile]
            if let profileID, let id = UUID(uuidString: profileID) {
                candidates = all.filter { $0.id == id }
            } else {
                let enabled = all.filter(\.isEnabled)
                candidates = enabled.isEmpty ? all : enabled
            }

            let snapshots = candidates
                .map { profile in
                    SeerrProfileSnapshot(
                        displayName: profile.displayName,
                        profileID: profile.id,
                        hostURL: profile.hostURL,
                        allowsUntrustedTLS: profile.allowsUntrustedTLS,
                        sessionCookieKey: profile.sessionCookieKey
                    )
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            guard !snapshots.isEmpty else { throw WidgetError.noSeerrServicesConfigured }
            return snapshots
        }
    }

    private static func makeSeerrClient(from profile: SeerrProfileSnapshot) async throws -> WidgetSeerrAPIClient {
        guard let cookie = try await KeychainHelper.shared.read(key: profile.sessionCookieKey),
              !cookie.isEmpty else {
            throw WidgetError.missingCredentials
        }

        let client = WidgetSeerrAPIClient(
            baseURL: profile.hostURL,
            sessionCookie: cookie,
            allowsUntrustedTLS: profile.allowsUntrustedTLS
        )
        let cookieKey = profile.sessionCookieKey
        await client.setCookieUpdateHandler { updated in
            Task.detached {
                try? await KeychainHelper.shared.save(key: cookieKey, value: updated)
            }
        }
        return client
    }

    private static func fetchSeerrPendingRequests(for profile: SeerrProfileSnapshot) async -> WidgetSeerrPendingSnapshot? {
        do {
            let client = try await makeSeerrClient(from: profile)
            async let count: WidgetSeerrRequestCount = client.getRequestCount()
            async let list: WidgetSeerrRequestListResponse = client.getRequests(take: 1, skip: 0, filter: "pending", sort: "added", sortDirection: "desc")
            let (requestCount, requestList) = try await (count, list)
            let totalPending = requestCount.pending ?? requestList.pageInfo.results ?? requestList.results.count
            let topRequest = requestList.results.first.map { request in
                let title = request.media?.displayTitle ?? "Request \(request.id)"
                let subtitle = request.requestedBy.map { "by \($0.displayName)" }
                let kindLabel = request.media?.typeLabel ?? (request.is4k == true ? "4K" : "Request")
                let createdAt = parseISO(request.createdAt)

                return WidgetSeerrItemSnapshot(
                    title: title,
                    subtitle: subtitle,
                    kindLabel: kindLabel,
                    serverName: profile.displayName,
                    createdAt: createdAt
                )
            }

            return WidgetSeerrPendingSnapshot(
                totalPending: totalPending,
                topRequest: topRequest,
                serverLabel: profile.displayName,
                checkedServerCount: 1,
                errorMessage: nil
            )
        } catch {
            logger.error("Seerr pending request fetch failed for host=\(profile.hostURL, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func fetchSeerrOpenIssues(for profile: SeerrProfileSnapshot) async -> WidgetSeerrIssuesSnapshot? {
        do {
            let client = try await makeSeerrClient(from: profile)
            let issueList = try await client.getIssues(take: 1, skip: 0, sort: "added", filter: "open")
            let topIssue = issueList.results.first.map { issue in
                WidgetSeerrItemSnapshot(
                    title: issue.media?.displayTitle ?? "Issue \(issue.id)",
                    subtitle: issue.createdBy.map { "by \($0.displayName)" },
                    kindLabel: issue.issueKindLabel,
                    serverName: profile.displayName,
                    createdAt: parseISO(issue.createdAt)
                )
            }

            return WidgetSeerrIssuesSnapshot(
                totalOpen: issueList.pageInfo.results ?? issueList.results.count,
                topIssue: topIssue,
                serverLabel: profile.displayName,
                checkedServerCount: 1,
                errorMessage: nil
            )
        } catch {
            logger.error("Seerr issue fetch failed for host=\(profile.hostURL, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func fetchArrLibraryHealth(for profile: ArrProfileSnapshot) async -> WidgetLibraryHealthServiceSnapshot {
        do {
            guard let apiKey = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey),
                  !apiKey.isEmpty else {
                throw WidgetError.missingCredentials
            }

            switch profile.serviceType {
            case .sonarr:
                let client = SonarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                return await fetchArrLibraryHealth(profile: profile, client: client)

            case .radarr:
                let client = RadarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                return await fetchArrLibraryHealth(profile: profile, client: client)

            case .prowlarr, .bazarr:
                return WidgetLibraryHealthServiceSnapshot(
                    serviceName: profile.displayName,
                    serviceType: profile.serviceType.displayName,
                    healthIssueCount: 0,
                    queueIssueCount: 0,
                    worstOffender: nil
                )
            }
        } catch {
            let offender = WidgetLibraryHealthOffender(
                serviceName: profile.displayName,
                serviceType: profile.serviceType.displayName,
                title: "\(profile.serviceType.displayName) Unavailable",
                detail: error.localizedDescription,
                severity: .error
            )
            return WidgetLibraryHealthServiceSnapshot(
                serviceName: profile.displayName,
                serviceType: profile.serviceType.displayName,
                healthIssueCount: 1,
                queueIssueCount: 0,
                worstOffender: offender
            )
        }
    }

    private static func fetchArrLibraryHealth<Client: SharedArrClient>(
        profile: ArrProfileSnapshot,
        client: Client
    ) async -> WidgetLibraryHealthServiceSnapshot {
        do {
            async let healthChecks = client.getHealth()
            async let queuePage = client.getQueue(page: 1, pageSize: 100)
            let (checks, queue) = try await (healthChecks, queuePage)

            let relevantChecks = checks.filter(isRelevantHealthCheck)
            let queueIssues = (queue.records ?? []).filter(\.isImportIssueQueueItem)

            var offenders: [WidgetLibraryHealthOffender] = relevantChecks.map { check in
                WidgetLibraryHealthOffender(
                    serviceName: profile.displayName,
                    serviceType: profile.serviceType.displayName,
                    title: check.source ?? "\(profile.serviceType.displayName) Health",
                    detail: check.message ?? "Health issue",
                    severity: healthSeverity(for: check)
                )
            }

            offenders.append(contentsOf: queueIssues.map { item in
                WidgetLibraryHealthOffender(
                    serviceName: profile.displayName,
                    serviceType: profile.serviceType.displayName,
                    title: item.title ?? "Queue Item",
                    detail: item.primaryStatusMessage ?? item.trackedDownloadState ?? item.status ?? "Queue issue",
                    severity: queueSeverity(for: item)
                )
            })

            let worst = offenders.max { lhs, rhs in
                if lhs.severity.rawValue != rhs.severity.rawValue {
                    return lhs.severity.rawValue < rhs.severity.rawValue
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }

            return WidgetLibraryHealthServiceSnapshot(
                serviceName: profile.displayName,
                serviceType: profile.serviceType.displayName,
                healthIssueCount: relevantChecks.count,
                queueIssueCount: queueIssues.count,
                worstOffender: worst
            )
        } catch {
            let offender = WidgetLibraryHealthOffender(
                serviceName: profile.displayName,
                serviceType: profile.serviceType.displayName,
                title: "\(profile.serviceType.displayName) Unavailable",
                detail: error.localizedDescription,
                severity: .error
            )
            return WidgetLibraryHealthServiceSnapshot(
                serviceName: profile.displayName,
                serviceType: profile.serviceType.displayName,
                healthIssueCount: 1,
                queueIssueCount: 0,
                worstOffender: offender
            )
        }
    }

    private static func isActiveTorrent(_ torrent: Torrent) -> Bool {
        switch torrent.state {
        case .downloading, .forcedDL, .metaDL, .stalledDL, .queuedDL, .checkingDL, .allocating, .moving:
            true
        case .uploading, .forcedUP, .stalledUP, .queuedUP, .checkingUP, .pausedDL, .pausedUP,
             .stoppedDL, .stoppedUP, .error, .missingFiles, .checkingResumeData, .unknown:
            torrent.dlspeed > 0
        }
    }

    private static func widgetETAText(for seconds: Int) -> String? {
        guard seconds > 0, seconds < 8_640_000 else { return nil }
        return ByteFormatter.formatETA(seconds: seconds)
    }

    private static func isRelevantHealthCheck(_ check: ArrHealthCheck) -> Bool {
        let type = check.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type.isEmpty {
            return check.message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return type != "ok"
    }

    private static func healthSeverity(for check: ArrHealthCheck) -> WidgetLibraryHealthSeverity {
        switch check.type?.lowercased() {
        case "error":
            .error
        case "notice":
            .notice
        default:
            .warning
        }
    }

    private static func queueSeverity(for item: ArrQueueItem) -> WidgetLibraryHealthSeverity {
        let status = item.trackedDownloadStatus?.lowercased()
        let state = item.normalizedState
        if status == "error" || state == "failedpending" {
            return .error
        }
        return .warning
    }

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
