import Foundation
import Network
import Testing
@testable import Trawl

/// Bazarr's language profiles are saved the same way its providers are: by replacing
/// the whole collection. `saveLanguageProfiles` encodes **every** profile into one
/// `languages-profiles` form field as JSON, so the request that edits one profile is
/// also the request that re-states all the others, and the request that deletes one is
/// simply the surviving list.
///
/// Two ways that goes wrong silently, neither covered before:
///
/// * A field the payload does not carry is dropped from profiles nobody touched - the
///   `BazarrLanguageProfileSettingsPayload` shape decides what survives, so a profile's
///   cutoff or must-contain rules can be reset by editing an unrelated profile.
/// * A stale or partial list deletes profiles outright. `BazarrLanguageProfilesView`
///   reloads after saving, so the screen agrees with whatever was just sent.
///
/// `saveEnabledLanguages` is covered here too: it is the repeated-form-field shape
/// already pinned for providers, applied to language codes.
@Suite("Bazarr language profile and enabled-language saves", .serialized)
@MainActor
struct BazarrLanguageProfileSaveTests {

    @Test("Editing one profile re-sends the others with every field intact")
    func editingOneProfilePreservesTheOthers() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-lang-edit") { _ in .json("{}") }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        let profiles = try JSONDecoder().decode(
            [BazarrLanguageProfile].self,
            from: Data(twoProfilesJSON.utf8)
        )
        #expect(profiles.count == 2)

        try await client.saveLanguageProfiles(profiles)

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        let encoded = try #require(request.formValues(named: "languages-profiles").first)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]]
        )

        #expect(sent.count == 2, "The whole collection must be sent - a partial list deletes the missing profiles.")

        // The profile nobody edited has to survive with all of its rules. These are the
        // fields that decide which subtitles are accepted at all.
        let untouched = try #require(sent.first { $0["profileId"] as? Int == 2 })
        #expect(untouched["name"] as? String == "Anime")
        #expect(untouched["cutoff"] as? Int == 21)
        #expect(untouched["mustContain"] as? [String] == ["dual"])
        #expect(untouched["mustNotContain"] as? [String] == ["signs"])
        #expect(untouched["originalFormat"] as? Int == 1)
        #expect(untouched["tag"] as? Int == 7)
        #expect(
            (untouched["items"] as? [[String: Any]])?.isEmpty == false,
            "A profile's language items must survive: an empty items list is a profile that accepts nothing."
        )
    }

    @Test("Deleting a profile sends the survivors and drops only that one")
    func deletingSendsTheSurvivors() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-lang-delete") { _ in .json("{}") }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        let profiles = try JSONDecoder().decode(
            [BazarrLanguageProfile].self,
            from: Data(twoProfilesJSON.utf8)
        )
        // What the view builds when deleting profile 1: the remaining profiles.
        let remaining = profiles.filter { $0.profileId != 1 }

        try await client.saveLanguageProfiles(remaining)

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        let encoded = try #require(request.formValues(named: "languages-profiles").first)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]]
        )

        #expect(sent.map { $0["profileId"] as? Int } == [2])
        #expect(sent.first?["name"] as? String == "Anime")
    }

    @Test("Deleting the last profile sends an empty array rather than nothing")
    func deletingTheLastProfileSendsAnEmptyArray() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-lang-empty") { _ in .json("{}") }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        try await client.saveLanguageProfiles([])

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        let encoded = try #require(request.formValues(named: "languages-profiles").first)
        #expect(
            encoded == "[]",
            "Clearing every profile must post an empty JSON array. An omitted or empty-string value is not a list, and would leave the profiles in place while the app reports the deletion succeeded."
        )
    }

    // MARK: - Enabled languages

    @Test("Enabled languages are sent as one field per code")
    func enabledLanguagesUseRepeatedFields() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-lang-enabled") { _ in .json("{}") }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        try await client.saveEnabledLanguages(["en", "fr", "ja"])

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        #expect(
            request.formValues(named: "languages-enabled") == ["en", "fr", "ja"],
            "Each enabled language needs its own field - collapsing them is how enabling one language disables the rest."
        )
    }

    @Test("Clearing enabled languages posts an explicit empty value")
    func clearingEnabledLanguagesSendsTheEmptyMarker() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-lang-enabled-empty") { _ in .json("{}") }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        try await client.saveEnabledLanguages([])

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        #expect(request.formValues(named: "languages-enabled") == [""])
    }

    @Test("A rejected profile save surfaces as an error rather than reporting success")
    func rejectedSaveThrows() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-lang-reject") { _ in
            .json(#"{"error":"nope"}"#, status: 500)
        }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        await #expect(throws: (any Error).self) {
            try await client.saveLanguageProfiles([])
        }
    }
}

/// Two profiles with their optional fields actually populated, so "the untouched one
/// survived intact" is observable. A profile with everything nil would pass the
/// preservation test while proving nothing.
///
/// `items` is Bazarr's own JSON-encoded-string-inside-JSON shape, which is why
/// `BazarrLanguageProfile` decodes it as `itemsJSON`.
///
/// File scope rather than a static on the suite: the suite is `@MainActor` and the
/// fixture server's router closure is `@Sendable`.
private let twoProfilesJSON = """
[
  {
    "profileId": 1,
    "name": "English",
    "cutoff": 20,
    "items": "[{\\"id\\":1,\\"language\\":\\"en\\",\\"audio_exclude\\":\\"False\\",\\"hi\\":\\"False\\",\\"forced\\":\\"False\\"}]",
    "mustContain": [],
    "mustNotContain": [],
    "originalFormat": 0,
    "tag": null
  },
  {
    "profileId": 2,
    "name": "Anime",
    "cutoff": 21,
    "items": "[{\\"id\\":2,\\"language\\":\\"ja\\",\\"audio_exclude\\":\\"False\\",\\"hi\\":\\"False\\",\\"forced\\":\\"False\\"}]",
    "mustContain": ["dual"],
    "mustNotContain": ["signs"],
    "originalFormat": 1,
    "tag": 7
  }
]
"""
