import Foundation
import Network

/// A loopback server that accepts a connection, reads the request, and then never
/// replies — so an in-flight request stays genuinely in flight until the test cancels
/// the task awaiting it.
///
/// Shared by the setup-view-model suites, which each need to prove what a *cancelled*
/// save does. `waitForFirstRequest` is a `CheckedContinuation` barrier resumed from
/// the listener's own queue, so nothing here waits on the clock.
nonisolated final class UnansweringServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private var sawRequest = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(label: String) async throws {
        self.queue = DispatchQueue(label: "UnansweringServer.\(label)")
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.lock.lock()
            self.held.append(connection)
            self.lock.unlock()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
                guard let self, data != nil else { return }
                self.markRequestSeen()
                // Deliberately no send(): the connection is held open, unanswered.
            }
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
            fatalError("UnansweringServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    func waitForFirstRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if sawRequest {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let connections = held
        held = []
        lock.unlock()
        for connection in connections { connection.cancel() }
        listener.cancel()
    }

    private func markRequestSeen() {
        lock.lock()
        sawRequest = true
        let ready = waiters
        waiters = []
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }
}
