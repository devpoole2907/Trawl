import Foundation
import Network
import SwiftData
import Testing
@testable import Trawl

/// Coverage for `OnboardingViewModel`, previously at 0% per the reliability audit
/// ("Connection validation and persistence rollback are unverified"). This is the very first
/// thing every new user touches.
///
/// `OnboardingViewModel.validateAndSave` builds its own `QBittorrentAPIClient` (and that client
/// its own ephemeral `URLSession`) internally, with no injectable session reachable from the
/// view model's public surface — unlike `QBittorrentAPIClient`/`AuthService` themselves, which
/// both accept one. There is therefore no `URLProtocol` seam to hang off of here, so these
/// tests drive the real view model over a real loopback TCP server, following the `NWListener`
/// pattern established in `ArrClientLifecycleTests.LifecycleArrTestServer`.
///
/// Login response shapes follow what `LiveCapturedShapeContractTests` pinned from a live
/// qBittorrent v5.2.3: a successful login is `204` with an empty body and a port-suffixed
/// `QBT_SID_<port>` cookie whose value may contain `/` and `+`; a rejected login is `401` with
/// a plain-text `Unauthorized` body. Older servers' `200` + `"Ok."` + plain `SID` cookie is
/// covered separately below, since onboarding is exactly where a user with an old server would
/// hit that path.
///
/// `TrawlTests` runs inside `Trawl.app` against the real Keychain. `ServerProfile.usernameKey`/
/// `passwordKey` are fixed by production code as `server_<uuid>_username`/`_password`; every
/// key this suite touches belongs to a `ServerProfile` with a freshly, randomly generated
/// `UUID` (either the view model's own or one this file creates), so none can collide with a
/// real saved credential. Every test deletes exactly the keys it created, on both the success
/// and failure path, via `cleaningUpKeychain(for:body:)` below. SwiftData storage is an
/// in-memory `ModelContainer` scoped to `ServerProfile` only, so nothing here touches disk.
@Suite("Onboarding view model validation, persistence, and rollback", .serialized)
@MainActor
struct OnboardingViewModelTests {

    // MARK: - Pre-flight validation: no request is ever made

