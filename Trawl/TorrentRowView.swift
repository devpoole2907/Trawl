import SwiftUI

struct TorrentRowView: View {
    let torrent: Torrent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Torrent name
            Text(torrent.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)

            // State badge and category
            HStack(spacing: 6) {
                Label(torrent.state.displayName, systemImage: torrent.state.systemImage)
                    .font(.caption)
                    .foregroundStyle(torrent.state.color)

                if let category = torrent.category, !category.isEmpty {
                    Text(category)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }

            // Progress bar
            ProgressView(value: torrent.progress)
                .tint(progressTint)

            // Stats row
            HStack(spacing: 12) {
                if torrent.dlspeed > 0 {
                    Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed), systemImage: "arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }

                if torrent.upspeed > 0 {
                    Label(ByteFormatter.formatSpeed(bytesPerSecond: torrent.upspeed), systemImage: "arrow.up")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }

                if !torrent.state.isCompleted && torrent.eta > 0 && torrent.eta < 8_640_000 {
                    Label(ByteFormatter.formatETA(seconds: torrent.eta), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(ByteFormatter.format(bytes: torrent.size))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(percentText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
