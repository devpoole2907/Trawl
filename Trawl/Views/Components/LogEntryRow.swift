import SwiftUI

struct LogEntryRow<Badge: View, Secondary: View>: View {
    let message: String
    let timestamp: String
    let messageLineLimit: Int
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let secondary: () -> Secondary

    init(
        message: String,
        timestamp: String,
        messageLineLimit: Int = 3,
        @ViewBuilder badge: @escaping () -> Badge,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self.message = message
        self.timestamp = timestamp
        self.messageLineLimit = messageLineLimit
        self.badge = badge
        self.secondary = secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                badge()
                Spacer(minLength: 8)

                Text(timestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(messageLineLimit)

            secondary()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

extension LogEntryRow where Secondary == EmptyView {
    init(
        message: String,
        timestamp: String,
        messageLineLimit: Int = 3,
        @ViewBuilder badge: @escaping () -> Badge
    ) {
        self.init(
            message: message,
            timestamp: timestamp,
            messageLineLimit: messageLineLimit,
            badge: badge,
            secondary: { EmptyView() }
        )
    }
}
