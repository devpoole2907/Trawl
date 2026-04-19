import SwiftUI

struct TorrentRowView: View {
    let torrent: Torrent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(torrent.name)
                .font(.subheadline)
                .lineLimit(2)

            HStack(spacing: 6) {
                StatusBadge(
                    title: torrent.state.displayName,
                    systemImage: torrent.state.systemImage,
                    tint: torrent.state.color
                )

                if let category = torrent.category, !category.isEmpty {
                    BadgeLabel(title: category)
                }
            }

            ProgressView(value: torrent.progress)
                .tint(progressTint)

            HStack(spacing: 12) {
                if torrent.dlspeed > 0 {
                    MetricLabel(
                        systemImage: "arrow.down",
                        text: ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed),
                        tint: .blue
                    )
                }

                if torrent.upspeed > 0 {
                    MetricLabel(
                        systemImage: "arrow.up",
                        text: ByteFormatter.formatSpeed(bytesPerSecond: torrent.upspeed),
                        tint: .green
                    )
                }

                if !torrent.state.isCompleted && torrent.eta > 0 && torrent.eta < 8_640_000 {
                    MetricLabel(
                        systemImage: "clock",
                        text: ByteFormatter.formatETA(seconds: torrent.eta),
                        tint: .secondary
                    )
                }

                Spacer()

                Text(ByteFormatter.format(bytes: torrent.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(percentText)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var percentText: String {
        "\(Int(torrent.progress * 100))%"
    }

    private var progressTint: Color {
        if torrent.progress >= 1.0 { return .green }
        if torrent.state.filterCategory == .errored { return .red }
        return .blue
    }
}

private struct StatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

private struct BadgeLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.tertiary)
            .clipShape(Capsule())
    }
}

private struct MetricLabel: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
    }
}
