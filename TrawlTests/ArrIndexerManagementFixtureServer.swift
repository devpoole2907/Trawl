import Foundation
import Network
@testable import Trawl

/// A loopback HTTP/1.1 server for `ArrIndexerManagementViewModel` — the
/// Sonarr/Radarr indexer manager at the bottom of `ProwlarrViewModel.swift`.
///
/// That view model resolves a real `SonarrAPIClient` / `RadarrAPIClient` per
/// `(profileID, serviceType)` via `ArrServiceManager.sonarrClient(for:)` /
/// `.radarrClient(for:)`, both of which speak the shared `/api/v3` surface and
/// have no session-injection seam — so, as with `ProwlarrFixtureServer`, a
/// real socket is the only faithful way to exercise the request path, and the
/// only way to prove an operation for one connected instance never reaches
/// another instance's socket. This is a parallel copy of that file's plumbing
/// rather than a shared one, because it fronts a structurally different API
/// surface (`/api/v3` indexer endpoints, not Prowlarr's `/api/v1`) — the same
/// reasoning `ProwlarrFixtureServer` itself gives for not sharing
/// `ArrClientLifecycleTests`' server.
nonisolated struct ArrIndexerFixtureRequest: Sendable, Equatable {
    let method: String
    let path: String
    let rawQuery: String
    let headers: [String: String]
    let body: String

    var apiKey: String? { headers["x-api-key"] }

    /// The request body parsed as JSON. Bodies are always compared as parsed
    /// JSON, never as `JSONEncoder` bytes: key order in encoder output is
    /// unstable, so a byte comparison passes once and then fails for no reason.
    func jsonObject() -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return raw as? [String: Any]
    }
}

