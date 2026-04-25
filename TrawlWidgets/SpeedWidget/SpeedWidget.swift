import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct SpeedEntry: TimelineEntry {
    let date: Date
    let dlSpeed: Int64
    let upSpeed: Int64
    let dlLimit: Int64
    let upLimit: Int64
    let serverName: String
    let isActive: Bool

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: isActive ? 10 : 1)
    }

    static let placeholder = SpeedEntry(
        date: .now,
        dlSpeed: 5_242_880,
        upSpeed: 1_048_576,
        dlLimit: 0,
        upLimit: 0,
        serverName: "Trawl Server",
        isActive: true
    )

    static let empty = SpeedEntry(
        date: .now,
        dlSpeed: 0,
        upSpeed: 0,
        dlLimit: 0,
        upLimit: 0,
        serverName: "No Server",
        isActive: false
    )
}

// MARK: - Provider

struct SpeedProvider: AppIntentTimelineProvider {
    typealias Entry = SpeedEntry
    typealias Intent = SelectServerIntent

    func placeholder(in context: Context) -> SpeedEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectServerIntent, in context: Context) async -> SpeedEntry {
        if context.isPreview {
            return .placeholder
        }
        return await fetchEntry(serverID: configuration.server?.id)
    }

    func timeline(for configuration: SelectServerIntent, in context: Context) async -> Timeline<SpeedEntry> {
        let entry = await fetchEntry(serverID: configuration.server?.id)
        // Refresh more frequently while transfers are active.
        let nextInterval: TimeInterval = entry.isActive ? 5 * 60 : 30 * 60
        let nextUpdate = Date(timeIntervalSinceNow: nextInterval)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func fetchEntry(serverID: String?) async -> SpeedEntry {
        do {
            let (info, name) = try await WidgetDataFetcher.fetchTransferInfo(serverID: serverID)
            return SpeedEntry(
                date: .now,
                dlSpeed: info.dlInfoSpeed,
                upSpeed: info.upInfoSpeed,
                dlLimit: info.dlRateLimit,
                upLimit: info.upRateLimit,
                serverName: name,
                isActive: info.dlInfoSpeed > 0 || info.upInfoSpeed > 0
            )
        } catch {
            return .empty
        }
    }
}

// MARK: - Views

struct SpeedWidgetEntryView: View {
    var entry: SpeedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallLayout
        default:
            mediumLayout
        }
    }

    // MARK: Small — icon + DL + UL + server name

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "app.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)

            Spacer(minLength: 8)

            speedRow(
                icon: "arrow.down.circle.fill",
                color: .green,
                speed: entry.dlSpeed,
                font: .title3.weight(.semibold)
            )
            .padding(.bottom, 4)

            speedRow(
                icon: "arrow.up.circle.fill",
                color: .blue,
                speed: entry.upSpeed,
                font: .title3.weight(.semibold)
            )

            Spacer(minLength: 8)

            Text(entry.serverName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(URL(string: "trawl://torrents"))
    }

    // MARK: Medium — speeds left, limits + status right

    private var mediumLayout: some View {
        HStack(spacing: 0) {
            // Left column: speeds
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)

                Spacer(minLength: 4)

                speedRow(icon: "arrow.down.circle.fill", color: .green, speed: entry.dlSpeed, font: .headline.weight(.semibold))
                speedRow(icon: "arrow.up.circle.fill", color: .blue, speed: entry.upSpeed, font: .headline.weight(.semibold))

                Spacer(minLength: 4)

                Text(entry.serverName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 16)

            // Right column: limits + activity
            VStack(alignment: .leading, spacing: 6) {
                limitRow(label: "DL Limit", limit: entry.dlLimit, color: .green)
                limitRow(label: "UL Limit", limit: entry.upLimit, color: .blue)

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.isActive ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(entry.isActive ? "Active" : "Idle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(URL(string: "trawl://torrents"))
    }

    // MARK: Helpers

    private func speedRow(icon: String, color: Color, speed: Int64, font: Font) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(font)
            Text(ByteFormatter.formatSpeed(bytesPerSecond: speed))
                .font(font.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func limitRow(label: String, limit: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(limit <= 0 ? "Unlimited" : ByteFormatter.formatSpeed(bytesPerSecond: limit))
                .font(.caption.weight(.medium))
                .foregroundStyle(limit <= 0 ? .secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Widget

struct SpeedWidget: Widget {
    let kind = "com.poole.james.Trawl.SpeedWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectServerIntent.self,
            provider: SpeedProvider()
        ) { entry in
            SpeedWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Download Speed")
        .description("Current global download and upload speeds from qBittorrent.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    SpeedWidget()
} timeline: {
    SpeedEntry.placeholder
    SpeedEntry.empty
}

#Preview(as: .systemMedium) {
    SpeedWidget()
} timeline: {
    SpeedEntry.placeholder
}
