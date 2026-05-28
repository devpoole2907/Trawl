import Foundation
import Observation
import SwiftData
import SwiftUI

// MARK: - Instance Entry Types

struct ArrClientEntry<Client: SharedArrClient>: Identifiable {
    let id: UUID
    let displayName: String
    var client: Client?
    var isConnected: Bool = false
    var isConnecting: Bool = false
    var connectionError: String?
    var qualityProfiles: [ArrQualityProfile] = []
    var rootFolders: [ArrRootFolder] = []
    var tags: [ArrTag] = []

    init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

typealias SonarrClientEntry = ArrClientEntry<SonarrAPIClient>
typealias RadarrClientEntry = ArrClientEntry<RadarrAPIClient>

struct BazarrClientEntry: Identifiable {
    let id: UUID
    let displayName: String
    var client: BazarrAPIClient?
    var isConnected: Bool = false
    var isConnecting: Bool = false
    var connectionError: String?
    var languageProfiles: [BazarrLanguageProfile] = []
    var languages: [BazarrLanguage] = []
    var cachedSeries: [BazarrSeries] = []
    var cachedMovies: [BazarrMovie] = []

    init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

enum ArrNotificationSetupStatus: Sendable {
    case notAdded
    case needsUpdate
    case configured
}

// MARK: - Service Manager

/// Central coordinator for all configured *arr services.
/// Holds active API clients and provides unified access to Sonarr/Radarr data.
@MainActor
@Observable
final class ArrServiceManager {

    // MARK: - Sonarr (multi-instance)
    private(set) var sonarrInstances: [SonarrClientEntry] = []
    private(set) var activeSonarrProfileID: UUID?

    // MARK: - Radarr (multi-instance)
    private(set) var radarrInstances: [RadarrClientEntry] = []
    private(set) var activeRadarrProfileID: UUID?

    // MARK: - Prowlarr (single instance)
    private(set) var prowlarrClient: ProwlarrAPIClient?
    private(set) var activeProwlarrProfileID: UUID?
    private(set) var prowlarrConnected: Bool = false
    private(set) var prowlarrIsConnecting: Bool = false
    private(set) var prowlarrConnectionError: String?
    private(set) var prowlarrTags: [ArrTag] = []

    // MARK: - Bazarr (multi-instance)
    private(set) var bazarrInstances: [BazarrClientEntry] = []
    private(set) var activeBazarrProfileID: UUID?

    // MARK: - Global state
    private(set) var isInitializing: Bool = false
    private(set) var connectionErrors: [String: String] = [:]
    private var storedProfiles: [ArrServiceProfile] = []

    // MARK: - Cached health & blocklist (populated eagerly so nav subtitles are ready)
    private(set) var sonarrHealthChecks: [ArrHealthCheck] = []
    private(set) var radarrHealthChecks: [ArrHealthCheck] = []
    private(set) var prowlarrHealthChecks: [ArrHealthCheck] = []
    private(set) var sonarrBlocklist: [ArrBlocklistItem] = []
    private(set) var radarrBlocklist: [ArrBlocklistItem] = []
    private(set) var sonarrImportListExclusions: [ArrImportListExclusion] = []
    private(set) var radarrImportListExclusions: [ArrImportListExclusion] = []
    private(set) var isLoadingHealth = false
    private(set) var isLoadingBlocklist = false
    private(set) var isLoadingImportListExclusions = false
    private(set) var blocklistError: String?
    private(set) var importListExclusionsError: String?

    // MARK: - Persistent ViewModels
    public private(set) var calendarViewModel: ArrCalendarViewModel!
    
    init() {
        self.calendarViewModel = ArrCalendarViewModel(serviceManager: self)
    }

    // MARK: - Active entry helpers

    var activeSonarrEntry: SonarrClientEntry? {
        if let id = activeSonarrProfileID, let entry = sonarrInstances.first(where: { $0.id == id }) {
            return entry
        }
        return sonarrInstances.first { $0.isConnected } ?? sonarrInstances.first
    }

    var activeRadarrEntry: RadarrClientEntry? {
        if let id = activeRadarrProfileID, let entry = radarrInstances.first(where: { $0.id == id }) {
            return entry
        }
        return radarrInstances.first { $0.isConnected } ?? radarrInstances.first
    }

    var hasProwlarrInstance: Bool { storedProfiles.contains { $0.resolvedServiceType == .prowlarr && $0.isEnabled } }
    var hasSonarrInstance: Bool { !sonarrInstances.isEmpty }
    var hasRadarrInstance: Bool { !radarrInstances.isEmpty }
    var hasAnyConnectedSonarrInstance: Bool { sonarrInstances.contains { $0.isConnected } }
    var hasAnyConnectedRadarrInstance: Bool { radarrInstances.contains { $0.isConnected } }
    var hasAnyConnectedProwlarrInstance: Bool { prowlarrConnected }

    var hasBazarrInstance: Bool { !bazarrInstances.isEmpty }
    var hasAnyConnectedBazarrInstance: Bool { bazarrInstances.contains { $0.isConnected } }
    var bazarrConnectionError: String? {
        activeBazarrEntry?.connectionError ?? bazarrInstances.first?.connectionError
    }

    func sonarrClient(for profileID: UUID) -> SonarrAPIClient? {
        sonarrInstances.first(where: { $0.id == profileID })?.client
    }

    func radarrClient(for profileID: UUID) -> RadarrAPIClient? {
        radarrInstances.first(where: { $0.id == profileID })?.client
    }

    func bazarrClient(for profileID: UUID) -> BazarrAPIClient? {
        bazarrInstances.first(where: { $0.id == profileID })?.client
    }

    func iCalFeedLinks() async throws -> [ArrICalFeedLink] {
        var links: [ArrICalFeedLink] = []

        if let entry = activeSonarrEntry, entry.isConnected, let client = entry.client {
            let url = try await client.iCalFeedURL()
            links.append(try ArrICalFeedLink(
                serviceType: .sonarr,
                profileID: entry.id,
                displayName: entry.displayName,
                url: url,
                webcalURL: client.webcalURL(from: url)
            ))
        }

        if let entry = activeRadarrEntry, entry.isConnected, let client = entry.client {
            let url = try await client.iCalFeedURL()
            links.append(try ArrICalFeedLink(
                serviceType: .radarr,
                profileID: entry.id,
                displayName: entry.displayName,
                url: url,
                webcalURL: client.webcalURL(from: url)
            ))
        }

        if links.isEmpty {
            throw ArrError.noServiceConfigured
        }

        return links
    }

