import Foundation
import Observation
import SwiftData
import SwiftUI

// MARK: - Instance Entry Types

struct SonarrClientEntry: Identifiable {
    let id: UUID
    let displayName: String
    var client: SonarrAPIClient?
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

struct RadarrClientEntry: Identifiable {
    let id: UUID
    let displayName: String
    var client: RadarrAPIClient?
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
    private(set) var isLoadingHealth = false
    private(set) var isLoadingBlocklist = false

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

    func sonarrClient(for profileID: UUID) -> SonarrAPIClient? {
        sonarrInstances.first(where: { $0.id == profileID })?.client
    }

    func radarrClient(for profileID: UUID) -> RadarrAPIClient? {
        radarrInstances.first(where: { $0.id == profileID })?.client
    }

    func isConnected(_ serviceType: ArrServiceType, profileID: UUID) -> Bool {
        switch serviceType {
        case .sonarr:
            sonarrInstances.first(where: { $0.id == profileID })?.isConnected ?? false
        case .radarr:
            radarrInstances.first(where: { $0.id == profileID })?.isConnected ?? false
        case .prowlarr:
            activeProwlarrProfileID == profileID && prowlarrConnected
        }
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

    func setupNotifications(for profile: ArrServiceProfile, workerURL: String, deviceToken: String) async throws {
        let client = try notificationClient(for: profile)
        let notificationName = notificationName(for: profile)
        let pushURL = try pushNotificationURL(from: workerURL)
        let notifications = try await client.getNotifications()
        let existing = notifications.first { $0.name == notificationName }

        if let existing, trawlNotificationMatches(existing, pushURL: pushURL, deviceToken: deviceToken) {
            return
        }

        let fields = [
            ArrNotificationField(name: "url", value: .string(pushURL)),
            ArrNotificationField(name: "method", value: .number(1)), // 1 = POST
            ArrNotificationField(name: "headers", value: .array([
                .object([
                    "Key": .string("X-Trawl-Token"),
                    "Value": .string(deviceToken)
                ])
            ]))
        ]

        let newNotification = ArrNotification(
            id: existing?.id,
            name: notificationName,
            onGrab: true,
            onDownload: true,
            onUpgrade: true,
            onRename: true,
            onHealthIssue: true,
            onApplicationUpdate: true,
            onSeriesDelete: false,
            onEpisodeFileDelete: false,
            onEpisodeFileDeleteForUpgrade: false,
            onMovieDelete: false,
            onMovieFileDelete: false,
            onMovieFileDeleteForUpgrade: false,
            implementation: "Webhook",
            configContract: "WebhookSettings",
            fields: fields,
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

        return trawlNotificationMatches(existing, pushURL: pushURL, deviceToken: deviceToken)
            ? .configured
            : .needsUpdate
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
                    updateSonarrEntry(id: profile.id) { entry in
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
                    updateRadarrEntry(id: profile.id) { entry in
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
                if activeProwlarrProfileID == nil || activeProwlarrProfileID == profile.id {
                    withAnimation(.snappy) {
                        prowlarrClient = client
                        activeProwlarrProfileID = profile.id
                        prowlarrConnected = true
                        prowlarrConnectionError = nil
                    }
                }
                connectionErrors.removeValue(forKey: profile.id.uuidString)
            }
        } catch {
            connectionErrors[profile.id.uuidString] = error.localizedDescription
            setError(error.localizedDescription, for: serviceType, id: profile.id)
        }
    }

    /// Disconnect all services.
    func disconnectAll() {
        withAnimation(.snappy) {
            sonarrInstances = []
            radarrInstances = []
            activeSonarrProfileID = nil
            activeRadarrProfileID = nil
            prowlarrClient = nil
            activeProwlarrProfileID = nil
            prowlarrConnected = false
            prowlarrIsConnecting = false
            prowlarrConnectionError = nil
        }
        connectionErrors.removeAll()
        sonarrHealthChecks = []
        radarrHealthChecks = []
        prowlarrHealthChecks = []
        sonarrBlocklist = []
        radarrBlocklist = []
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
                }
            }
            if let id = profileID {
                connectionErrors.removeValue(forKey: id.uuidString)
            }
        }
    }

