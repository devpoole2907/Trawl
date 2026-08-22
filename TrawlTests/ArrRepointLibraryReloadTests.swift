import Foundation
import Network
import Testing
@testable import Trawl

/// N-01: after a same-ID repoint, the Series list renders empty even though the app
/// is connected to the new server and that server's library has already been fetched.
///
/// This reproduces the model half of that sequence in-process — real
/// `ArrServiceManager`, real `SonarrAPIClient`, real `ArrLibraryCache`, two real
/// loopback servers — and drives a view model through exactly the appear-time
/// sequence `ArrMediaListView.performInitialLoadAndStartPolling` uses. It exists to
/// separate "the manager/cache/view-model layer is wrong" from "the view never asks
/// it to load".
@Suite("Arr repoint library reload", .serialized)
@MainActor
struct ArrRepointLibraryReloadTests {
    @Test("A view model created after a same-ID repoint loads the replacement server's library")
    func viewModelCreatedAfterRepointLoadsNewLibrary() async throws {
        let serverA = try await RepointReloadTestServer(label: "reload-a", seriesBody: #"[{"id":1,"title":"From A"}]"#)
        let serverB = try await RepointReloadTestServer(label: "reload-b", seriesBody: #"[{"id":2,"title":"From B"}]"#)
        defer { serverA.stop(); serverB.stop() }

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: serverA.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "repoint-reload-key")
        defer { Task { try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey) } }

        await manager.connectService(profile)

        // The appear-time sequence the list view runs.
        let firstViewModel = SonarrViewModel(serviceManager: manager)
        _ = firstViewModel.adoptCachedLibraryItems()
        await firstViewModel.loadLibraryItems(maxAge: ArrLibraryCachePolicy.appearMaxAge)
        #expect(firstViewModel.series.map(\.title) == ["From A"])

        profile.hostURL = serverB.baseURL
        await manager.connectService(profile)

        // The list recreates its view model when the client revision rotates, so a
        // brand-new one is exactly what the view is holding at this point.
        let secondViewModel = SonarrViewModel(serviceManager: manager)
        _ = secondViewModel.adoptCachedLibraryItems()
        await secondViewModel.loadLibraryItems(maxAge: ArrLibraryCachePolicy.appearMaxAge)

        #expect(secondViewModel.series.map(\.title) == ["From B"])
        #expect(serverB.receivedSeriesRequest)
    }

    @Test("An appear-time load after a repoint refetches rather than serving the old server's cached library")
    func appearTimeLoadAfterRepointIgnoresStaleCache() async throws {
        let serverA = try await RepointReloadTestServer(label: "stale-a", seriesBody: #"[{"id":1,"title":"From A"}]"#)
        let serverB = try await RepointReloadTestServer(label: "stale-b", seriesBody: #"[{"id":2,"title":"From B"}]"#)
        defer { serverA.stop(); serverB.stop() }

        let profile = ArrServiceProfile(displayName: "Sonarr", hostURL: serverA.baseURL, serviceType: .sonarr)
        let manager = ArrServiceManager()

        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "repoint-stale-key")
        defer { Task { try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey) } }

        await manager.connectService(profile)
        _ = try await manager.loadSeriesLibrary()

        profile.hostURL = serverB.baseURL
        await manager.connectService(profile)

        // A 120s staleness window would happily serve A's copy if the repoint had not
        // invalidated the entry — that invalidation is what this pins.
        let library = try await manager.loadSeriesLibrary(maxAge: ArrLibraryCachePolicy.appearMaxAge)
        #expect(library.map(\.title) == ["From B"])
    }
}

private struct RepointReloadRequest: Sendable, Equatable {
    let method: String
    let path: String
}

private final class RepointReloadTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let seriesBody: String
    private let lock = NSLock()
    private var recordedRequests: [RepointReloadRequest] = []

    init(label: String, seriesBody: String) async throws {
        self.queue = DispatchQueue(label: "RepointReloadTestServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.seriesBody = seriesBody
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
        guard let port = listener.port else { fatalError("Repoint reload test server did not bind a port.") }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var receivedSeriesRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.contains(.init(method: "GET", path: "/api/v3/series"))
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
            switch request.path {
            case "/api/v3/series": body = self.seriesBody
            case "/api/v3/system/status": body = "{}"
            default: body = "[]"
            }
            connection.send(
                content: Self.httpResponse(body: body),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    private static func request(from data: Data) -> RepointReloadRequest {
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return .init(method: "", path: "")
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        return .init(method: method, path: String(rawPath.split(separator: "?", maxSplits: 1).first ?? ""))
    }

    private static func httpResponse(body: String) -> Data {
        let bytes = Data(body.utf8)
        return Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8) + bytes
    }
}