    func iCalFeedLink(for serviceType: ArrServiceType) async throws -> ArrICalFeedLink {
        switch serviceType {
        case .sonarr:
            guard let entry = activeSonarrEntry, entry.isConnected, let client = entry.client else {
                throw ArrError.noServiceConfigured
            }
            let url = try await client.iCalFeedURL()
            return try ArrICalFeedLink(
                serviceType: .sonarr,
                profileID: entry.id,
                displayName: entry.displayName,
                url: url,
                webcalURL: client.webcalURL(from: url)
            )
        case .radarr:
            guard let entry = activeRadarrEntry, entry.isConnected, let client = entry.client else {
                throw ArrError.noServiceConfigured
            }
            let url = try await client.iCalFeedURL()
            return try ArrICalFeedLink(
                serviceType: .radarr,
                profileID: entry.id,
                displayName: entry.displayName,
                url: url,
                webcalURL: client.webcalURL(from: url)
            )
        case .prowlarr, .bazarr:
            throw ArrError.noServiceConfigured
        }
    }

    func isConnected(_ serviceType: ArrServiceType) -> Bool {
        switch serviceType {
        case .sonarr: return sonarrConnected
        case .radarr: return radarrConnected
        case .prowlarr: return prowlarrConnected
        case .bazarr: return activeBazarrEntry?.isConnected ?? false
        }
    }

    func isConnecting(_ serviceType: ArrServiceType) -> Bool {
        switch serviceType {
        case .sonarr: return sonarrIsConnecting
        case .radarr: return radarrIsConnecting
        case .prowlarr: return prowlarrIsConnecting
        case .bazarr: return activeBazarrEntry?.isConnecting ?? false
        }
    }

    func connectionError(_ serviceType: ArrServiceType) -> String? {
        switch serviceType {
        case .sonarr: return sonarrConnectionError
        case .radarr: return radarrConnectionError
        case .prowlarr: return prowlarrConnectionError
        case .bazarr: return bazarrConnectionError
        }
    }

    func activeInstanceID(_ serviceType: ArrServiceType) -> UUID? {
        switch serviceType {
        case .sonarr: return activeSonarrInstanceID
        case .radarr: return activeRadarrInstanceID
        case .prowlarr: return activeProwlarrProfileID
        case .bazarr: return activeBazarrProfileID
        }
    }

    func isConnected(_ serviceType: ArrServiceType, profileID: UUID) -> Bool {

        switch serviceType {
        case .sonarr:
            sonarrInstances.first(where: { $0.id == profileID })?.isConnected ?? false
        case .radarr:
            radarrInstances.first(where: { $0.id == profileID })?.isConnected ?? false
        case .prowlarr:
            activeProwlarrProfileID == profileID && prowlarrConnected
        case .bazarr:
            bazarrInstances.first(where: { $0.id == profileID })?.isConnected ?? false
        }
    }

    var activeBazarrEntry: BazarrClientEntry? {
        if let id = activeBazarrProfileID, let entry = bazarrInstances.first(where: { $0.id == id }) {
            return entry
        }
        return bazarrInstances.first { $0.isConnected } ?? bazarrInstances.first
    }

    func resolvedProfile(
        for serviceType: ArrServiceType,
        in profiles: [ArrServiceProfile],
        allowErroredFallback: Bool = true
    ) -> ArrServiceProfile? {
        let activeID: UUID? = {
            switch serviceType {
            case .sonarr: return activeSonarrInstanceID
            case .radarr: return activeRadarrInstanceID
            case .prowlarr: return activeProwlarrProfileID
            case .bazarr: return activeBazarrProfileID
            }
        }()

        if let activeID, let activeProfile = profiles.first(where: { $0.id == activeID }) {
            let activeHasError = connectionErrors[activeProfile.id.uuidString] != nil
            if allowErroredFallback || !activeHasError {
                return activeProfile
            }
        }

        let matches = profiles.filter { $0.resolvedServiceType == serviceType && $0.isEnabled }
        if let connectedMatch = matches.first(where: { connectionErrors[$0.id.uuidString] == nil }) {
            return connectedMatch
        }

        guard allowErroredFallback else { return nil }
        return matches.sorted { $0.dateAdded > $1.dateAdded }.first
    }

    func resolvedProfile(
        for serviceType: ArrServiceType,
        allowErroredFallback: Bool = true
    ) -> ArrServiceProfile? {
        resolvedProfile(
            for: serviceType,
            in: storedProfiles,
            allowErroredFallback: allowErroredFallback
        )
    }

    func setupNotifications(for profile: ArrServiceProfile, workerURL: String, deviceToken: String) async throws {
        let client = try notificationClient(for: profile)
        let notificationName = notificationName(for: profile)
        let pushURL = try pushNotificationURL(from: workerURL)
        let notifications = try await client.getNotifications()
        let existing = notifications.first { $0.name == notificationName }
        let serviceType = profile.resolvedServiceType

        if let existing, trawlNotificationMatches(existing, pushURL: pushURL, deviceToken: deviceToken, serviceType: serviceType) {
            return
        }

        let isSonarr = serviceType == .sonarr
        let isRadarr = serviceType == .radarr
        let isProwlarr = serviceType == .prowlarr

        let newNotification = ArrNotification(
            id: existing?.id,
            name: notificationName,
            onGrab: isProwlarr ? nil : true,
            onDownload: isProwlarr ? nil : true,
            onUpgrade: isProwlarr ? nil : true,
            onRename: isProwlarr ? nil : true,
            onHealthIssue: true,
            onApplicationUpdate: true,
            onSeriesAdd: isSonarr ? false : nil,
            onSeriesDelete: isSonarr ? false : nil,
            onEpisodeFileDelete: isSonarr ? false : nil,
            onEpisodeFileDeleteForUpgrade: isSonarr ? false : nil,
            onMovieAdded: isRadarr ? false : nil,
            onMovieDelete: isRadarr ? false : nil,
            onMovieFileDelete: isRadarr ? false : nil,
            onMovieFileDeleteForUpgrade: isRadarr ? false : nil,
            includeHealthWarnings: true,
            implementation: "Webhook",
            configContract: "WebhookSettings",
            fields: notificationFields(pushURL: pushURL, deviceToken: deviceToken, serviceType: serviceType),
            tags: []
        )

        #if DEBUG
        if let encoded = try? JSONEncoder().encode(newNotification),
           var jsonString = String(data: encoded, encoding: .utf8) {
            jsonString = jsonString.replacingOccurrences(of: deviceToken, with: "[REDACTED]")
            print("--- Trawl Notification Payload (Redacted) ---")
            print(jsonString)
            print("---------------------------------------------")
        }
        #endif

        if existing != nil {
            _ = try await client.updateNotification(newNotification)
        } else {
            _ = try await client.createNotification(newNotification)
        }
    }

