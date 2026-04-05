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
                    Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed), systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                if torrent.upspeed > 0 {
                    Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.upspeed), systemImage: "arrow.up")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if !torrent.state.isCompleted && torrent.eta > 0 && torrent.eta < 8_640_000 {
                    Label(ByteFormatter.formatETA(seconds: torrent.eta), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        Label(title, systemImage: systemImage)
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
