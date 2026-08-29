import Foundation
import Testing
@testable import Trawl

/// These tests drive the real `SABnzbdServiceManager` against the real
/// `SABnzbdAPIClient` request path. Two fake SABnzbd servers answer on distinct
/// hosts through an injected `URLProtocol`, and the *server* - never Trawl's own
/// code - is what the test stalls. Ordering is owned entirely by checked
/// continuations: a response is parked until the test releases it, and the test
/// only proceeds once the server confirms the parked requests have arrived.
@Suite("SABnzbd profile switching", .serialized)
@MainActor
struct SABnzbdProfileSwitchTests {
    @Test("A slow refresh from the previous server cannot publish under the newly selected profile")
    func lateRefreshFromPreviousProfileIsDiscarded() async throws {
        let manager = SABnzbdServiceManager(sessionConfiguration: Self.interceptedConfiguration())
        defer { manager.stopPolling() }

        let profileA = SABnzbdServiceProfile(
            displayName: "Server A",
            hostURL: "https://\(SABnzbdSwitchRemote.hostA)"
        )
        let profileB = SABnzbdServiceProfile(
            displayName: "Server B",
            hostURL: "https://\(SABnzbdSwitchRemote.hostB)"
        )

        await SABnzbdSwitchRemote.shared.reset()
        await Self.installServerAPhaseOneFixtures()
        await Self.installServerBFixtures()

        try await withSavedAPIKeys(for: [profileA, profileB]) {
            await manager.connectService(profileA)

            #expect(manager.activeProfileID == profileA.id)
            #expect(manager.queue?.jobs.map(\.name) == ["Downloading On A"])
            #expect(manager.history?.jobs.map(\.name) == ["Ghost From Server A"])
            // The ghost job is mid-unpack, so it forms the completion baseline.
            // Server A's next answer flips it to Completed.
            #expect(manager.history?.jobs.first?.normalizedStatus == .unpacking)

            await Self.installServerAPhaseTwoFixtures()
            await SABnzbdSwitchRemote.shared.startParking(host: SABnzbdSwitchRemote.hostA)

            let staleRefresh = Task { @MainActor in await manager.refresh() }
            // Both halves of server A's refresh (queue + history) are now parked
            // inside the fake server, so the manager is mid-flight against A.
            await SABnzbdSwitchRemote.shared.waitForParkedRequests(count: 2)

            await manager.connectService(profileB)

            // Requirement: A's in-flight refresh must not block B's own refresh.
            #expect(manager.activeProfileID == profileB.id)
            #expect(manager.queue?.jobs.map(\.name) == ["Downloading On B"])
            #expect(manager.history?.jobs.map(\.name) == ["Finished On B"])

            await SABnzbdSwitchRemote.shared.releaseParkedRequests()
            await staleRefresh.value

            // Requirement: A's late response changes nothing.
            #expect(manager.activeProfileID == profileB.id)
            #expect(manager.isConnected)
            #expect(!manager.isRefreshing)
            #expect(manager.hasRefreshedOnce)
            #expect(manager.connectionError == nil)
            #expect(manager.queue?.jobs.map(\.name) == ["Downloading On B"])
            #expect(manager.history?.jobs.map(\.name) == ["Finished On B"])
            #expect(manager.activeJobs.map(\.name) == ["Downloading On B"])
            #expect(manager.historyJobs.map(\.name) == ["Finished On B"])

            // A's completion must not be announced under B's connection.
            let ghostAnnouncements = InAppNotificationCenter.shared.recentNotifications.filter {
                $0.title == "Download Complete" && $0.message == "Ghost From Server A"
            }
            #expect(ghostAnnouncements.isEmpty)

            // Server B was actually polled: version + queue for the connect, then
            // queue + history for its own refresh. Without the fix, B's refresh is
            // swallowed by A's still-held `isRefreshing` and history never arrives.
            let modesB = await SABnzbdSwitchRemote.shared.requestedModes(host: SABnzbdSwitchRemote.hostB)
            #expect(modesB.sorted() == ["history", "queue", "queue", "version"])

            // Server A saw exactly its connect, its first refresh, and the parked
            // second refresh - and nothing after the switch.
            let modesA = await SABnzbdSwitchRemote.shared.requestedModes(host: SABnzbdSwitchRemote.hostA)
            #expect(modesA.sorted() == ["history", "history", "queue", "queue", "queue", "version"])
        }
    }