    func notificationSetupStatus(
        for profile: ArrServiceProfile,
        workerURL: String,
        deviceToken: String
    ) async throws -> ArrNotificationSetupStatus {
        let client = try notificationClient(for: profile)
        let notificationName = notificationName(for: profile)
        let pushURL = try pushNotificationURL(from: workerURL)
        let notifications = try await client.getNotifications()

        guard let existing = notifications.first(where: { $0.name == notificationName }) else {
            return .notAdded
        }

        return trawlNotificationMatches(existing, pushURL: pushURL, deviceToken: deviceToken, serviceType: profile.resolvedServiceType)
            ? .configured
            : .needsUpdate
    }

    func trawlNotification(
        for profile: ArrServiceProfile,
        workerURL: String,
        deviceToken: String
    ) async throws -> ArrNotification {
        let client = try notificationClient(for: profile)
        let notificationName = notificationName(for: profile)
        let pushURL = try pushNotificationURL(from: workerURL)
        let notifications = try await client.getNotifications()
        let existing = notifications.first { $0.name == notificationName }
        return notificationPayload(
            existing: existing,
            profile: profile,
            pushURL: pushURL,
            deviceToken: deviceToken
        )
    }

    func saveTrawlNotification(
        _ notification: ArrNotification,
        for profile: ArrServiceProfile,
        workerURL: String,
        deviceToken: String
    ) async throws {
        let client = try notificationClient(for: profile)
        let pushURL = try pushNotificationURL(from: workerURL)
        let payload = notificationPayload(
            existing: notification,
            profile: profile,
            pushURL: pushURL,
            deviceToken: deviceToken
        )

        if payload.id == nil {
            _ = try await client.createNotification(payload)
        } else {
            _ = try await client.updateNotification(payload)
        }
    }

    func testTrawlNotification(
        _ notification: ArrNotification,
        for profile: ArrServiceProfile,
        workerURL: String,
        deviceToken: String
    ) async throws {
        let client = try notificationClient(for: profile)
        let pushURL = try pushNotificationURL(from: workerURL)
        let payload = notificationPayload(
            existing: notification,
            profile: profile,
            pushURL: pushURL,
            deviceToken: deviceToken
        )
        try await client.testNotification(payload)
    }

    func trawlNotificationSendsGrab(
        for profile: ArrServiceProfile,
        workerURL: String,
        deviceToken: String
    ) async throws -> Bool {
        let client = try notificationClient(for: profile)
        let notificationName = notificationName(for: profile)
        let pushURL = try pushNotificationURL(from: workerURL)
        let notifications = try await client.getNotifications()

        guard let existing = notifications.first(where: { $0.name == notificationName }) else {
            return false
        }

        return trawlNotificationMatches(existing, pushURL: pushURL, deviceToken: deviceToken, serviceType: profile.resolvedServiceType) && existing.onGrab == true
    }

    func tags(for profile: ArrServiceProfile) -> [ArrTag] {
        guard let serviceType = profile.resolvedServiceType else { return [] }

        switch serviceType {
        case .sonarr:
            return sonarrInstances.first(where: { $0.id == profile.id })?.tags ?? []
        case .radarr:
            return radarrInstances.first(where: { $0.id == profile.id })?.tags ?? []
        case .prowlarr:
            return prowlarrTags
        case .bazarr:
            return []
        }
    }

    // MARK: - Backward-compatible Sonarr computed properties

    var sonarrClient: SonarrAPIClient? { activeSonarrEntry?.client }
    var sonarrConnected: Bool { activeSonarrEntry?.isConnected ?? false }
    var sonarrIsConnecting: Bool {
        activeSonarrEntry?.isConnecting ?? sonarrInstances.contains { $0.isConnecting }
    }
    var sonarrConnectionError: String? {
        activeSonarrEntry?.connectionError ?? sonarrInstances.first?.connectionError
    }
    var sonarrQualityProfiles: [ArrQualityProfile] { activeSonarrEntry?.qualityProfiles ?? [] }
    var sonarrRootFolders: [ArrRootFolder] { activeSonarrEntry?.rootFolders ?? [] }
    var sonarrTags: [ArrTag] { activeSonarrEntry?.tags ?? [] }

    /// ID of the active Sonarr instance — use as `.task(id:)` trigger for view model recreation
    var activeSonarrInstanceID: UUID? { activeSonarrEntry?.id }

    // MARK: - Backward-compatible Radarr computed properties

    var radarrClient: RadarrAPIClient? { activeRadarrEntry?.client }
    var radarrConnected: Bool { activeRadarrEntry?.isConnected ?? false }
    var radarrIsConnecting: Bool {
        activeRadarrEntry?.isConnecting ?? radarrInstances.contains { $0.isConnecting }
    }
    var radarrConnectionError: String? {
        activeRadarrEntry?.connectionError ?? radarrInstances.first?.connectionError
    }
    var radarrQualityProfiles: [ArrQualityProfile] { activeRadarrEntry?.qualityProfiles ?? [] }
    var radarrRootFolders: [ArrRootFolder] { activeRadarrEntry?.rootFolders ?? [] }
    var radarrTags: [ArrTag] { activeRadarrEntry?.tags ?? [] }

    /// ID of the active Radarr instance — use as `.task(id:)` trigger for view model recreation
    var activeRadarrInstanceID: UUID? { activeRadarrEntry?.id }

    // MARK: - Instance switching

    func setActiveSonarr(_ profileID: UUID) {
        withAnimation(.snappy) {
            activeSonarrProfileID = profileID
        }
    }

    func setActiveRadarr(_ profileID: UUID) {
        withAnimation(.snappy) {
            activeRadarrProfileID = profileID
        }
    }

    func setActiveBazarr(_ profileID: UUID) {
        withAnimation(.snappy) {
            activeBazarrProfileID = profileID
        }
    }

    // MARK: - Initialization

    func initialize(from profiles: [ArrServiceProfile]) async {
        storedProfiles = profiles
        isInitializing = true
        defer { isInitializing = false }
        disconnectAll()

        // Pre-build instance placeholders so connecting state is visible immediately
        withAnimation(.snappy) {
            sonarrInstances = profiles
                .filter { $0.resolvedServiceType == .sonarr && $0.isEnabled }
                .map { SonarrClientEntry(id: $0.id, displayName: $0.displayName) }
            radarrInstances = profiles
                .filter { $0.resolvedServiceType == .radarr && $0.isEnabled }
                .map { RadarrClientEntry(id: $0.id, displayName: $0.displayName) }
            bazarrInstances = profiles
                .filter { $0.resolvedServiceType == .bazarr && $0.isEnabled }
                .map { BazarrClientEntry(id: $0.id, displayName: $0.displayName) }
        }

        for profile in profiles where profile.isEnabled {
            await connectService(profile)
        }
        
        await calendarViewModel.initialize()

        // Prefetch health and blocklist so nav subtitles are populated immediately on first navigation
        Task {
            async let h: Void = loadHealth()
            async let b: Void = loadBlocklist()
            _ = await (h, b)
        }
    }

