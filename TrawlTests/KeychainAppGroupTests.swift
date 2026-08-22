import Foundation
import Security
import SwiftData
import Testing
@testable import Trawl

/// Exercises the two persistence boundaries the reliability audit flagged as untested:
/// `KeychainHelper` (0% line coverage) and the App Group SwiftData store shared by
/// `TrawlApp`, `TrawlWidgets`, and `TrawlShare` (via `ArrIntentSupport.makeModelContainer()`).
///
/// `TrawlTests` is hosted inside `Trawl.app`, so these run with the app's real entitlements
/// against the real Keychain and the real App Group container — genuine integration tests,
/// not simulations. Every key/record this suite writes is namespaced with a test-only prefix
/// that cannot collide with production key/data shapes (see `keyPrefix` and
/// `uniqueMarkerPath()` below), and every test deletes exactly what it created, on both the
/// success and failure paths.
@Suite("Keychain and App Group persistence", .serialized)
@MainActor
struct KeychainAppGroupTests {

    // MARK: - Keychain: save / read round trip

    @Test(
        "Save then read returns the exact value, including non-ASCII and long values",
        arguments: [
            "trawl-tests-plain-value",
            "héllo wörld 🐟🍣 — accénted & emoji",
            "日本語のテスト文字列。空白　全角も含む。",
            "e\u{0301}toile-with-combining-accent",
            String(repeating: "Trawl-long-value-🐠-", count: 1_000)
        ]
    )
    func saveThenReadRoundTrips(_ value: String) async throws {
        try await withTestKey { key in
            try await KeychainHelper.shared.save(key: key, value: value)
            let read = try await KeychainHelper.shared.read(key: key)
            #expect(read == value)
        }
    }

    @Test("Overwriting an existing key replaces the stored value rather than duplicating or failing")
    func overwriteReplacesRatherThanDuplicating() async throws {
        try await withTestKey { key in
            try await KeychainHelper.shared.save(key: key, value: "first-value")
            try await KeychainHelper.shared.save(key: key, value: "second-value")

            let read = try await KeychainHelper.shared.read(key: key)
            #expect(read == "second-value")

            // KeychainHelper's own `read` uses kSecMatchLimitOne, so it cannot itself prove
            // there isn't a second, shadowed item left behind by the overwrite. Query the raw
            // Keychain (matching KeychainHelper's own service name and no access group, exactly
            // as KeychainHelper does in this build — see the audit's AppIdentifierPrefix note)
            // with kSecMatchLimitAll to prove there is genuinely one item, not two.
            let matchCount = try Self.rawKeychainItemCount(account: key)
            #expect(matchCount == 1)
        }
    }

    @Test("Deleting a key removes it, and a subsequent read returns nil rather than throwing")
    func deleteThenReadReturnsNil() async throws {
        try await withTestKey { key in
            try await KeychainHelper.shared.save(key: key, value: "to-be-deleted")

            try await KeychainHelper.shared.delete(key: key)
            let read = try await KeychainHelper.shared.read(key: key)

            #expect(read == nil)
        }
    }

    @Test("Reading a key that was never written returns nil")
    func readingUnwrittenKeyReturnsNil() async throws {
        let key = Self.uniqueTestKey()
        let read = try await KeychainHelper.shared.read(key: key)
        #expect(read == nil)
    }

    @Test("Deleting a key that does not exist does not throw")
    func deletingMissingKeyDoesNotThrow() async throws {
        let key = Self.uniqueTestKey()
        try await KeychainHelper.shared.delete(key: key)
        // Reaching this line without the test function throwing is the assertion: delete()
        // treats errSecItemNotFound as success rather than surfacing KeychainError.deleteFailed.
    }

    @Test("Saving an empty string succeeds and reads back as an empty string")
    func emptyStringRoundTrips() async throws {
        // `"".data(using: .utf8)` is a valid zero-length Data (never nil), so
        // KeychainHelper.save never hits `.encodingFailed` for an empty value, and
        // SecItemAdd accepts zero-length kSecValueData. Pinning the actual observed
        // behavior here rather than assuming it, per the audit's instruction.
        try await withTestKey { key in
            try await KeychainHelper.shared.save(key: key, value: "")
            let read = try await KeychainHelper.shared.read(key: key)
            #expect(read == "")
        }
    }

    // MARK: - App Group: reachability

    @Test("AppGroup.identifier resolves and the shared container is reachable and writable")
    func appGroupContainerIsReachableAndWritable() throws {
        #expect(AppGroup.identifier == "group.com.poole.james.Trawl")

        let containerURL = try #require(AppGroup.sharedContainerURL)
        #expect(FileManager.default.fileExists(atPath: containerURL.path))

        let markerURL = containerURL.appendingPathComponent(
            "trawlTestsOnly-appgroup-probe-\(UUID().uuidString).txt"
        )
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let payload = Data("trawl-tests-app-group-probe".utf8)
        try payload.write(to: markerURL, options: .atomic)
        let readBack = try Data(contentsOf: markerURL)
        #expect(readBack == payload)
    }