nonisolated struct ArrIndexerFixtureResponse: Sendable {
    let status: Int
    let body: Data

    static func json(_ string: String, status: Int = 200) -> ArrIndexerFixtureResponse {
        ArrIndexerFixtureResponse(status: status, body: Data(string.utf8))
    }

    /// A Sonarr/Radarr-shaped failure. `ArrError.serverError` renders the
    /// `message` field of the payload into the string the view models store.
    static func failure(status: Int, message: String) -> ArrIndexerFixtureResponse {
        .json(#"{"message":"\#(message)"}"#, status: status)
    }

    static let empty = ArrIndexerFixtureResponse(status: 200, body: Data())
}

nonisolated final class ArrIndexerFixtureServer: @unchecked Sendable {
    typealias Handler = @Sendable (ArrIndexerFixtureRequest) -> ArrIndexerFixtureResponse?

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: Handler

    private let lock = NSLock()
    private var recorded: [ArrIndexerFixtureRequest] = []

    init(label: String, handler: @escaping Handler) async throws {
        self.queue = DispatchQueue(label: "ArrIndexerFixtureServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
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
        guard let port = listener.port else {
            fatalError("Arr indexer fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [ArrIndexerFixtureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(path: String) -> [ArrIndexerFixtureRequest] {
        requests.filter { $0.path == path }
    }

    func requestCount(path: String) -> Int {
        requests(path: path).count
    }

    func requestCount(method: String, path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let request = Self.parse(accumulated) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: accumulated)
                }
                return
            }

            self.lock.lock()
            self.recorded.append(request)
            self.lock.unlock()

            let response = self.handler(request) ?? .json("[]")
            connection.send(
                content: Self.encode(response),
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }

    // MARK: - HTTP framing

    private static func parse(_ buffer: Data) -> ArrIndexerFixtureRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyBytes = Data(buffer[separator.upperBound...])
        guard bodyBytes.count >= contentLength else { return nil }
        let body = String(data: bodyBytes.prefix(contentLength), encoding: .utf8) ?? ""

        let target = String(parts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return ArrIndexerFixtureRequest(
            method: String(parts[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count > 1 ? String(targetParts[1]) : "",
            headers: headers,
            body: body
        )
    }

    private static func encode(_ response: ArrIndexerFixtureResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

// MARK: - Routing helpers

/// Answers the endpoints every connected Sonarr/Radarr instance needs but no
/// test is asserting on: the `system/status` + `qualityprofile` + `rootfolder`
/// + `tag` quartet `ArrServiceManager.connectService` requires to mark a
/// Sonarr/Radarr profile connected. Handlers pass anything they do not route
/// themselves to this.
nonisolated func arrIndexerDefaultResponse(for request: ArrIndexerFixtureRequest) -> ArrIndexerFixtureResponse {
    switch request.path {
    case "/api/v3/system/status": return .json("{}")
    case "/api/v3/qualityprofile", "/api/v3/rootfolder", "/api/v3/tag": return .json("[]")
    default: return .json("[]")
    }
}

// MARK: - JSON fixtures

/// Builds one `ArrManagedIndexer` payload as Sonarr/Radarr would return it.
nonisolated func arrManagedIndexerJSON(
    id: Int,
    name: String,
    tags: [Int] = [],
    enableRss: Bool = true,
    protocolName: String = "usenet",
    priority: Int = 25
) -> String {
    let tagList = tags.map(String.init).joined(separator: ",")
    return """
    {"id":\(id),"name":"\(name)","implementation":"Newznab","implementationName":"Newznab",\
    "configContract":"NewznabSettings","infoLink":"https://wiki.servarr.com",\
    "tags":[\(tagList)],"enableRss":\(enableRss),"enableAutomaticSearch":true,\
    "enableInteractiveSearch":true,"supportsRss":true,"supportsSearch":true,\
    "protocol":"\(protocolName)","priority":\(priority)}
    """
}

nonisolated func arrJSONArray(_ elements: [String]) -> String {
    "[\(elements.joined(separator: ","))]"
}

/// Builds an in-memory `ArrManagedIndexer` for POST/PUT/test request bodies —
/// the counterpart to `arrManagedIndexerJSON`, which builds the server's
/// response shape.
nonisolated func makeTestArrManagedIndexer(
    id: Int,
    name: String,
    tags: [Int] = [],
    enableRss: Bool = true,
    protocolValue: ArrIndexerProtocol = .usenet,
    priority: Int? = 25
) -> ArrManagedIndexer {
    ArrManagedIndexer(
        id: id,
        name: name,
        fields: nil,
        implementationName: "Newznab",
        implementation: "Newznab",
        configContract: "NewznabSettings",
        infoLink: nil,
        message: nil,
        tags: tags,
        presets: nil,
        enableRss: enableRss,
        enableAutomaticSearch: true,
        enableInteractiveSearch: true,
        supportsRss: true,
        supportsSearch: true,
        protocol: protocolValue,
        priority: priority,
        seasonSearchMaximumSingleEpisodeAge: nil,
        downloadClientId: nil
    )
}

// MARK: - Connection helper

nonisolated enum ArrIndexerFixtureFailure: Error {
    case notConnected(String)
}

/// One instance to connect: which fixture server it points at, whether it's a
/// Sonarr or Radarr profile, and its display name.
nonisolated struct ArrIndexerFixtureInstance: Sendable {
    let server: ArrIndexerFixtureServer
    let serviceType: ArrServiceType
    let displayName: String

    init(_ server: ArrIndexerFixtureServer, _ serviceType: ArrServiceType, _ displayName: String) {
        self.server = server
        self.serviceType = serviceType
        self.displayName = displayName
    }
}

/// Stands up a real `ArrServiceManager` and connects it to every instance in
/// `instances`, each through the production `connectService` path (Keychain
/// read, real `SonarrAPIClient`/`RadarrAPIClient`, real
/// `/api/v3/system/status` + quality-profile + root-folder + tag round trip).
/// Hands the manager and the connected profiles (same order as `instances`)
/// to `body`. Every API key is removed afterwards, success or failure.
@MainActor
func withConnectedArrInstances(
    _ instances: [ArrIndexerFixtureInstance],
    _ body: (ArrServiceManager, [ArrServiceProfile]) async throws -> Void
) async throws {
    let manager = ArrServiceManager()
    var profiles: [ArrServiceProfile] = []
    for instance in instances {
        let profile = ArrServiceProfile(displayName: instance.displayName, hostURL: instance.server.baseURL, serviceType: instance.serviceType)
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "arr-indexer-fixture-key")
        profiles.append(profile)
    }

    do {
        for (index, instance) in instances.enumerated() {
            await manager.connectService(profiles[index])
            let connected: Bool
            switch instance.serviceType {
            case .sonarr: connected = manager.sonarrClient(for: profiles[index].id) != nil
            case .radarr: connected = manager.radarrClient(for: profiles[index].id) != nil
            default: connected = false
            }
            guard connected else {
                throw ArrIndexerFixtureFailure.notConnected("\(instance.displayName) did not connect.")
            }
        }
        try await body(manager, profiles)
        for profile in profiles {
            try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        }
    } catch {
        for profile in profiles {
            try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        }
        throw error
    }
}
