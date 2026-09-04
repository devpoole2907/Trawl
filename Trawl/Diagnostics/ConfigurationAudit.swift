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
        let port: String?
        let isEnabled: Bool
        /// The category this server tags its downloads with. Two servers sharing one
        /// client *and* one category is how an HD queue and a 4K queue get mixed:
        /// each server sees the other's downloads as its own and imports them.
        let category: String?

        init(
            name: String,
            implementation: String,
            host: String,
            port: String? = nil,
            isEnabled: Bool,
            category: String? = nil
        ) {
            self.name = name
            self.implementation = implementation
            self.host = host
            self.port = port
            self.isEnabled = isEnabled
            self.category = category
        }

        /// Host and port, in the one spelling both sides of a comparison agree on.
        var endpoint: String {
            DownloadClientLinkChecker.normalizedEndpoint(host: host, port: port)
        }

        var normalizedCategory: String? {
            let trimmed = (category ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// One entry from an Arr's own `/health`.
    ///
    /// Arr already checks things Trawl cannot see from outside - whether a download
    /// client actually answers, whether an import path resolves, whether an indexer
    /// has been failing - and the app was throwing that away. `type` is Arr's own
    /// vocabulary: "ok", "notice", "warning", "error".
    struct HealthCheck: Sendable, Hashable {
        let source: String
        let type: String
        let message: String

        init(source: String, type: String, message: String) {
            self.source = source
            self.type = type
            self.message = message
        }

        var isError: Bool { type.caseInsensitiveCompare("error") == .orderedSame }
        var isWarning: Bool { type.caseInsensitiveCompare("warning") == .orderedSame }

        /// Checks whose subject is something this audit is also about, so a failure
        /// Trawl cannot see from outside is still reported as a problem rather than
        /// as a passing remark. Anything else stays a note however loudly Arr words
        /// it: an out-of-date branch warning is not a reason to tell someone their
        /// setup is broken.
        static let blockingSources: Set<String> = [
            "downloadclientcheck",
            "downloadclientstatuscheck",
            "downloadclientrootfoldercheck",
            "importmechanismcheck",
            "remotepathmappingcheck",
            "rootfoldercheck",
            "indexerstatuscheck",
            "indexerlongtermstatuscheck",
            "indexersearchcheck",
            "applicationlongtermstatuscheck",
            "applicationstatuscheck"
        ]

        var isBlocking: Bool {
            isError || (isWarning && Self.blockingSources.contains(source.lowercased()))
        }
    }

    /// One row of an Arr's remote path mapping table.
    struct RemotePathMapping: Sendable, Hashable {
        let host: String
        let remotePath: String
        let localPath: String

        init(host: String, remotePath: String, localPath: String) {
            self.host = host
            self.remotePath = remotePath
            self.localPath = localPath
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
    /// failed. They become an explicit unknown result rather than either claiming a
    /// fault or silently treating a check we could not perform as healthy.
    struct Server: Sendable, Hashable {
        let instanceID: UUID
        let serviceType: ArrServiceType
        let displayName: String
        let isConnected: Bool
        let downloadClients: [DownloadClient]?
        let rootFolders: [RootFolder]?
        let enabledIndexerCount: Int?
        /// Indexers that can be reached without a person driving them - RSS or
        /// automatic search. Counted apart from `enabledIndexerCount` because an
        /// interactive-only indexer satisfies "has an indexer" while leaving every
        /// automatic grab with nowhere to look, which is the silent half of the
        /// original check.
        let automaticIndexerCount: Int?
        /// The addresses this server's indexers point at. Read only to work out
        /// whether something else is managing them - see `ProwlarrIndexerOrigin`.
        let indexerBaseURLs: [String]?
        let healthChecks: [HealthCheck]?
        let remotePathMappings: [RemotePathMapping]?
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
            automaticIndexerCount: Int? = nil,
            indexerBaseURLs: [String]? = nil,
            healthChecks: [HealthCheck]? = nil,
            remotePathMappings: [RemotePathMapping]? = nil,
            host: String? = nil
        ) {
            self.instanceID = instanceID
            self.serviceType = serviceType
            self.displayName = displayName
            self.isConnected = isConnected
            self.downloadClients = downloadClients
            self.rootFolders = rootFolders
            self.enabledIndexerCount = enabledIndexerCount
            self.automaticIndexerCount = automaticIndexerCount
            self.indexerBaseURLs = indexerBaseURLs
            self.healthChecks = healthChecks
            self.remotePathMappings = remotePathMappings
            self.host = host
        }
    }

    struct BazarrServer: Sendable, Hashable {
        let instanceID: UUID
        let displayName: String
        let isConnected: Bool
        /// Which apps this Bazarr has switched on. Nil when its settings could not
        /// be read, which becomes unknown rather than reporting everything unlinked.
        let linkedApps: Set<ArrServiceType>?
        /// The address Bazarr has been given for each app it is linked to. A switch
        /// being on says Bazarr will *try*; this says whether it is trying the right
        /// server, which for an HD/4K pair is a different question.
        let linkedBaseURLs: [ArrServiceType: String]
        /// Bazarr fetches nothing without a language profile to fetch *for*, and
        /// nothing without a provider to fetch *from*. Nil when the list could not be
        /// read, which is unknown rather than none.
        let languageProfileCount: Int?
        let enabledProviderCount: Int?

        init(
            instanceID: UUID,
            displayName: String,
            isConnected: Bool = true,
            linkedApps: Set<ArrServiceType>?,
            linkedBaseURLs: [ArrServiceType: String] = [:],
            languageProfileCount: Int? = 1,
            enabledProviderCount: Int? = 1
        ) {
            self.instanceID = instanceID
            self.displayName = displayName
            self.isConnected = isConnected
            self.linkedApps = linkedApps
            self.linkedBaseURLs = linkedBaseURLs
            self.languageProfileCount = languageProfileCount
            self.enabledProviderCount = enabledProviderCount
        }
    }

    /// One entry from Prowlarr's applications list.
    struct ProwlarrApplication: Sendable, Hashable {
        let name: String
        /// Which Arr this entry syncs to, when Prowlarr's implementation names one.
        let serviceType: ArrServiceType?
        let baseURL: String?
        /// Prowlarr syncs nothing to an application whose sync level is "disabled",
        /// so an entry that exists is not on its own evidence the server gets
        /// indexers.
        let isSyncDisabled: Bool

        init(name: String, serviceType: ArrServiceType?, baseURL: String?, isSyncDisabled: Bool = false) {
            self.name = name
            self.serviceType = serviceType
            self.baseURL = baseURL
            self.isSyncDisabled = isSyncDisabled
        }
    }

    /// One Sonarr or Radarr server as Seerr has been told about it.
    struct SeerrDVR: Sendable, Hashable {
        let name: String
        let serviceType: ArrServiceType
        let is4k: Bool
        let isDefault: Bool
        let baseURL: String
        let hasRootFolder: Bool
        let hasQualityProfile: Bool

        init(
            name: String,
            serviceType: ArrServiceType,
            is4k: Bool = false,
            isDefault: Bool = false,
            baseURL: String = "",
            hasRootFolder: Bool = true,
            hasQualityProfile: Bool = true
        ) {
            self.name = name
            self.serviceType = serviceType
            self.is4k = is4k
            self.isDefault = isDefault
            self.baseURL = baseURL
            self.hasRootFolder = hasRootFolder
            self.hasQualityProfile = hasQualityProfile
        }
    }

    /// Seerr takes requests and hands them to Sonarr and Radarr. Everything about it
    /// that can silently do nothing is a question of whether that handover exists.
    struct SeerrSetup: Sendable, Hashable {
        let displayName: String
        let isConnected: Bool
        /// Nil when Seerr's public settings could not be read.
        let isInitialized: Bool?
        /// Nil when that kind's server list could not be read.
        let dvrServers: [SeerrDVR]?

        init(
            displayName: String = "Seerr",
            isConnected: Bool = true,
            isInitialized: Bool? = true,
            dvrServers: [SeerrDVR]? = []
        ) {
            self.displayName = displayName
            self.isConnected = isConnected
            self.isInitialized = isInitialized
            self.dvrServers = dvrServers
        }
    }

    /// Cleanuparr already decides for itself whether it can reach the Arrs and the
    /// download clients it prunes. `isReady` is nil when Trawl could not ask.
    struct CleanuparrStatus: Sendable, Hashable {
        let displayName: String
        let isConnected: Bool
        let isReady: Bool?

        init(displayName: String = "Cleanuparr", isConnected: Bool = true, isReady: Bool? = true) {
            self.displayName = displayName
            self.isConnected = isConnected
            self.isReady = isReady
        }
    }

    /// Sonarr and Radarr servers. Prowlarr and Bazarr are carried separately because
    /// the checks that concern them are about what they point *at*.
    var servers: [Server] = []
    /// The download clients Trawl itself is configured with, keyed by kind.
    var trawlClients: [DownloadClientLinkKind: [String]] = [:]
    /// The applications Prowlarr is set to sync to. Nil when no Prowlarr is
    /// configured, or its applications could not be read.
    var prowlarrApplications: [ProwlarrApplication]?
    var isProwlarrConfigured = false
    var bazarrServers: [BazarrServer] = []
    /// Nil when no Seerr is configured.
    var seerr: SeerrSetup?
    /// Nil when no Cleanuparr is configured.
    var cleanuparr: CleanuparrStatus?

    init(
        servers: [Server] = [],
        trawlClients: [DownloadClientLinkKind: [String]] = [:],
        prowlarrApplications: [ProwlarrApplication]? = nil,
        isProwlarrConfigured: Bool = false,
        bazarrServers: [BazarrServer] = [],
        seerr: SeerrSetup? = nil,
        cleanuparr: CleanuparrStatus? = nil
    ) {
        self.servers = servers
        self.trawlClients = trawlClients
        self.prowlarrApplications = prowlarrApplications
        self.isProwlarrConfigured = isProwlarrConfigured
        self.bazarrServers = bazarrServers
        self.seerr = seerr
        self.cleanuparr = cleanuparr
    }
}

/// Where an Arr's indexers came from.
///
/// Prowlarr does not announce itself to the servers it syncs, and Sonarr and Radarr
/// keep no record that an indexer was synced rather than typed in. But it leaves one
/// unmistakable mark: it proxies every indexer it manages under its own numeric id,
/// so a synced Newznab entry points at `<prowlarr>/<id>/api` rather than at the
/// tracker itself. Nothing a person adds by hand looks like that.
///
/// That is enough to tell someone their indexers are being managed somewhere Trawl
/// cannot see - and, usefully, to tell them the address.
enum ProwlarrIndexerOrigin {

    /// The Prowlarr these indexers appear to be served through, if any.
    ///
    /// The most frequently seen address wins, so one stray hand-made entry that
    /// happens to fit the shape cannot outvote a real sync. Ties break alphabetically
    /// rather than arbitrarily: a finding that names a different server on each audit
    /// is worse than one that is occasionally arbitrary but always the same.
    static func syncedBaseURL(inIndexerBaseURLs baseURLs: [String]) -> String? {
        var counts: [String: Int] = [:]
        for raw in baseURLs {
            guard let base = proxyBase(of: raw) else { continue }
            counts[base, default: 0] += 1
        }
        return counts
            .max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }?
            .key
    }

    /// The address in front of a `/<id>/api` proxy path, or nil if this is not one.
    private static func proxyBase(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let host = components.host,
              !host.isEmpty else { return nil }

        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 2,
              segments[segments.count - 1].caseInsensitiveCompare("api") == .orderedSame else { return nil }
        let idSegment = segments[segments.count - 2]
        guard !idSegment.isEmpty, idSegment.allSatisfy(\.isNumber) else { return nil }

        // Whatever sits in front of the proxy path is Prowlarr's own address,
        // including a reverse-proxy URL base if there is one.
        let prefix = segments.dropLast(2).joined(separator: "/")
        components.path = prefix.isEmpty ? "" : "/" + prefix
        components.query = nil
        components.fragment = nil
        return components.string
    }
}

/// The rules. Every one is a pure function of the snapshot.
enum ConfigurationAudit {

    static func issues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        for server in snapshot.servers {
            guard server.isConnected else {
                issues.append(unreachableIssue(for: server))
                continue
            }
            issues += downloadClientIssues(for: server, snapshot: snapshot)
            issues += rootFolderIssues(for: server)
            issues += indexerIssues(for: server)
            issues += remotePathMappingIssues(for: server)
            issues += healthIssues(for: server)
            issues += unavailableConfigurationIssues(for: server)
        }
        issues += sharedRootFolderIssues(in: snapshot)
        issues += sharedDownloadCategoryIssues(in: snapshot)
        issues += unusedTrawlClientIssues(in: snapshot)
        issues += prowlarrIssues(in: snapshot)
        issues += prowlarrDiscoveryIssues(in: snapshot)
        issues += bazarrIssues(in: snapshot)
        issues += seerrIssues(in: snapshot)
        issues += cleanuparrIssues(in: snapshot)
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
                    .arrDownloadClients(server.serviceType, instanceID: server.instanceID),
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
                    .arrDownloadClients(server.serviceType, instanceID: server.instanceID),
                    actionTitle: "Review Download Clients",
                    guidance: "Enable a download client on \(server.displayName)."
                )
            )]
        }

        // Only compare against clients Trawl itself knows, because only those have a
        // host to compare with. A server pointed at something Trawl has never heard
        // of is a legitimate setup, not a fault.
        var issues: [ConfigurationIssue] = []
        for (kind, trawlHosts) in snapshot.trawlClients.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let sameKind = enabled.filter {
                $0.implementation.caseInsensitiveCompare(kind.arrImplementation) == .orderedSame
            }
            guard !sameKind.isEmpty else { continue }
            let matched = sameKind.contains {
                let arrEndpoint = DownloadClientLinkChecker.normalizedEndpoint(host: $0.host, port: $0.port)
                return trawlHosts.contains {
                    DownloadClientLinkChecker.normalizedEndpoint(from: $0) == arrEndpoint
                }
            }
            guard !matched, let other = sameKind.first else { continue }
            let arrAddress = DownloadClientLinkChecker.displayEndpoint(host: other.host, port: other.port)
            issues.append(ConfigurationIssue(
                kind: .downloadClientElsewhere,
                severity: .note,
                subject: subject,
                title: "\(server.displayName)'s \(kind.displayName) is a different address",
                detail: "\(server.displayName) sends \(kind.displayName) downloads to \(arrAddress), while Trawl talks to \(trawlHosts.joined(separator: ", ")). Often the same machine by two names - worth a look only if downloads never appear.",
                fix: .manual(guidance: "If these are the same endpoint, nothing needs changing."),
                discriminator: kind.rawValue
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
            .flatMap { kind, hosts in hosts.sorted().map { (kind, $0) } }
            .compactMap { kind, host in
                let expectedEndpoint = DownloadClientLinkChecker.normalizedEndpoint(from: host)
                let referenced = servers.contains { server in
                    (server.downloadClients ?? []).contains {
                        $0.isEnabled
                            && $0.implementation.caseInsensitiveCompare(kind.arrImplementation) == .orderedSame
                            && DownloadClientLinkChecker.normalizedEndpoint(host: $0.host, port: $0.port) == expectedEndpoint
                    }
                }
                guard !referenced else { return nil }
                return ConfigurationIssue(
                    kind: .downloadClientUnused,
                    severity: .note,
                    subject: ConfigurationIssueSubject(displayName: kind.displayName),
                    title: "Nothing grabs through \(kind.displayName) at \(host)",
                    detail: "Trawl is connected to \(kind.displayName) at \(host), but no Sonarr or Radarr server sends downloads to it. You will see its queue, but nothing from your library will arrive in it.",
                    fix: .open(
                        .downloadClientsManagement,
                        actionTitle: "Review Clients",
                        guidance: "Add this \(kind.displayName) endpoint to a Sonarr or Radarr server, or ignore this if it is used outside Trawl."
                    ),
                    discriminator: expectedEndpoint
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
                fix: .open(.rootFolders(instanceID: server.instanceID), actionTitle: "Add a Root Folder", guidance: "Add a root folder to \(server.displayName).")
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
            fix: .open(.rootFolders(instanceID: server.instanceID), actionTitle: "Review Root Folders", guidance: "Check the mount and permissions for \(paths) on the \(server.serviceType.displayName) host.")
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
                    fix: .open(.rootFolders(instanceID: sharing[0].instanceID), actionTitle: "Review Root Folders", guidance: "Point \(names) at separate root folders."),
                    discriminator: path
                ))
            }
        }
        return issues
    }

    // MARK: Indexers

    private static func indexerIssues(for server: ConfigurationSnapshot.Server) -> [ConfigurationIssue] {
        guard let count = server.enabledIndexerCount else { return [] }
        guard count > 0 else {
            return [ConfigurationIssue(
                kind: .noIndexers,
                severity: .problem,
                subject: subject(for: server),
                title: "\(server.displayName) has no enabled indexer",
                detail: "\(server.displayName) has nowhere to search, so nothing will ever be found for it automatically.",
                fix: .open(.prowlarrIndexers, actionTitle: "Review Indexers", guidance: "Add an indexer to \(server.displayName), or sync one from Prowlarr.")
            )]
        }

        // Having an indexer and being able to grab automatically are different
        // facts. An indexer with only interactive search enabled answers a person
        // pressing Search and nothing else, so monitoring, RSS and every automatic
        // grab silently find nothing while the setup looks complete.
        guard let automatic = server.automaticIndexerCount, automatic == 0 else { return [] }
        return [ConfigurationIssue(
            kind: .noAutomaticIndexer,
            severity: .problem,
            subject: subject(for: server),
            title: "\(server.displayName) can only search when you ask it to",
            detail: "Every indexer on \(server.displayName) has RSS and automatic search switched off, so monitored items will never be grabbed on their own - only an interactive search will find anything.",
            fix: .open(.prowlarrIndexers, actionTitle: "Review Indexers", guidance: "Turn on RSS or automatic search for at least one of \(server.displayName)'s indexers.")
        )]
    }

    // MARK: Remote paths

    /// A download client on another machine, and no mapping to translate its paths.
    ///
    /// Deliberately a note. Arr and its client frequently sit on different hosts
    /// while sharing an identical mount, in which case no mapping is needed and
    /// everything works - so this cannot be called a fault from the outside. The
    /// case where it genuinely is broken raises `RemotePathMappingCheck` in Arr's own
    /// health, which this audit now reports as a problem in its own right.
    private static func remotePathMappingIssues(
        for server: ConfigurationSnapshot.Server
    ) -> [ConfigurationIssue] {
        guard let mappings = server.remotePathMappings,
              let clients = server.downloadClients,
              let serverHost = server.host else { return [] }

        let ownHost = DownloadClientLinkChecker.normalizedHost(from: serverHost)
        let mapped = Set(mappings.map { DownloadClientLinkChecker.normalizedHost(from: $0.host) })

        let unmapped = clients
            .filter(\.isEnabled)
            .map { DownloadClientLinkChecker.normalizedHost(from: $0.host) }
            .filter { !$0.isEmpty && $0 != ownHost && !mapped.contains($0) }

        guard let host = Set(unmapped).sorted().first else { return [] }
        return [ConfigurationIssue(
            kind: .remotePathMappingMissing,
            severity: .note,
            subject: subject(for: server),
            title: "\(server.displayName) has no path mapping for \(host)",
            detail: "\(server.displayName) downloads through a client on \(host) and has no remote path mapping for it. That is correct when both see the same paths; if grabs succeed but imports never happen, this is the first thing to check.",
            fix: .open(.arrRemotePathMappings, actionTitle: "Review Path Mappings", guidance: "Add a mapping only if \(server.displayName) and the client on \(host) see the download folder at different paths."),
            discriminator: host
        )]
    }

    // MARK: Service health

    /// What the server says about itself.
    ///
    /// Arr checks things Trawl cannot see from outside - whether a download client
    /// actually answers, whether an indexer has been failing, whether an import path
    /// resolves - and the app was reading those only for a separate screen. A setup
    /// check that ignores them can call a server healthy while the server itself is
    /// saying otherwise.
    private static func healthIssues(for server: ConfigurationSnapshot.Server) -> [ConfigurationIssue] {
        guard let checks = server.healthChecks else { return [] }
        var seen: Set<String> = []
        return checks
            .filter { $0.isError || $0.isWarning }
            .compactMap { check in
                guard seen.insert(check.source.lowercased()).inserted else { return nil }
                let blocking = check.isBlocking
                return ConfigurationIssue(
                    kind: blocking ? .serviceHealthError : .serviceHealthWarning,
                    severity: blocking ? .problem : .note,
                    subject: subject(for: server),
                    // The wording follows the severity. Everything Arr raises came
                    // through one code path here and was titled "reports a problem",
                    // so "New update is available" - a notice, correctly filed as a
                    // note - was announced as a fault. A setup check that calls an
                    // available update a problem teaches people to ignore it.
                    title: blocking
                        ? "\(server.displayName) reports a problem"
                        : "\(server.displayName) has a notice",
                    detail: check.message,
                    fix: .open(
                        .arrHealth,
                        actionTitle: "Review Health",
                        guidance: blocking
                            ? "\(server.displayName) raised this itself. Fix it on the server, then run the setup check again."
                            : "\(server.displayName) raised this itself. Nothing here stops it working."
                    ),
                    discriminator: check.source
                )
            }
    }

    // MARK: Download categories

    /// Two servers grabbing into one client under one category.
    ///
    /// Each server treats everything in its category as its own, so an HD download
    /// and a 4K download land in the same bucket and whichever server polls first
    /// imports both. The category is what keeps them apart, which is why an empty
    /// one is not evidence of anything and is skipped.
    private static func sharedDownloadCategoryIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        let servers = snapshot.servers.filter { $0.isConnected && $0.downloadClients != nil }
        guard servers.count > 1 else { return [] }

        var byBucket: [String: [ConfigurationSnapshot.Server]] = [:]
        for server in servers {
            for client in (server.downloadClients ?? []).filter(\.isEnabled) {
                guard let category = client.normalizedCategory else { continue }
                byBucket["\(client.endpoint)#\(category)", default: []].append(server)
            }
        }

        return byBucket
            .sorted { $0.key < $1.key }
            .compactMap { bucket, sharing in
                // Sorted, and only then indexed. A dictionary's values come back in
                // no particular order, so picking "the first" server out of the group
                // unsorted gives the finding a different subject - and therefore a
                // different id - from one audit to the next, which is exactly what
                // stops a dismissal sticking.
                let distinct = Dictionary(grouping: sharing, by: \.instanceID).values
                    .compactMap(\.first)
                    .sorted { $0.displayName < $1.displayName }
                guard distinct.count > 1, let primary = distinct.first else { return nil }
                let names = distinct.map(\.displayName).joined(separator: " and ")
                let category = bucket.split(separator: "#").last.map(String.init) ?? bucket
                return ConfigurationIssue(
                    kind: .downloadClientCategoryShared,
                    severity: .problem,
                    subject: ConfigurationIssueSubject(
                        instanceID: primary.instanceID,
                        serviceType: primary.serviceType,
                        displayName: names
                    ),
                    title: "\(names) share the \"\(category)\" download category",
                    detail: "Both grab into the same category on the same download client, so each will try to import the other's downloads. Give each server its own category.",
                    fix: .open(
                        .arrDownloadClients(primary.serviceType, instanceID: primary.instanceID),
                        actionTitle: "Review Download Clients",
                        guidance: "Give \(names) separate download categories."
                    ),
                    discriminator: bucket
                )
            }
    }

    // MARK: Prowlarr

    /// Prowlarr syncs indexers into each Arr it has an application entry for. A
    /// server missing from that list quietly gets none.
    private static func prowlarrIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        guard let applications = snapshot.prowlarrApplications else {
            guard snapshot.isProwlarrConfigured else { return [] }
            return [ConfigurationIssue(
                kind: .configurationUnavailable,
                severity: .unknown,
                subject: ConfigurationIssueSubject(serviceType: .prowlarr, displayName: "Prowlarr"),
                title: "Prowlarr could not be checked",
                detail: "Trawl could not read Prowlarr's linked applications, so their sync status is unknown.",
                fix: .open(.serviceSettings(.prowlarr, instanceID: nil), actionTitle: "Review Prowlarr", guidance: "Check the Prowlarr connection, then run the setup check again."),
                discriminator: "applications"
            )]
        }
        return snapshot.servers
            .filter { $0.isConnected }
            .compactMap { server in
                guard let host = server.host else { return nil }
                let endpoint = normalizedEndpoint(from: host)

                // Matched on the application's type as well as its address. Two
                // entries can share a host and differ only in which Arr they drive,
                // and an entry for Radarr is not evidence Sonarr gets indexers.
                let matching = applications.filter { application in
                    guard let baseURL = application.baseURL else { return false }
                    guard normalizedEndpoint(from: baseURL) == endpoint else { return false }
                    guard let type = application.serviceType else { return true }
                    return type == server.serviceType
                }

                guard let entry = matching.first else {
                    return ConfigurationIssue(
                        kind: .missingProwlarrApplication,
                        severity: .problem,
                        subject: subject(for: server),
                        title: "Prowlarr does not sync to \(server.displayName)",
                        detail: "Prowlarr has no application entry for \(server.displayName), so the indexers you manage there never reach it.",
                        fix: .open(.prowlarrApplications, actionTitle: "Review Prowlarr Apps", guidance: "Add \(server.displayName) as an application in Prowlarr."),
                        discriminator: server.instanceID.uuidString
                    )
                }

                // An entry set to "disabled" sync is an entry that does nothing.
                // Reporting it as present is how a server with a listed application
                // still ends up with no indexers.
                guard matching.allSatisfy(\.isSyncDisabled) else { return nil }
                return ConfigurationIssue(
                    kind: .prowlarrSyncDisabled,
                    severity: .problem,
                    subject: subject(for: server),
                    title: "Prowlarr's entry for \(server.displayName) syncs nothing",
                    detail: "\(entry.name) points at \(server.displayName) but its sync level is disabled, so Prowlarr never sends it any indexers.",
                    fix: .open(.prowlarrApplications, actionTitle: "Review Prowlarr Apps", guidance: "Set \(entry.name)'s sync level to Add and Remove Only, or Full Sync."),
                    discriminator: server.instanceID.uuidString
                )
            }
    }

    /// Prowlarr is clearly running, and Trawl has never been told about it.
    ///
    /// A note, not a problem, and the wording matters: nothing is broken. The
    /// indexers work, the servers are searching, and a user who manages Prowlarr in a
    /// browser has made a perfectly reasonable choice. What they lose is that Trawl
    /// cannot show or manage those indexers, and the screen they would look for them
    /// on is the one that says so.
    private static func prowlarrDiscoveryIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        guard !snapshot.isProwlarrConfigured else { return [] }
        let baseURLs = snapshot.servers
            .filter(\.isConnected)
            .flatMap { $0.indexerBaseURLs ?? [] }
        guard let prowlarr = ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: baseURLs) else { return [] }

        return [ConfigurationIssue(
            kind: .prowlarrDetectedButNotConnected,
            severity: .note,
            subject: ConfigurationIssueSubject(serviceType: .prowlarr, displayName: "Prowlarr"),
            title: "Prowlarr is managing your indexers",
            detail: "Your servers get their indexers from Prowlarr at \(prowlarr), and Trawl is not connected to it - so it cannot show or manage them here. Adding it is optional: everything keeps working either way.",
            fix: .open(
                .serviceSettings(.prowlarr, instanceID: nil),
                actionTitle: "Add Prowlarr",
                guidance: "Add Prowlarr at \(prowlarr) in Settings, and its indexers appear here."
            ),
            discriminator: prowlarr
        )]
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
            guard bazarr.isConnected else {
                issues.append(ConfigurationIssue(
                    kind: .serviceUnreachable,
                    severity: .unknown,
                    subject: ConfigurationIssueSubject(instanceID: bazarr.instanceID, serviceType: .bazarr, displayName: bazarr.displayName),
                    title: "\(bazarr.displayName) could not be reached",
                    detail: "Trawl could not verify this Bazarr server's linked applications.",
                    fix: .open(.serviceSettings(.bazarr, instanceID: bazarr.instanceID), actionTitle: "Review Connection", guidance: "Restore the Bazarr connection, then run the setup check again.")
                ))
                continue
            }
            guard let linked = bazarr.linkedApps else {
                issues.append(ConfigurationIssue(
                    kind: .configurationUnavailable,
                    severity: .unknown,
                    subject: ConfigurationIssueSubject(instanceID: bazarr.instanceID, serviceType: .bazarr, displayName: bazarr.displayName),
                    title: "\(bazarr.displayName)'s links could not be checked",
                    detail: "Trawl reached Bazarr but could not read its linked-app settings.",
                    fix: .open(.bazarrLinkedApplications(instanceID: bazarr.instanceID), actionTitle: "Review Linked Apps", guidance: "Check the linked apps, then run the setup check again."),
                    discriminator: "linked-apps"
                ))
                continue
            }
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
                    fix: .open(.bazarrLinkedApplications(instanceID: bazarr.instanceID), actionTitle: "Link \(serviceType.displayName)", guidance: "Turn on \(serviceType.displayName) in \(bazarr.displayName)'s linked apps."),
                    discriminator: serviceType.rawValue
                ))
            }

            issues += bazarrAddressIssues(for: bazarr, linked: linked, in: snapshot)
            issues += bazarrCapabilityIssues(for: bazarr)
        }
        return issues
    }

    /// Whether the switch that is on is pointed at a server Trawl knows.
    ///
    /// `use_sonarr = true` says Bazarr will try; it says nothing about *which*
    /// Sonarr. With an HD/4K pair the wrong one means subtitles quietly never appear
    /// for half the library. A note rather than a problem, because a Docker name and
    /// a LAN address are routinely the same box and Trawl cannot tell from here -
    /// the same reason `downloadClientElsewhere` is a note.
    private static func bazarrAddressIssues(
        for bazarr: ConfigurationSnapshot.BazarrServer,
        linked: Set<ArrServiceType>,
        in snapshot: ConfigurationSnapshot
    ) -> [ConfigurationIssue] {
        let knownEndpoints = Set(
            snapshot.servers.compactMap { $0.host.map(normalizedEndpoint(from:)) }
        )
        guard !knownEndpoints.isEmpty else { return [] }

        return linked
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { serviceType in
                guard let address = bazarr.linkedBaseURLs[serviceType], !address.isEmpty else { return nil }
                guard !knownEndpoints.contains(normalizedEndpoint(from: address)) else { return nil }
                return ConfigurationIssue(
                    kind: .bazarrPointsElsewhere,
                    severity: .note,
                    subject: ConfigurationIssueSubject(
                        instanceID: bazarr.instanceID,
                        serviceType: .bazarr,
                        displayName: bazarr.displayName
                    ),
                    title: "\(bazarr.displayName)'s \(serviceType.displayName) is a different address",
                    detail: "\(bazarr.displayName) is set to talk to \(serviceType.displayName) at \(address), which is not an address Trawl is connected to. Often the same server by another name - worth a look only if subtitles never arrive.",
                    fix: .open(.bazarrLinkedApplications(instanceID: bazarr.instanceID), actionTitle: "Review Linked Apps", guidance: "Check that \(address) is the same \(serviceType.displayName) Trawl uses."),
                    discriminator: serviceType.rawValue
                )
            }
    }

    /// Whether this Bazarr can do anything at all.
    ///
    /// Linking it to Sonarr and Radarr is only half a setup. It fetches subtitles
    /// *for* a language profile and *from* a provider, and with neither it sits there
    /// connected, healthy, linked, and silent - which is the hardest kind of broken to
    /// notice, because every screen that would tell you looks fine.
    private static func bazarrCapabilityIssues(
        for bazarr: ConfigurationSnapshot.BazarrServer
    ) -> [ConfigurationIssue] {
        let subject = ConfigurationIssueSubject(
            instanceID: bazarr.instanceID,
            serviceType: .bazarr,
            displayName: bazarr.displayName
        )
        var issues: [ConfigurationIssue] = []

        if bazarr.languageProfileCount == 0 {
            issues.append(ConfigurationIssue(
                kind: .bazarrNoLanguageProfile,
                severity: .problem,
                subject: subject,
                title: "\(bazarr.displayName) has no language profile",
                detail: "\(bazarr.displayName) has nothing to say which languages to look for, so it will never fetch a subtitle for anything.",
                fix: .open(
                    .bazarrLanguageProfiles(instanceID: bazarr.instanceID),
                    actionTitle: "Add a Language Profile",
                    guidance: "Create a language profile in \(bazarr.displayName) and assign it to your libraries."
                )
            ))
        }

        if bazarr.enabledProviderCount == 0 {
            issues.append(ConfigurationIssue(
                kind: .bazarrNoProvider,
                severity: .problem,
                subject: subject,
                title: "\(bazarr.displayName) has no subtitle provider",
                detail: "\(bazarr.displayName) has nowhere to search, so even a correctly configured language profile finds nothing.",
                fix: .open(
                    .bazarrProviders(instanceID: bazarr.instanceID),
                    actionTitle: "Add a Provider",
                    guidance: "Enable at least one subtitle provider in \(bazarr.displayName)."
                )
            ))
        }

        var unavailable: [String] = []
        if bazarr.languageProfileCount == nil { unavailable.append("language profiles") }
        if bazarr.enabledProviderCount == nil { unavailable.append("subtitle providers") }
        if !unavailable.isEmpty {
            issues.append(ConfigurationIssue(
                kind: .configurationUnavailable,
                severity: .unknown,
                subject: subject,
                title: "Part of \(bazarr.displayName)'s setup could not be checked",
                detail: "Trawl could not read \(unavailable.joined(separator: " or ")), so this audit is incomplete.",
                fix: .open(
                    .serviceSettings(.bazarr, instanceID: bazarr.instanceID),
                    actionTitle: "Review Connection",
                    guidance: "Check the \(bazarr.displayName) connection, then run the setup check again."
                ),
                discriminator: unavailable.joined(separator: "|")
            ))
        }
        return issues
    }

    // MARK: Seerr

    /// Seerr hands approved requests to Sonarr and Radarr. Everything that can go
    /// wrong here fails the same way: the request is accepted, the user is told it
    /// is on its way, and nothing is ever downloaded.
    private static func seerrIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        guard let seerr = snapshot.seerr else { return [] }
        let subject = ConfigurationIssueSubject(displayName: seerr.displayName)

        guard seerr.isConnected else {
            return [ConfigurationIssue(
                kind: .serviceUnreachable,
                severity: .unknown,
                subject: subject,
                title: "\(seerr.displayName) could not be reached",
                detail: "Trawl could not check how \(seerr.displayName) is set to hand requests to Sonarr and Radarr.",
                fix: .open(.seerrLinkedApplications, actionTitle: "Review Connection", guidance: "Restore the \(seerr.displayName) connection, then run the setup check again."),
                discriminator: "seerr"
            )]
        }

        guard let isInitialized = seerr.isInitialized else {
            return [ConfigurationIssue(
                kind: .configurationUnavailable,
                severity: .unknown,
                subject: subject,
                title: "\(seerr.displayName)'s setup could not be checked",
                detail: "Trawl reached \(seerr.displayName) but could not read its settings, so its request routing has not been verified.",
                fix: .open(.seerrLinkedApplications, actionTitle: "Review Seerr", guidance: "Check the \(seerr.displayName) connection, then run the setup check again."),
                discriminator: "seerr-settings"
            )]
        }

        guard isInitialized else {
            return [ConfigurationIssue(
                kind: .seerrNotInitialized,
                severity: .problem,
                subject: subject,
                title: "\(seerr.displayName) has not finished its own setup",
                detail: "\(seerr.displayName) reports that it is not initialised, so it cannot accept or fulfil requests yet.",
                fix: .open(.seerrLinkedApplications, actionTitle: "Review Seerr", guidance: "Finish \(seerr.displayName)'s first-run setup in its own web interface."),
                discriminator: "initialised"
            )]
        }

        guard let dvrServers = seerr.dvrServers else {
            return [ConfigurationIssue(
                kind: .configurationUnavailable,
                severity: .unknown,
                subject: subject,
                title: "\(seerr.displayName)'s servers could not be checked",
                detail: "Trawl could not read which Sonarr and Radarr servers \(seerr.displayName) hands requests to.",
                fix: .open(.seerrLinkedApplications, actionTitle: "Review Linked Apps", guidance: "Check the \(seerr.displayName) connection, then run the setup check again."),
                discriminator: "seerr-dvr"
            )]
        }

        var issues: [ConfigurationIssue] = []
        let configuredServices = Set(snapshot.servers.filter(\.isConnected).map(\.serviceType))
            .intersection([.sonarr, .radarr])

        for serviceType in configuredServices.sorted(by: { $0.rawValue < $1.rawValue }) {
            let forService = dvrServers.filter { $0.serviceType == serviceType }
            guard !forService.isEmpty else {
                issues.append(ConfigurationIssue(
                    kind: .seerrMissingDVR,
                    severity: .problem,
                    subject: subject,
                    title: "\(seerr.displayName) has no \(serviceType.displayName) server",
                    detail: "Requests for \(serviceType == .sonarr ? "series" : "movies") will be approved and then go nowhere, because \(seerr.displayName) has nothing to hand them to.",
                    fix: .open(.seerrLinkedApplications, actionTitle: "Add \(serviceType.displayName)", guidance: "Add \(serviceType.displayName) to \(seerr.displayName)'s servers."),
                    discriminator: serviceType.rawValue
                ))
                continue
            }

            // A non-4K default is what an ordinary request uses. Without one, Seerr
            // has servers listed and still nowhere to send anything.
            if !forService.contains(where: { $0.isDefault && !$0.is4k }) {
                issues.append(ConfigurationIssue(
                    kind: .seerrNoDefaultDVR,
                    severity: .problem,
                    subject: subject,
                    title: "\(seerr.displayName) has no default \(serviceType.displayName)",
                    detail: "\(seerr.displayName) knows about \(forService.count == 1 ? "a \(serviceType.displayName) server" : "\(forService.count) \(serviceType.displayName) servers") but none is marked default, so ordinary requests have no destination.",
                    fix: .open(.seerrLinkedApplications, actionTitle: "Review Servers", guidance: "Mark one \(serviceType.displayName) server as the default in \(seerr.displayName)."),
                    discriminator: "default-\(serviceType.rawValue)"
                ))
            }

            for server in forService where !server.hasRootFolder || !server.hasQualityProfile {
                let missing = [
                    server.hasRootFolder ? nil : "root folder",
                    server.hasQualityProfile ? nil : "quality profile"
                ].compactMap { $0 }.joined(separator: " or ")
                issues.append(ConfigurationIssue(
                    kind: .seerrDVRIncomplete,
                    severity: .problem,
                    subject: subject,
                    title: "\(seerr.displayName)'s \(server.name) has no \(missing)",
                    detail: "\(seerr.displayName) cannot send anything to \(server.name) until it has been given a \(missing) to use.",
                    fix: .open(.seerrLinkedApplications, actionTitle: "Review \(server.name)", guidance: "Set a \(missing) for \(server.name) in \(seerr.displayName)."),
                    discriminator: "incomplete-\(server.serviceType.rawValue)-\(server.name)"
                ))
            }
        }
        return issues
    }

    // MARK: Cleanuparr

    /// Cleanuparr decides for itself whether it can reach the Arrs and download
    /// clients it prunes, and the app was not asking.
    private static func cleanuparrIssues(in snapshot: ConfigurationSnapshot) -> [ConfigurationIssue] {
        guard let cleanuparr = snapshot.cleanuparr else { return [] }
        let subject = ConfigurationIssueSubject(displayName: cleanuparr.displayName)

        guard cleanuparr.isConnected else {
            return [ConfigurationIssue(
                kind: .serviceUnreachable,
                severity: .unknown,
                subject: subject,
                title: "\(cleanuparr.displayName) could not be reached",
                detail: "Trawl could not check whether \(cleanuparr.displayName) is able to run.",
                fix: .open(.cleanuparr, actionTitle: "Review Connection", guidance: "Restore the \(cleanuparr.displayName) connection, then run the setup check again."),
                discriminator: "cleanuparr"
            )]
        }

        guard let isReady = cleanuparr.isReady else {
            return [ConfigurationIssue(
                kind: .configurationUnavailable,
                severity: .unknown,
                subject: subject,
                title: "\(cleanuparr.displayName)'s readiness could not be checked",
                detail: "Trawl reached \(cleanuparr.displayName) but it did not report whether it is ready to run.",
                fix: .open(.cleanuparr, actionTitle: "Review Cleanuparr", guidance: "Open \(cleanuparr.displayName) and check its status, then run the setup check again."),
                discriminator: "cleanuparr-ready"
            )]
        }

        guard !isReady else { return [] }
        return [ConfigurationIssue(
            kind: .cleanuparrNotReady,
            severity: .problem,
            subject: subject,
            title: "\(cleanuparr.displayName) is not ready to run",
            detail: "\(cleanuparr.displayName) reports that it cannot reach everything it needs, so stalled and failed downloads will not be cleaned up.",
            fix: .open(.cleanuparr, actionTitle: "Open Cleanuparr", guidance: "Check \(cleanuparr.displayName)'s own Arr and download-client settings.")
        )]
    }

    // MARK: Helpers

    private static func unreachableIssue(for server: ConfigurationSnapshot.Server) -> ConfigurationIssue {
        ConfigurationIssue(
            kind: .serviceUnreachable,
            severity: .unknown,
            subject: subject(for: server),
            title: "\(server.displayName) could not be reached",
            detail: "Trawl could not inspect this server, so its setup has not been verified.",
            fix: .open(.serviceSettings(server.serviceType, instanceID: server.instanceID), actionTitle: "Review Connection", guidance: "Restore the connection, then run the setup check again.")
        )
    }

    private static func unavailableConfigurationIssues(for server: ConfigurationSnapshot.Server) -> [ConfigurationIssue] {
        var unavailable: [String] = []
        if server.downloadClients == nil { unavailable.append("download clients") }
        if server.rootFolders == nil { unavailable.append("root folders") }
        if server.enabledIndexerCount == nil { unavailable.append("indexers") }
        if server.healthChecks == nil { unavailable.append("its own health") }
        guard !unavailable.isEmpty else { return [] }

        return [ConfigurationIssue(
            kind: .configurationUnavailable,
            severity: .unknown,
            subject: subject(for: server),
            title: "Part of \(server.displayName)'s setup could not be checked",
            detail: "Trawl could not read \(unavailable.joined(separator: ", ")), so this audit is incomplete.",
            fix: .open(.serviceSettings(server.serviceType, instanceID: server.instanceID), actionTitle: "Review Connection", guidance: "Check the server connection and permissions, then run the setup check again."),
            discriminator: unavailable.joined(separator: "|")
        )]
    }

    private static func subject(for server: ConfigurationSnapshot.Server) -> ConfigurationIssueSubject {
        ConfigurationIssueSubject(
            instanceID: server.instanceID,
            serviceType: server.serviceType,
            displayName: server.displayName
        )
    }

    /// Host *and* port for matching a Prowlarr application to an Arr server.
    ///
    /// An HD/4K pair is usually one machine on two ports. Folding the port away would
    /// make Prowlarr's entry for one of them look like an entry for both - and the
    /// server that genuinely has no entry would never be reported, which is the one
    /// case this check exists for. The port is available here because both sides are
    /// full URLs: Prowlarr's `baseUrl`, and the server's own host URL.
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
