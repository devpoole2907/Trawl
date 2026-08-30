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

    private static func server(
        id: UUID,
        type: ArrServiceType = .radarr,
        name: String,
        clients: [ConfigurationSnapshot.DownloadClient]? = [],
        folders: [ConfigurationSnapshot.RootFolder]? = [ConfigurationSnapshot.RootFolder(path: "/data/movies")],
        indexers: Int? = 1,
        host: String? = nil,
        isConnected: Bool = true
    ) -> ConfigurationSnapshot.Server {
        ConfigurationSnapshot.Server(
            instanceID: id,
            serviceType: type,
            displayName: name,
            isConnected: isConnected,
            downloadClients: clients,
            rootFolders: folders,
            enabledIndexerCount: indexers,
            host: host
        )
    }

    private static func qbClient(host: String = "10.0.0.5", enabled: Bool = true) -> ConfigurationSnapshot.DownloadClient {
        ConfigurationSnapshot.DownloadClient(
            name: "qBittorrent",
            implementation: "QBittorrent",
            host: host,
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
            trawlClients: [.qbittorrent: "http://10.0.0.5:8080"]
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
            trawlClients: [.qbittorrent: "http://10.0.0.5:8080"]
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
            trawlClients: [.qbittorrent: "http://10.0.0.5:8080"]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .downloadClientElsewhere }
        #expect(found.count == 1)
        #expect(found.first?.severity == .note)
    }

    @Test("Loopback spellings are not treated as a different host")
    func loopbackSpellingsMatch() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [Self.qbClient(host: "localhost")])],
            trawlClients: [.qbittorrent: "http://127.0.0.1:8080"]
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .downloadClientElsewhere })
    }

    @Test("A client nothing grabs through is reported once, as a note")
    func unusedTrawlClient() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [])],
            trawlClients: [.sabnzbd: "http://10.0.0.9:8080"]
        )
        let found = ConfigurationAudit.issues(in: snapshot).filter { $0.kind == .downloadClientUnused }
        #expect(found.count == 1)
        #expect(found.first?.severity == .note)
    }

    /// "Could not ask" is not "there is nothing there". A server that was down when
    /// the audit ran must not be reported as misconfigured.
    @Test("A server whose clients could not be read reports nothing about them")
    func unreadableClientsStaySilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: nil, folders: nil, indexers: nil)],
            trawlClients: [.qbittorrent: "http://10.0.0.5:8080"]
        )
        #expect(ConfigurationAudit.issues(in: snapshot).isEmpty)
    }

    @Test("A disconnected server is not audited at all")
    func disconnectedServerIsSkipped() {
        let snapshot = ConfigurationSnapshot(
            servers: [Self.server(id: Self.hdID, name: "Radarr", clients: [], folders: [], indexers: 0, isConnected: false)]
        )
        #expect(ConfigurationAudit.issues(in: snapshot).isEmpty)
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
            prowlarrApplicationHosts: ["http://10.0.0.5:7878"]
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
            prowlarrApplicationHosts: nil
        )
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .missingProwlarrApplication })
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
        #expect(!ConfigurationAudit.issues(in: snapshot).contains { $0.kind == .bazarrAppNotLinked })
    }

    // MARK: Presentation contract

    @Test("Problems sort ahead of notes")
    func problemsSortFirst() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, name: "Radarr HD", clients: [Self.qbClient(host: "gluetun")]),
                Self.server(id: Self.uhdID, name: "Radarr 4K", clients: [])
            ],
            trawlClients: [.qbittorrent: "http://10.0.0.5:8080"]
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

    @Test("A fully wired setup produces nothing")
    func healthySetupIsSilent() {
        let snapshot = ConfigurationSnapshot(
            servers: [
                Self.server(id: Self.hdID, type: .radarr, name: "Radarr", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data/movies")], indexers: 2, host: "http://10.0.0.5:7878"),
                Self.server(id: Self.uhdID, type: .sonarr, name: "Sonarr", clients: [Self.qbClient()], folders: [ConfigurationSnapshot.RootFolder(path: "/data/tv")], indexers: 2, host: "http://10.0.0.5:8989")
            ],
            trawlClients: [.qbittorrent: "http://10.0.0.5:8080"],
            prowlarrApplicationHosts: ["http://10.0.0.5:7878", "http://10.0.0.5:8989"],
            bazarrServers: [ConfigurationSnapshot.BazarrServer(
                instanceID: Self.bazarrID, displayName: "Bazarr", linkedApps: [.sonarr, .radarr]
            )]
        )
        #expect(ConfigurationAudit.issues(in: snapshot).isEmpty)
    }
}
