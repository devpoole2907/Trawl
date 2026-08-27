import Foundation
import Network
import SwiftData
import Testing
@testable import Trawl

/// Coverage for `ArrSetupViewModel.validateAndSave(modelContext:)`, which had none.
/// Jellyfin and Seerr each have a setup-view-model suite; the Arr equivalent did not
/// exist, and the only things exercising this ~200-line method were
/// `ArrSetupEditJourneyUITests` and `ArrRepointJourneyUITests` — both of which drive
/// the **edit** path exclusively.
///
/// The add path is not a variation on editing, it is different code:
///
/// * Editing mutates an existing profile and, on failure, restores each field
///   individually and rewrites the original Keychain value. Adding inserts a new
///   profile and unwinds through `modelContext.rollback()` plus a Keychain *delete*.
/// * Adding Prowlarr when one already exists does not insert a second profile: it
///   adopts the existing one as the edit target and disables every other Prowlarr
///   profile (`ArrSetupViewModel.swift:87-90`). The UI states this in help text, but
///   nothing tested it.
///
/// The ordering these tests pin matters as much as the outcomes: `testConnection` is
/// the first `await` in `validateAndSave`, ahead of the Keychain write and every
/// profile mutation, so a rejected key must leave no trace at all.
///
/// ## Harness
///
/// `ArrServiceManager.testConnection` builds its own client per service type
/// (`ArrServiceManager.swift:981`) with no injectable `URLSession` reaching the
/// caller, so there is no `URLProtocol` seam — these tests drive the real view model
/// over the real loopback `ArrIndexerFixtureServer` already used by the indexer
/// suites, rather than adding another fixture. Pure-validation paths never reach the
/// network; where a test claims "no request was made", a live server is pointed at
/// anyway so the claim is proven at a socket rather than assumed.
///
/// `TrawlTests` runs inside `Trawl.app` against the real Keychain. Every key touched
/// here belongs to an `ArrServiceProfile` with a freshly generated `UUID`
/// (`arr_<uuid>_apikey`), so none can collide with a real saved credential, and every
/// test deletes exactly the keys it created on both the success and failure paths.
@Suite("Arr setup view model: add path, validation and persistence", .serialized)
@MainActor
struct ArrSetupViewModelTests {

    // MARK: - Pre-flight validation: nothing is requested and nothing is persisted