    /// Test a connection without persisting it.
    func testConnection(hostURL: String, apiKey: String, serviceType: ArrServiceType, allowsUntrustedTLS: Bool = false) async throws -> ArrSystemStatus {
        switch serviceType {
        case .prowlarr:
            let client = ProwlarrAPIClient(baseURL: hostURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
            return try await client.getSystemStatus()
        default:
            let client = ArrAPIClient(baseURL: hostURL, apiKey: apiKey, allowsUntrustedTLS: allowsUntrustedTLS)
            return try await client.getSystemStatus()
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
        async let s = _fetchHealth(sonarrClient)
        async let r = _fetchHealth(radarrClient)
        async let p = _fetchProwlarrHealth()
        let (sv, rv, pv) = await (s, r, p)
        sonarrHealthChecks = sv
        radarrHealthChecks = rv
        prowlarrHealthChecks = pv
    }

    func loadBlocklist() async {
        guard sonarrConnected || radarrConnected else {
            sonarrBlocklist = []
            radarrBlocklist = []
            return
        }
        isLoadingBlocklist = true
        defer { isLoadingBlocklist = false }
        async let s = _fetchBlocklist(sonarrClient)
        async let r = _fetchBlocklist(radarrClient)
        let (sv, rv) = await (s, r)
        sonarrBlocklist = sv
        radarrBlocklist = rv
    }

    func removeBlocklistItem(id: Int, source: ArrServiceType) async {
        switch source {
        case .sonarr:
            try? await sonarrClient?.deleteBlocklistItem(id: id)
            sonarrBlocklist.removeAll { $0.id == id }
        case .radarr:
            try? await radarrClient?.deleteBlocklistItem(id: id)
            radarrBlocklist.removeAll { $0.id == id }
        case .prowlarr:
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

    private func _fetchHealth(_ client: SonarrAPIClient?) async -> [ArrHealthCheck] {
        guard let client else { return [] }
        return (try? await client.getHealth()) ?? []
    }

    private func _fetchHealth(_ client: RadarrAPIClient?) async -> [ArrHealthCheck] {
        guard let client else { return [] }
        return (try? await client.getHealth()) ?? []
    }

    private func _fetchProwlarrHealth() async -> [ArrHealthCheck] {
        guard let client = prowlarrClient else { return [] }
        return (try? await client.getHealth()) ?? []
    }

    private func _fetchBlocklist(_ client: SonarrAPIClient?) async -> [ArrBlocklistItem] {
        guard let client else { return [] }
        return (try? await client.getBlocklist().records) ?? []
    }

    private func _fetchBlocklist(_ client: RadarrAPIClient?) async -> [ArrBlocklistItem] {
        guard let client else { return [] }
        return (try? await client.getBlocklist().records) ?? []
    }

    /// Refresh cached configuration data for all connected services.
    func refreshConfiguration() async {
        let sonarrSnapshots = sonarrInstances.compactMap { entry -> (UUID, SonarrAPIClient)? in
            guard entry.isConnected, let client = entry.client else { return nil }
            return (entry.id, client)
        }
        for (id, client) in sonarrSnapshots {
            do {
                async let qp = client.getQualityProfiles()
                async let rf = client.getRootFolders()
                async let t = client.getTags()
                let (profiles, folders, tags) = try await (qp, rf, t)
                updateSonarrEntry(id: id) { entry in
                    entry.qualityProfiles = profiles
                    entry.rootFolders = folders
                    entry.tags = tags
                    entry.connectionError = nil
                }
            } catch {
                updateSonarrEntry(id: id) { entry in
                    entry.connectionError = "Failed to refresh config: \(error.localizedDescription)"
                }
            }
        }

        let radarrSnapshots = radarrInstances.compactMap { entry -> (UUID, RadarrAPIClient)? in
            guard entry.isConnected, let client = entry.client else { return nil }
            return (entry.id, client)
        }
        for (id, client) in radarrSnapshots {
            do {
                async let qp = client.getQualityProfiles()
                async let rf = client.getRootFolders()
                async let t = client.getTags()
                let (profiles, folders, tags) = try await (qp, rf, t)
                updateRadarrEntry(id: id) { entry in
                    entry.qualityProfiles = profiles
                    entry.rootFolders = folders
                    entry.tags = tags
                    entry.connectionError = nil
                }
            } catch {
                updateRadarrEntry(id: id) { entry in
                    entry.connectionError = "Failed to refresh config: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Private helpers

    private func setConnecting(_ value: Bool, for serviceType: ArrServiceType, id: UUID) {
        switch serviceType {
        case .sonarr:
            updateSonarrEntry(id: id) { entry in
                entry.isConnecting = value
            }
        case .radarr:
            updateRadarrEntry(id: id) { entry in
                entry.isConnecting = value
            }
        case .prowlarr:
            prowlarrIsConnecting = value
        }
    }

    private func setError(_ message: String?, for serviceType: ArrServiceType, id: UUID) {
        switch serviceType {
        case .sonarr:
            updateSonarrEntry(id: id) { entry in
                entry.connectionError = message
                entry.isConnected = false
            }
        case .radarr:
            updateRadarrEntry(id: id) { entry in
                entry.connectionError = message
                entry.isConnected = false
            }
        case .prowlarr:
            if activeProwlarrProfileID == id {
                prowlarrClient = nil
                prowlarrConnectionError = message
                prowlarrConnected = false
                activeProwlarrProfileID = nil
            }
        }
    }

    private func updateSonarrEntry(id: UUID, _ mutate: (inout SonarrClientEntry) -> Void) {
        guard let idx = sonarrInstances.firstIndex(where: { $0.id == id }) else { return }
        var entry = sonarrInstances[idx]
        mutate(&entry)
        sonarrInstances[idx] = entry
    }

    private func updateRadarrEntry(id: UUID, _ mutate: (inout RadarrClientEntry) -> Void) {
        guard let idx = radarrInstances.firstIndex(where: { $0.id == id }) else { return }
        var entry = radarrInstances[idx]
        mutate(&entry)
        radarrInstances[idx] = entry
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
            throw ArrError.unsupportedNotificationsService(serviceType.displayName)
        }
    }

    private func notificationName(for profile: ArrServiceProfile) -> String {
        "Trawl (\(profile.displayName))"
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
        deviceToken: String
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
            guard case .array(let headers) = notification.fields.first(where: { $0.name == "headers" })?.value else { return false }
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
        }()
        let triggersMatch =
            notification.onGrab &&
            notification.onDownload &&
            notification.onUpgrade != false &&
            notification.onRename != false &&
            notification.onHealthIssue != false &&
            notification.onApplicationUpdate != false

        return urlMatches && methodMatches && tokenMatches && triggersMatch
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