    func syncProfiles(_ profiles: [ArrServiceProfile]) {
        storedProfiles = profiles
    }

    /// Retry connecting a specific service type using the last known profiles.
    func retry(_ serviceType: ArrServiceType) async {
        let profiles = storedProfiles.filter { $0.resolvedServiceType == serviceType && $0.isEnabled }
        for profile in profiles {
            await connectService(profile)
        }
    }

    /// Retry only services that are configured but not currently connected or connecting.
    /// Safe to call on foreground return — does not reset already-connected services.
    func retryDisconnected() async {
        guard !isInitializing else { return }
        for serviceType in ArrServiceType.allCases {
            guard !isConnected(serviceType), !isConnecting(serviceType) else { continue }
            let profiles = storedProfiles.filter { $0.resolvedServiceType == serviceType && $0.isEnabled }
            guard !profiles.isEmpty else { continue }
            for profile in profiles {
                await connectService(profile)
            }
        }
    }

    /// Connect a single service profile.
    func connectService(_ profile: ArrServiceProfile) async {
        guard let serviceType = profile.resolvedServiceType else {
            connectionErrors[profile.id.uuidString] = "Invalid service type: \(profile.serviceType)"
            return
        }

        setConnecting(true, for: serviceType, id: profile.id)
        defer { setConnecting(false, for: serviceType, id: profile.id) }

        do {
            guard let apiKey = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey),
                  !apiKey.isEmpty else {
                let msg = "API key not found in Keychain."
                connectionErrors[profile.id.uuidString] = msg
                setError(msg, for: serviceType, id: profile.id)
                return
            }

            switch serviceType {
            case .sonarr:
                let client = SonarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                _ = try await client.getSystemStatus()
                async let qp = client.getQualityProfiles()
                async let rf = client.getRootFolders()
                async let t = client.getTags()
                let (fetchedProfiles, folders, fetchedTags) = try await (qp, rf, t)

                if sonarrInstances.contains(where: { $0.id == profile.id }) {
                    updateEntry(in: &sonarrInstances, id: profile.id) { entry in
                        entry.client = client
                        entry.isConnected = true
                        entry.connectionError = nil
                        entry.qualityProfiles = fetchedProfiles
                        entry.rootFolders = folders
                        entry.tags = fetchedTags
                    }
                } else {
                    // Profile was added after initialization
                    var entry = SonarrClientEntry(id: profile.id, displayName: profile.displayName)
                    entry.client = client
                    entry.isConnected = true
                    entry.qualityProfiles = fetchedProfiles
                    entry.rootFolders = folders
                    entry.tags = fetchedTags
                    withAnimation(.snappy) {
                        sonarrInstances.append(entry)
                    }
                }
                if activeSonarrProfileID == nil {
                    withAnimation(.snappy) {
                        activeSonarrProfileID = profile.id
                    }
                }
                connectionErrors.removeValue(forKey: profile.id.uuidString)

            case .radarr:
                let client = RadarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                _ = try await client.getSystemStatus()
                async let qp = client.getQualityProfiles()
                async let rf = client.getRootFolders()
                async let t = client.getTags()
                let (fetchedProfiles, folders, fetchedTags) = try await (qp, rf, t)

                if radarrInstances.contains(where: { $0.id == profile.id }) {
                    updateEntry(in: &radarrInstances, id: profile.id) { entry in
                        entry.client = client
                        entry.isConnected = true
                        entry.connectionError = nil
                        entry.qualityProfiles = fetchedProfiles
                        entry.rootFolders = folders
                        entry.tags = fetchedTags
                    }
                } else {
                    var entry = RadarrClientEntry(id: profile.id, displayName: profile.displayName)
                    entry.client = client
                    entry.isConnected = true
                    entry.qualityProfiles = fetchedProfiles
                    entry.rootFolders = folders
                    entry.tags = fetchedTags
                    withAnimation(.snappy) {
                        radarrInstances.append(entry)
                    }
                }
                if activeRadarrProfileID == nil {
                    withAnimation(.snappy) {
                        activeRadarrProfileID = profile.id
                    }
                }
                connectionErrors.removeValue(forKey: profile.id.uuidString)

            case .prowlarr:
                let client = ProwlarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                _ = try await client.getSystemStatus()
                let fetchedTags = (try? await client.getTags()) ?? []
                if activeProwlarrProfileID == nil || activeProwlarrProfileID == profile.id {
                    withAnimation(.snappy) {
                        prowlarrClient = client
                        activeProwlarrProfileID = profile.id
                        prowlarrConnected = true
                        prowlarrConnectionError = nil
                        prowlarrTags = fetchedTags
                    }
                }
                connectionErrors.removeValue(forKey: profile.id.uuidString)

            case .bazarr:
                let client = BazarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                _ = try await client.getSystemStatus()
                async let lp = client.getLanguageProfiles()
                async let lang = client.getLanguages()
                let (profiles, languages) = try await (lp, lang)

                if bazarrInstances.contains(where: { $0.id == profile.id }) { updateEntry(in: &bazarrInstances, id: profile.id) { entry in
                        entry.client = client
                        entry.isConnected = true
                        entry.connectionError = nil
                        entry.languageProfiles = profiles
                        entry.languages = languages
                    }
                } else {
                    var entry = BazarrClientEntry(id: profile.id, displayName: profile.displayName)
                    entry.client = client
                    entry.isConnected = true
                    entry.languageProfiles = profiles
                    entry.languages = languages
                    withAnimation(.snappy) {
                        bazarrInstances.append(entry)
                    }
                }
                if activeBazarrProfileID == nil {
                    withAnimation(.snappy) {
                        activeBazarrProfileID = profile.id
                    }
                }
                connectionErrors.removeValue(forKey: profile.id.uuidString)
                Task { await refreshBazarrSubtitleCache(for: profile.id, client: client) }
            }
        } catch {
            connectionErrors[profile.id.uuidString] = error.localizedDescription
            setError(error.localizedDescription, for: serviceType, id: profile.id)
        }
    }

    func refreshBazarrSubtitleCache(for id: UUID, client: BazarrAPIClient) async {
        async let seriesPage = try? client.getSeries(start: 0, length: -1)
        async let moviesPage = try? client.getMovies(start: 0, length: -1)
        let (series, movies) = await (seriesPage, moviesPage)
        updateEntry(in: &bazarrInstances, id: id) { entry in
            if let s = series { entry.cachedSeries = s.data }
            if let m = movies { entry.cachedMovies = m.data }
        }
    }

