//
//  UnifiedIndexerIdentityTests.swift
//  TrawlTests
//
//  The Indexers screen is one list built from two different places: the indexers
//  Prowlarr manages, and the ones configured directly on each Sonarr/Radarr. Both
//  number their rows from their own sequence, so `id 5` names a different indexer
//  depending on which server answered - and a `ForEach` given two rows with one id
//  renders one row, silently. The HD/4K pair makes it likely rather than theoretical:
//  two Sonarrs on one machine hand out the same ids for entirely different indexers.
//
//  The delete confirmation has the same shape of risk pointing the other way. It is
//  the last thing a user reads before an indexer is removed from a server, and it has
//  to name the server it is actually about to touch.
//

import Foundation
import SwiftUI
import Testing
@testable import Trawl

@Suite("Unified indexer identity")
@MainActor
struct UnifiedIndexerIdentityTests {

    @Test("Two servers' indexers keep separate identities even when they share an id")
    func directIndexersFromTwoServersDoNotCollide() throws {
        let hd = Self.profile(name: "Sonarr HD", tier: .hd)
        let uhd = Self.profile(name: "Sonarr 4K", tier: .uhd)
        let indexer = try Self.managedIndexer(id: 5, name: "NZBgeek")

        let onHD = OwnedDirectIndexer(indexer: indexer, profile: hd, serviceType: .sonarr)
        let onUHD = OwnedDirectIndexer(indexer: indexer, profile: uhd, serviceType: .sonarr)

        #expect(onHD.id != onUHD.id, "One indexer id from two servers must not collapse into one row.")
        #expect(onHD.id.contains(hd.id.uuidString))
        #expect(onUHD.id.contains(uhd.id.uuidString))
    }

    /// The other half of the same question: Sonarr and Radarr on one host also number
    /// from their own sequences, so the service has to be part of the identity too.
    @Test("Sonarr and Radarr indexers sharing an id stay separate rows")
    func directIndexersFromTwoServicesDoNotCollide() throws {
        let profile = Self.profile(name: "Shared", tier: .hd)
        let indexer = try Self.managedIndexer(id: 5, name: "NZBgeek")

        let asSonarr = OwnedDirectIndexer(indexer: indexer, profile: profile, serviceType: .sonarr)
        let asRadarr = OwnedDirectIndexer(indexer: indexer, profile: profile, serviceType: .radarr)

        #expect(asSonarr.id != asRadarr.id)
    }

    /// Prowlarr's rows and a server's own rows share the list, and Prowlarr's ids come
    /// from a third sequence again.
    @Test("A Prowlarr row and a direct row never share a list identity")
    func prowlarrAndDirectRowsDoNotCollide() throws {
        let prowlarrIndexer = try Self.prowlarrIndexer(id: 5, name: "NZBgeek")
        let owned = OwnedDirectIndexer(
            indexer: try Self.managedIndexer(id: 5, name: "NZBgeek"),
            profile: Self.profile(name: "Sonarr HD", tier: .hd),
            serviceType: .sonarr
        )

        let fromProwlarr = Self.listItem(.prowlarr(prowlarrIndexer))
        let fromServer = Self.listItem(.direct(owned))

        #expect(fromProwlarr.id != fromServer.id)
        #expect(fromProwlarr.id == "prowlarr-5")
        #expect(fromServer.id == owned.id)
    }

    /// `AddIndexerDestination` is what the add sheet is keyed on. Two servers offering
    /// "add an indexer here" that shared an id would open one sheet for both.
    @Test("Each add destination is its own sheet identity")
    func addDestinationsAreDistinct() {
        let hdID = UUID()
        let uhdID = UUID()

        let destinations: [AddIndexerDestination] = [
            .prowlarr,
            .direct(profileID: hdID, serviceType: .sonarr),
            .direct(profileID: uhdID, serviceType: .sonarr),
            .direct(profileID: hdID, serviceType: .radarr)
        ]

        let ids = destinations.map(\.id)
        #expect(Set(ids).count == ids.count, "Two add destinations sharing an id would present one sheet for both.")
        #expect(ids.first == "prowlarr")
    }

    /// The confirmation a destructive action is read from. "This removes X from
    /// Sonarr 4K" is the only place the user is told *which* server loses the indexer,
    /// and the HD and 4K rows look identical otherwise.
    @Test("The delete confirmation names the server it is about to change")
    func deleteMessageNamesItsSource() throws {
        let prowlarr = UnifiedIndexerDeleteTarget.prowlarr(try Self.prowlarrIndexer(id: 9, name: "NZBgeek"))
        #expect(prowlarr.deleteMessage == "This removes \"NZBgeek\" from Prowlarr.")

        let direct = UnifiedIndexerDeleteTarget.direct(
            OwnedDirectIndexer(
                indexer: try Self.managedIndexer(id: 9, name: "NZBgeek"),
                profile: Self.profile(name: "Sonarr 4K", tier: .uhd),
                serviceType: .sonarr
            )
        )
        #expect(direct.deleteMessage == "This removes \"NZBgeek\" from Sonarr 4K.")

        // An indexer with no name still produces a sentence rather than an empty
        // quotation - the confirmation is shown either way.
        let unnamed = UnifiedIndexerDeleteTarget.prowlarr(try Self.prowlarrIndexer(id: 10, name: nil))
        #expect(unnamed.deleteMessage == "This removes \"this indexer\" from Prowlarr.")
    }

    @Test("Sections order torrent, then usenet, then everything else")
    func sectionsSortInReadingOrder() {
        let ordered = IndexerListSection.allCases.sorted { $0.sortOrder < $1.sortOrder }
        #expect(ordered.map(\.title) == ["Torrent", "Usenet", "Other"])
        #expect(Set(IndexerListSection.allCases.map(\.id)).count == IndexerListSection.allCases.count)
    }

    // MARK: - Fixtures

    /// Decoded from the wire shape rather than built field by field, so a model that
    /// gains a field does not silently drift away from what the servers send.
    private static func managedIndexer(id: Int, name: String?) throws -> ArrManagedIndexer {
        let nameJSON = name.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": \(id), "name": \(nameJSON), "protocol": "usenet", "enableRss": true,
         "enableAutomaticSearch": true, "enableInteractiveSearch": true, "priority": 25}
        """
        return try JSONDecoder().decode(ArrManagedIndexer.self, from: Data(json.utf8))
    }

    private static func prowlarrIndexer(id: Int, name: String?) throws -> ProwlarrIndexer {
        let nameJSON = name.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id": \(id), "name": \(nameJSON), "enable": true, "protocol": "usenet", "priority": 25}
        """
        return try JSONDecoder().decode(ProwlarrIndexer.self, from: Data(json.utf8))
    }

    private static func profile(name: String, tier: ArrQualityTier) -> ArrServiceProfile {
        ArrServiceProfile(
            displayName: name,
            hostURL: "http://127.0.0.1:1",
            serviceType: .sonarr,
            qualityTier: tier
        )
    }

    private static func listItem(_ kind: UnifiedIndexerListItem.Kind) -> UnifiedIndexerListItem {
        UnifiedIndexerListItem(
            kind: kind,
            title: "NZBgeek",
            implementationName: "Newznab",
            protocolName: "usenet",
            sourceLabel: "Prowlarr",
            barColor: .accentColor,
            warningState: .connected,
            section: .usenet
        )
    }
}
