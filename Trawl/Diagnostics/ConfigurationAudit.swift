//
//  ConfigurationAudit.swift
//  Trawl
//
//  Reconciles what each service has been told about the others.
//

import Foundation

/// Everything the audit needs, as plain values.
///
/// The fetching lives in `ConfigurationAuditStore`; this is what it produces. Keeping
/// the two apart is what makes the checks testable: every rule below is a pure
/// function of this struct, so a test builds the wiring it wants to describe instead
/// of standing up servers.
struct ConfigurationSnapshot: Sendable, Hashable {

    struct DownloadClient: Sendable, Hashable {
        let name: String
        /// The `implementation` value Sonarr/Radarr report, e.g. "QBittorrent".
        let implementation: String
        let host: String
        let isEnabled: Bool

        init(name: String, implementation: String, host: String, isEnabled: Bool) {
            self.name = name
            self.implementation = implementation
            self.host = host
            self.isEnabled = isEnabled
        }
    }

    struct RootFolder: Sendable, Hashable {
        let path: String
        let isAccessible: Bool

        init(path: String, isAccessible: Bool = true) {
            self.path = path
            self.isAccessible = isAccessible
        }
    }

    /// One Sonarr or Radarr server.
    ///
    /// The optionals mean "could not ask" - a server that is down, or a request that
    /// failed. They are never reported as faults: claiming a link is broken when we
    /// simply could not look sends the user hunting for a problem that isn't there.
    struct Server: Sendable, Hashable {
        let instanceID: UUID
        let serviceType: ArrServiceType
        let displayName: String
        let isConnected: Bool
        let downloadClients: [DownloadClient]?
        let rootFolders: [RootFolder]?
        let enabledIndexerCount: Int?
        /// The address Prowlarr would have to be pointed at to sync this server.
        let host: String?

        init(
            instanceID: UUID,
            serviceType: ArrServiceType,
            displayName: String,
            isConnected: Bool = true,
            downloadClients: [DownloadClient]? = nil,
            rootFolders: [RootFolder]? = nil,
            enabledIndexerCount: Int? = nil,
            host: String? = nil
        ) {
            self.instanceID = instanceID
            self.serviceType = serviceType
            self.displayName = displayName
            self.isConnected = isConnected
            self.downloadClients = downloadClients
            self.rootFolders = rootFolders
            self.enabledIndexerCount = enabledIndexerCount
            self.host = host
        }
    }

    struct BazarrServer: Sendable, Hashable {
        let instanceID: UUID
        let displayName: String
        /// Which apps this Bazarr has switched on. Nil when its settings could not
        /// be read, which stays silent rather than reporting everything unlinked.
        let linkedApps: Set<ArrServiceType>?

        init(instanceID: UUID, displayName: String, linkedApps: Set<ArrServiceType>?) {
            self.instanceID = instanceID
            self.displayName = displayName
            self.linkedApps = linkedApps
        }
    }

    /// Sonarr and Radarr servers. Prowlarr and Bazarr are carried separately because
    /// the checks that concern them are about what they point *at*.
    var servers: [Server] = []
    /// The download clients Trawl itself is configured with, keyed by kind.
    var trawlClients: [DownloadClientLinkKind: String] = [:]
    /// Hosts Prowlarr is set to sync to. Nil when no Prowlarr is configured, or its
    /// applications could not be read.
    var prowlarrApplicationHosts: [String]?
    var bazarrServers: [BazarrServer] = []

    init(
        servers: [Server] = [],
        trawlClients: [DownloadClientLinkKind: String] = [:],
        prowlarrApplicationHosts: [String]? = nil,
        bazarrServers: [BazarrServer] = []
    ) {
        self.servers = servers
        self.trawlClients = trawlClients
        self.prowlarrApplicationHosts = prowlarrApplicationHosts
        self.bazarrServers = bazarrServers
    }
}

/// The rules. Every one is a pure function of the snapshot.
enum ConfigurationAudit {

