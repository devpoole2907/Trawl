//
//  ConfigurationCategoryRepairTests.swift
//  TrawlTests
//
//  The wizard's "give each server its own download category" repair is the one place
//  in Trawl that writes a download client back to an Arr on the user's behalf, and it
//  is offered to someone who has already been told their setup is broken. Getting it
//  wrong is worse than not offering it: a client is a whole object on the wire, so a
//  careless save reverts every field the audit did not read, and a category written
//  in the wrong spelling or the wrong field is reported as success while changing
//  nothing.
//
//  These drive the real repair against a loopback Radarr and read what actually went
//  over the socket. The recorded PUT body is compared as parsed JSON rather than as
//  encoder bytes, because field order is not part of the contract.
//

import Foundation
import Testing
@testable import Trawl

@Suite("Configuration category repair", .serialized)
@MainActor
struct ConfigurationCategoryRepairTests {

    /// A Radarr SABnzbd client with an empty category, sitting on fields the repair
    /// has no business touching. `port` is a number and `enable` a bool on purpose:
    /// a repair that rebuilt the row from the fields it understands would flatten
    /// both, and the assertion below would catch it.
    private static let untaggedClientJSON = #"""
    [
      {
        "id": 7,
        "name": "SABnzbd",
        "implementation": "Sabnzbd",
        "implementationName": "SABnzbd",
        "configContract": "SabnzbdSettings",
        "enable": true,
        "priority": 3,
        "supportsCategories": true,
        "removeCompletedDownloads": true,
        "fields": [
          {"order": 0, "name": "host", "value": "nas.local"},
          {"order": 1, "name": "port", "value": 8080},
          {"order": 2, "name": "movieCategory", "value": ""},
          {"order": 3, "name": "recentMoviePriority", "value": -100}
        ]
      }
    ]
    """#

    // MARK: - The plan

    /// The text field accepts anything. What reaches disk is trimmed and lowercased,
    /// because that is the form every comparison in the audit is made against - a
    /// category written as "Movies 4K" and read back as "movies 4k" would otherwise
    /// re-report itself as unrepaired on the next run.
    @Test("A category is normalized to what the audit will read back")
    func planNormalizesTheCategoryItWillWrite() {
        let plan = ConfigurationCategoryRepair.Plan(change(suggested: "  Movies 4K  "))
        #expect(plan.normalizedCategory == "movies 4k")
        #expect(plan.isValid)
    }

    /// Three spellings the field accepts and the download client does not: SABnzbd's
    /// catch-all, and either path separator, which name a folder rather than a
    /// category once written.
    @Test("Categories that mean something else are refused")
    func planRefusesCategoriesThatAreNotCategories() {
        for spelling in ["", "   ", "*", "movies/4k", #"movies\4k"#] {
            let plan = ConfigurationCategoryRepair.Plan(change(suggested: spelling))
            #expect(plan.isValid == false, "\"\(spelling)\" should not be accepted as a category.")
        }
    }

    // MARK: - Applying it

    /// The whole point of the repair, and the assertion that matters most: the client
    /// is re-read immediately before it is written, and everything the audit never
    /// looked at comes back unchanged.
    @Test("Applying a repair re-reads the client and writes only the category")
    func applyWritesTheCategoryWithoutDisturbingTheClient() async throws {
        let radarr = try await DualInstanceRadarrServer(
            label: "repair-apply",
            movies: "[]",
            downloadClients: Self.untaggedClientJSON
        )
        defer { radarr.stop() }

        try await withRadarr(radarr) { manager, instanceID in
            let repair = ConfigurationCategoryRepair(
                serviceManager: manager,
                sabnzbdServiceManager: nil,
                sabnzbdEndpoints: [],
                activeSabnzbdEndpoint: nil
            )
            let plan = ConfigurationCategoryRepair.Plan(
                change(instanceID: instanceID, suggested: "Movies 4K")
            )

            let outcome = await repair.apply(plan)

            guard case .succeeded(let message) = outcome else {
                Issue.record("Expected the repair to succeed, got \(outcome).")
                return
            }
            #expect(message.contains("Radarr 4K"))
            #expect(message.contains("movies 4k"))

            let put = try #require(radarr.putRequests.first)
            #expect(put.path == "/api/v3/downloadclient/7")
            #expect(radarr.putRequests.count == 1)

            // Read before write, on this repair rather than on some earlier fetch:
            // the audit's snapshot is minutes old by the time anyone presses a button.
            let paths = radarr.requestedPaths
            let read = try #require(paths.firstIndex { $0.hasPrefix("/api/v3/downloadclient") && !$0.contains("/7") })
            let write = try #require(paths.firstIndex { $0.contains("/api/v3/downloadclient/7") })
            #expect(read < write)

            let decoded = try JSONSerialization.jsonObject(with: Data(put.body.utf8))
            let written = try #require(decoded as? [String: Any])
            #expect(written["id"] as? Int == 7)
            #expect(written["name"] as? String == "SABnzbd")
            #expect(written["enable"] as? Bool == true)
            #expect(written["priority"] as? Int == 3)
            #expect(written["removeCompletedDownloads"] as? Bool == true)

            let fields = try #require(written["fields"] as? [[String: Any]])
            func value(of name: String) -> Any? {
                fields.first { $0["name"] as? String == name }?["value"]
            }
            #expect(value(of: "movieCategory") as? String == "movies 4k")
            #expect(value(of: "host") as? String == "nas.local")
            #expect(value(of: "port") as? Int == 8080)
            #expect(value(of: "recentMoviePriority") as? Int == -100)
            // The category belongs in the field Radarr reads. A repair that invents a
            // plain `category` field on a Radarr client writes something Radarr
            // ignores and then reports success.
            #expect(fields.count == 4)
        }
    }

    /// A shared SABnzbd needs its category created before the save, because Arr
    /// validates the name against the client and answers 400 for one it has never
    /// heard of. When Trawl is not connected to that SABnzbd it cannot do the first
    /// step - and must not do the second either, or the user is left with a server
    /// pointed at a category that does not exist.
    @Test("A SABnzbd Trawl cannot reach leaves the Arr untouched")
    func applyRefusesWhenTheSharedSabnzbdIsNotConnected() async throws {
        let radarr = try await DualInstanceRadarrServer(
            label: "repair-sab-guard",
            movies: "[]",
            downloadClients: Self.untaggedClientJSON
        )
        defer { radarr.stop() }

        try await withRadarr(radarr) { manager, instanceID in
            let repair = ConfigurationCategoryRepair(
                serviceManager: manager,
                sabnzbdServiceManager: nil,
                sabnzbdEndpoints: ["nas.local:8080"],
                activeSabnzbdEndpoint: nil
            )
            let outcome = await repair.apply(
                ConfigurationCategoryRepair.Plan(
                    change(instanceID: instanceID, suggested: "movies4k", endpoint: "nas.local:8080")
                )
            )

            guard case .failed(let message) = outcome else {
                Issue.record("Expected the repair to refuse, got \(outcome).")
                return
            }
            #expect(message.contains("nas.local:8080"))
            #expect(message.contains("left unchanged"))
            #expect(radarr.putRequests.isEmpty)
        }
    }

    /// The audit's snapshot can name a download client that has since been deleted.
    /// Saying so is the whole job here: the alternative is a PUT that Arr treats as a
    /// create and a duplicate client nobody asked for.
    @Test("A download client that is gone is reported, not recreated")
    func applyReportsAMissingDownloadClient() async throws {
        let radarr = try await DualInstanceRadarrServer(
            label: "repair-gone",
            movies: "[]",
            downloadClients: "[]"
        )
        defer { radarr.stop() }

        try await withRadarr(radarr) { manager, instanceID in
            let repair = ConfigurationCategoryRepair(
                serviceManager: manager,
                sabnzbdServiceManager: nil,
                sabnzbdEndpoints: [],
                activeSabnzbdEndpoint: nil
            )
            let outcome = await repair.apply(
                ConfigurationCategoryRepair.Plan(change(instanceID: instanceID, suggested: "movies4k"))
            )

            guard case .failed(let message) = outcome else {
                Issue.record("Expected the repair to report the missing client, got \(outcome).")
                return
            }
            #expect(message.contains("SABnzbd"))
            #expect(radarr.putRequests.isEmpty)
        }
    }

    /// An unusable category is caught before anything is sent, so a rejected repair
    /// costs no round trip and cannot half-apply.
    @Test("An invalid category never reaches the server")
    func applyRefusesAnInvalidCategoryBeforeAnyRequest() async throws {
        let radarr = try await DualInstanceRadarrServer(
            label: "repair-invalid",
            movies: "[]",
            downloadClients: Self.untaggedClientJSON
        )
        defer { radarr.stop() }

        try await withRadarr(radarr) { manager, instanceID in
            let repair = ConfigurationCategoryRepair(
                serviceManager: manager,
                sabnzbdServiceManager: nil,
                sabnzbdEndpoints: [],
                activeSabnzbdEndpoint: nil
            )
            let before = radarr.requestedPaths.count
            let outcome = await repair.apply(
                ConfigurationCategoryRepair.Plan(change(instanceID: instanceID, suggested: "*"))
            )

            guard case .failed = outcome else {
                Issue.record("Expected an invalid category to be refused, got \(outcome).")
                return
            }
            #expect(radarr.putRequests.isEmpty)
            #expect(radarr.requestedPaths.filter { $0.contains("downloadclient") }.count == 0)
            #expect(radarr.requestedPaths.count == before)
        }
    }

    // MARK: - Helpers

    private func change(
        instanceID: UUID = UUID(),
        suggested: String,
        endpoint: String = "nas.local:8080"
    ) -> ConfigurationGuidedRepair.DownloadCategoryChange {
        ConfigurationGuidedRepair.DownloadCategoryChange(
            instanceID: instanceID,
            serviceType: .radarr,
            serverName: "Radarr 4K",
            downloadClientID: 7,
            downloadClientName: "SABnzbd",
            currentCategory: nil,
            suggestedCategory: suggested,
            endpoint: endpoint
        )
    }

    /// Connects the loopback server as a Radarr, runs the body with its instance id,
    /// and leaves no Keychain entry behind.
    private func withRadarr(
        _ server: DualInstanceRadarrServer,
        _ body: (ArrServiceManager, UUID) async throws -> Void
    ) async throws {
        let manager = ArrServiceManager()
        let profile = ArrServiceProfile(
            displayName: "Radarr 4K",
            hostURL: server.baseURL,
            serviceType: .radarr,
            qualityTier: .uhd
        )
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "repair-key")
        defer {
            let key = profile.apiKeyKeychainKey
            Task { try? await KeychainHelper.shared.delete(key: key) }
        }

        await manager.connectService(profile)
        #expect(manager.connectedRadarr.count == 1)

        try await body(manager, profile.id)
    }
}
