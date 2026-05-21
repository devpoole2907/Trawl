import Foundation
import SwiftUI

struct ConnectionRetryCountdownView: View {
    @Environment(ConnectionRetryScheduler.self) private var retryScheduler

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let nextRetryDate = retryScheduler.nextRetryDate,
               !retryScheduler.isRetrying {
                let remainingSeconds = Self.remainingSeconds(until: nextRetryDate, from: context.date)
                if remainingSeconds > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "timer")
                        Text("Retrying in \(Self.formattedTime(remainingSeconds: remainingSeconds))")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.snappy, value: retryScheduler.nextRetryDate)
        .animation(.snappy, value: retryScheduler.isRetrying)
    }

    private static func remainingSeconds(until retryDate: Date, from currentDate: Date) -> Int {
        max(0, Int(ceil(retryDate.timeIntervalSince(currentDate))))
    }

    private static func formattedTime(remainingSeconds: Int) -> String {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60

        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02d", seconds))s"
        }

        return "\(seconds)s"
    }
}
