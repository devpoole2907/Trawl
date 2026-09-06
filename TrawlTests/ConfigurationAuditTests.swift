//
//  ConfigurationAuditTests.swift
//  TrawlTests
//
//  The audit reconciles facts that live in different places - what Trawl is
//  connected to, and what each Arr has been told about the same things. Nothing
//  else in the app checks that they agree, so a wrong answer here is silent in both
//  directions: a fault nobody is told about, or a warning about a setup that is fine.
//
//  Every rule is a pure function of `ConfigurationSnapshot`, which is why these
//  build the wiring they want to describe instead of standing up servers.
//

import Foundation
import Testing
@testable import Trawl

@Suite("Configuration audit")
@MainActor
struct ConfigurationAuditTests {

    private static let hdID = UUID()
    private static let uhdID = UUID()
    private static let bazarrID = UUID()

    /// `automaticIndexers` defaults to `indexers` and `health` to an empty list, so a
    /// test that says nothing about them describes a server that answered every
    /// question and had nothing to report - not one Trawl could not finish checking.
    private static func server(
        id: UUID,
        type: ArrServiceType = .radarr,
        name: String,
        clients: [ConfigurationSnapshot.DownloadClient]? = [],
        folders: [ConfigurationSnapshot.RootFolder]? = [ConfigurationSnapshot.RootFolder(path: "/data/movies")],
        indexers: Int? = 1,
        automaticIndexers: Int?? = nil,
        indexerBaseURLs: [String]? = [],
        health: [ConfigurationSnapshot.HealthCheck]? = [],
        mappings: [ConfigurationSnapshot.RemotePathMapping]? = [],
        host: String? = nil,
        isConnected: Bool = true,
        tier: ArrQualityTier? = nil
    ) -> ConfigurationSnapshot.Server {
        ConfigurationSnapshot.Server(
            instanceID: id,
            serviceType: type,
            displayName: name,
            isConnected: isConnected,
            downloadClients: clients,
            rootFolders: folders,
            enabledIndexerCount: indexers,
            automaticIndexerCount: automaticIndexers ?? indexers,
            indexerBaseURLs: indexerBaseURLs,
            healthChecks: health,
            remotePathMappings: mappings,
            host: host,
            tier: tier
        )
    }

    private static func prowlarrApp(
        _ baseURL: String,
        type: ArrServiceType? = nil,
        syncDisabled: Bool = false
    ) -> ConfigurationSnapshot.ProwlarrApplication {
        ConfigurationSnapshot.ProwlarrApplication(
            name: "\(type?.displayName ?? "App") @ \(baseURL)",
            serviceType: type,
            baseURL: baseURL,
            isSyncDisabled: syncDisabled
        )
    }

    private static func qbClient(host: String = "10.0.0.5", port: String? = "8080", enabled: Bool = true) -> ConfigurationSnapshot.DownloadClient {
        ConfigurationSnapshot.DownloadClient(
            name: "qBittorrent",
            implementation: "QBittorrent",
            host: host,
            port: port,
            isEnabled: enabled
        )
    }

    // MARK: Download clients