    func refreshActiveBazarrSubtitleCache() async {
        guard let entry = activeBazarrEntry, let client = entry.client else { return }
        await refreshBazarrSubtitleCache(for: entry.id, client: client)
    }

    func updateBazarrLanguageProfiles(for id: UUID, profiles: [BazarrLanguageProfile], languages: [BazarrLanguage]) {
        updateEntry(in: &bazarrInstances, id: id) { entry in
            entry.languageProfiles = profiles
            entry.languages = languages
        }
    }

    func getBazarrEpisodes(forSonarrSeriesId sonarrSeriesId: Int) async throws -> [BazarrEpisode] {
        guard let client = activeBazarrEntry?.client else { return [] }
        let episodes = try await client.getEpisodes(seriesIds: [sonarrSeriesId])
        await refreshActiveBazarrSubtitleCache()
        return episodes
    }

    func bazarrSubtitleStatus(forSonarrSeriesId sonarrId: Int) -> BazarrSubtitleStatus? {
        guard let entry = activeBazarrEntry, entry.isConnected else { return nil }
        guard let series = entry.cachedSeries.first(where: { $0.sonarrSeriesId == sonarrId }) else { return nil }
        return BazarrViewModel.subtitleStatus(for: series)
    }

    func bazarrSubtitleStatus(forRadarrId radarrId: Int) -> BazarrSubtitleStatus? {
        guard let entry = activeBazarrEntry, entry.isConnected else { return nil }
        guard let movie = entry.cachedMovies.first(where: { $0.radarrId == radarrId }) else { return nil }
        return BazarrViewModel.subtitleStatus(for: movie)
    }

    /// Disconnect all services.
    func disconnectAll() {
        withAnimation(.snappy) {
            sonarrInstances = []
            radarrInstances = []
            bazarrInstances = []
            activeSonarrProfileID = nil
            activeRadarrProfileID = nil
            activeBazarrProfileID = nil
            prowlarrClient = nil
            activeProwlarrProfileID = nil
            prowlarrConnected = false
            prowlarrIsConnecting = false
            prowlarrConnectionError = nil
            prowlarrTags = []
        }
        connectionErrors.removeAll()
        sonarrHealthChecks = []
        radarrHealthChecks = []
        prowlarrHealthChecks = []
        sonarrBlocklist = []
        radarrBlocklist = []
        sonarrImportListExclusions = []
        radarrImportListExclusions = []
        blocklistError = nil
        importListExclusionsError = nil
    }

    /// Disconnect a single service and clear any cached state.
    func disconnectService(_ serviceType: ArrServiceType, profileID: UUID? = nil) {
        switch serviceType {
        case .sonarr:
            if let id = profileID {
                connectionErrors.removeValue(forKey: id.uuidString)
                withAnimation(.snappy) {
                    sonarrInstances.removeAll { $0.id == id }
                    if activeSonarrProfileID == id {
                        activeSonarrProfileID = sonarrInstances
                            .first(where: { $0.isConnected })?
                            .id ?? sonarrInstances.first?.id
                    }
                }
            } else {
                withAnimation(.snappy) {
                    sonarrInstances = []
                    activeSonarrProfileID = nil
                }
            }
        case .radarr:
            if let id = profileID {
                connectionErrors.removeValue(forKey: id.uuidString)
                withAnimation(.snappy) {
                    radarrInstances.removeAll { $0.id == id }
                    if activeRadarrProfileID == id {
                        activeRadarrProfileID = radarrInstances
                            .first(where: { $0.isConnected })?
                            .id ?? radarrInstances.first?.id
                    }
                }
            } else {
                withAnimation(.snappy) {
                    radarrInstances = []
                    activeRadarrProfileID = nil
                }
            }
        case .prowlarr:
            if profileID == nil || activeProwlarrProfileID == profileID {
                withAnimation(.snappy) {
                    prowlarrClient = nil
                    activeProwlarrProfileID = nil
                    prowlarrConnected = false
                    prowlarrConnectionError = nil
                    prowlarrTags = []
                }
            }
            if let id = profileID {
                connectionErrors.removeValue(forKey: id.uuidString)
            }
        case .bazarr:
            if let id = profileID {
                connectionErrors.removeValue(forKey: id.uuidString)
                withAnimation(.snappy) {
                    bazarrInstances.removeAll { $0.id == id }
                    if activeBazarrProfileID == id {
                        activeBazarrProfileID = bazarrInstances
                            .first(where: { $0.isConnected })?
                            .id ?? bazarrInstances.first?.id
                    }
                }
            } else {
                withAnimation(.snappy) {
                    bazarrInstances = []
                    activeBazarrProfileID = nil
                }
            }
        }
    }