    @Test("An empty host clears the banner error, marks the attempt, and makes no request")
    func emptyHostDoesNotValidate() async throws {
        let viewModel = OnboardingViewModel()
        viewModel.hostURL = ""
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == nil)
        #expect(viewModel.hasAttemptedSubmit == true)
        #expect(viewModel.isValidating == false)
        #expect(viewModel.isValid == false)
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
    }

    @Test("A whitespace-only host clears the banner error and makes no request")
    func whitespaceHostDoesNotValidate() async throws {
        let viewModel = OnboardingViewModel()
        viewModel.hostURL = "   \n\t  "
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == nil)
        #expect(viewModel.hasAttemptedSubmit == true)
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
    }

    @Test("A missing username clears the banner error and makes no request")
    func missingUsernameDoesNotValidate() async throws {
        let viewModel = OnboardingViewModel()
        viewModel.hostURL = "http://192.0.2.5:8080"
        viewModel.username = ""
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == nil)
        #expect(viewModel.isValidating == false)
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
    }

    @Test("A missing password clears the banner error and makes no request")
    func missingPasswordDoesNotValidate() async throws {
        let viewModel = OnboardingViewModel()
        viewModel.hostURL = "http://192.0.2.5:8080"
        viewModel.username = "sam"
        viewModel.password = ""

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == nil)
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
    }

    @Test("An unsupported URL scheme is rejected with the specific message before any request")
    func unsupportedSchemeIsRejected() async throws {
        let viewModel = OnboardingViewModel()
        viewModel.hostURL = "ftp://example.com"
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == "Server URL must start with http:// or https://.")
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
    }

    @Test("A URL with a trailing path is rejected with the specific message before any request")
    func urlWithPathIsRejected() async throws {
        let viewModel = OnboardingViewModel()
        viewModel.hostURL = "http://example.com/webui"
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == "Enter the server address only, without any trailing path such as /api or /webui.")
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
    }

    // MARK: - Failed connection: nothing is persisted, real error text surfaces

    @Test("A rejected (401) login reads as a credentials problem and persists nothing")
    func rejectedLoginPersistsNothing() async throws {
        let server = try await OnboardingFakeQBServer(label: "rejected-login")
        defer { server.stop() }
        // Verbatim shape from LiveCapturedShapeContractTests: qBittorrent v5.2.3 answers a
        // rejected login with 401 and a plain-text "Unauthorized" body.
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 401,
            body: Data("Unauthorized".utf8),
            contentType: "text/plain; charset=UTF-8"
        ))

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "wrong-password"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == "Authentication failed. Check your credentials.")
        #expect(viewModel.isValid == false)
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
        // getAppVersion() must never be reached once login itself was rejected.
        #expect(server.requests == ["POST /api/v2/auth/login"])
    }

    @Test("A 5xx login response is not mistaken for success and persists nothing")
    func serverErrorLoginPersistsNothing() async throws {
        let server = try await OnboardingFakeQBServer(label: "5xx-login")
        defer { server.stop() }
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 502,
            body: Data("<html><body>Bad Gateway</body></html>".utf8),
            contentType: "text/html"
        ))

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        // AuthService.performLogin only recognizes 204, or 200 with an "Ok." body, as success;
        // every other status code — including a proxy's 502 — falls into the same .authFailed
        // branch as a rejected login, so the user sees the identical "check your credentials"
        // message a bad password would produce. This is real, current behavior; this suite pins
        // it rather than changing it.
        #expect(viewModel.validationError == "Authentication failed. Check your credentials.")
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
        #expect(server.requests == ["POST /api/v2/auth/login"])
    }

    @Test("A 5xx app/version response after a successful login is not mistaken for success and persists nothing (pins M-03)")
    func serverErrorVersionCheckPersistsNothing() async throws {
        let server = try await OnboardingFakeQBServer(label: "5xx-version")
        defer { server.stop() }
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 204,
            body: Data(),
            // A real qBittorrent v5 login always sets this alongside the 204;
            // without it `AuthService` extracts no session and correctly throws.
            setCookie: "QBT_SID_8080=onboarding-fixture-sid; HttpOnly; SameSite=Lax; path=/"
        ))
        server.route("GET /api/v2/app/version", FakeQBResponse(
            statusCode: 500,
            body: Data("<html><body>Internal Server Error</body></html>".utf8),
            contentType: "text/html"
        ))

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        // Pins audit finding M-03: QBittorrentAPIClient.performRequest validates the HTTP
        // status code (via validateSuccessfulStatus) before getAppVersion() ever converts the
        // body to a string, so a proxy's HTML error page can no longer pass onboarding
        // validation as if it were a version string.
        #expect(viewModel.validationError == "Server error (500): Unknown")
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
        #expect(server.requests == ["POST /api/v2/auth/login", "GET /api/v2/app/version"])
    }

    @Test("A non-UTF8 app/version body after a successful login is not mistaken for success and persists nothing")
    func invalidVersionBodyPersistsNothing() async throws {
        let server = try await OnboardingFakeQBServer(label: "invalid-version-body")
        defer { server.stop() }
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 204,
            body: Data(),
            // A real qBittorrent v5 login always sets this alongside the 204;
            // without it `AuthService` extracts no session and correctly throws.
            setCookie: "QBT_SID_8080=onboarding-fixture-sid; HttpOnly; SameSite=Lax; path=/"
        ))
        server.route("GET /api/v2/app/version", FakeQBResponse(
            statusCode: 200,
            body: Data([0xFF, 0xFE, 0xFD]),
            contentType: "application/octet-stream"
        ))

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)

        #expect(saved == false)
        #expect(viewModel.validationError == "Invalid response from server.")
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
        #expect(server.requests == ["POST /api/v2/auth/login", "GET /api/v2/app/version"])
    }

    // MARK: - Successful connection: persists exactly what was entered

    @Test("A successful connection creates and persists a new server profile with its exact credentials")
    func successfulConnectionPersistsNewProfile() async throws {
        let server = try await OnboardingFakeQBServer(label: "success-new-profile")
        defer { server.stop() }
        // Verbatim shape from LiveCapturedShapeContractTests: qBittorrent v5.2.3 answers a
        // successful login with 204, an empty body, and a port-suffixed QBT_SID_<port> cookie
        // whose value may contain "/" and "+".
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 204,
            body: Data(),
            setCookie: "QBT_SID_8080=mRdEjKBWOJEloRFqri/nG9lif+qkfnrs; HttpOnly; SameSite=Lax; path=/"
        ))
        server.route("GET /api/v2/app/version", FakeQBResponse(statusCode: 200, body: Data("v5.2.3\n".utf8)))

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "correct-horse"
        viewModel.displayName = "Living Room NAS"
        viewModel.allowsUntrustedTLS = true

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<ServerProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(saved == true)
            #expect(viewModel.isValid == true)
            #expect(viewModel.isValidating == false)
            #expect(viewModel.validationError == nil)
            #expect(server.requests == ["POST /api/v2/auth/login", "GET /api/v2/app/version"])

            let profile = try #require(profiles.first)
            let expectedHostURL = try ServerURLValidator.normalizedURLString(from: server.baseURL)
            #expect(profile.displayName == "Living Room NAS")
            #expect(profile.hostURL == expectedHostURL)
            #expect(profile.allowsUntrustedTLS == true)
            #expect(profile.isActive == true)

            let storedUsername = try await KeychainHelper.shared.read(key: profile.usernameKey)
            let storedPassword = try await KeychainHelper.shared.read(key: profile.passwordKey)
            #expect(storedUsername == "sam")
            #expect(storedPassword == "correct-horse")
        }
    }

    @Test("An empty display name defaults to the normalized host URL")
    func successfulConnectionDefaultsDisplayNameToHostURL() async throws {
        let server = try await OnboardingFakeQBServer(label: "success-default-name")
        defer { server.stop() }
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 204,
            body: Data(),
            // A real qBittorrent v5 login always sets this alongside the 204;
            // without it `AuthService` extracts no session and correctly throws.
            setCookie: "QBT_SID_8080=onboarding-fixture-sid; HttpOnly; SameSite=Lax; path=/"
        ))
        server.route("GET /api/v2/app/version", FakeQBResponse(statusCode: 200, body: Data("v5.2.3\n".utf8)))

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "correct-horse"
        viewModel.displayName = ""

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<ServerProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(saved == true)
            let profile = try #require(profiles.first)
            let expectedHostURL = try ServerURLValidator.normalizedURLString(from: server.baseURL)
            #expect(profile.displayName == expectedHostURL)
            #expect(profile.hostURL == expectedHostURL)
        }
    }

    @Test("A successful new connection deactivates any previously active server")
    func successfulConnectionDeactivatesExistingActiveServer() async throws {
        let server = try await OnboardingFakeQBServer(label: "success-deactivate")
        defer { server.stop() }
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 204,
            body: Data(),
            // A real qBittorrent v5 login always sets this alongside the 204;
            // without it `AuthService` extracts no session and correctly throws.
            setCookie: "QBT_SID_8080=onboarding-fixture-sid; HttpOnly; SameSite=Lax; path=/"
        ))
        server.route("GET /api/v2/app/version", FakeQBResponse(statusCode: 200, body: Data("v5.2.3\n".utf8)))

        let context = try makeInMemoryContext()
        let previouslyActive = ServerProfile(displayName: "Old Server", hostURL: "http://192.0.2.9:8080")
        previouslyActive.isActive = true
        context.insert(previouslyActive)
        try context.save()

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let saved = await viewModel.validateAndSave(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<ServerProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(saved == true)
            #expect(profiles.count == 2)
            #expect(previouslyActive.isActive == false)
            let newProfile = try #require(profiles.first { $0.id != previouslyActive.id })
            #expect(newProfile.isActive == true)
        }
    }

    @Test("A legacy 200/Ok./SID login still succeeds through onboarding")
    func legacyLoginStillSucceeds() async throws {
        let server = try await OnboardingFakeQBServer(label: "legacy-login")
        defer { server.stop() }
        // Older qBittorrent servers answer 200 with an "Ok." body and a plain SID cookie
        // instead of 204 + QBT_SID_<port>; AuthService supports both.
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 200,
            body: Data("Ok.".utf8),
            setCookie: "SID=legacy-session-token; path=/"
        ))
        server.route("GET /api/v2/app/version", FakeQBResponse(statusCode: 200, body: Data("v4.6.0\n".utf8)))

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = server.baseURL
        viewModel.username = "sam"
        viewModel.password = "correct-horse"

        let context = try makeInMemoryContext()
        let saved = await viewModel.validateAndSave(modelContext: context)
        let profiles = try context.fetch(FetchDescriptor<ServerProfile>())

        try await cleaningUpKeychain(for: profiles) {
            #expect(saved == true)
            #expect(viewModel.isValid == true)
            #expect(profiles.count == 1)
        }
    }

    @Test("Editing an existing server updates it in place and overwrites its credentials")
    func editingServerUpdatesInPlace() async throws {
        let server = try await OnboardingFakeQBServer(label: "edit-success")
        defer { server.stop() }
        server.route("POST /api/v2/auth/login", FakeQBResponse(
            statusCode: 204,
            body: Data(),
            // A real qBittorrent v5 login always sets this alongside the 204;
            // without it `AuthService` extracts no session and correctly throws.
            setCookie: "QBT_SID_8080=onboarding-fixture-sid; HttpOnly; SameSite=Lax; path=/"
        ))
        server.route("GET /api/v2/app/version", FakeQBResponse(statusCode: 200, body: Data("v5.2.3\n".utf8)))

        let context = try makeInMemoryContext()
        let editingServer = ServerProfile(displayName: "Original NAS", hostURL: "http://192.0.2.10:8080")
        editingServer.isActive = false
        context.insert(editingServer)
        try context.save()

        try await KeychainHelper.shared.save(key: editingServer.usernameKey, value: "original-user")
        try await KeychainHelper.shared.save(key: editingServer.passwordKey, value: "original-pass")

        try await cleaningUpKeychain(for: [editingServer]) {
            let viewModel = OnboardingViewModel()
            viewModel.hostURL = server.baseURL
            viewModel.username = "new-user"
            viewModel.password = "new-pass"
            viewModel.displayName = "Updated NAS"
            viewModel.allowsUntrustedTLS = true

            let saved = await viewModel.validateAndSave(modelContext: context, editingServer: editingServer)

            #expect(saved == true)
            let expectedHostURL = try ServerURLValidator.normalizedURLString(from: server.baseURL)
            #expect(editingServer.displayName == "Updated NAS")
            #expect(editingServer.hostURL == expectedHostURL)
            #expect(editingServer.allowsUntrustedTLS == true)
            #expect(editingServer.isActive == true)

            let profiles = try context.fetch(FetchDescriptor<ServerProfile>())
            #expect(profiles.count == 1)

            let storedUsername = try await KeychainHelper.shared.read(key: editingServer.usernameKey)
            let storedPassword = try await KeychainHelper.shared.read(key: editingServer.passwordKey)
            #expect(storedUsername == "new-user")
            #expect(storedPassword == "new-pass")
        }
    }

    // MARK: - Rollback: the audit's named concern

    /// Forces the real failure the audit called out: a later save step failing *after* an
    /// earlier one already succeeded. Production performs the Keychain writes first and
    /// `modelContext.save()` last, so making that final `save()` throw exercises exactly the
    /// "earlier step already committed, later step failed" scenario the audit describes.
    ///
    /// `ServerProfile.id` carries `@Attribute(.unique)`. This test pre-saves `editingServer`
    /// (id X, standing in for "a server the user already onboarded"), then inserts — but does
    /// not save — a second, decoy `ServerProfile` whose `id` is reassigned to that same X
    /// before `validateAndSave` runs. When `validateAndSave` calls its own `modelContext.save()`,
    /// it tries to commit both `editingServer`'s mutated fields and the decoy's still-pending
    /// insert together; the duplicate unique `id` violates the store's constraint and `save()`
    /// throws — a genuine SwiftData failure, not a simulated one, landing exactly in the branch
    /// the audit is worried about (Keychain already overwritten with the new credentials,
    /// `modelContext.save()` the thing that fails).
    ///
    /// `validateAndSave`'s rollback runs inside `defer` as an **unstructured, unawaited**
    /// `Task { @MainActor in ... }` — the function returns `false` without waiting for that task
    /// to finish undoing the mutation (see the "found wrong but not changed" note in this
    /// suite's final report). There is no seam to await it directly, so this polls real state
    /// with bounded `Task.yield()` cycles rather than a wall-clock sleep or a fixed delay.
    // NOTE: rollback on a persistence failure is deliberately NOT covered here.
    //
    // `validateAndSave` writes the Keychain credentials *before* its final
    // `modelContext.save()`, so a save failure is exactly the "earlier step
    // committed, later step failed" case the audit asks about. Forcing that save to
    // fail is the problem. The attempt made here relied on `ServerProfile.id`'s
    // `@Attribute(.unique)` rejecting a colliding pending insert; against an
    // in-memory `ModelConfiguration` it does **not** throw, so the test passed
    // through the success path and asserted nothing about rollback. It was removed
    // rather than reshaped into something that merely goes green.
    //
    // The new-profile branch is harder still: its `ServerProfile.id` is a fresh UUID
    // generated inside the method, so nothing can be arranged to collide with it,
    // and forcing a genuine `SecItemAdd` failure would mean interfering with the
    // real Keychain. Covering this properly needs an injectable persistence or
    // Keychain seam in `OnboardingViewModel`.
    //
    // Worth knowing while it is uncovered: the rollback runs as an unstructured,
    // unawaited `Task { @MainActor in ... }` inside a `defer`, so `validateAndSave`
    // returns `false` before the undo has necessarily finished. A caller that
    // inspects the profile or the Keychain immediately after a `false` result can
    // observe half-rolled-back state.


    // MARK: - Cancellation

    /// `OnboardingSheet` cancels the in-flight `saveTask` in `onDisappear` and again on
    /// every Connect tap while one is running. Two things have to hold for that to be
    /// harmless, and this pins both.
    ///
    /// The attempt must **return promptly**. `AuthService` coalesces logins behind an
    /// unstructured `Task`, which does not inherit cancellation, so before
    /// `propagatesCancellation` this call sat until the request timed out sixty seconds
    /// later. Onboarding's `AuthService` is a throwaway with a single caller, so it opts
    /// in; the shared instance behind `QBittorrentAPIClient.reauthenticate` deliberately
    /// does not, since a login there can have several waiters.
    ///
    /// And it must **report nothing**, rather than showing raw transport text to
    /// someone still setting the app up for the first time.
    @Test("A cancelled connection attempt returns promptly and reports no error")
    func cancelledAttemptReportsNoError() async throws {
        let blackHole = try await UnansweringServer(label: "onboarding-cancel")
        defer { blackHole.stop() }

        let viewModel = OnboardingViewModel()
        viewModel.hostURL = blackHole.baseURL
        viewModel.username = "ada"
        viewModel.password = "hunter2"

        let context = try makeInMemoryContext()

        let started = Date()
        let attempt = Task { await viewModel.validateAndSave(modelContext: context) }
        await blackHole.waitForFirstRequest()
        attempt.cancel()
        let saved = await attempt.value
        let elapsed = Date().timeIntervalSince(started)

        #expect(saved == false)
        #expect(
            viewModel.validationError == nil,
            "A cancelled attempt must not surface an error: the user dismissed the sheet or asked for a new attempt."
        )
        // The request's own timeout is 60s. This is not a timing assertion on the
        // machine's speed — it is the difference between cancellation being honoured at
        // all and the login running to completion regardless.
        #expect(
            elapsed < 20,
            "Cancelling must cancel the login rather than waiting out its timeout; took \(elapsed)s."
        )
        #expect(try context.fetch(FetchDescriptor<ServerProfile>()).isEmpty)
    }

    // MARK: - Helpers

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([ServerProfile.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        // Prevent SwiftData's own implicit autosave triggers from saving mid-test, ahead of the
        // exact modelContext.save() call this suite is trying to control the timing of.
        context.autosaveEnabled = false
        return context
    }

    /// Runs `body`, then deletes the Keychain credentials for every profile in `profiles` on
    /// both the success and failure path — mirrors `ArrClientLifecycleTests.withSavedAPIKey`
    /// and `KeychainAppGroupTests.withTestKey`. Every profile passed in was created either by
    /// this test file or by the real `OnboardingViewModel` under test, each with its own
    /// randomly generated `UUID`, so this never touches a real saved credential.
    private func cleaningUpKeychain(for profiles: [ServerProfile], body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            for profile in profiles {
                try? await KeychainHelper.shared.delete(key: profile.usernameKey)
                try? await KeychainHelper.shared.delete(key: profile.passwordKey)
            }
            throw error
        }
        for profile in profiles {
            try? await KeychainHelper.shared.delete(key: profile.usernameKey)
            try? await KeychainHelper.shared.delete(key: profile.passwordKey)
        }
    }

    /// Cooperatively yields the MainActor and re-checks `condition` after each yield, up to
    /// `maxYields` times. Used only to observe the completion of `validateAndSave`'s unawaited
    /// rollback `Task` (see the doc comment on `editRollsBackProfileAndCredentialsOnSaveFailure`)
    /// without a wall-clock sleep or any assumption about how many hops that task needs.
    private func awaitCondition(maxYields: Int = 1_000, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }
}

