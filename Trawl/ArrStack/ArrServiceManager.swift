import Foundation
import Observation
import SwiftData

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

    func setupNotifications(for profile: ArrServiceProfile, workerURL: String, deviceToken: String) async throws {
        guard let serviceType = profile.resolvedServiceType else {
            throw ArrError.noServiceConfigured
        }

        let client: any SharedArrClient
        switch serviceType {
        case .sonarr:
            guard let resolvedClient = sonarrInstances.first(where: { $0.id == profile.id })?.client else {
                throw ArrError.noServiceConfigured
            }
            client = resolvedClient
        case .radarr:
            guard let resolvedClient = radarrInstances.first(where: { $0.id == profile.id })?.client else {
                throw ArrError.noServiceConfigured
            }
            client = resolvedClient
        case .prowlarr:
            throw ArrError.unsupportedNotificationsService(serviceType.displayName)
        }

        let notificationName = "Trawl (\(profile.displayName))"
        let normalizedWorkerURL = try normalizedNotificationWorkerURL(from: workerURL)
        var components = URLComponents(string: normalizedWorkerURL)

        var pathParts = components?.path.split(separator: "/").map(String.init) ?? []
        pathParts.removeAll { $0.lowercased() == "push" }
        pathParts.append("push")
        components?.path = "/" + pathParts.joined(separator: "/")

        guard let pushURL = components?.url?.absoluteString else {
            throw ArrError.invalidURL
        }

        let notifications = try await client.getNotifications()
        let existing = notifications.first { $0.name == notificationName }

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
        activeSonarrProfileID = profileID
    }

    func setActiveRadarr(_ profileID: UUID) {
        activeRadarrProfileID = profileID
    }

    // MARK: - Initialization

    func initialize(from profiles: [ArrServiceProfile]) async {
        storedProfiles = profiles
        isInitializing = true
        defer { isInitializing = false }
        disconnectAll()

        // Pre-build instance placeholders so connecting state is visible immediately
        sonarrInstances = profiles
            .filter { $0.resolvedServiceType == .sonarr && $0.isEnabled }
            .map { SonarrClientEntry(id: $0.id, displayName: $0.displayName) }
        radarrInstances = profiles
            .filter { $0.resolvedServiceType == .radarr && $0.isEnabled }
            .map { RadarrClientEntry(id: $0.id, displayName: $0.displayName) }

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

                if let idx = sonarrInstances.firstIndex(where: { $0.id == profile.id }) {
                    sonarrInstances[idx].client = client
                    sonarrInstances[idx].isConnected = true
                    sonarrInstances[idx].connectionError = nil
                    sonarrInstances[idx].qualityProfiles = fetchedProfiles
                    sonarrInstances[idx].rootFolders = folders
                    sonarrInstances[idx].tags = fetchedTags
                } else {
                    // Profile was added after initialization
                    var entry = SonarrClientEntry(id: profile.id, displayName: profile.displayName)
                    entry.client = client
                    entry.isConnected = true
                    entry.qualityProfiles = fetchedProfiles
                    entry.rootFolders = folders
                    entry.tags = fetchedTags
                    sonarrInstances.append(entry)
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

                if let idx = radarrInstances.firstIndex(where: { $0.id == profile.id }) {
                    radarrInstances[idx].client = client
                    radarrInstances[idx].isConnected = true
                    radarrInstances[idx].connectionError = nil
                    radarrInstances[idx].qualityProfiles = fetchedProfiles
                    radarrInstances[idx].rootFolders = folders
                    radarrInstances[idx].tags = fetchedTags
                } else {
                    var entry = RadarrClientEntry(id: profile.id, displayName: profile.displayName)
                    entry.client = client
                    entry.isConnected = true
                    entry.qualityProfiles = fetchedProfiles
                    entry.rootFolders = folders
                    entry.tags = fetchedTags
                    radarrInstances.append(entry)
                }
                connectionErrors.removeValue(forKey: profile.id.uuidString)

            case .prowlarr:
                let client = ProwlarrAPIClient(
                    baseURL: profile.hostURL,
                    apiKey: apiKey,
                    allowsUntrustedTLS: profile.allowsUntrustedTLS
                )
                _ = try await client.getSystemStatus()
                prowlarrClient = client
                prowlarrConnected = true
                prowlarrConnectionError = nil
                connectionErrors.removeValue(forKey: profile.id.uuidString)
            }
        } catch {
            connectionErrors[profile.id.uuidString] = error.localizedDescription
            setError(error.localizedDescription, for: serviceType, id: profile.id)
        }
    }

    /// Disconnect all services.
    func disconnectAll() {
        sonarrInstances = []
        radarrInstances = []
        activeSonarrProfileID = nil
        activeRadarrProfileID = nil
        prowlarrClient = nil
        prowlarrConnected = false
        prowlarrIsConnecting = false
        prowlarrConnectionError = nil
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
                if let idx = sonarrInstances.firstIndex(where: { $0.id == id }) {
                    sonarrInstances[idx].client = nil
                    sonarrInstances[idx].isConnected = false
                    sonarrInstances[idx].connectionError = nil
                    sonarrInstances[idx].qualityProfiles = []
                    sonarrInstances[idx].rootFolders = []
                    sonarrInstances[idx].tags = []
                }
                connectionErrors.removeValue(forKey: id.uuidString)
            } else {
                sonarrInstances = []
                activeSonarrProfileID = nil
            }
        case .radarr:
            if let id = profileID {
                if let idx = radarrInstances.firstIndex(where: { $0.id == id }) {
                    radarrInstances[idx].client = nil
                    radarrInstances[idx].isConnected = false
                    radarrInstances[idx].connectionError = nil
                    radarrInstances[idx].qualityProfiles = []
                    radarrInstances[idx].rootFolders = []
                    radarrInstances[idx].tags = []
                }
                connectionErrors.removeValue(forKey: id.uuidString)
            } else {
                radarrInstances = []
                activeRadarrProfileID = nil
            }
        case .prowlarr:
            prowlarrClient = nil
            prowlarrConnected = false
            prowlarrConnectionError = nil
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
        for i in sonarrInstances.indices where sonarrInstances[i].isConnected {
            guard let client = sonarrInstances[i].client else { continue }
            do {
                async let qp = client.getQualityProfiles()
                async let rf = client.getRootFolders()
                async let t = client.getTags()
                let (profiles, folders, tags) = try await (qp, rf, t)
                sonarrInstances[i].qualityProfiles = profiles
                sonarrInstances[i].rootFolders = folders
                sonarrInstances[i].tags = tags
                sonarrInstances[i].connectionError = nil
            } catch {
                sonarrInstances[i].connectionError = "Failed to refresh config: \(error.localizedDescription)"
            }
        }

        for i in radarrInstances.indices where radarrInstances[i].isConnected {
            guard let client = radarrInstances[i].client else { continue }
            do {
                async let qp = client.getQualityProfiles()
                async let rf = client.getRootFolders()
                async let t = client.getTags()
                let (profiles, folders, tags) = try await (qp, rf, t)
                radarrInstances[i].qualityProfiles = profiles
                radarrInstances[i].rootFolders = folders
                radarrInstances[i].tags = tags
                radarrInstances[i].connectionError = nil
            } catch {
                radarrInstances[i].connectionError = "Failed to refresh config: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Private helpers

    private func setConnecting(_ value: Bool, for serviceType: ArrServiceType, id: UUID) {
        switch serviceType {
        case .sonarr:
            if let idx = sonarrInstances.firstIndex(where: { $0.id == id }) {
                sonarrInstances[idx].isConnecting = value
            }
        case .radarr:
            if let idx = radarrInstances.firstIndex(where: { $0.id == id }) {
                radarrInstances[idx].isConnecting = value
            }
        case .prowlarr:
            prowlarrIsConnecting = value
        }
    }

    private func setError(_ message: String?, for serviceType: ArrServiceType, id: UUID) {
        switch serviceType {
        case .sonarr:
            if let idx = sonarrInstances.firstIndex(where: { $0.id == id }) {
                sonarrInstances[idx].connectionError = message
                sonarrInstances[idx].isConnected = false
            }
        case .radarr:
            if let idx = radarrInstances.firstIndex(where: { $0.id == id }) {
                radarrInstances[idx].connectionError = message
                radarrInstances[idx].isConnected = false
            }
        case .prowlarr:
            prowlarrConnectionError = message
            prowlarrConnected = false
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
              isAllowedScheme(components) else {
            throw ArrError.invalidURL
        }

        return normalizedCandidate
    }
}