    /// Test a connection without persisting it.
    func testConnection(hostURL: String, apiKey: String, serviceType: ArrServiceType, allowsUntrustedTLS: Bool = false) async throws -> ArrSystemStatus {
        switch serviceType {
        case .prowlarr:
            let client = ProwlarrAPIClient(baseURL: hostURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
            return try await client.getSystemStatus()
        case .bazarr:
            let client = BazarrAPIClient(baseURL: hostURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
            let status = try await client.getSystemStatus()
            return ArrSystemStatus(
                appName: "Bazarr",
                instanceName: "Bazarr",
                version: status.bazarrVersion,
                buildTime: nil,
                isDebug: nil,
                isProduction: nil,
                isAdmin: nil,
                isUserInteractive: nil,
                startupPath: status.bazarrDirectory,
                appData: status.bazarrConfigDirectory,
                osName: status.operatingSystem,
                osVersion: nil,
                isDocker: nil,
                isLinux: nil,
                isOsx: nil,
                isWindows: nil,
                urlBase: nil,
                runtimeVersion: status.pythonVersion,
                runtimeName: "Python"
            )
        default:
            // Sonarr & Radarr both speak /api/v3 — use the base actor's HTTP primitive
            // directly so this path doesn't need a service-specific wrapper.
            let client = ArrAPIClient(baseURL: hostURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
            let status: ArrSystemStatus = try await client.get("/api/v3/system/status")
            return status
        }
    }

    // MARK: - Health & Blocklist

    func loadHealth() async {
        guard sonarrConnected || radarrConnected || prowlarrConnected else {
            sonarrHealthChecks = []
            radarrHealthChecks = []
            prowlarrHealthChecks = []
            return
        }
        isLoadingHealth = true
        defer { isLoadingHealth = false }
        async let s = fetchHealth(sonarrClient)
        async let r = fetchHealth(radarrClient)
        async let p = fetchHealth(prowlarrClient)
        let (sv, rv, pv) = await (s, r, p)
        sonarrHealthChecks = sv
        radarrHealthChecks = rv
        prowlarrHealthChecks = pv
    }

    func loadBlocklist() async {
        guard sonarrConnected || radarrConnected else {
            sonarrBlocklist = []
            radarrBlocklist = []
            blocklistError = nil
            return
        }
        isLoadingBlocklist = true
        defer { isLoadingBlocklist = false }
        async let s = fetchBlocklist(sonarrClient, serviceName: "Sonarr")
        async let r = fetchBlocklist(radarrClient, serviceName: "Radarr")
        let (sv, rv) = await (s, r)
        sonarrBlocklist = sv.items
        radarrBlocklist = rv.items
        let errors = [sv.error, rv.error].compactMap { $0 }
        blocklistError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func loadImportListExclusions() async {
        guard sonarrConnected || radarrConnected else {
            sonarrImportListExclusions = []
            radarrImportListExclusions = []
            importListExclusionsError = nil
            return
        }
        isLoadingImportListExclusions = true
        defer { isLoadingImportListExclusions = false }
        async let s = fetchImportListExclusions(sonarrClient, serviceName: "Sonarr")
        async let r = fetchImportListExclusions(radarrClient, serviceName: "Radarr")
        let (sv, rv) = await (s, r)
        sonarrImportListExclusions = sv.items
        radarrImportListExclusions = rv.items
        let errors = [sv.error, rv.error].compactMap { $0 }
        importListExclusionsError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func removeBlocklistItem(id: Int, source: ArrServiceType) async {
        switch source {
        case .sonarr:
            try? await sonarrClient?.deleteBlocklistItem(id: id)
            sonarrBlocklist.removeAll { $0.id == id }
        case .radarr:
            try? await radarrClient?.deleteBlocklistItem(id: id)
            radarrBlocklist.removeAll { $0.id == id }
        case .prowlarr, .bazarr:
            break
        }
    }

    func clearBlocklist(sonarrIDs: [Int], radarrIDs: [Int]) async {
        await withTaskGroup(of: Void.self) { group in
            if !sonarrIDs.isEmpty, let client = sonarrClient {
                group.addTask { try? await client.deleteBlocklistItems(ids: sonarrIDs) }
            }
            if !radarrIDs.isEmpty, let client = radarrClient {
                group.addTask { try? await client.deleteBlocklistItems(ids: radarrIDs) }
            }
        }
        sonarrBlocklist.removeAll { sonarrIDs.contains($0.id) }
        radarrBlocklist.removeAll { radarrIDs.contains($0.id) }
    }

    func removeImportListExclusion(id: Int, source: ArrServiceType) async {
        switch source {
        case .sonarr:
            do {
                try await sonarrClient?.deleteImportListExclusion(id: id)
                sonarrImportListExclusions.removeAll { $0.id == id }
            } catch {
                // Deletion failed, do not remove from local array
            }
        case .radarr:
            do {
                try await radarrClient?.deleteImportListExclusion(id: id)
                radarrImportListExclusions.removeAll { $0.id == id }
            } catch {
                // Deletion failed, do not remove from local array
            }
        case .prowlarr, .bazarr:
            break
        }
    }

    func clearImportListExclusions(sonarrIDs: [Int], radarrIDs: [Int]) async {
        let successfulSonarrIDs = await withTaskGroup(of: Int?.self) { group in
            if let client = sonarrClient {
                for id in sonarrIDs {
                    group.addTask {
                        do {
                            try await client.deleteImportListExclusion(id: id)
                            return id
                        } catch {
                            return nil
                        }
                    }
                }
            }
            var successful: [Int] = []
            for await result in group {
                if let id = result {
                    successful.append(id)
                }
            }
            return successful
        }

        let successfulRadarrIDs = await withTaskGroup(of: Int?.self) { group in
            if let client = radarrClient {
                for id in radarrIDs {
                    group.addTask {
                        do {
                            try await client.deleteImportListExclusion(id: id)
                            return id
                        } catch {
                            return nil
                        }
                    }
                }
            }
            var successful: [Int] = []
            for await result in group {
                if let id = result {
                    successful.append(id)
                }
            }
            return successful
        }

        sonarrImportListExclusions.removeAll { successfulSonarrIDs.contains($0.id) }
        radarrImportListExclusions.removeAll { successfulRadarrIDs.contains($0.id) }
    }

    private func fetchHealth<C: SharedArrClient>(_ client: C?) async -> [ArrHealthCheck] {
        guard let client else { return [] }
        return (try? await client.getHealth()) ?? []
    }

    private func fetchBlocklist<C: SharedArrClient>(
        _ client: C?,
        serviceName: String
    ) async -> (items: [ArrBlocklistItem], error: String?) {
        guard let client else { return ([], nil) }
        do {
            return (try await client.getBlocklist().records ?? [], nil)
        } catch {
            return ([], "\(serviceName): \(error.localizedDescription)")
        }
    }

    private func fetchImportListExclusions<C: SharedArrClient>(
        _ client: C?,
        serviceName: String
    ) async -> (items: [ArrImportListExclusion], error: String?) {
        guard let client else { return ([], nil) }
        do {
            var allItems: [ArrImportListExclusion] = []
            var page = 1
            let pageSize = 100

            while true {
                let response = try await client.getImportListExclusions(page: page, pageSize: pageSize)
                let records = response.records ?? []
                allItems.append(contentsOf: records)

                // Check if we've fetched all pages
                if records.count < pageSize {
                    break
                }
                page += 1
            }

            return (allItems, nil)
        } catch {
            return ([], "\(serviceName): \(error.localizedDescription)")
        }
    }

    private func applyConfigurationUpdate<C: SharedArrClient>(
        in array: inout [ArrClientEntry<C>],
        id: UUID,
        profiles: [ArrQualityProfile]?,
        folders: [ArrRootFolder]?,
        tags: [ArrTag]?,
        error: String?
    ) {
        updateEntry(in: &array, id: id) { entry in
            if let profiles { entry.qualityProfiles = profiles }
            if let folders { entry.rootFolders = folders }
            if let tags { entry.tags = tags }
            entry.connectionError = error
        }
        if let error = error {
            connectionErrors[id.uuidString] = error
        } else {
            connectionErrors.removeValue(forKey: id.uuidString)
        }
    }

    /// Refresh cached configuration data for all connected services.
    func refreshConfiguration() async {
        await refreshConfiguration(snapshots: configurationSnapshots(from: sonarrInstances)) { id, profiles, folders, tags, error in
            applyConfigurationUpdate(in: &sonarrInstances, id: id, profiles: profiles, folders: folders, tags: tags, error: error)
        }
        await refreshConfiguration(snapshots: configurationSnapshots(from: radarrInstances)) { id, profiles, folders, tags, error in
            applyConfigurationUpdate(in: &radarrInstances, id: id, profiles: profiles, folders: folders, tags: tags, error: error)
        }
    }

    // MARK: - Private helpers

    private func setConnecting(_ value: Bool, for serviceType: ArrServiceType, id: UUID) {
        switch serviceType {
        case .sonarr:
            updateEntry(in: &sonarrInstances, id: id) { $0.isConnecting = value }
        case .radarr:
            updateEntry(in: &radarrInstances, id: id) { $0.isConnecting = value }
        case .prowlarr:
            prowlarrIsConnecting = value
        case .bazarr:
            updateEntry(in: &bazarrInstances, id: id) { $0.isConnecting = value }
        }
    }

    private func setError(_ message: String?, for serviceType: ArrServiceType, id: UUID) {
        switch serviceType {
        case .sonarr:
            updateEntry(in: &sonarrInstances, id: id) {
                $0.connectionError = message
                $0.isConnected = false
            }
        case .radarr:
            updateEntry(in: &radarrInstances, id: id) {
                $0.connectionError = message
                $0.isConnected = false
            }
        case .prowlarr:
            if activeProwlarrProfileID == id {
                prowlarrClient = nil
                prowlarrConnectionError = message
                prowlarrConnected = false
                activeProwlarrProfileID = nil
                prowlarrTags = []
            }
        case .bazarr:
            updateEntry(in: &bazarrInstances, id: id) {
                $0.connectionError = message
                $0.isConnected = false
            }
        }
    }

    private func updateEntry<T: Identifiable>(in array: inout [T], id: T.ID, _ mutate: (inout T) -> Void) {
        guard let idx = array.firstIndex(where: { $0.id == id }) else { return }
        var entry = array[idx]
        mutate(&entry)
        array[idx] = entry
    }

    private func configurationSnapshots<C: SharedArrClient>(from entries: [ArrClientEntry<C>]) -> [(UUID, C)] {
        entries.compactMap { entry in
            guard entry.isConnected, let client = entry.client else { return nil }
            return (entry.id, client)
        }
    }

    private func refreshConfiguration<C: SharedArrClient>(
        snapshots: [(UUID, C)],
        update: (UUID, [ArrQualityProfile]?, [ArrRootFolder]?, [ArrTag]?, String?) -> Void
    ) async {
        for (id, client) in snapshots {
            do {
                async let qp = client.getQualityProfiles()
                async let rf = client.getRootFolders()
                async let t = client.getTags()
                let (profiles, folders, tags) = try await (qp, rf, t)
                update(id, profiles, folders, tags, nil)
            } catch {
                update(id, nil, nil, nil, "Failed to refresh config: \(error.localizedDescription)")
            }
        }
    }

    private func normalizedNotificationWorkerURL(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? NotificationConstants.defaultWorkerURL : trimmed

        func isAllowedScheme(_ components: URLComponents) -> Bool {
            guard let scheme = components.scheme?.lowercased() else { return false }
            switch scheme {
            case "https":
                return true
            case "http":
                let host = components.host?.lowercased()
                return host == "localhost" || host == "127.0.0.1"
            default:
                return false
            }
        }

        let withHTTPS = candidate.hasPrefix("//") ? "https:\(candidate)" : "https://\(candidate)"
        let normalizedCandidate = (URLComponents(string: candidate)?.scheme?.isEmpty == false) ? candidate : withHTTPS

        guard let components = URLComponents(string: normalizedCandidate),
              let host = components.host,
              !host.isEmpty,
              isAllowedScheme(components),
              // Return the URL rebuilt from parsed components so the caller always
              // receives a canonical string, not the raw (possibly unclean) input.
              let canonicalURL = components.url?.absoluteString else {
            throw ArrError.invalidURL
        }

        return canonicalURL
    }

    private func notificationClient(for profile: ArrServiceProfile) throws -> any SharedArrClient {
        guard let serviceType = profile.resolvedServiceType else {
            throw ArrError.noServiceConfigured
        }

        switch serviceType {
        case .sonarr:
            guard let client = sonarrInstances.first(where: { $0.id == profile.id })?.client else {
                throw ArrError.noServiceConfigured
            }
            return client
        case .radarr:
            guard let client = radarrInstances.first(where: { $0.id == profile.id })?.client else {
                throw ArrError.noServiceConfigured
            }
            return client
        case .prowlarr:
            guard activeProwlarrProfileID == profile.id, let prowlarrClient else {
                throw ArrError.noServiceConfigured
            }
            return prowlarrClient
        case .bazarr:
            throw ArrError.unsupportedNotificationsService(serviceType.displayName)
        }
    }

    private func notificationName(for profile: ArrServiceProfile) -> String {
        "Trawl (\(profile.displayName))"
    }

    private func notificationPayload(
        existing: ArrNotification?,
        profile: ArrServiceProfile,
        pushURL: String,
        deviceToken: String
    ) -> ArrNotification {
        let serviceType = profile.resolvedServiceType
        let isSonarr = serviceType == .sonarr
        let isRadarr = serviceType == .radarr
        let isProwlarr = serviceType == .prowlarr

        return ArrNotification(
            id: existing?.id,
            name: notificationName(for: profile),
            onGrab: isProwlarr ? nil : (existing?.onGrab ?? true),
            onDownload: isProwlarr ? nil : (existing?.onDownload ?? true),
            onUpgrade: isProwlarr ? nil : (existing?.onUpgrade ?? true),
            onRename: isProwlarr ? nil : (existing?.onRename ?? true),
            onHealthIssue: existing?.onHealthIssue ?? true,
            onApplicationUpdate: existing?.onApplicationUpdate ?? true,
            onSeriesAdd: isSonarr ? (existing?.onSeriesAdd ?? false) : nil,
            onSeriesDelete: isSonarr ? (existing?.onSeriesDelete ?? false) : nil,
            onEpisodeFileDelete: isSonarr ? (existing?.onEpisodeFileDelete ?? false) : nil,
            onEpisodeFileDeleteForUpgrade: isSonarr ? (existing?.onEpisodeFileDeleteForUpgrade ?? false) : nil,
            onMovieAdded: isRadarr ? (existing?.onMovieAdded ?? false) : nil,
            onMovieDelete: isRadarr ? (existing?.onMovieDelete ?? false) : nil,
            onMovieFileDelete: isRadarr ? (existing?.onMovieFileDelete ?? false) : nil,
            onMovieFileDeleteForUpgrade: isRadarr ? (existing?.onMovieFileDeleteForUpgrade ?? false) : nil,
            includeHealthWarnings: existing?.includeHealthWarnings ?? true,
            implementation: "Webhook",
            configContract: "WebhookSettings",
            fields: notificationFields(pushURL: pushURL, deviceToken: deviceToken, serviceType: serviceType),
            tags: existing?.tags ?? []
        )
    }

    private func notificationFields(pushURL: String, deviceToken: String, serviceType: ArrServiceType?) -> [ArrNotificationField] {
        if serviceType == .prowlarr {
            return [
                ArrNotificationField(name: "url", value: .string(pushURL)),
                ArrNotificationField(name: "method", value: .number(1)), // 1 = POST
                ArrNotificationField(name: "username", value: .string("trawl")),
                ArrNotificationField(name: "password", value: .string(deviceToken))
            ]
        }

        return [
            ArrNotificationField(name: "url", value: .string(pushURL)),
            ArrNotificationField(name: "method", value: .number(1)), // 1 = POST
            ArrNotificationField(name: "headers", value: .array([
                .object([
                    "Key": .string("X-Trawl-Token"),
                    "Value": .string(deviceToken)
                ])
            ]))
        ]
    }

    private func pushNotificationURL(from workerURL: String) throws -> String {
        let normalizedWorkerURL = try normalizedNotificationWorkerURL(from: workerURL)
        var components = URLComponents(string: normalizedWorkerURL)

        var pathParts = components?.path.split(separator: "/").map(String.init) ?? []
        if pathParts.last?.lowercased() == "push" {
            pathParts.removeLast()
        }
        pathParts.append("push")
        components?.path = "/" + pathParts.joined(separator: "/")

        guard let pushURL = components?.url?.absoluteString else {
            throw ArrError.invalidURL
        }

        return pushURL
    }

    private func trawlNotificationMatches(
        _ notification: ArrNotification,
        pushURL: String,
        deviceToken: String,
        serviceType: ArrServiceType?
    ) -> Bool {
        let urlMatches: Bool = {
            guard case .string(let url) = notification.fields.first(where: { $0.name == "url" })?.value else { return false }
            return normalizedNotificationComparisonURL(url) == normalizedNotificationComparisonURL(pushURL)
        }()
        let methodMatches: Bool = {
            guard let methodValue = notification.fields.first(where: { $0.name == "method" })?.value else { return true }
            switch methodValue {
            case .number(let method):
                return method == 1
            case .string(let method):
                let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "1" || normalized == "post"
            default:
                return false
            }
        }()
        let tokenMatches: Bool = {
            if serviceType == .prowlarr {
                return prowlarrAuthMatches(notification, deviceToken: deviceToken)
            }

            if case .array(let headers) = notification.fields.first(where: { $0.name == "headers" })?.value {
                return headers.contains { headerValue in
                    guard case .object(let header) = headerValue else { return false }

                    let key: String? = {
                        if case .string(let value) = header["Key"] { return value }
                        if case .string(let value) = header["key"] { return value }
                        return nil
                    }()

                    let value: String? = {
                        if case .string(let storedValue) = header["Value"] { return storedValue }
                        if case .string(let storedValue) = header["value"] { return storedValue }
                        return nil
                    }()

                    return key == "X-Trawl-Token" && value == deviceToken
                }
            }

            guard case .string(let password) = notification.fields.first(where: { $0.name == "password" })?.value else { return false }
            return password == deviceToken
        }()
        return urlMatches && methodMatches && tokenMatches
    }

    private func prowlarrAuthMatches(_ notification: ArrNotification, deviceToken: String) -> Bool {
        guard case .string(let username) = notification.fields.first(where: { $0.name == "username" })?.value,
              username.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("trawl") == .orderedSame else {
            return false
        }

        guard let passwordValue = notification.fields.first(where: { $0.name == "password" })?.value else {
            return true
        }

        switch passwordValue {
        case .string(let password):
            let normalized = password.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == deviceToken || normalized.isEmpty || normalized.allSatisfy { $0 == "*" }
        case .null:
            return true
        default:
            return false
        }
    }

    private func normalizedNotificationComparisonURL(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue) else {
            return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        return components.url?.absoluteString ?? rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if DEBUG
extension ArrServiceManager {
    enum PreviewState {
        case allConfigured
        case sonarrOnly
        case radarrOnly
        case noneConfigured
        case sonarrConnecting
        case sonarrConnectionError(String)
    }

    static func preview(_ state: PreviewState = .allConfigured) -> ArrServiceManager {
        let manager = ArrServiceManager()
        switch state {
        case .allConfigured:
            manager.installPreviewSonarr(connected: true)
            manager.installPreviewRadarr(connected: true)
            manager.installPreviewProwlarr(connected: true)
            manager.installPreviewBazarr(connected: true)
        case .sonarrOnly:
            manager.installPreviewSonarr(connected: true)
        case .radarrOnly:
            manager.installPreviewRadarr(connected: true)
        case .noneConfigured:
            break
        case .sonarrConnecting:
            manager.installPreviewSonarr(connected: false, isConnecting: true)
        case .sonarrConnectionError(let msg):
            manager.installPreviewSonarr(connected: false, error: msg)
        }
        return manager
    }

    fileprivate func installPreviewSonarr(connected: Bool, isConnecting: Bool = false, error: String? = nil) {
        let id = UUID()
        var entry = SonarrClientEntry(id: id, displayName: "Sonarr (preview)")
        entry.client = connected ? .preview() : nil
        entry.isConnected = connected
        entry.isConnecting = isConnecting
        entry.connectionError = error
        entry.qualityProfiles = ArrQualityProfile.previewList
        entry.rootFolders = ArrRootFolder.previewList
        entry.tags = ArrTag.previewList
        sonarrInstances = [entry]
        activeSonarrProfileID = id
    }

    fileprivate func installPreviewRadarr(connected: Bool, isConnecting: Bool = false, error: String? = nil) {
        let id = UUID()
        var entry = RadarrClientEntry(id: id, displayName: "Radarr (preview)")
        entry.client = connected ? .preview() : nil
        entry.isConnected = connected
        entry.isConnecting = isConnecting
        entry.connectionError = error
        entry.qualityProfiles = ArrQualityProfile.previewList
        entry.rootFolders = ArrRootFolder.previewList
        entry.tags = ArrTag.previewList
        radarrInstances = [entry]
        activeRadarrProfileID = id
    }

    fileprivate func installPreviewProwlarr(connected: Bool) {
        prowlarrClient = connected ? .preview() : nil
        prowlarrConnected = connected
        activeProwlarrProfileID = UUID()
    }

    fileprivate func installPreviewBazarr(connected: Bool) {
        let id = UUID()
        var entry = BazarrClientEntry(id: id, displayName: "Bazarr (preview)")
        entry.client = connected ? .preview() : nil
        entry.isConnected = connected
        bazarrInstances = [entry]
        activeBazarrProfileID = id
    }
}
#endif