    // MARK: - App Group: SwiftData ModelContainer

    @Test("A ModelContainer built on the App Group configuration with the full schema opens successfully")
    func modelContainerOpensOnAppGroupConfiguration() throws {
        // ArrIntentSupport.makeModelContainer() is the exact production helper widgets and
        // App Intents use to open the shared store, and its doc comment states it mirrors
        // TrawlApp's own ModelConfiguration(schema:groupContainer:.identifier(AppGroup.identifier)).
        // Using it directly (rather than re-deriving the configuration in the test) exercises
        // real production code, not a re-implementation of it.
        let container = try ArrIntentSupport.makeModelContainer()
        _ = ModelContext(container)
    }

    @Test("Data written through one App Group container is visible through a freshly constructed container")
    func dataWrittenIsVisibleThroughFreshContainer() throws {
        let marker = Self.uniqueMarkerPath()
        let predicate = #Predicate<RecentSavePath> { $0.path == marker }

        let writingContainer = try ArrIntentSupport.makeModelContainer()
        let writingContext = ModelContext(writingContainer)
        writingContext.insert(RecentSavePath(path: marker))
        try writingContext.save()

        // Always remove exactly the marker record this test created, even if an assertion
        // below fails — never touches any other RecentSavePath row.
        defer {
            if let cleanupContainer = try? ArrIntentSupport.makeModelContainer() {
                let cleanupContext = ModelContext(cleanupContainer)
                if let leftovers = try? cleanupContext.fetch(FetchDescriptor<RecentSavePath>(predicate: predicate)) {
                    for leftover in leftovers {
                        cleanupContext.delete(leftover)
                    }
                    try? cleanupContext.save()
                }
            }
        }

        // A second, independently constructed container on the same configuration proves the
        // record is really on disk in the shared App Group store, not just live in the first
        // container's in-memory object graph.
        let readingContainer = try ArrIntentSupport.makeModelContainer()
        let readingContext = ModelContext(readingContainer)
        let matches = try readingContext.fetch(FetchDescriptor<RecentSavePath>(predicate: predicate))

        #expect(matches.count == 1)
        #expect(matches.first?.path == marker)
    }

    // NOTE: an intentionally-unentitled App Group identifier was tried here, to pin the
    // premise behind `TrawlApp.init`'s App Group -> local -> in-memory fallback ladder.
    // It does not hold: `ModelContainer(for:configurations:)` **crashes the process**
    // rather than throwing when the build is not entitled to the group. The `catch`
    // around the App Group container in `TrawlApp.init` therefore cannot rescue an
    // entitlement mismatch — only a store that fails for a catchable reason. The test was
    // removed rather than weakened, because a crashing test takes its whole process with
    // it. The identifier is hardcoded and correct today, so this is a latent sharp edge,
    // not a live defect.

    // MARK: - Helpers

    /// Prefix for every Keychain key this suite creates. Production keys look like
    /// `arr_<uuid>_apikey`, `sabnzbd_<uuid>_apikey`, `cleanuparr_<uuid>_apikey`,
    /// `server_<uuid>_username`/`_password`, and Seerr/Jellyfin's own `<service>_...`
    /// namespaces (see `KeychainHelper.accessibility(for:)`'s prefix checks). This prefix is
    /// deliberately outside all of those and unique per test run via a UUID suffix, so it can
    /// never collide with a real saved credential.
    private static let keyPrefix = "trawlTestsOnly_kc_"

    private static func uniqueTestKey() -> String {
        "\(keyPrefix)\(UUID().uuidString)"
    }

    private static func uniqueMarkerPath() -> String {
        "trawlTestsOnly-appgroup-marker-\(UUID().uuidString)"
    }

    /// Mirrors `KeychainHelper`'s own private `service` constant so the raw duplicate-count
    /// query in `overwriteReplacesRatherThanDuplicating()` matches exactly what KeychainHelper
    /// itself stores under. This is a fixed, non-secret service label, not a credential.
    private static let keychainService = "com.poole.james.Trawl"

    private enum RawQueryError: Error {
        case unexpectedStatus(OSStatus)
    }

    private static func rawKeychainItemCount(account: String) throws -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return 0
        }
        guard status == errSecSuccess else {
            throw RawQueryError.unexpectedStatus(status)
        }

        if let matches = result as? [[String: Any]] {
            return matches.count
        }
        // A single-item result surfaces as one dictionary rather than an array of one.
        return result != nil ? 1 : 0
    }

    /// Follows the `withSavedAPIKey` pattern in `TrawlTests/ArrClientLifecycleTests.swift`:
    /// create a uniquely namespaced key, run the operation, then delete that exact key on
    /// both the success and failure paths. Never deletes anything the operation didn't create.
    private func withTestKey(operation: (String) async throws -> Void) async throws {
        let key = Self.uniqueTestKey()
        do {
            try await operation(key)
            try? await KeychainHelper.shared.delete(key: key)
        } catch {
            try? await KeychainHelper.shared.delete(key: key)
            throw error
        }
    }
}
