import Foundation
import Network
import Testing
@testable import Trawl

/// Bazarr's subtitle providers are saved by **replacing the whole enabled set**, and
/// nothing covered that. `saveEnabledProviders` posts one
/// `settings-general-enabled_providers` form field per enabled key, so the request that
/// enables a single provider is also the request that re-states every provider the user
/// already had. Anything that drops the others — a stale local list, a dictionary
/// collapsing the repeated field, a "send only what changed" refactor — silently
/// disables them, and `BazarrProvidersView` reloads afterwards so the screen would
/// simply show the new, smaller truth.
///
/// The empty case is separately load-bearing: disabling the last provider posts an
/// explicit empty value rather than omitting the field, which is what actually clears
/// the set server-side. Omitting it would leave the provider enabled while the UI
/// reported success.
@Suite("Bazarr enabled-provider saves", .serialized)
@MainActor
struct BazarrProviderSaveTests {

    @Test("Enabling a provider re-sends every provider already enabled, one field each")
    func enablingReSendsTheExistingProviders() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-provider-enable") { _ in
            .json("{}")
        }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        // What BazarrProvidersView builds when enabling "podnapisi" on top of two
        // already-enabled providers: the existing keys plus the new one.
        try await client.saveEnabledProviders(["opensubtitles", "addic7ed", "podnapisi"])

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        #expect(
            request.formValues(named: "settings-general-enabled_providers") == ["opensubtitles", "addic7ed", "podnapisi"],
            "Every enabled provider must appear as its own field. Collapsing these to one value is how enabling one provider disables the rest."
        )
    }

    @Test("Disabling a provider sends the survivors and omits the disabled one")
    func disablingSendsOnlyTheSurvivors() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-provider-disable") { _ in
            .json("{}")
        }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        try await client.saveEnabledProviders(["opensubtitles", "podnapisi"])

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        let sent = request.formValues(named: "settings-general-enabled_providers")
        #expect(sent == ["opensubtitles", "podnapisi"])
        #expect(sent.contains("addic7ed") == false, "The disabled provider must not be re-sent.")
    }

    @Test("Disabling the last provider posts an explicit empty value rather than dropping the field")
    func disablingTheLastProviderSendsAnEmptyMarker() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-provider-empty") { _ in
            .json("{}")
        }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        try await client.saveEnabledProviders([])

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        #expect(
            request.formValues(named: "settings-general-enabled_providers") == [""],
            "Clearing the set needs the field present with an empty value. Omitting it entirely leaves the providers enabled on the server while the app reports the save succeeded."
        )
    }

    @Test("Provider field values are sent alongside the enabled set, not instead of it")
    func fieldValuesAccompanyTheEnabledSet() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-provider-fields") { _ in
            .json("{}")
        }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        try await client.saveEnabledProviders(
            ["opensubtitles"],
            fieldValues: ["settings-opensubtitles-username": "ada"]
        )

        let request = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/system/settings" })
        #expect(request.formValues(named: "settings-general-enabled_providers") == ["opensubtitles"])
        #expect(request.formValues(named: "settings-opensubtitles-username") == ["ada"])
    }

    @Test("A rejected provider save surfaces as an error rather than reporting success")
    func rejectedSaveThrows() async throws {
        let server = try await BazarrFixtureServer(label: "bazarr-provider-reject") { _ in
            .json(#"{"error":"nope"}"#, status: 500)
        }
        defer { server.stop() }
        let client = BazarrAPIClient(baseURL: server.baseURL, apiKey: "bazarr-key")

        await #expect(throws: (any Error).self) {
            try await client.saveEnabledProviders(["opensubtitles"])
        }
        #expect(server.requests.contains { $0.method == "POST" && $0.path == "/api/system/settings" })
    }
}