    @Test("A slow connect to the previous server cannot claim the manager after a newer connect")
    func lateConnectFromPreviousProfileIsDiscarded() async throws {
        let manager = SABnzbdServiceManager(sessionConfiguration: Self.interceptedConfiguration())
        defer { manager.stopPolling() }

        let profileA = SABnzbdServiceProfile(
            displayName: "Server A",
            hostURL: "https://\(SABnzbdSwitchRemote.hostA)"
        )
        let profileB = SABnzbdServiceProfile(
            displayName: "Server B",
            hostURL: "https://\(SABnzbdSwitchRemote.hostB)"
        )

        await SABnzbdSwitchRemote.shared.reset()
        await Self.installServerAPhaseOneFixtures()
        await Self.installServerBFixtures()

        try await withSavedAPIKeys(for: [profileA, profileB]) {
            await SABnzbdSwitchRemote.shared.startParking(host: SABnzbdSwitchRemote.hostA)
            let staleConnect = Task { @MainActor in await manager.connectService(profileA) }
            // Server A has received the connect handshake (version + queue) and is
            // holding both responses.
            await SABnzbdSwitchRemote.shared.waitForParkedRequests(count: 2)

            await manager.connectService(profileB)
            #expect(manager.activeProfileID == profileB.id)

            await SABnzbdSwitchRemote.shared.releaseParkedRequests()
            await staleConnect.value

            #expect(manager.activeProfileID == profileB.id)
            #expect(manager.isConnected)
            #expect(!manager.isConnecting)
            #expect(manager.connectionError == nil)
            #expect(manager.queue?.jobs.map(\.name) == ["Downloading On B"])
            #expect(manager.history?.jobs.map(\.name) == ["Finished On B"])

            // The abandoned connect must not have gone on to refresh server A.
            let modesA = await SABnzbdSwitchRemote.shared.requestedModes(host: SABnzbdSwitchRemote.hostA)
            #expect(modesA.sorted() == ["queue", "version"])

            let modesB = await SABnzbdSwitchRemote.shared.requestedModes(host: SABnzbdSwitchRemote.hostB)
            #expect(modesB.sorted() == ["history", "queue", "queue", "version"])
        }
    }

    // MARK: - Fixtures

    private static func interceptedConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SABnzbdSwitchURLProtocol.self]
        return configuration
    }

    private static func installServerAPhaseOneFixtures() async {
        let remote = SABnzbdSwitchRemote.shared
        let host = SABnzbdSwitchRemote.hostA
        await remote.setBody(#"{"version":"4.5.0"}"#, host: host, mode: "version")
        await remote.setBody(
            #"{"queue":{"slots":[{"nzo_id":"a-queue-1","filename":"Downloading On A","status":"Downloading","mb":100,"mbleft":40,"percentage":60,"size":"100 MB","sizeleft":"40 MB"}]}}"#,
            host: host,
            mode: "queue"
        )
        await remote.setBody(
            #"{"history":{"last_history_update":1,"slots":[{"nzo_id":"a-history-1","name":"Ghost From Server A","status":"Extracting","bytes":100000,"downloaded":100000,"size":"100 KB"}]}}"#,
            host: host,
            mode: "history"
        )
    }

    /// Server A's second answer: the ghost job has now completed. If the manager
    /// publishes this under profile B, the queue, the history, and the completion
    /// banner all belong to the wrong server.
    private static func installServerAPhaseTwoFixtures() async {
        let remote = SABnzbdSwitchRemote.shared
        let host = SABnzbdSwitchRemote.hostA
        await remote.setBody(
            #"{"queue":{"slots":[{"nzo_id":"a-queue-2","filename":"Stale Job From Server A","status":"Downloading","mb":100,"mbleft":10,"percentage":90,"size":"100 MB","sizeleft":"10 MB"}]}}"#,
            host: host,
            mode: "queue"
        )
        await remote.setBody(
            #"{"history":{"last_history_update":2,"slots":[{"nzo_id":"a-history-1","name":"Ghost From Server A","status":"Completed","bytes":100000,"downloaded":100000,"size":"100 KB","completed":1700000000}]}}"#,
            host: host,
            mode: "history"
        )
    }

    private static func installServerBFixtures() async {
        let remote = SABnzbdSwitchRemote.shared
        let host = SABnzbdSwitchRemote.hostB
        await remote.setBody(#"{"version":"4.5.1"}"#, host: host, mode: "version")
        await remote.setBody(
            #"{"queue":{"slots":[{"nzo_id":"b-queue-1","filename":"Downloading On B","status":"Downloading","mb":200,"mbleft":100,"percentage":50,"size":"200 MB","sizeleft":"100 MB"}]}}"#,
            host: host,
            mode: "queue"
        )
        await remote.setBody(
            #"{"history":{"last_history_update":9,"slots":[{"nzo_id":"b-history-1","name":"Finished On B","status":"Completed","bytes":200000,"downloaded":200000,"size":"200 KB","completed":1700000100}]}}"#,
            host: host,
            mode: "history"
        )
    }

    private func withSavedAPIKeys(
        for profiles: [SABnzbdServiceProfile],
        operation: () async throws -> Void
    ) async throws {
        for profile in profiles {
            try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "switch-test-key")
        }
        do {
            try await operation()
        } catch {
            for profile in profiles {
                try? await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
            }
            throw error
        }
        for profile in profiles {
            try await KeychainHelper.shared.delete(key: profile.apiKeyKeychainKey)
        }
    }
}