    static func issues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        for server in snapshot.servers where server.isConnected {
            issues += downloadClientIssues(for: server, snapshot: snapshot)
            issues += rootFolderIssues(for: server)
            issues += indexerIssues(for: server)
        }
        issues += sharedRootFolderIssues(in: snapshot)
        issues += unusedTrawlClientIssues(in: snapshot)
        issues += prowlarrIssues(in: snapshot)
        issues += bazarrIssues(in: snapshot)
        return issues.displayOrdered
    }

    // MARK: Download clients

    /// Deliberately per server, not unioned across a service.
    ///
    /// A pair does not share download clients, so "Radarr has a client somewhere"
    /// is not the question - each server grabs through its own. Answering it for the
    /// service as a whole is exactly how a 4K server with no client at all stays
    /// invisible behind a healthy HD one.
    private static func downloadClientIssues(
        for server: ConfigurationSnapshot.Server,
        snapshot: ConfigurationSnapshot
    ) -> [ConfigurationIssue] {
        guard let clients = server.downloadClients else { return [] }
        let subject = subject(for: server)

        guard !clients.isEmpty else {
            return [ConfigurationIssue(
                kind: .noDownloadClient,
                severity: .problem,
                subject: subject,
                title: "\(server.displayName) has no download client",
                detail: "Grabs from \(server.displayName) have nowhere to go, so every release it tries to download will fail.",
                fix: .open(
                    .arrDownloadClients(server.serviceType),
                    actionTitle: "Add a Download Client",
                    guidance: "Add the download client Trawl uses to \(server.displayName)."
                )
            )]
        }

        let enabled = clients.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            return [ConfigurationIssue(
                kind: .downloadClientsAllDisabled,
                severity: .problem,
                subject: subject,
                title: "\(server.displayName)'s download clients are all disabled",
                detail: "\(server.displayName) has \(clients.count == 1 ? "a download client" : "\(clients.count) download clients") configured, but none are enabled, so nothing can be grabbed.",
                fix: .open(
                    .arrDownloadClients(server.serviceType),
                    actionTitle: "Review Download Clients",
                    guidance: "Enable a download client on \(server.displayName)."
                )
            )]
        }

        // Only compare against clients Trawl itself knows, because only those have a
        // host to compare with. A server pointed at something Trawl has never heard
        // of is a legitimate setup, not a fault.
        var issues: [ConfigurationIssue] = []
        for (kind, trawlHost) in snapshot.trawlClients.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let sameKind = enabled.filter {
                $0.implementation.caseInsensitiveCompare(kind.arrImplementation) == .orderedSame
            }
            guard !sameKind.isEmpty else { continue }
            let trawlNormalized = DownloadClientLinkChecker.normalizedHost(from: trawlHost)
            let matched = sameKind.contains {
                DownloadClientLinkChecker.normalizedHost(from: $0.host) == trawlNormalized
            }
            guard !matched, let other = sameKind.first else { continue }
            issues.append(ConfigurationIssue(
                kind: .downloadClientElsewhere,
                severity: .note,
                subject: subject,
                title: "\(server.displayName)'s \(kind.displayName) is a different address",
                detail: "\(server.displayName) sends \(kind.displayName) downloads to \(other.host), while Trawl talks to \(trawlHost). Often the same machine by two names - worth a look only if downloads never appear.",
                fix: .manual(guidance: "If these are the same machine, nothing needs changing.")
            ))
        }
        return issues
    }

    /// A client Trawl talks to that nothing grabs through. Harmless on its own -
    /// the queue still shows - but it means Arr downloads will never land in it.
    private static func unusedTrawlClientIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        let servers = snapshot.servers.filter { $0.isConnected && $0.downloadClients != nil }
        guard !servers.isEmpty else { return [] }

        return snapshot.trawlClients
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .compactMap { kind, host in
                let referenced = servers.contains { server in
                    (server.downloadClients ?? []).contains {
                        $0.isEnabled && $0.implementation.caseInsensitiveCompare(kind.arrImplementation) == .orderedSame
                    }
                }
                guard !referenced else { return nil }
                return ConfigurationIssue(
                    kind: .downloadClientUnused,
                    severity: .note,
                    subject: ConfigurationIssueSubject(displayName: kind.displayName),
                    title: "Nothing grabs through \(kind.displayName)",
                    detail: "Trawl is connected to \(kind.displayName) at \(host), but no Sonarr or Radarr server sends downloads to it. You will see its queue, but nothing from your library will arrive in it.",
                    fix: .open(
                        .downloadClientsManagement,
                        actionTitle: "Review Clients",
                        guidance: "Add \(kind.displayName) to a Sonarr or Radarr server, or ignore this if it is used outside Trawl."
                    )
                )
            }
    }

    // MARK: Root folders

    private static func rootFolderIssues(for server: ConfigurationSnapshot.Server) -> [ConfigurationIssue] {
        guard let folders = server.rootFolders else { return [] }
        let subject = subject(for: server)

        guard !folders.isEmpty else {
            return [ConfigurationIssue(
                kind: .noRootFolder,
                severity: .problem,
                subject: subject,
                title: "\(server.displayName) has no root folder",
                detail: "Nothing can be added to \(server.displayName) until it has somewhere to put it.",
                fix: .open(.rootFolders, actionTitle: "Add a Root Folder", guidance: "Add a root folder to \(server.displayName).")
            )]
        }

        let unreachable = folders.filter { !$0.isAccessible }
        guard !unreachable.isEmpty else { return [] }
        let paths = unreachable.map(\.path).joined(separator: ", ")
        return [ConfigurationIssue(
            kind: .rootFolderInaccessible,
            severity: .problem,
            subject: subject,
            title: "\(server.displayName) cannot reach a root folder",
            detail: "\(server.displayName) reports \(paths) as inaccessible. Imports into it will fail until the path or its permissions are fixed on the server.",
            fix: .open(.rootFolders, actionTitle: "Review Root Folders", guidance: "Check the mount and permissions for \(paths) on the \(server.serviceType.displayName) host.")
        )]
    }

    /// Two servers of the same service writing to one folder.
    ///
    /// This is the HD/4K failure that looks like nothing is wrong: both servers
    /// import into the same tree, each sees the other's files as unmanaged, and they
    /// take turns deleting and re-grabbing them.
    private static func sharedRootFolderIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        for serviceType in [ArrServiceType.sonarr, .radarr] {
            let servers = snapshot.servers.filter {
                $0.serviceType == serviceType && $0.isConnected && $0.rootFolders != nil
            }
            guard servers.count > 1 else { continue }

            var byPath: [String: [ConfigurationSnapshot.Server]] = [:]
            for server in servers {
                for folder in server.rootFolders ?? [] {
                    byPath[normalizedPath(folder.path), default: []].append(server)
                }
            }
            for (path, sharing) in byPath.sorted(by: { $0.key < $1.key }) where sharing.count > 1 {
                let names = sharing.map(\.displayName).sorted().joined(separator: " and ")
                issues.append(ConfigurationIssue(
                    kind: .rootFolderShared,
                    severity: .problem,
                    subject: ConfigurationIssueSubject(serviceType: serviceType, displayName: serviceType.displayName),
                    title: "\(names) share a root folder",
                    detail: "Both import into \(path). Each server treats the other's files as unmanaged, so they will compete over the same titles. Give each server its own folder.",
                    fix: .open(.rootFolders, actionTitle: "Review Root Folders", guidance: "Point \(names) at separate root folders.")
                ))
            }
        }
        return issues
    }

    // MARK: Indexers

    private static func indexerIssues(for server: ConfigurationSnapshot.Server) -> [ConfigurationIssue] {
        guard let count = server.enabledIndexerCount, count == 0 else { return [] }
        return [ConfigurationIssue(
            kind: .noIndexers,
            severity: .problem,
            subject: subject(for: server),
            title: "\(server.displayName) has no enabled indexer",
            detail: "\(server.displayName) has nowhere to search, so nothing will ever be found for it automatically.",
            fix: .open(.prowlarrIndexers, actionTitle: "Review Indexers", guidance: "Add an indexer to \(server.displayName), or sync one from Prowlarr.")
        )]
    }

    // MARK: Prowlarr

    /// Prowlarr syncs indexers into each Arr it has an application entry for. A
    /// server missing from that list quietly gets none.
    private static func prowlarrIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        guard let applicationHosts = snapshot.prowlarrApplicationHosts else { return [] }
        let synced = Set(applicationHosts.map(normalizedEndpoint(from:)))

        return snapshot.servers
            .filter { $0.isConnected }
            .compactMap { server in
                guard let host = server.host else { return nil }
                guard !synced.contains(normalizedEndpoint(from: host)) else { return nil }
                return ConfigurationIssue(
                    kind: .missingProwlarrApplication,
                    severity: .problem,
                    subject: subject(for: server),
                    title: "Prowlarr does not sync to \(server.displayName)",
                    detail: "Prowlarr has no application entry for \(server.displayName), so the indexers you manage there never reach it.",
                    fix: .open(.prowlarrApplications, actionTitle: "Review Prowlarr Apps", guidance: "Add \(server.displayName) as an application in Prowlarr.")
                )
            }
    }

    // MARK: Bazarr

    /// Bazarr only fetches subtitles for libraries it is linked to, and each Bazarr
    /// keeps its own links - so one being connected says nothing about the other.
    private static func bazarrIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        let configuredServices = Set(
            snapshot.servers.filter(\.isConnected).map(\.serviceType)
        ).intersection([.sonarr, .radarr])
        guard !configuredServices.isEmpty else { return [] }

        var issues: [ConfigurationIssue] = []
        for bazarr in snapshot.bazarrServers {
            guard let linked = bazarr.linkedApps else { continue }
            for serviceType in configuredServices.sorted(by: { $0.rawValue < $1.rawValue }) where !linked.contains(serviceType) {
                issues.append(ConfigurationIssue(
                    kind: .bazarrAppNotLinked,
                    severity: .problem,
                    subject: ConfigurationIssueSubject(
                        instanceID: bazarr.instanceID,
                        serviceType: .bazarr,
                        displayName: bazarr.displayName
                    ),
                    title: "\(bazarr.displayName) is not linked to \(serviceType.displayName)",
                    detail: "\(bazarr.displayName) will not fetch subtitles for anything in \(serviceType.displayName) until the two are connected.",
                    fix: .open(.bazarrLinkedApplications, actionTitle: "Link \(serviceType.displayName)", guidance: "Turn on \(serviceType.displayName) in \(bazarr.displayName)'s linked apps.")
                ))
            }
        }
        return issues
    }

    // MARK: Helpers

    private static func subject(for server: ConfigurationSnapshot.Server) -> ConfigurationIssueSubject {
        ConfigurationIssueSubject(
            instanceID: server.instanceID,
            serviceType: server.serviceType,
            displayName: server.displayName
        )
    }

    /// Host *and* port, unlike the download-client comparison.
    ///
    /// An HD/4K pair is usually one machine on two ports. Folding the port away, the
    /// way the download-client check has to, would make Prowlarr's entry for one of
    /// them look like an entry for both - and the server that genuinely has no entry
    /// would never be reported, which is the one case this check exists for. The port
    /// is available here because both sides are full URLs: Prowlarr's `baseUrl`, and
    /// the server's own host URL.
    static func normalizedEndpoint(from value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        // Without a scheme, `URLComponents` reads "10.0.0.5:7878" as a scheme and a
        // path rather than a host and a port.
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }

        guard let components = URLComponents(string: trimmed), let host = components.host else {
            return DownloadClientLinkChecker.normalizedHost(from: value)
        }
        let port = components.port ?? (components.scheme == "https" ? 443 : 80)
        return "\(DownloadClientLinkChecker.normalizedHost(from: host)):\(port)"
    }

    /// Trailing slashes and case are not a difference worth reporting as two folders.
    static func normalizedPath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}
