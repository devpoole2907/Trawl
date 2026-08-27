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
    var errorMessage: String? = nil

    var isUnavailable: Bool { errorMessage != nil }

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

    static func unavailable(_ message: String) -> SpeedEntry {
        SpeedEntry(
            date: .now,
            dlSpeed: 0,
            upSpeed: 0,
            dlLimit: 0,
            upLimit: 0,
            serverName: message,
            isActive: false,
            errorMessage: message
        )
    }

    static let empty = unavailable("No Client")
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
        let nextInterval = WidgetTimelinePolicy.speedRefreshInterval(isActive: entry.isActive)
        let nextUpdate = Date(timeIntervalSinceNow: nextInterval)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func fetchEntry(serverID: String?) async -> SpeedEntry {
        let snapshot = await WidgetDataFetcher.fetchDownloadSpeed(serverID: serverID)
        guard snapshot.errorMessage == nil else {
            return .unavailable(snapshot.errorMessage ?? "Unavailable")
        }
        return SpeedEntry(
            date: .now,
            dlSpeed: snapshot.dlSpeed,
            upSpeed: snapshot.upSpeed,
            dlLimit: snapshot.dlLimit,
            upLimit: snapshot.upLimit,
            serverName: snapshot.serverName,
            isActive: snapshot.isActive
        )
    }
}

// MARK: - Views

struct SpeedWidgetEntryView: View {
    var entry: SpeedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        // Accessory families are checked before the unavailable branch: a
        // lock-screen slot has no room for the full "open Trawl to set up" card,
        // so an unreachable client is folded into the accessory's own layout.
        switch family {
        case .accessoryInline:
            accessoryInlineLayout
        case .accessoryCircular:
            accessoryCircularLayout
        default:
            if entry.isUnavailable {
                unavailableLayout
            } else if family == .systemSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
    }

    // MARK: Lock screen

    private var accessoryInlineLayout: some View {
        Text(
            WidgetGlanceFormatter.inlineSpeedText(
                formattedDownloadRate: ByteFormatter.formatSpeed(bytesPerSecond: entry.dlSpeed),
                isActive: entry.isActive,
                isUnavailable: entry.isUnavailable
            )
        )
        .widgetURL(URL(string: "trawl://downloads"))
    }

    private var accessoryCircularLayout: some View {
        Gauge(
            value: WidgetGlanceFormatter.speedGaugeFraction(
                bytesPerSecond: entry.dlSpeed,
                limitBytesPerSecond: entry.dlLimit
            )
        ) {
            Image(systemName: entry.isUnavailable ? "wifi.exclamationmark" : "arrow.down")
        } currentValueLabel: {
            Text(
                WidgetGlanceFormatter.compactRateLabel(
                    bytesPerSecond: entry.dlSpeed,
                    isUnavailable: entry.isUnavailable
                )
            )
            .monospacedDigit()
            .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(URL(string: "trawl://downloads"))
    }

    private var unavailableLayout: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(entry.errorMessage ?? "Unavailable")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Open Trawl to set up")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(URL(string: "trawl://downloads"))
    }

    // MARK: Small

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 8)

            speedRow(
                icon: "arrow.down.circle.fill",
                color: .blue,
                speed: entry.dlSpeed,
                font: .title3.weight(.semibold)
            )
            .padding(.bottom, 4)

            speedRow(
                icon: "arrow.up.circle.fill",
                color: .green,
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
        .widgetURL(URL(string: "trawl://downloads"))
    }

    // MARK: Medium

    private var mediumLayout: some View {
        HStack(spacing: 0) {
            // Left column: speeds
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.blue)
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Spacer(minLength: 4)

                speedRow(icon: "arrow.down.circle.fill", color: .blue, speed: entry.dlSpeed, font: .headline.weight(.semibold))
                speedRow(icon: "arrow.up.circle.fill", color: .green, speed: entry.upSpeed, font: .headline.weight(.semibold))

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
                limitRow(label: "DL Limit", limit: entry.dlLimit, color: .blue)
                limitRow(label: "UL Limit", limit: entry.upLimit, color: .green)

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
        .widgetURL(URL(string: "trawl://downloads"))
    }

    // MARK: Helpers

    private func speedRow(icon: String, color: Color, speed: Int64, font: Font) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(font)
            Text(ByteFormatter.formatSpeed(bytesPerSecond: speed))
                .font(font.monospaced())
                .monospacedDigit()
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
                .monospacedDigit()
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
        .description("Current global download and upload speeds across qBittorrent and SABnzbd.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    SpeedWidget()
} timeline: {
    SpeedEntry.placeholder
    SpeedEntry.unavailable("No Client")
}

#Preview(as: .systemMedium) {
    SpeedWidget()
} timeline: {
    SpeedEntry.placeholder
}

#Preview(as: .accessoryCircular) {
    SpeedWidget()
} timeline: {
    SpeedEntry.placeholder
}

#Preview(as: .accessoryInline) {
    SpeedWidget()
} timeline: {
    SpeedEntry.placeholder
    SpeedEntry.unavailable("No Client")
}
