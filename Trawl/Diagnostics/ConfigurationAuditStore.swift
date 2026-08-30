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

    var problems: [ConfigurationIssue] { issues.problems }
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
        trawlClients: [DownloadClientLinkKind: String]
    ) async {
        guard !isAuditing else { return }
        isAuditing = true
        defer { isAuditing = false }

        let snapshot = await snapshot(serviceManager: serviceManager, trawlClients: trawlClients)
        let found = ConfigurationAudit.issues(in: snapshot)
        issues = found.filter { !dismissedIDs.contains($0.id) }
        lastAuditDate = .now
        Self.logger.info("Configuration audit found \(found.count) issues (\(found.problems.count) problems)")
    }

    // MARK: Collection

    private func snapshot(
        serviceManager: ArrServiceManager,
        trawlClients: [DownloadClientLinkKind: String]
    ) async -> ConfigurationSnapshot {
        var snapshot = ConfigurationSnapshot(trawlClients: trawlClients)
        snapshot.servers = await servers(serviceManager: serviceManager)
        snapshot.prowlarrApplicationHosts = await prowlarrApplicationHosts(serviceManager: serviceManager)
        snapshot.bazarrServers = await bazarrServers(serviceManager: serviceManager)
        return snapshot
    }

    private func servers(serviceManager: ArrServiceManager) async -> [ConfigurationSnapshot.Server] {
        let instances = serviceManager.visibleArrInstances
        guard !instances.isEmpty else { return [] }

        var servers: [ConfigurationSnapshot.Server] = []
        for (ref, client) in instances {
            // Each read is independently optional: one failing must not turn the
            // other two into "could not ask", which would silence real findings.
            async let clientsResult = try? await client.getDownloadClients()
            async let foldersResult = try? await client.getRootFolders()
            async let indexersResult = try? await client.getIndexers() as [ArrManagedIndexer]?

            let downloadClients = await clientsResult.map { fetched in
                fetched.map {
                    ConfigurationSnapshot.DownloadClient(
                        name: $0.name ?? "Download Client",
                        implementation: $0.implementation ?? "",
                        host: $0.hostDisplayValue ?? "",
                        isEnabled: $0.enable
                    )
                }
            }
            let rootFolders = await foldersResult.map { fetched in
                fetched.map {
                    ConfigurationSnapshot.RootFolder(path: $0.path, isAccessible: $0.accessible ?? true)
                }
            }
            let enabledIndexerCount = await indexersResult.map { fetched in
                fetched.count { $0.enableRss || $0.enableAutomaticSearch || $0.enableInteractiveSearch }
            }

            servers.append(ConfigurationSnapshot.Server(
                instanceID: ref.id,
                serviceType: ref.serviceType,
                displayName: displayName(for: ref, serviceManager: serviceManager),
                isConnected: true,
                downloadClients: downloadClients,
                rootFolders: rootFolders,
                enabledIndexerCount: enabledIndexerCount,
                host: serviceManager.storedProfiles.first { $0.id == ref.id }?.hostURL
            ))
        }
        return servers
    }

    private func prowlarrApplicationHosts(serviceManager: ArrServiceManager) async -> [String]? {
        guard let client = serviceManager.prowlarrClient else { return nil }
        guard let applications = try? await client.getApplications() else { return nil }
        return applications.compactMap { $0.stringFieldValue(named: "baseUrl") }
    }

    private func bazarrServers(serviceManager: ArrServiceManager) async -> [ConfigurationSnapshot.BazarrServer] {
        let refs = serviceManager.bazarrRefs
        guard !refs.isEmpty else { return [] }

        var servers: [ConfigurationSnapshot.BazarrServer] = []
        for ref in refs {
            var linked: Set<ArrServiceType>?
            if let client = serviceManager.bazarrClient(for: ref.id),
               let settings = try? await client.getSettings() {
                linked = Set(
                    BazarrLinkedApplicationType.allCases
                        .filter { settings.bazarrLinkedAppIsEnabled($0) }
                        .map(\.serviceType)
                )
            }
            servers.append(ConfigurationSnapshot.BazarrServer(
                instanceID: ref.id,
                displayName: displayName(for: ref, serviceManager: serviceManager),
                linkedApps: linked
            ))
        }
        return servers
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