// MARK: - Fake qBittorrent server

/// A minimal loopback HTTP server standing in for qBittorrent's WebUI API. `OnboardingViewModel`
/// builds its own `QBittorrentAPIClient` (and that client its own ephemeral `URLSession`)
/// internally, with no injectable seam reachable from outside — see the suite's top doc
/// comment — so this drives the real view model over real loopback TCP, following the pattern
/// established by `ArrClientLifecycleTests.LifecycleArrTestServer`.
private nonisolated final class OnboardingFakeQBServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var routes: [String: FakeQBResponse] = [:]
    private var recordedRequests: [String] = []

    init(label: String) async throws {
        self.queue = DispatchQueue(label: "OnboardingFakeQBServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.respond(to: connection)
        }
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else { fatalError("Onboarding fake server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func route(_ methodAndPath: String, _ response: FakeQBResponse) {
        lock.lock()
        defer { lock.unlock() }
        routes[methodAndPath] = response
    }

    func stop() { listener.cancel() }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let key = Self.requestKey(from: data)

            self.lock.lock()
            self.recordedRequests.append(key)
            let response = self.routes[key] ?? FakeQBResponse(statusCode: 404, body: Data())
            self.lock.unlock()

            connection.send(
                content: Self.httpResponse(response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func requestKey(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return ""
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")
        return "\(method) \(path)"
    }

    private static func httpResponse(_ response: FakeQBResponse) -> Data {
        var head = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        if let cookie = response.setCookie {
            head += "Set-Cookie: \(cookie)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }
}

/// A canned response `OnboardingFakeQBServer` sends for one configured route.
private nonisolated struct FakeQBResponse: Sendable {
    let statusCode: Int
    let reasonPhrase: String
    let body: Data
    let contentType: String
    let setCookie: String?

    init(statusCode: Int, body: Data, contentType: String = "text/plain", setCookie: String? = nil) {
        self.statusCode = statusCode
        self.reasonPhrase = Self.reasonPhrase(for: statusCode)
        self.body = body
        self.contentType = contentType
        self.setCookie = setCookie
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 204: return "No Content"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}