    /// The case that prompted all of this: the old checker unioned every server of a
    /// service, so a 4K server with no download client at all was invisible behind a
    /// healthy HD one. A pair does not share clients, so the question is per server.
    @Test("A server with no download client is reported even when its partner has one")
    func perServerNotUnioned() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [Self.qbClient()]),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [])
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )

        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .noDownloadClient }
        #expect(found.count == 1)
        #expect(found.first?.subject.instanceID == Self.uhdID)
        #expect(found.first?.severity == .problem)
    }

    @Test("A server whose clients are all disabled is a problem of its own")
    func allClientsDisabled() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient(enabled: false)])],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        let kinds = ConfigurationAudit.issues(in: snapshot).map(\.kind)
        #expect(kinds.contains(.downloadClientsAllDisabled))
        #expect(!kinds.contains(.noDownloadClient))
    }

    /// A Docker hostname and a LAN IP are routinely the same box, so this is a note.
    /// Reporting it as a fault sends people to fix working setups.
    @Test("A client pointed at a different host is a note, not a problem")
    func differentHostIsANote() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient(host: "gluetun")])],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .downloadClientElsewhere }
        #expect(found.count == 1)
        #expect(found.first?.severity == .note)
    }

    @Test("Loopback spellings are not treated as a different host")
    func loopbackSpellingsMatch() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient(host: "localhost")])],
            trawlClients: [.qbittorrent: ["http://127.0.0.1:8080"]]
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientElsewhere })
    }

    @Test("Download clients on the same host but different ports are different endpoints")
    func sameHostDifferentPortDoesNotMatch() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient(port: "9090")])],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )

        #expect(ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientElsewhere })
    }

    @Test("An Arr client may match any configured Trawl endpoint of the same kind")
    func multipleTrawlEndpointsAreComparedIndividually() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient(port: "9090")])],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080", "http://10.0.0.5:9090"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot)

        #expect(!found.contains { $0.kind == .downloadClientElsewhere })
        #expect(found.filter { $0.kind == .downloadClientUnused }.count == 1)
        #expect(found.first { $0.kind == .downloadClientUnused }?.detail.contains("8080") == true)
    }

    @Test("A client nothing grabs through is reported once, as a note")
    func unusedTrawlClient() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [])],
            trawlClients: [.sabnzbd: ["http://10.0.0.9:8080"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .downloadClientUnused }
        #expect(found.count == 1)
        #expect(found.first?.severity == .note)
    }

    /// "Could not ask" is not "there is nothing there". A server that was down when
    /// the audit ran must not be reported as misconfigured.
    @Test("A server whose configuration could not be read is explicitly unknown")
    func unreadableClientsAreUnknown() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: nil, folders: nil, indexers: nil)],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot)
        #expect(found.count == 1)
        #expect(found.first?.kind == .configurationUnavailable)
        #expect(found.first?.severity == .unknown)
    }

    @Test("A disconnected configured server prevents an all-clear result")
    func disconnectedServerIsUnknown() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [], folders: [], indexers: 0, isConnected: false)]
        )
        let found = ConfigurationAudit.issues(in: snapshot)
        #expect(found.count == 1)
        #expect(found.first?.kind == .serviceUnreachable)
        #expect(found.first?.severity == .unknown)
    }

    // MARK: Root folders

    @Test("A server with no root folder, and one it cannot reach, are both problems")
    func rootFolderFaults() {
        let none = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()], folders: [])]
        )
        #expect(ConfigurationAudit.issues(in: none).contains { $0.kind == .noRootFolder && $0.severity == .problem })

        let unreachable = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID, name: "Radarr", clients: [Self.qbClient()],
                folders: [ConfigurationSnapshot.RootFolder(path: "/data/movies", isAccessible: false)]
            )]
        )
        #expect(ConfigurationAudit.issues(in: unreachable).contains { $0.kind == .rootFolderInaccessible })
    }

    /// The HD/4K failure that looks like nothing is wrong until the two servers start
    /// deleting each other's files.
    @Test("Two servers of one service sharing a root folder is a problem")
    func sharedRootFolder() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data/movies")]),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data/movies/")])
            ]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .rootFolderShared }
        #expect(found.count == 1, "A trailing slash is not a second folder.")
        #expect(found.first?.severity == .problem)
    }

    @Test("Sonarr and Radarr using the same path is not reported as sharing")
    func differentServicesDoNotShare() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data")]),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data")])
            ]
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .rootFolderShared })
    }

    // MARK: Indexers

    @Test("A server with no enabled indexer is a problem, and one with any is silent")
    func indexerCounts() {
        let none = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()], indexers: 0)]
        )
        #expect(none.servers.count == 1)
        #expect(ConfigurationAudit.issues(in: none).contains { $0.kind == .noIndexers })

        let some = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()], indexers: 3)]
        )
        #expect(!ConfigurationAudit.issues(in: some).contains { $0.kind == .noIndexers })
    }

    // MARK: Prowlarr

    @Test("A server Prowlarr does not sync to is reported, matched on host")
    func prowlarrApplicationMissing() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [Self.qbClient()], host: "http://10.0.0.5:7878"),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [Self.qbClient()], host: "http://10.0.0.5:7879")
            ],
            prowlarrApplications: [Self.prowlarrApp("http://10.0.0.5:7878")]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .missingProwlarrApplication }
        #expect(found.count == 1)
        #expect(found.first?.subject.instanceID == Self.uhdID)
    }

    /// The pair are one machine on two ports, which is the normal way to run them.
    /// Comparing on host alone made Prowlarr's entry for the HD server answer for
    /// the 4K one too, so the server that genuinely had no entry was never reported.
    @Test("A same-host, different-port pair is told apart")
    func prowlarrDistinguishesPortsOnOneHost() {
        #expect(
            ConfigurationAudit.normalizedEndpoint(from: "http://10.0.0.5:7878")
                != ConfigurationAudit.normalizedEndpoint(from: "http://10.0.0.5:7879")
        )
        #expect(
            ConfigurationAudit.normalizedEndpoint(from: "http://localhost:7878")
                == ConfigurationAudit.normalizedEndpoint(from: "http://127.0.0.1:7878"),
            "Loopback spellings are still the same endpoint."
        )
        #expect(
            ConfigurationAudit.normalizedEndpoint(from: "10.0.0.5:7878")
                == ConfigurationAudit.normalizedEndpoint(from: "http://10.0.0.5:7878/"),
            "A missing scheme and a trailing slash are not a different server."
        )
        #expect(
            ConfigurationAudit.normalizedEndpoint(from: "https://arr.example.com")
                != ConfigurationAudit.normalizedEndpoint(from: "http://arr.example.com"),
            "Default ports differ by scheme."
        )
    }

    @Test("With no Prowlarr configured nothing is claimed about syncing")
    func noProwlarrStaysSilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()], host: "http://10.0.0.5:7878")],
            prowlarrApplications: nil
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .missingProwlarrApplication })
    }

    @Test("A configured Prowlarr whose applications cannot be read is unknown")
    func unreadableProwlarrIsUnknown() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()], host: "http://10.0.0.5:7878")],
            prowlarrApplications: nil,
            isProwlarrConfigured: true
        )

        #expect(ConfigurationAudit.issues(in: snapshot).contains {
            $0.kind == .configurationUnavailable && $0.subject.serviceType == .prowlarr && $0.severity == .unknown
        })
    }

    // MARK: Bazarr

    @Test("A Bazarr not linked to a configured service is a problem, per service")
    func bazarrLinks() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()]),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [Self.qbClient()])
            ],
            bazarrServers: [ConfigurationSnapshot.BazarrServer(
                instanceID: Self.bazarrID, displayName: "Bazarr", linkedApps: [.sonarr]
            )]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .bazarrAppNotLinked }
        #expect(found.count == 1)
        #expect(found.first?.title.contains("Radarr") == true)
    }

    @Test("A Bazarr whose settings could not be read reports nothing")
    func unreadableBazarrStaysSilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()])],
            bazarrServers: [ConfigurationSnapshot.BazarrServer(
                instanceID: Self.bazarrID, displayName: "Bazarr", linkedApps: nil
            )]
        )
        let found = ConfigurationAudit.issues(in: snapshot)
        #expect(!found.contains { $0.kind == .bazarrAppNotLinked })
        #expect(found.contains { $0.kind == .configurationUnavailable && $0.severity == .unknown })
    }

    // MARK: Presentation contract

    @Test("Problems sort ahead of notes")
    func problemsSortFirst() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [Self.qbClient(host: "gluetun")]),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [])
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        let issues = ConfigurationAudit.issues(in: snapshot)
        let firstNote = issues.firstIndex { $0.severity == .note }
        let lastProblem = issues.lastIndex { $0.severity == .problem }
        if let firstNote, let lastProblem { #expect(lastProblem < firstNote) }
        #expect(!issues.problems.isEmpty)
        #expect(!issues.notes.isEmpty)
    }

    /// Ids have to survive a re-audit or a dismissal cannot stick and a list cannot
    /// animate: the same fault on the same server is the same row.
    @Test("The same fault keeps the same id across audits")
    func idsAreStable() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [])]
        )
        let first = ConfigurationAudit.issues(in: snapshot).map(\.id)
        let second = ConfigurationAudit.issues(in: snapshot).map(\.id)
        #expect(first == second)
        #expect(Set(first).count == first.count, "Ids must not collide within one audit.")
    }

    @Test("Two related faults on one subject still have unique identities")
    func relatedFaultIDsDoNotCollide() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()]),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [Self.qbClient()])
            ],
            bazarrServers: [ConfigurationSnapshot.BazarrServer(
                instanceID: Self.bazarrID, displayName: "Bazarr", linkedApps: []
            )]
        )
        let links = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .bazarrAppNotLinked }

        #expect(links.count == 2)
        #expect(Set(links.map(\.id)).count == 2)
    }

    // MARK: Service health

    /// Arr checks things Trawl cannot see from outside. Throwing those away is how a
    /// server whose download client stopped answering passes a setup check.
    @Test("An Arr health check about something the audit covers is a problem, not a note")
    func healthChecksAboutWiringAreProblems() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID,
                name: "Radarr",
                clients: [Self.qbClient()],
                health: [
                    ConfigurationSnapshot.HealthCheck(
                        source: "DownloadClientStatusCheck",
                        type: "warning",
                        message: "Download clients are unavailable due to failures: qBittorrent"
                    ),
                    ConfigurationSnapshot.HealthCheck(
                        source: "UpdateCheck",
                        type: "warning",
                        message: "New update is available"
                    ),
                    ConfigurationSnapshot.HealthCheck(
                        source: "ok-noise",
                        type: "ok",
                        message: "Nothing to say"
                    )
                ]
            )],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )

        let found = ConfigurationAudit.issues(in: snapshot)
        let blocking = found.filter { $0.kind == .serviceHealthError }
        let advisory = found.filter { $0.kind == .serviceHealthWarning }
        #expect(blocking.count == 1)
        #expect(blocking.first?.severity == .problem)
        #expect(blocking.first?.detail.contains("qBittorrent") == true)
        // An update notice is not a reason to tell someone their setup is broken.
        #expect(advisory.count == 1)
        #expect(advisory.first?.severity == .note)
        // "ok" is not a finding at all.
        #expect(found.count { $0.detail == "Nothing to say" } == 0)
    }

    /// An `error` is serious whoever raised it, even from a check this audit has
    /// never heard of.
    @Test("An error-level health check is a problem from any source")
    func healthErrorsAreAlwaysProblems() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID,
                name: "Radarr",
                clients: [Self.qbClient()],
                health: [ConfigurationSnapshot.HealthCheck(source: "SomethingNew", type: "error", message: "Database is locked")]
            )],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .serviceHealthError }
        #expect(found.count == 1)
        #expect(found.first?.severity == .problem)
    }

    @Test("Health that could not be read is unknown, never a pass")
    func unreadableHealthIsUnknown() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()], health: nil)],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        #expect(ConfigurationAudit.issues(in: snapshot).contains {
            $0.kind == .configurationUnavailable && $0.severity == .unknown
        })
    }

    // MARK: Indexer capability

    /// Having an indexer and being able to grab without a person present are
    /// different facts, and the original check only asked the first.
    @Test("Interactive-only indexers cannot satisfy automatic acquisition")
    func interactiveOnlyIndexersAreReported() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID,
                name: "Radarr",
                clients: [Self.qbClient()],
                indexers: 2,
                automaticIndexers: .some(0)
            )],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot)
        #expect(found.contains { $0.kind == .noAutomaticIndexer && $0.severity == .problem })
        // And not *also* reported as having no indexers at all, which would be wrong.
        #expect(!found.contains { $0.kind == .noIndexers })
    }

    // MARK: Download categories

    /// The HD/4K failure that looks like nothing is wrong: both grab into one
    /// category, and whichever server polls first imports the other's download.
    @Test("Two servers sharing a client and a category is a problem")
    func sharedDownloadCategory() {
        let hd = ConfigurationSnapshot.DownloadClient(
            name: "qBittorrent", implementation: "QBittorrent",
            host: "10.0.0.5", port: "8080", isEnabled: true, category: "movies"
        )
        let uhd = ConfigurationSnapshot.DownloadClient(
            name: "qBittorrent", implementation: "QBittorrent",
            host: "10.0.0.5", port: "8080", isEnabled: true, category: "Movies"
        )
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [hd], folders: [ConfigurationSnapshot.RootFolder(path: "/data/hd")]),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [uhd], folders: [ConfigurationSnapshot.RootFolder(path: "/data/4k")])
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .downloadClientCategoryShared }
        #expect(found.count == 1)
        #expect(found.first?.severity == .problem)
    }

    /// Separate categories are the whole point of the setting, so a pair that has
    /// them is silent - and a pair that has none is not, because untagged grabs from
    /// two servers land in one default location just as surely as two matching
    /// category names do.
    @Test("Different categories are left alone; two untagged servers are not")
    func distinctCategoriesAreSilentAndBlankOnesAreNot() {
        func client(_ category: String?) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                name: "qBittorrent", implementation: "QBittorrent",
                host: "10.0.0.5", port: "8080", isEnabled: true, category: category
            )
        }
        func issues(_ pair: (ConfigurationSnapshot.DownloadClient, ConfigurationSnapshot.DownloadClient)) -> [ConfigurationIssue] {
            let snapshot = ConfigurationSnapshot(
                servers: [
                    Self.server(id: Self.hdID, name: "Radarr HD", clients: [pair.0], folders: [ConfigurationSnapshot.RootFolder(path: "/data/hd")]),
                    Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [pair.1], folders: [ConfigurationSnapshot.RootFolder(path: "/data/4k")])
                ],
                trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
            )
            return ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .downloadClientCategoryShared }
        }

        #expect(issues((client("movies"), client("movies-4k"))).isEmpty)

        // Nil and empty string are the same absence and must land in one bucket, not
        // two: reported separately, neither pair would ever reach a count of two.
        // Both servers here are Radarrs, which is what makes this a real race - see
        // `untaggedAcrossServiceKindsIsSilent` for the pair that is not.
        for pair in [(client(nil), client(nil)), (client(""), client("")), (client(nil), client(""))] {
            let found = issues(pair)
            #expect(found.count == 1)
            #expect(found.first?.severity == .problem)
            // Worded as the absence it is, rather than as a shared name that is not
            // on screen anywhere - a step reading `share the "" category` is how a
            // real finding gets read as a bug in Trawl.
            #expect(found.first?.title == "Radarr 4K and Radarr HD do not tag their downloads")
        }
    }

    /// One tagged server and one untagged one are in different buckets, and neither
    /// bucket has two servers in it. The check must not fall back to "they share a
    /// client" - that is a different finding with a different fix.
    @Test("A tagged server and an untagged one do not collide")
    func oneTaggedOneUntaggedIsSilent() {
        func client(_ category: String?) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                name: "qBittorrent", implementation: "QBittorrent",
                host: "10.0.0.5", port: "8080", isEnabled: true, category: category
            )
        }
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [client("movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/hd")]),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [client(nil)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/4k")])
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientCategoryShared })
    }

    /// Untagged servers on *different* clients are not sharing anything. The bucket
    /// key is endpoint-and-category, and a regression that keyed on category alone
    /// would report every multi-server setup that has never used categories.
    @Test("Untagged servers on different clients are left alone")
    func untaggedOnDifferentClientsIsSilent() {
        func client(_ port: String) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                name: "qBittorrent", implementation: "QBittorrent",
                host: "10.0.0.5", port: port, isEnabled: true, category: nil
            )
        }
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [client("8080")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/hd")]),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [client("8081")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/4k")])
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientCategoryShared })
    }

    /// The untagged check is scoped to one kind of server on purpose. The race needs
    /// both servers to hold the *same* download, and a Sonarr will never have a
    /// movie's download id in its queue - while "a Radarr and a Sonarr on one
    /// qBittorrent, neither using categories" is the ordinary setup of anyone who has
    /// never touched the setting. Reporting it would fire on working installs.
    @Test("An untagged Radarr and an untagged Sonarr are not a collision")
    func untaggedAcrossServiceKindsIsSilent() {
        func client(_ id: Int) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                id: id, name: "qBittorrent", implementation: "QBittorrent",
                host: "10.0.0.5", port: "8080", isEnabled: true, category: nil
            )
        }
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [client(1)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/movies")]),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [client(2)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/tv")])
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientCategoryShared })
    }

    /// A category two different kinds of server were both deliberately given is still
    /// reported. Nobody arrives at that by default, so it is worth asking about even
    /// though the import race itself needs a matching pair.
    @Test("A shared category across service kinds is still reported")
    func sharedNamedCategoryAcrossKindsIsReported() {
        func client(_ id: Int) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                id: id, name: "qBittorrent", implementation: "QBittorrent",
                host: "10.0.0.5", port: "8080", isEnabled: true, category: "media"
            )
        }
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [client(1)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/movies")]),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [client(2)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/tv")])
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )
        #expect(ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientCategoryShared })
    }

    // MARK: Category folders

    private static func sabClient(_ id: Int, _ category: String) -> ConfigurationSnapshot.DownloadClient {
        ConfigurationSnapshot.DownloadClient(
            id: id, name: "SABnzbd", implementation: "Sabnzbd",
            host: "192.168.68.79", port: "8082", isEnabled: true, category: category
        )
    }

    private static let sabEndpoint = DownloadClientLinkChecker.normalizedEndpoint(
        host: "192.168.68.79", port: "8082"
    )

    /// The half-done fix: separate categories on the Arr side, but the new one was
    /// never given a folder, so SABnzbd drops both into its completed root and the
    /// import race is exactly as it was. Invisible to the shared-category check,
    /// because from the Arrs' side this looks correctly separated.
    @Test("Different categories writing into one folder is a problem")
    func categoriesSharingAFolder() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr", clients: [Self.sabClient(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [Self.sabClient(2, "movies-4k")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
            ],
            sabnzbd: ConfigurationSnapshot.SABnzbdSetup(
                endpoint: Self.sabEndpoint,
                categoryDirectories: ["movies": "", "movies-4k": ""]
            )
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .downloadCategoryFolderShared }
        #expect(found.count == 1)
        #expect(found.first?.severity == .problem)
        // The shared-category check must stay quiet: the categories genuinely differ.
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientCategoryShared })
    }

    /// The fix actually deployed: each category gets a folder of its own.
    @Test("Categories with their own folders are silent")
    func categoriesWithDistinctFoldersAreSilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr", clients: [Self.sabClient(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [Self.sabClient(2, "movies-4k")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
            ],
            sabnzbd: ConfigurationSnapshot.SABnzbdSetup(
                endpoint: Self.sabEndpoint,
                categoryDirectories: ["movies": "", "movies-4k": "/data/downloads/complete/movies-4k"]
            )
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadCategoryFolderShared })
    }

    /// A trailing slash and a capital letter are not a second folder.
    @Test("Folder comparison ignores case and trailing slashes")
    func folderComparisonIsNormalized() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr", clients: [Self.sabClient(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [Self.sabClient(2, "movies-4k")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
            ],
            sabnzbd: ConfigurationSnapshot.SABnzbdSetup(
                endpoint: Self.sabEndpoint,
                categoryDirectories: ["movies": "/data/Complete/Movies", "movies-4k": "/data/complete/movies/"]
            )
        )
        #expect(ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadCategoryFolderShared })
    }

    /// The false positive this check must never produce. A brand-new SABnzbd category
    /// has no folder, so "Radarr on movies, Sonarr on tv, both empty" is what a
    /// default install looks like - and those two cannot race in any case.
    @Test("A Radarr and a Sonarr with folderless categories are silent")
    func folderlessCategoriesAcrossKindsAreSilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.sabClient(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")]),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [Self.sabClient(2, "tv")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/TV")])
            ],
            sabnzbd: ConfigurationSnapshot.SABnzbdSetup(
                endpoint: Self.sabEndpoint,
                categoryDirectories: ["movies": "", "tv": ""]
            )
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadCategoryFolderShared })
    }

    /// A category the Arr names but SABnzbd does not have is a grab that will fail
    /// outright, which Arr's own health check reports far better than a guess here.
    @Test("A category SABnzbd does not have is not a folder collision")
    func unknownCategoryIsNotAFolderCollision() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr", clients: [Self.sabClient(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [Self.sabClient(2, "nowhere")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
            ],
            sabnzbd: ConfigurationSnapshot.SABnzbdSetup(
                endpoint: Self.sabEndpoint,
                categoryDirectories: ["movies": ""]
            )
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadCategoryFolderShared })
    }

    /// Unknown is not healthy - but only once the check has something to say. An
    /// unreadable category list on a setup where no two servers of one kind share
    /// that SABnzbd would be reporting the absence of an answer nobody needed.
    @Test("An unreadable category list is unknown, and only when it matters")
    func unreadableCategoriesAreUnknownOnlyWhenRelevant() {
        func snapshot(_ servers: [ConfigurationSnapshot.Server]) -> ConfigurationSnapshot {
            ConfigurationSnapshot(
                servers: servers,
                sabnzbd: ConfigurationSnapshot.SABnzbdSetup(
                    endpoint: Self.sabEndpoint, categoryDirectories: nil
                )
            )
        }
        let contested = snapshot([
            Self.server(id: Self.hdID, name: "Radarr", clients: [Self.sabClient(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
            Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [Self.sabClient(2, "movies-4k")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
        ])
        #expect(ConfigurationAudit.issues(in: contested).contains {
            $0.kind == .configurationUnavailable && $0.severity == .unknown && $0.title.contains("SABnzbd")
        })

        let single = snapshot([
            Self.server(id: Self.hdID, name: "Radarr", clients: [Self.sabClient(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd)
        ])
        #expect(!ConfigurationAudit.issues(in: single).contains {
            $0.kind == .configurationUnavailable && $0.title.contains("SABnzbd")
        })
    }

    // MARK: The guided repair

    /// The plan for the incident this whole check exists for: an HD Radarr and a 4K
    /// Radarr both tagged "movies" on one SABnzbd. Only the 4K server moves, and it
    /// moves to the name its tier implies.
    @Test("The repair moves the 4K server and leaves the HD one alone")
    func repairMovesTheTierThatShouldMove() {
        func client(_ id: Int) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                id: id, name: "SABnzbd", implementation: "Sabnzbd",
                host: "192.168.68.79", port: "8082", isEnabled: true, category: "movies"
            )
        }
        let snapshot = ConfigurationSnapshot(servers: [
            Self.server(id: Self.hdID, name: "Radarr", clients: [client(1)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
            Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [client(2)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
        ])
        let issue = ConfigurationAudit.issues(in: snapshot).first { $0.kind == .downloadClientCategoryShared }
        let changes = try! #require(issue?.fix.guidedRepair).downloadCategoryChanges

        #expect(changes.count == 1)
        #expect(changes.first?.instanceID == Self.uhdID)
        #expect(changes.first?.suggestedCategory == "movies-4k")
        #expect(changes.first?.downloadClientID == 2)
        #expect(changes.first?.currentCategory == "movies")
        // The fallback survives alongside the repair: a guided fix that hid the
        // screen where the change is made by hand would make the wizard the only
        // way to do it.
        #expect(issue?.fix.destination != nil)
    }

    /// Both untagged: nothing to preserve, so both move, and the pair comes back with
    /// the two names that make an HD/4K setup readable.
    @Test("Two untagged servers are both given a name")
    func repairNamesBothUntaggedServers() {
        func client(_ id: Int) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                id: id, name: "SABnzbd", implementation: "Sabnzbd",
                host: "192.168.68.79", port: "8082", isEnabled: true, category: nil
            )
        }
        let snapshot = ConfigurationSnapshot(servers: [
            Self.server(id: Self.hdID, name: "Radarr", clients: [client(1)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
            Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [client(2)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
        ])
        let issue = ConfigurationAudit.issues(in: snapshot).first { $0.kind == .downloadClientCategoryShared }
        let changes = try! #require(issue?.fix.guidedRepair).downloadCategoryChanges

        #expect(changes.count == 2)
        #expect(Set(changes.map(\.suggestedCategory)) == ["movies", "movies-4k"])
        #expect(changes.allSatisfy { $0.currentCategory == nil })
    }

    /// A suggestion must not be a name something else on that client already holds -
    /// that would move the collision rather than end it. Here a third server is
    /// already on "movies-4k", so the 4K Radarr has to be offered something else.
    @Test("A suggestion never reuses a category already in play")
    func repairAvoidsCategoriesAlreadyTaken() {
        func client(_ id: Int, _ category: String) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                id: id, name: "SABnzbd", implementation: "Sabnzbd",
                host: "192.168.68.79", port: "8082", isEnabled: true, category: category
            )
        }
        let third = UUID()
        let snapshot = ConfigurationSnapshot(servers: [
            Self.server(id: Self.hdID, name: "Radarr", clients: [client(1, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
            Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [client(2, "movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd),
            Self.server(id: third, name: "Radarr Anime", clients: [client(3, "movies-4k")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Anime")], tier: .uhd)
        ])
        let issue = ConfigurationAudit.issues(in: snapshot).first { $0.kind == .downloadClientCategoryShared }
        let changes = try! #require(issue?.fix.guidedRepair).downloadCategoryChanges
        let suggested = changes.map(\.suggestedCategory)

        #expect(!suggested.contains("movies-4k"))
        #expect(!suggested.contains("movies"))
        #expect(Set(suggested).count == suggested.count)
    }

    /// A snapshot with no real client ids cannot name the row it would rewrite, so no
    /// repair is offered and the finding falls back to the screen. The finding itself
    /// is unaffected - a repair Trawl cannot run is not a reason to stop reporting.
    @Test("No repair is offered without real download client ids")
    func repairIsWithheldWithoutClientIDs() {
        func client(_ category: String) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                name: "SABnzbd", implementation: "Sabnzbd",
                host: "192.168.68.79", port: "8082", isEnabled: true, category: category
            )
        }
        let snapshot = ConfigurationSnapshot(servers: [
            Self.server(id: Self.hdID, name: "Radarr", clients: [client("movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies")], tier: .hd),
            Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [client("movies")], folders: [ConfigurationSnapshot.RootFolder(path: "/data/Movies-4K")], tier: .uhd)
        ])
        let issue = ConfigurationAudit.issues(in: snapshot).first { $0.kind == .downloadClientCategoryShared }
        #expect(issue != nil)
        #expect(issue?.fix.guidedRepair == nil)
        #expect(issue?.fix.destination != nil)
    }

    /// Sonarr's names, not Radarr's. The repair writes these onto a filesystem, and a
    /// TV server handed "movies-4k" is a folder the user has to go and undo.
    @Test("Sonarr is offered tv categories")
    func repairNamesSonarrCategories() {
        func client(_ id: Int) -> ConfigurationSnapshot.DownloadClient {
            ConfigurationSnapshot.DownloadClient(
                id: id, name: "SABnzbd", implementation: "Sabnzbd",
                host: "192.168.68.79", port: "8082", isEnabled: true, category: "tv"
            )
        }
        let snapshot = ConfigurationSnapshot(servers: [
            Self.server(id: Self.hdID, type: .sonarr, name: "Sonarr", clients: [client(1)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/TV")], tier: .hd),
            Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr 4K", clients: [client(2)], folders: [ConfigurationSnapshot.RootFolder(path: "/data/TV-4K")], tier: .uhd)
        ])
        let issue = ConfigurationAudit.issues(in: snapshot).first { $0.kind == .downloadClientCategoryShared }
        let changes = try! #require(issue?.fix.guidedRepair).downloadCategoryChanges
        #expect(changes.count == 1)
        #expect(changes.first?.suggestedCategory == "tv-4k")
    }

    // MARK: Remote path mappings

    /// A note, never a problem: Arr and its client routinely sit on different hosts
    /// sharing one mount, where no mapping is needed and everything works.
    @Test("A client on another host with no mapping is a note")
    func unmappedRemoteClientIsANote() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID,
                name: "Radarr",
                clients: [Self.qbClient(host: "10.0.0.9")],
                mappings: [],
                host: "http://10.0.0.5:7878"
            )],
            trawlClients: [.qbittorrent: ["http://10.0.0.9:8080"]]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .remotePathMappingMissing }
        #expect(found.count == 1)
        #expect(found.first?.severity == .note)

        // With a mapping for that host, nothing is said.
        let mapped = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID,
                name: "Radarr",
                clients: [Self.qbClient(host: "10.0.0.9")],
                mappings: [ConfigurationSnapshot.RemotePathMapping(host: "10.0.0.9", remotePath: "/downloads", localPath: "/data/downloads")],
                host: "http://10.0.0.5:7878"
            )],
            trawlClients: [.qbittorrent: ["http://10.0.0.9:8080"]]
        )
        #expect(!ConfigurationAudit.issues(in: mapped).contains { $0.kind == .remotePathMappingMissing })
    }

    // MARK: Prowlarr sync level

    /// An application entry set to "disabled" sync is an entry that does nothing, so
    /// counting its presence as coverage leaves the server with no indexers.
    @Test("A Prowlarr application with sync disabled is not coverage")
    func prowlarrSyncDisabled() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient()], host: "http://10.0.0.5:7878")],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]],
            prowlarrApplications: [Self.prowlarrApp("http://10.0.0.5:7878", type: .radarr, syncDisabled: true)]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .prowlarrSyncDisabled }
        #expect(found.count == 1)
        #expect(found.first?.severity == .problem)
    }

    /// One address, two entries: an entry for Radarr says nothing about Sonarr.
    @Test("A Prowlarr application is matched on its app type as well as its address")
    func prowlarrMatchesAppType() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()], host: "http://10.0.0.5:7878"),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data/tv")], host: "http://10.0.0.5:7878")
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]],
            prowlarrApplications: [Self.prowlarrApp("http://10.0.0.5:7878", type: .radarr)]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .missingProwlarrApplication }
        #expect(found.count == 1)
        #expect(found.first?.subject.instanceID == Self.uhdID)
    }

    // MARK: Prowlarr discovery

    /// Prowlarr leaves one unmistakable mark on the servers it syncs: it proxies
    /// every indexer under its own numeric id. Nothing a person adds by hand looks
    /// like that, which is what makes this safe to act on.
    @Test("A Prowlarr proxy path is recognised, and a hand-added indexer is not")
    func prowlarrProxyPathDetection() {
        #expect(
            ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: [
                "http://10.0.0.5:9696/1/api",
                "http://10.0.0.5:9696/2/api"
            ]) == "http://10.0.0.5:9696"
        )
        // A reverse proxy in front of Prowlarr keeps its URL base.
        #expect(
            ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: ["https://arr.example.com/prowlarr/7/api"])
                == "https://arr.example.com/prowlarr"
        )
        // An indexer added by hand points at the tracker, not at a proxy path.
        #expect(
            ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: [
                "https://api.nzbgeek.info",
                "https://tracker.example.org/api",
                "https://tracker.example.org/v2/api"
            ]) == nil
        )
        #expect(ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: []) == nil)
        #expect(ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: ["   ", "not a url"]) == nil)
    }

    /// One stray hand-made entry that happens to fit the shape must not outvote a
    /// real sync, and the answer has to be the same on every audit or the finding's
    /// id moves and a dismissal stops sticking.
    @Test("The most-seen Prowlarr wins, and ties resolve the same way every time")
    func prowlarrProxyPathIsStable() {
        let mixed = [
            "http://10.0.0.9:9696/4/api",
            "http://10.0.0.5:9696/1/api",
            "http://10.0.0.5:9696/2/api"
        ]
        #expect(ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: mixed) == "http://10.0.0.5:9696")
        #expect(
            ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: mixed.reversed())
                == ProwlarrIndexerOrigin.syncedBaseURL(inIndexerBaseURLs: mixed),
            "The order the servers answered in must not change which Prowlarr is named."
        )
    }

    /// A note, never a problem: nothing is broken, and a user who manages Prowlarr in
    /// a browser has made a perfectly reasonable choice.
    @Test("An unconfigured Prowlarr that is clearly running is a note with somewhere to go")
    func prowlarrDetectedButNotConnected() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID,
                name: "Radarr",
                clients: [Self.qbClient()],
                indexers: 2,
                indexerBaseURLs: ["http://10.0.0.5:9696/1/api", "http://10.0.0.5:9696/2/api"],
                host: "http://10.0.0.5:7878"
            )],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]]
        )

        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .prowlarrDetectedButNotConnected }
        #expect(found.count == 1)
        #expect(found.first?.severity == .note)
        #expect(found.first?.detail.contains("http://10.0.0.5:9696") == true)
        // The wizard renders a note with a destination as a link, so the note is only
        // worth raising if it has one.
        #expect(found.first?.fix.destination != nil)
    }

    @Test("A configured Prowlarr is never nudged about, however its indexers look")
    func configuredProwlarrIsSilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(
                id: Self.hdID,
                name: "Radarr",
                clients: [Self.qbClient()],
                indexerBaseURLs: ["http://10.0.0.5:9696/1/api"],
                host: "http://10.0.0.5:7878"
            )],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]],
            prowlarrApplications: [Self.prowlarrApp("http://10.0.0.5:7878")],
            isProwlarrConfigured: true
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .prowlarrDetectedButNotConnected })
    }

    // MARK: Seerr

    @Test("A Seerr with no server for a configured service will accept requests and drop them")
    func seerrMissingDVR() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()])],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]],
            seerr: ConfigurationSnapshot.SeerrSetup(dvrServers: [])
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .seerrMissingDVR }
        #expect(found.count == 1)
        #expect(found.first?.severity == .problem)
    }

    @Test("A Seerr with servers but no default has nowhere to send an ordinary request")
    func seerrNoDefault() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()])],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]],
            seerr: ConfigurationSnapshot.SeerrSetup(dvrServers: [
                ConfigurationSnapshot.SeerrDVR(name: "Radarr 4K", serviceType: .radarr, is4k: true, isDefault: true)
            ])
        )
        let found = ConfigurationAudit.issues(in: snapshot)
        #expect(found.contains { $0.kind == .seerrNoDefaultDVR && $0.severity == .problem })
    }

    @Test("A Seerr server missing a root folder or profile is reported by name")
    func seerrIncompleteDVR() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()])],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]],
            seerr: ConfigurationSnapshot.SeerrSetup(dvrServers: [
                ConfigurationSnapshot.SeerrDVR(name: "Main Radarr", serviceType: .radarr, isDefault: true, hasRootFolder: false)
            ])
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .seerrDVRIncomplete }
        #expect(found.count == 1)
        #expect(found.first?.title.contains("Main Radarr") == true)
    }

    @Test("An uninitialised Seerr is a problem; an unreadable one is unknown")
    func seerrInitialisation() {
        let uninitialised = ConfigurationSnapshot(
            seerr: ConfigurationSnapshot.SeerrSetup(isInitialized: false)
        )
        #expect(ConfigurationAudit.issues(in: uninitialised).contains {
            $0.kind == .seerrNotInitialized && $0.severity == .problem
        })

        let unreadable = ConfigurationSnapshot(
            seerr: ConfigurationSnapshot.SeerrSetup(isInitialized: nil)
        )
        #expect(ConfigurationAudit.issues(in: unreadable).allSatisfy { $0.severity == .unknown })

        let unreachable = ConfigurationSnapshot(
            seerr: ConfigurationSnapshot.SeerrSetup(isConnected: false, isInitialized: nil, dvrServers: nil)
        )
        #expect(ConfigurationAudit.issues(in: unreachable).contains {
            $0.kind == .serviceUnreachable && $0.severity == .unknown
        })
    }

    // MARK: Cleanuparr

    @Test("Cleanuparr's own readiness is a finding; not knowing it is unknown")
    func cleanuparrReadiness() {
        let notReady = ConfigurationSnapshot(
            cleanuparr: ConfigurationSnapshot.CleanuparrStatus(isReady: false)
        )
        #expect(ConfigurationAudit.issues(in: notReady).contains {
            $0.kind == .cleanuparrNotReady && $0.severity == .problem
        })

        let unknown = ConfigurationSnapshot(
            cleanuparr: ConfigurationSnapshot.CleanuparrStatus(isReady: nil)
        )
        #expect(ConfigurationAudit.issues(in: unknown).allSatisfy { $0.severity == .unknown })

        let ready = ConfigurationSnapshot(
            cleanuparr: ConfigurationSnapshot.CleanuparrStatus(isReady: true)
        )
        #expect(ConfigurationAudit.issues(in: ready).isEmpty)
    }

    // MARK: Topics

    /// The contextual banners filter on this, and a connection fault has to reach
    /// every one of them: it is the reason that screen's own checks are unknown.
    @Test("Every kind has a topic, and connection faults reach every screen")
    func topicsCoverEveryKind() {
        for kind in ConfigurationIssueKind.allCases {
            #expect(ConfigurationIssueKind.allCases.contains(kind))
            _ = kind.topic
        }
        #expect(ConfigurationIssueKind.noDownloadClient.topic == .downloads)
        #expect(ConfigurationIssueKind.noIndexers.topic == .search)
        #expect(ConfigurationIssueKind.bazarrAppNotLinked.topic == .subtitles)
        #expect(ConfigurationIssueKind.seerrMissingDVR.topic == .requests)
        #expect(ConfigurationIssueKind.cleanuparrNotReady.topic == .maintenance)
        #expect(ConfigurationIssueKind.serviceHealthError.topic == .connection)

        let issues = ConfigurationAudit.issues(in: ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [], health: nil)]
        ))
        #expect(!issues.concerning(.downloads).isEmpty)
        #expect(!issues.concerning(.requests).isEmpty, "The unknown health read reaches every screen.")
    }

    @Test("A fully wired setup produces nothing")
    func healthySetupIsSilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data/movies")], indexers: 2, host: "http://10.0.0.5:7878"),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data/tv")], indexers: 2, host: "http://10.0.0.5:8989")
            ],
            trawlClients: [.qbittorrent: ["http://10.0.0.5:8080"]],
            prowlarrApplications: [
                Self.prowlarrApp("http://10.0.0.5:7878", type: .radarr),
                Self.prowlarrApp("http://10.0.0.5:8989", type: .sonarr)
            ],
            bazarrServers: [ConfigurationSnapshot.BazarrServer(
                instanceID: Self.bazarrID, displayName: "Bazarr", linkedApps: [.sonarr, .radarr]
            )]
        )
        #expect(ConfigurationAudit.issues(in: snapshot).isEmpty)
    }
}
