import Foundation
import Network
import SwiftData
import Testing
@testable import Trawl

/// Regression coverage for M-02: `AddRadarrMovieIntent` / `AddSonarrSeriesIntent` must not
/// swallow a failed duplicate-check library read. Previously `try? await client.getMovies()`
/// (and the Sonarr equivalent) turned any failure into an empty array, so the intent believed
/// the library was empty and went on to add — even though it had no idea whether the item
/// already existed.
///
/// These tests drive the real `perform()` path — a real `AddRadarrMovieIntent` /
/// `AddSonarrSeriesIntent`, a real service profile persisted to the App Group SwiftData store
/// (the same store `ArrIntentSupport.loadServices` reads), a real Keychain-backed API key, and a
/// real loopback `NWListener` standing in for Radarr/Sonarr — following the pattern established
/// in `ArrClientLifecycleTests`.
@Suite("Arr Add Intent duplicate-check failure handling", .serialized)
@MainActor
struct ArrAddIntentDuplicateCheckTests {

    // MARK: - Required behavior: a failed read blocks the add

    @Test("Add Movie to Radarr reports the duplicate-check read failure and sends no add mutation")
    func radarrDuplicateCheckFailureBlocksAdd() async throws {
        let server = try await DuplicateCheckArrTestServer(
            label: "radarr-dup-fail",
            routes: [
                "GET /api/v3/movie/lookup": (200, #"[{"id":100,"title":"Dune","tmdbId":693134}]"#),
                "GET /api/v3/movie": (500, #"{"message":"boom"}"#),
                "GET /api/v3/qualityprofile": (200, #"[{"id":4,"name":"HD-1080p"}]"#),
                "GET /api/v3/rootfolder": (200, #"[{"id":1,"path":"/data/Movies","accessible":true}]"#)
            ]
        )
        defer { server.stop() }

        try await withStoredArrProfile(displayName: "Test Radarr", hostURL: server.baseURL, serviceType: .radarr) { profile in
            var intent = AddRadarrMovieIntent()
            intent.title = "Dune"
            intent.service = ArrServiceEntity(id: profile.id.uuidString, name: profile.displayName, serviceType: "radarr")

            do {
                _ = try await intent.perform()
                Issue.record("Expected the intent to throw when the duplicate-check read failed.")
            } catch let error as ArrIntentError {
                guard case .requestFailed(let detail) = error else {
                    Issue.record("Expected .requestFailed, got \(error)")
                    return
                }
                // Confirms the surfaced message actually reflects the library-read failure
                // (a 500 from the fake server), not some unrelated error.
                #expect(detail.contains("500"))
            }

            // The library read must have been attempted...
            #expect(server.requests.contains(.init(method: "GET", path: "/api/v3/movie")))
            // ...but the intent must never have gone on to add the movie.
            #expect(server.requests.contains { $0.method == "POST" && $0.path == "/api/v3/movie" } == false)
        }
    }

    @Test("Add Series to Sonarr reports the duplicate-check read failure and sends no add mutation")
    func sonarrDuplicateCheckFailureBlocksAdd() async throws {
        let server = try await DuplicateCheckArrTestServer(
            label: "sonarr-dup-fail",
            routes: [
                "GET /api/v3/series/lookup": (200, #"[{"id":200,"title":"Severance","tvdbId":371980,"titleSlug":"severance"}]"#),
                "GET /api/v3/series": (500, #"{"message":"boom"}"#),
                "GET /api/v3/qualityprofile": (200, #"[{"id":4,"name":"HD-1080p"}]"#),
                "GET /api/v3/rootfolder": (200, #"[{"id":1,"path":"/data/TV","accessible":true}]"#)
            ]
        )
        defer { server.stop() }

        try await withStoredArrProfile(displayName: "Test Sonarr", hostURL: server.baseURL, serviceType: .sonarr) { profile in
            var intent = AddSonarrSeriesIntent()
            intent.title = "Severance"
            intent.service = ArrServiceEntity(id: profile.id.uuidString, name: profile.displayName, serviceType: "sonarr")

            do {
                _ = try await intent.perform()
                Issue.record("Expected the intent to throw when the duplicate-check read failed.")
            } catch let error as ArrIntentError {
                guard case .requestFailed(let detail) = error else {
                    Issue.record("Expected .requestFailed, got \(error)")
                    return
                }
                #expect(detail.contains("500"))
            }

            #expect(server.requests.contains(.init(method: "GET", path: "/api/v3/series")))
            #expect(server.requests.contains { $0.method == "POST" && $0.path == "/api/v3/series" } == false)
        }
    }

    // MARK: - Counterpart: a genuinely empty library still proceeds

    @Test("Add Movie to Radarr still adds when the library read succeeds but is empty")
    func radarrEmptyLibraryStillAdds() async throws {
        let server = try await DuplicateCheckArrTestServer(
            label: "radarr-empty-ok",
            routes: [
                "GET /api/v3/movie/lookup": (200, #"[{"id":100,"title":"Dune","tmdbId":693134}]"#),
                "GET /api/v3/movie": (200, "[]"),
                "GET /api/v3/qualityprofile": (200, #"[{"id":4,"name":"HD-1080p"}]"#),
                "GET /api/v3/rootfolder": (200, #"[{"id":1,"path":"/data/Movies","accessible":true}]"#),
                "POST /api/v3/movie": (201, #"{"id":555,"title":"Dune","tmdbId":693134}"#)
            ]
        )
        defer { server.stop() }

        try await withStoredArrProfile(displayName: "Test Radarr", hostURL: server.baseURL, serviceType: .radarr) { profile in
            var intent = AddRadarrMovieIntent()
            intent.title = "Dune"
            intent.service = ArrServiceEntity(id: profile.id.uuidString, name: profile.displayName, serviceType: "radarr")

            _ = try await intent.perform()

            #expect(server.requests.contains { $0.method == "POST" && $0.path == "/api/v3/movie" })
        }
    }

    @Test("Add Series to Sonarr still adds when the library read succeeds but is empty")
    func sonarrEmptyLibraryStillAdds() async throws {
        let server = try await DuplicateCheckArrTestServer(
            label: "sonarr-empty-ok",
            routes: [
                "GET /api/v3/series/lookup": (200, #"[{"id":200,"title":"Severance","tvdbId":371980,"titleSlug":"severance"}]"#),
                "GET /api/v3/series": (200, "[]"),
                "GET /api/v3/qualityprofile": (200, #"[{"id":4,"name":"HD-1080p"}]"#),
                "GET /api/v3/rootfolder": (200, #"[{"id":1,"path":"/data/TV","accessible":true}]"#),
                "POST /api/v3/series": (201, #"{"id":555,"title":"Severance","tvdbId":371980,"titleSlug":"severance"}"#)
            ]
        )
        defer { server.stop() }

        try await withStoredArrProfile(displayName: "Test Sonarr", hostURL: server.baseURL, serviceType: .sonarr) { profile in
            var intent = AddSonarrSeriesIntent()
            intent.title = "Severance"
            intent.service = ArrServiceEntity(id: profile.id.uuidString, name: profile.displayName, serviceType: "sonarr")

            _ = try await intent.perform()

            #expect(server.requests.contains { $0.method == "POST" && $0.path == "/api/v3/series" })
        }
    }

    // MARK: - Helpers

    /// Persists a real `ArrServiceProfile` to the same App Group SwiftData store
    /// `ArrIntentSupport.loadServices` reads, saves a matching Keychain API key, runs
    /// `operation`, then removes both — regardless of whether `operation` throws.
    ///
    /// This mirrors `ArrClientLifecycleTests.withSavedAPIKey`, extended to also cover the
    /// SwiftData side that the intent layer (as opposed to `ArrServiceManager`) resolves
    /// services through.
    private func withStoredArrProfile(
        displayName: String,
        hostURL: String,
        serviceType: ArrServiceType,
        operation: (ArrServiceProfile) async throws -> Void
    ) async throws {
        let container = try ArrIntentSupport.makeModelContainer()
        let context = ModelContext(container)
        let profile = ArrServiceProfile(displayName: displayName, hostURL: hostURL, serviceType: serviceType)
        context.insert(profile)
        try context.save()
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "duplicate-check-test-key")

        do {
            try await operation(profile)
        } catch {
            context.delete(profile)
            try? context.save()
            try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            throw error
        }

        context.delete(profile)
        try context.save()
        try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
    }
}

// MARK: - Fake *arr server

private struct RecordedRequest: Sendable, Equatable {
    let method: String
    let path: String
}

/// A loopback HTTP stand-in for Radarr/Sonarr, configured per-test with an exact
/// `"METHOD path"` -> `(statusCode, body)` route table. Anything not explicitly routed
/// returns `200 []`, so unrelated calls made by the intent never crash the test.
private final class DuplicateCheckArrTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let routes: [String: (status: Int, body: String)]
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []

    init(label: String, routes: [String: (status: Int, body: String)]) async throws {
        self.queue = DispatchQueue(label: "DuplicateCheckArrTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.routes = routes
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
        guard let port = listener.port else { fatalError("Duplicate-check test server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func stop() { listener.cancel() }

    private func respond(to connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            let request = Self.request(from: data)
            self.lock.lock()
            self.recordedRequests.append(request)
            self.lock.unlock()

            let match = self.routes["\(request.method) \(request.path)"]
            connection.send(
                content: Self.httpResponse(statusCode: match?.status ?? 200, body: match?.body ?? "[]"),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func request(from data: Data) -> RecordedRequest {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return .init(method: "", path: "")
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        return .init(method: method, path: String(rawPath.split(separator: "?", maxSplits: 1).first ?? ""))
    }

    private static func httpResponse(statusCode: Int, body: String) -> Data {
        let statusText: String
        switch statusCode {
        case 200: statusText = "200 OK"
        case 201: statusText = "201 Created"
        case 500: statusText = "500 Internal Server Error"
        default: statusText = "\(statusCode) Error"
        }
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }
}