// MARK: - Fake SABnzbd servers

private struct SABnzbdSwitchResponse: Sendable {
    let statusCode: Int
    let body: Data
}

/// Two fake SABnzbd servers behind one `URLProtocol`, keyed by host. Requests to
/// a "parked" host are suspended on a checked continuation until the test
/// releases them, which is what makes the interleaving deterministic without any
/// sleeping or polling.
private actor SABnzbdSwitchRemote {
    static let hostA = "sabnzbd-a.switch.test"
    static let hostB = "sabnzbd-b.switch.test"
    static let shared = SABnzbdSwitchRemote()

    private struct ParkedRequest {
        let host: String
        let mode: String
        let continuation: CheckedContinuation<SABnzbdSwitchResponse, Never>
    }

    private var recordedModes: [String: [String]] = [:]
    private var bodies: [String: [String: String]] = [:]
    private var parkingHosts: Set<String> = []
    private var parkedRequests: [ParkedRequest] = []
    private var parkTarget: Int?
    private var parkObserver: CheckedContinuation<Void, Never>?

    func reset() {
        recordedModes = [:]
        bodies = [:]
        parkingHosts = []
        parkedRequests = []
        parkTarget = nil
        parkObserver = nil
    }

    func setBody(_ body: String, host: String, mode: String) {
        bodies[host, default: [:]][mode] = body
    }

    func startParking(host: String) {
        parkingHosts.insert(host)
    }

    func requestedModes(host: String) -> [String] {
        recordedModes[host] ?? []
    }

    func waitForParkedRequests(count: Int) async {
        guard parkedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            precondition(parkObserver == nil, "Only one parked-request wait may be pending.")
            parkTarget = count
            parkObserver = continuation
        }
    }

    func releaseParkedRequests() {
        let released = parkedRequests
        parkedRequests = []
        parkingHosts = []
        parkTarget = nil
        for request in released {
            request.continuation.resume(returning: response(host: request.host, mode: request.mode))
        }
    }

    func response(for request: URLRequest) async -> SABnzbdSwitchResponse {
        guard let url = request.url, let host = url.host() else {
            return SABnzbdSwitchResponse(statusCode: 500, body: Data())
        }
        let mode = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "mode" })?
            .value ?? ""
        recordedModes[host, default: []].append(mode)

        guard parkingHosts.contains(host) else {
            return response(host: host, mode: mode)
        }

        return await withCheckedContinuation { continuation in
            parkedRequests.append(ParkedRequest(host: host, mode: mode, continuation: continuation))
            if let parkTarget, parkedRequests.count >= parkTarget {
                self.parkTarget = nil
                parkObserver?.resume()
                parkObserver = nil
            }
        }
    }

    private func response(host: String, mode: String) -> SABnzbdSwitchResponse {
        guard let body = bodies[host]?[mode] else {
            return SABnzbdSwitchResponse(statusCode: 500, body: Data())
        }
        return SABnzbdSwitchResponse(statusCode: 200, body: Data(body.utf8))
    }
}

private final class SABnzbdSwitchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return host == SABnzbdSwitchRemote.hostA || host == SABnzbdSwitchRemote.hostB
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let protocolInstance = self
        Task.detached { @Sendable in
            guard let url = request.url else { return }
            let response = await SABnzbdSwitchRemote.shared.response(for: request)
            protocolInstance.complete(url: url, response: response)
        }
    }

    override func stopLoading() {}

    private func complete(url: URL, response: SABnzbdSwitchResponse) {
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