    @Test("An empty host is rejected before any request or persistence")
    func emptyHostIsRejectedBeforeAnyRequest() async throws {
        let viewModel = ArrSetupViewModel(serviceManager: ArrServiceManager())
        viewModel.hostURL = ""
        viewModel.apiKey = "any-key"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == "Server URL is required.")
        #expect(viewModel.isValidating == false)
        #expect(try context.fetch(FetchDescriptor<ArrServiceProfile>()).isEmpty)
    }

    @Test("An empty API key is rejected before the server is contacted")
    func emptyAPIKeyIsRejectedBeforeAnyRequest() async throws {
        let server = try await ArrIndexerFixtureServer(label: "arr-setup-empty-key") { request in
            arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        let viewModel = ArrSetupViewModel(serviceManager: ArrServiceManager())
        viewModel.hostURL = server.baseURL
        viewModel.apiKey = ""

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == "API key is required.")
        // The host was a live, reachable server: an empty key must be caught by the
        // guard rather than sent and rejected by the service.
        #expect(server.requests.isEmpty)
        #expect(try context.fetch(FetchDescriptor<ArrServiceProfile>()).isEmpty)
    }

    @Test("A host carrying a trailing path is rejected with the specific message, before any request")
    func trailingPathIsRejectedBeforeAnyRequest() async throws {
        let server = try await ArrIndexerFixtureServer(label: "arr-setup-bad-url") { request in
            arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        let viewModel = ArrSetupViewModel(serviceManager: ArrServiceManager())
        viewModel.hostURL = "\(server.baseURL)/api"
        viewModel.apiKey = "any-key"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == "Enter the server address only, without any trailing path such as /api or /webui.")
        #expect(server.requests.isEmpty)
        #expect(try context.fetch(FetchDescriptor<ArrServiceProfile>()).isEmpty)
    }

    // MARK: - A rejected key must leave no trace

    @Test("A rejected API key surfaces the production error and persists no profile")
    func rejectedKeyPersistsNothing() async throws {
        let rejectedKey = "wrong-key"
        let server = try await ArrIndexerFixtureServer(label: "arr-setup-401") { request in
            if request.path == "/api/v3/system/status" {
                return .failure(status: 401, message: "Unauthorized")
            }
            return arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        let viewModel = ArrSetupViewModel(serviceManager: ArrServiceManager())
        viewModel.hostURL = server.baseURL
        viewModel.apiKey = rejectedKey
        viewModel.serviceType = .sonarr

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        // `ArrAPIClient`'s mapper declares `unauthorizedStatusCodes: [401]` with
        // `unauthorized: { ArrError.invalidAPIKey }`, whose description this is.
        #expect(viewModel.validationError == "Invalid API key. Check your *arr service settings.")
        #expect(viewModel.isValidating == false)
        #expect(viewModel.validatedStatus == nil)

        // The typed key reached the socket through the real production client rather
        // than being judged locally.
        let statusRequests = server.requests.filter { $0.path == "/api/v3/system/status" }
        #expect(statusRequests.isEmpty == false)
        #expect(statusRequests.allSatisfy { $0.apiKey == rejectedKey })

        // Nothing was written: the rejection happens before the Keychain save and
        // before the profile is inserted.
        #expect(try context.fetch(FetchDescriptor<ArrServiceProfile>()).isEmpty)
    }

    // MARK: - A successful add

    @Test("A successful add persists a new profile, its exact key, and the server's version")
    func successfulAddPersistsProfileAndKey() async throws {
        let acceptedKey = "correct-key"
        let server = try await ArrIndexerFixtureServer(label: "arr-setup-success") { request in
            if request.path == "/api/v3/system/status" {
                return .json(#"{"instanceName":"Basement Sonarr","version":"4.0.9.2244"}"#)
            }
            return arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        let viewModel = ArrSetupViewModel(serviceManager: ArrServiceManager())
        viewModel.hostURL = server.baseURL
        viewModel.apiKey = acceptedKey
        viewModel.serviceType = .sonarr

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<ArrServiceProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(saved == true)
            #expect(viewModel.validationError == nil)
            #expect(viewModel.isValidating == false)

            #expect(profiles.count == 1)
            let profile = try #require(profiles.first)
            #expect(profile.hostURL == server.baseURL)
            #expect(profile.resolvedServiceType == .sonarr)
            #expect(profile.isEnabled == true)
            #expect(profile.apiVersion == "4.0.9.2244")
            // An empty display name falls back to the server's own instance name.
            #expect(profile.displayName == "Basement Sonarr")

            let storedKey = try await KeychainHelper.shared.read(key: profile.apiKeyKeychainKey)
            #expect(storedKey == acceptedKey)

            let statusRequests = server.requests.filter { $0.path == "/api/v3/system/status" }
            #expect(statusRequests.allSatisfy { $0.apiKey == acceptedKey })
        }
    }

    @Test("An explicit display name is kept instead of the server's instance name")
    func explicitDisplayNameIsKept() async throws {
        let server = try await ArrIndexerFixtureServer(label: "arr-setup-display-name") { request in
            if request.path == "/api/v3/system/status" {
                return .json(#"{"instanceName":"Server Chosen Name","version":"4.0.0"}"#)
            }
            return arrIndexerDefaultResponse(for: request)
        }
        defer { server.stop() }

        let viewModel = ArrSetupViewModel(serviceManager: ArrServiceManager())
        viewModel.hostURL = server.baseURL
        viewModel.apiKey = "correct-key"
        viewModel.serviceType = .radarr
        viewModel.displayName = "User Chosen Name"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<ArrServiceProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(saved == true)
            let profile = try #require(profiles.first)
            #expect(profile.displayName == "User Chosen Name")
            #expect(profile.resolvedServiceType == .radarr)
        }
    }

    // MARK: - Prowlarr is a singleton

    @Test("Adding Prowlarr when one exists updates that profile instead of inserting a second")
    func addingProwlarrAdoptsTheExistingProfile() async throws {
        let server = try await ArrIndexerFixtureServer(label: "arr-setup-prowlarr") { request in
            // Prowlarr is on /api/v1, not /api/v3.
            if request.path == "/api/v1/system/status" {
                return .json(#"{"instanceName":"Prowlarr","version":"1.21.0"}"#)
            }
            return .json("[]")
        }
        defer { server.stop() }

        let context = try makeInMemoryContext()

        // Two existing Prowlarr profiles, both enabled. Production picks the first
        // enabled one as the adoption target when no active ID is set.
        let firstEnabled = ArrServiceProfile(
            displayName: "Existing Prowlarr",
            hostURL: "http://127.0.0.1:1",
            serviceType: .prowlarr,
            allowsUntrustedTLS: false
        )
        let secondEnabled = ArrServiceProfile(
            displayName: "Other Prowlarr",
            hostURL: "http://127.0.0.1:2",
            serviceType: .prowlarr,
            allowsUntrustedTLS: false
        )
        firstEnabled.isEnabled = true
        secondEnabled.isEnabled = true
        context.insert(firstEnabled)
        context.insert(secondEnabled)
        try context.save()

        let viewModel = ArrSetupViewModel(serviceManager: ArrServiceManager())
        viewModel.hostURL = server.baseURL
        viewModel.apiKey = "prowlarr-key"
        viewModel.serviceType = .prowlarr

        let saved = await viewModel.validateAndSave(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<ArrServiceProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(saved == true)

            // The defining assertion: no third profile. Trawl supports one Prowlarr,
            // and "adding" another silently repoints the existing one.
            #expect(profiles.count == 2)

            let adopted = try #require(profiles.first { $0.id == firstEnabled.id })
            #expect(adopted.hostURL == server.baseURL)
            #expect(adopted.isEnabled == true)

            // Every other Prowlarr profile is disabled, so exactly one stays active.
            let other = try #require(profiles.first { $0.id == secondEnabled.id })
            #expect(other.isEnabled == false)
            #expect(profiles.filter { $0.resolvedServiceType == .prowlarr && $0.isEnabled }.count == 1)
        }
    }

    // MARK: - Helpers

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([ArrServiceProfile.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// Runs `body`, then deletes the API-key entry for every profile in `profiles` on
    /// both the success and failure path — mirrors
    /// `SeerrSetupViewModelTests.cleaningUpKeychain`. `TrawlTests` uses the real
    /// Keychain, so a suite that throws mid-test must not leave entries behind.
    private func cleaningUpKeychain(for profiles: [ArrServiceProfile], body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            for profile in profiles { try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey) }
            throw error
        }
        for profile in profiles { try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey) }
    }
}
