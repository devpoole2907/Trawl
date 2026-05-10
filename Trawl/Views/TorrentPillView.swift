import SwiftUI

struct TorrentSummaryView<Accessory: View>: View {
    let torrent: Torrent
    var isProcessing: Bool
    var titleFont: Font
    var titleLineLimit: Int?
    var isTitleSelectable: Bool
    var displayedSize: Int64
    @ViewBuilder let accessory: () -> Accessory

    init(
        torrent: Torrent,
        isProcessing: Bool = false,
        titleFont: Font = .subheadline,
        titleLineLimit: Int? = 2,
        isTitleSelectable: Bool = false,
        displayedSize: Int64? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.torrent = torrent
        self.isProcessing = isProcessing
        self.titleFont = titleFont
        self.titleLineLimit = titleLineLimit
        self.isTitleSelectable = isTitleSelectable
        self.displayedSize = displayedSize ?? torrent.size
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title

            HStack(spacing: 6) {
                TorrentStatusBadge(
                    title: torrent.state.displayName,
                    systemImage: torrent.state.systemImage,
                    tint: torrent.state.color
                )

                if let category = torrent.category, !category.isEmpty {
                    CategoryBadge(title: category)
                }

                if isProcessing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Processing...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }

            ProgressView(value: torrent.progress)
                .tint(progressTint)

            accessory()

            HStack(spacing: 12) {
                if torrent.dlspeed > 0 {
                    TorrentMetricLabel(
                        systemImage: "arrow.down",
                        text: ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed),
                        tint: .blue
                    )
                }

                if torrent.upspeed > 0 {
                    TorrentMetricLabel(
                        systemImage: "arrow.up",
                        text: ByteFormatter.formatSpeed(bytesPerSecond: torrent.upspeed),
                        tint: .green
                    )
                }

                if !torrent.state.isCompleted && torrent.eta > 0 && torrent.eta < 8_640_000 {
                    TorrentMetricLabel(
                        systemImage: "clock",
                        text: ByteFormatter.formatETA(seconds: torrent.eta),
                        tint: .secondary
                    )
                }

                Spacer()

                Text(ByteFormatter.format(bytes: displayedSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(percentText)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isProcessing ? 0.6 : 1.0)
        .animation(.default, value: isProcessing)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var title: some View {
        let text = Text(torrent.name)
            .font(titleFont)
            .lineLimit(titleLineLimit)

        if isTitleSelectable {
            text.textSelection(.enabled)
        } else {
            text
        }
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

struct TorrentStatusBadge: View {
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

private struct TorrentMetricLabel: View {
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

struct CategoryBadge: View {
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
