import Foundation
import Network
import Testing
@testable import Trawl

/// These tests use real `ArrAPIClient` URL loading against two independent
/// loopback servers. They deliberately retain the view model through an edit:
/// that is the lifecycle that previously retained server A's actor.
@Suite("Arr client lifecycle", .serialized)
@MainActor
struct ArrClientLifecycleTests {
    @Test("A retained Sonarr view model refreshes and mutates only the reconnected server")
    func sonarrViewModelUsesReplacementClient() async throws {
        let serverA = try await LifecycleArrTestServer(label: "sonarr-a", libraryPath: "/api/v3/series", libraryBody: #"[{"id":1,"title":"From A"}]"#)
        let serverB = try await LifecycleArrTestServer(label: "sonarr-b", libraryPath: "/api/v3/series", libraryBody: #"[{"id":2,"title":"From B"}]"#)
        defer { serverA.stop(); serverB.stop() }

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: serverA.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let viewModel = SonarrViewModel(serviceManager: manager)
            await viewModel.loadSeries()
            #expect(viewModel.series.map(\.title) == ["From A"])
            let requestsBeforeEdit = serverA.requests

            profile.hostURL = serverB.baseURL
            await manager.connectService(profile)

            // The same view model is intentionally retained. Both its library
            // refresh and its command must resolve through manager's new client.
            await viewModel.loadSeries()
            let queuedSearch = await viewModel.searchSeries(seriesId: 2)

            #expect(queuedSearch)
            #expect(viewModel.series.map(\.title) == ["From B"])
            #expect(serverA.requests == requestsBeforeEdit)
            #expect(serverB.requests.contains(.init(method: "GET", path: "/api/v3/series")))
            #expect(serverB.requests.contains(.init(method: "POST", path: "/api/v3/command")))
        }
    }

    @Test("A retained Radarr view model refreshes and mutates only the reconnected server")
    func radarrViewModelUsesReplacementClient() async throws {
        let serverA = try await LifecycleArrTestServer(label: "radarr-a", libraryPath: "/api/v3/movie", libraryBody: #"[{"id":1,"title":"From A"}]"#)
        let serverB = try await LifecycleArrTestServer(label: "radarr-b", libraryPath: "/api/v3/movie", libraryBody: #"[{"id":2,"title":"From B"}]"#)
        defer { serverA.stop(); serverB.stop() }

        let profile = ArrServiceProfile(displayName: "Radarr", hostURL: serverA.baseURL, serviceType: .radarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let viewModel = RadarrViewModel(serviceManager: manager)
            await viewModel.loadMovies()
            #expect(viewModel.movies.map(\.title) == ["From A"])
            let requestsBeforeEdit = serverA.requests

            profile.hostURL = serverB.baseURL
            await manager.connectService(profile)

            await viewModel.loadMovies()
            let queuedSearch = await viewModel.searchMovie(movieId: 2)

            #expect(queuedSearch)
            #expect(viewModel.movies.map(\.title) == ["From B"])
            #expect(serverA.requests == requestsBeforeEdit)
            #expect(serverB.requests.contains(.init(method: "GET", path: "/api/v3/movie")))
            #expect(serverB.requests.contains(.init(method: "POST", path: "/api/v3/command")))
        }
    }

    @Test("A failed same-ID reconnect removes the stale Sonarr client from manager and retained view model")
    func failedReconnectDoesNotExposeOldSonarrClient() async throws {
        let serverA = try await LifecycleArrTestServer(label: "failed-a", libraryPath: "/api/v3/series", libraryBody: #"[{"id":1,"title":"From A"}]"#)
        let failingServerB = try await LifecycleArrTestServer(label: "failed-b", libraryPath: "/api/v3/series", libraryBody: "[]", statusCode: 401)
        defer { serverA.stop(); failingServerB.stop() }

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: serverA.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()
        try await withSavedAPIKey(for: profile) {
            await manager.connectService(profile)
            let viewModel = SonarrViewModel(serviceManager: manager)
            await viewModel.loadSeries()
            let requestsBeforeFailure = serverA.requests

            profile.hostURL = failingServerB.baseURL
            await manager.connectService(profile)

            #expect(manager.sonarrConnected == false)
            #expect(manager.sonarrClient == nil)
            #expect(manager.sonarrClient(for: profile.id) == nil)

            // These are manager and retained-view-model entry points. None may
            // revive or reach the client that was configured for server A.
            let libraryAfterFailure = try await manager.loadSeriesLibrary()
            await manager.loadHealth()
            await manager.refreshQueues()
            await viewModel.loadSeries()
            let queuedSearch = await viewModel.searchSeries(seriesId: 1)

            #expect(libraryAfterFailure.isEmpty)
            #expect(queuedSearch == false)
            #expect(serverA.requests == requestsBeforeFailure)
            #expect(failingServerB.requests == [.init(method: "GET", path: "/api/v3/system/status")])
        }
    }

    private func withSavedAPIKey(
        for profile: ArrServiceProfile,
        operation: () async throws -> Void
    ) async throws {
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "lifecycle-test-key")
        do {
            try await operation()
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        } catch {
            try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            throw error
        }
    }
}

private struct LifecycleRequest: Sendable, Equatable {
    let method: String
    let path: String
}

private final class LifecycleArrTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let libraryPath: String
    private let libraryBody: String
    private let statusCode: Int
    private let lock = NSLock()
    private var recordedRequests: [LifecycleRequest] = []

    init(label: String, libraryPath: String, libraryBody: String, statusCode: Int = 200) async throws {
        self.queue = DispatchQueue(label: "LifecycleArrTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.libraryPath = libraryPath
        self.libraryBody = libraryBody
        self.statusCode = statusCode
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
        guard let port = listener.port else { fatalError("Lifecycle test server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [LifecycleRequest] {
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

            let body: String
            if self.statusCode == 200 {
                switch request.path {
                case self.libraryPath: body = self.libraryBody
                case "/api/v3/system/status": body = "{}"
                case "/api/v3/qualityprofile", "/api/v3/rootfolder", "/api/v3/tag": body = "[]"
                case "/api/v3/command": body = "{}"
                default: body = "[]"
                }
            } else {
                body = #"{"message":"credentials rejected"}"#
            }
            connection.send(
                content: Self.httpResponse(statusCode: self.statusCode, body: body),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func request(from data: Data) -> LifecycleRequest {
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
        let status = statusCode == 200 ? "200 OK" : "\(statusCode) Unauthorized"
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }
}
