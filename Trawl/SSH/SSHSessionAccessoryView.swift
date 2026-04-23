import SwiftUI

struct SSHSessionAccessoryView: View {
    let title: String
    let subtitle: String
    let statusText: String
    let statusColor: Color
    let openSession: () -> Void
    let closeSession: () -> Void

    private let compactThreshold: CGFloat = 310

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < compactThreshold

            HStack(spacing: 10) {
                Button(action: openSession) {
                    HStack(spacing: isCompact ? 10 : 12) {
                        iconBadge

                        if isCompact {
                            compactText
                        } else {
                            regularText
                        }

                        Spacer(minLength: 0)

                        if !isCompact {
                            statusBadge
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: closeSession) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 8)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isCompact)
        }
        .frame(height: 52)
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.green.opacity(0.16))
                .frame(width: 36, height: 36)
            Image(systemName: "terminal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.green)
        }
    }

    private var regularText: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var compactText: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
