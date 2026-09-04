//
//  ConfigurationAuditStore.swift
//  Trawl
//
//  Gathers the snapshot the audit reads, and holds the result for any surface.
//

import Foundation
import Observation
import OSLog

/// Runs the configuration audit and keeps its findings.
///
/// Separate from `ConfigurationAudit` on purpose: everything here talks to servers,
/// and everything there is a pure function of what it collected. A surface observes
/// this - a badge, a settings row, the wizard - without having to know how any of it
/// was fetched, and a test exercises the rules without a network.
@Observable
@MainActor
final class ConfigurationAuditStore {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Trawl",
        category: "ConfigurationAudit"
    )

    private(set) var issues: [ConfigurationIssue] = []
    private(set) var isAuditing = false
    /// Nil until the first audit finishes, which is how a surface tells "nothing is
    /// wrong" apart from "we have not looked yet".
    private(set) var lastAuditDate: Date?
    private(set) var lastInputRevision: String?

    var problems: [ConfigurationIssue] { issues.problems }
    var unknowns: [ConfigurationIssue] { issues.unknowns }
    var notes: [ConfigurationIssue] { issues.notes }
    var problemCount: Int { problems.count }
    var hasCompletedAnAudit: Bool { lastAuditDate != nil }

    /// Issues the user has waved away this session. They stay out of the counts so a
    /// deliberate setup - a Docker hostname, a server left bare on purpose - stops
    /// nagging, without being written to disk where a real fault could be buried
    /// forever.
    private var dismissedIDs: Set<String> = []

    /// Nothing is persisted, so a relaunch re-audits from scratch.
    init() {}

    func dismiss(_ issue: ConfigurationIssue) {
        dismissedIDs.insert(issue.id)
        issues.removeAll { $0.id == issue.id }
    }

    func restoreDismissed() {
        dismissedIDs.removeAll()
    }

    /// Re-reads every service and recomputes the findings.
    func refresh(
        serviceManager: ArrServiceManager,
        trawlClients: [DownloadClientLinkKind: [String]],
        seerrServiceManager: SeerrServiceManager? = nil,
        cleanuparrServiceManager: CleanuparrServiceManager? = nil,
        inputRevision: String? = nil
    ) async {
        guard !isAuditing else { return }
        isAuditing = true
        defer { isAuditing = false }

        let snapshot = await snapshot(
            serviceManager: serviceManager,
            trawlClients: trawlClients,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager
        )
        let found = ConfigurationAudit.issues(in: snapshot)
        issues = found.filter { !dismissedIDs.contains($0.id) }
        lastAuditDate = .now
        lastInputRevision = inputRevision
        Self.logger.info("Configuration audit found \(found.count) issues (\(found.problems.count) problems)")
    }

    /// Keeps passive surfaces fresh without making each appearance fan out across
    /// every service. Configuration changes invalidate immediately; otherwise the
    /// cached result is reused for five minutes.
    func refreshIfNeeded(
        serviceManager: ArrServiceManager,
        trawlClients: [DownloadClientLinkKind: [String]],
        seerrServiceManager: SeerrServiceManager? = nil,
        cleanuparrServiceManager: CleanuparrServiceManager? = nil,
        inputRevision: String,
        maxAge: TimeInterval = 300
    ) async {
        let isFresh = lastAuditDate.map { Date.now.timeIntervalSince($0) < maxAge } ?? false
        guard !isFresh || lastInputRevision != inputRevision else { return }
        await refresh(
            serviceManager: serviceManager,
            trawlClients: trawlClients,
            seerrServiceManager: seerrServiceManager,
            cleanuparrServiceManager: cleanuparrServiceManager,
            inputRevision: inputRevision
        )
    }

    // MARK: Collection

    private func snapshot(
        serviceManager: ArrServiceManager,
        trawlClients: [DownloadClientLinkKind: [String]],
        seerrServiceManager: SeerrServiceManager?,
        cleanuparrServiceManager: CleanuparrServiceManager?
    ) async -> ConfigurationSnapshot {
        var snapshot = ConfigurationSnapshot(
            trawlClients: trawlClients,
            isProwlarrConfigured: serviceManager.hasProwlarrInstance
        )
        snapshot.servers = await servers(serviceManager: serviceManager)
        snapshot.prowlarrApplications = await prowlarrApplications(serviceManager: serviceManager)
        snapshot.bazarrServers = await bazarrServers(serviceManager: serviceManager)
        snapshot.seerr = await seerrSetup(seerrServiceManager)
        snapshot.cleanuparr = cleanuparrStatus(cleanuparrServiceManager)
        return snapshot
    }

    private func servers(serviceManager: ArrServiceManager) async -> [ConfigurationSnapshot.Server] {
        let profiles = serviceManager.storedProfiles.filter {
            $0.isEnabled && ($0.resolvedServiceType == .sonarr || $0.resolvedServiceType == .radarr)
        }
        guard !profiles.isEmpty else { return [] }

        var servers: [ConfigurationSnapshot.Server] = []
        for profile in profiles {
            guard let serviceType = profile.resolvedServiceType else { continue }
            let ref = serviceManager.instanceRef(serviceType, id: profile.id)
                ?? ArrInstanceRef(id: profile.id, serviceType: serviceType, displayName: profile.displayName, tier: profile.qualityTier)
            guard serviceManager.isConnected(serviceType, profileID: profile.id),
                  let client = serviceManager.sharedClient(for: ref) else {
                servers.append(ConfigurationSnapshot.Server(
                    instanceID: profile.id,
                    serviceType: serviceType,
                    displayName: displayName(for: ref, serviceManager: serviceManager),
                    isConnected: false,
                    host: profile.hostURL
                ))
                continue
            }

            // Each read is independently optional: one failing must not turn the
            // others into "could not ask", which would silence real findings.
            async let clientsResult = try? await client.getDownloadClients()
            async let foldersResult = try? await client.getRootFolders()
            async let indexersResult = try? await client.getIndexers() as [ArrManagedIndexer]?
            async let healthResult = try? await client.getHealth()
            async let mappingsResult = try? await client.getRemotePathMappings()

            let downloadClients = await clientsResult.map { fetched in
                fetched.map {
                    ConfigurationSnapshot.DownloadClient(
                        name: $0.name ?? "Download Client",
                        implementation: $0.implementation ?? "",
                        host: $0.hostDisplayValue ?? "",
                        port: $0.portDisplayValue,
                        isEnabled: $0.enable,
                        category: $0.categoryDisplayValue
                    )
                }
            }
            let rootFolders = await foldersResult.map { fetched in
                fetched.map {
                    ConfigurationSnapshot.RootFolder(path: $0.path, isAccessible: $0.accessible ?? true)
                }
            }
            let indexers = await indexersResult
            let enabledIndexerCount = indexers.map { fetched in
                fetched.count { $0.enableRss || $0.enableAutomaticSearch || $0.enableInteractiveSearch }
            }
            // RSS and automatic search only. An interactive-only indexer answers a
            // person pressing Search and nothing else, so counting it as coverage is
            // how a library that never grabs anything on its own looks healthy.
            let automaticIndexerCount = indexers.map { fetched in
                fetched.count { $0.enableRss || $0.enableAutomaticSearch }
            }
            let indexerBaseURLs = indexers.map { fetched in
                fetched.compactMap(\.baseURLDisplayValue)
            }
            let healthChecks = await healthResult.map { fetched in
                fetched.map {
                    ConfigurationSnapshot.HealthCheck(
                        source: $0.source ?? "",
                        type: $0.type ?? "",
                        message: $0.message ?? ""
                    )
                }
            }
            let remotePathMappings = await mappingsResult.map { fetched in
                fetched.map {
                    ConfigurationSnapshot.RemotePathMapping(
                        host: $0.host,
                        remotePath: $0.remotePath,
                        localPath: $0.localPath
                    )
                }
            }

            servers.append(ConfigurationSnapshot.Server(
                instanceID: ref.id,
                serviceType: ref.serviceType,
                displayName: displayName(for: ref, serviceManager: serviceManager),
                isConnected: true,
                downloadClients: downloadClients,
                rootFolders: rootFolders,
                enabledIndexerCount: enabledIndexerCount,
                automaticIndexerCount: automaticIndexerCount,
                indexerBaseURLs: indexerBaseURLs,
                healthChecks: healthChecks,
                remotePathMappings: remotePathMappings,
                host: profile.hostURL
            ))
        }
        return servers
    }

    private func prowlarrApplications(
        serviceManager: ArrServiceManager
    ) async -> [ConfigurationSnapshot.ProwlarrApplication]? {
        guard let client = serviceManager.prowlarrClient else { return nil }
        guard let applications = try? await client.getApplications() else { return nil }
        return applications.map { application in
            ConfigurationSnapshot.ProwlarrApplication(
                name: application.name ?? "Application",
                serviceType: application.linkedAppType.map { $0 == .sonarr ? .sonarr : .radarr },
                baseURL: application.stringFieldValue(named: "baseUrl"),
                isSyncDisabled: application.syncLevel == .disabled
            )
        }
    }

    private func bazarrServers(serviceManager: ArrServiceManager) async -> [ConfigurationSnapshot.BazarrServer] {
        let refs = serviceManager.bazarrRefs
        guard !refs.isEmpty else { return [] }

        var servers: [ConfigurationSnapshot.BazarrServer] = []
        for ref in refs {
            var linked: Set<ArrServiceType>?
            var linkedBaseURLs: [ArrServiceType: String] = [:]
            var languageProfileCount: Int?
            var enabledProviderCount: Int?
            let isConnected = serviceManager.isConnected(.bazarr, profileID: ref.id)
            if isConnected, let client = serviceManager.bazarrClient(for: ref.id) {
                // Each read is independently optional, for the reason the Arr reads
                // are: one failing must not turn the others into "could not ask".
                async let settingsResult = try? await client.getSettings()
                async let profilesResult = try? await client.getLanguageProfiles()
                async let providersResult = try? await client.getProviders()

                if let settings = await settingsResult {
                    linked = Set(
                        BazarrLinkedApplicationType.allCases
                            .filter { settings.bazarrLinkedAppIsEnabled($0) }
                            .map(\.serviceType)
                    )
                    for appType in BazarrLinkedApplicationType.allCases {
                        guard let address = settings.bazarrLinkedAppBaseURL(appType) else { continue }
                        linkedBaseURLs[appType.serviceType] = address
                    }
                }
                languageProfileCount = await profilesResult?.count
                enabledProviderCount = await providersResult?.count
            }
            servers.append(ConfigurationSnapshot.BazarrServer(
                instanceID: ref.id,
                displayName: displayName(for: ref, serviceManager: serviceManager),
                isConnected: isConnected,
                linkedApps: linked,
                linkedBaseURLs: linkedBaseURLs,
                languageProfileCount: languageProfileCount,
                enabledProviderCount: enabledProviderCount
            ))
        }
        return servers
    }

    // MARK: Seerr and Cleanuparr

    /// Seerr's request routing, as far as it can be read.
    ///
    /// `isConfigured` has to be told to us rather than inferred: the manager clears
    /// its active profile when a connection drops, so "no active client" cannot tell
    /// a Seerr that was never set up from one that is broken - and that difference is
    /// exactly what decides whether silence here is a pass or a finding.
    private func seerrSetup(_ manager: SeerrServiceManager?) async -> ConfigurationSnapshot.SeerrSetup? {
        guard let manager, manager.hasConfiguredProfile else { return nil }
        guard manager.isConnected, let client = manager.activeClient else {
            return ConfigurationSnapshot.SeerrSetup(isConnected: false, isInitialized: nil, dvrServers: nil)
        }

        async let settingsResult = try? await client.getPublicSettings()
        async let sonarrResult = try? await client.getDVRSettings(.sonarr)
        async let radarrResult = try? await client.getDVRSettings(.radarr)

        // Nil only when the read itself failed. A Seerr that answers but omits the
        // flag is up and serving, so treating a missing field as "unknown" would
        // report every older Overseerr as unverifiable.
        let isInitialized = await settingsResult.map { $0.initialized ?? true }
        let sonarr = await sonarrResult
        let radarr = await radarrResult

        // Nil only when *both* lists failed. One kind answering while the other does
        // not is still enough to report on the one that did.
        var dvrServers: [ConfigurationSnapshot.SeerrDVR]?
        if sonarr != nil || radarr != nil {
            dvrServers = (sonarr ?? []).map { seerrDVR($0, serviceType: .sonarr) }
                + (radarr ?? []).map { seerrDVR($0, serviceType: .radarr) }
        }

        return ConfigurationSnapshot.SeerrSetup(
            isConnected: true,
            isInitialized: isInitialized,
            dvrServers: dvrServers
        )
    }

    private func seerrDVR(
        _ settings: SeerrDVRSettings,
        serviceType: ArrServiceType
    ) -> ConfigurationSnapshot.SeerrDVR {
        ConfigurationSnapshot.SeerrDVR(
            name: settings.name,
            serviceType: serviceType,
            is4k: settings.is4k ?? false,
            isDefault: settings.isDefault ?? false,
            baseURL: settings.displayURL,
            hasRootFolder: !settings.activeDirectory.trimmingCharacters(in: .whitespaces).isEmpty,
            hasQualityProfile: settings.activeProfileId > 0
        )
    }

    /// Cleanuparr already decides for itself whether it can run; this only reads the
    /// answer it has cached from its own connect.
    private func cleanuparrStatus(
        _ manager: CleanuparrServiceManager?
    ) -> ConfigurationSnapshot.CleanuparrStatus? {
        guard let manager, manager.hasConfiguredProfile else { return nil }
        guard manager.isConnected else {
            return ConfigurationSnapshot.CleanuparrStatus(isConnected: false, isReady: nil)
        }
        return ConfigurationSnapshot.CleanuparrStatus(isConnected: true, isReady: manager.isReady)
    }

    /// "Radarr" with one server of that type, the server's own name with two, so a
    /// finding names the thing the user has to go and change.
    private func displayName(for ref: ArrInstanceRef, serviceManager: ArrServiceManager) -> String {
        guard serviceManager.showsInstanceProvenance(for: ref.serviceType) else {
            return ref.serviceType.displayName
        }
        return ref.displayName
    }
}
