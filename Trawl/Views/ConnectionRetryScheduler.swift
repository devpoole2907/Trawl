import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ConnectionRetryScheduler {
    static let retryInterval: TimeInterval = 30

    private(set) var nextRetryDate: Date?
    private(set) var isRetrying = false

    func start(retry: @escaping @MainActor () async -> Void) async {
        while !Task.isCancelled {
            withAnimation(.snappy) {
                isRetrying = false
                nextRetryDate = Date().addingTimeInterval(Self.retryInterval)
            }

            do {
                try await Task.sleep(for: .seconds(Self.retryInterval))
            } catch {
                break
            }

            guard !Task.isCancelled else { break }
            withAnimation(.snappy) {
                nextRetryDate = nil
                isRetrying = true
            }
            await retry()
            withAnimation(.snappy) {
                isRetrying = false
            }
        }

        withAnimation(.snappy) {
            nextRetryDate = nil
            isRetrying = false
        }
    }
}
