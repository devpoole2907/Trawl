import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct ActiveDownloadsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetDataFetcher.WidgetActiveDownloadsSnapshot

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: snapshot.activeCount > 0 ? 8 : 1)
    }

    static let placeholder = ActiveDownloadsEntry(date: .now, snapshot: .activeDownloadsPlaceholder)
    static let noConfig = ActiveDownloadsEntry(date: .now, snapshot: .activeDownloadsUnavailable("No Client"))
}

// MARK: - Provider

struct ActiveDownloadsProvider: AppIntentTimelineProvider {
    typealias Entry = ActiveDownloadsEntry
    typealias Intent = SelectServerIntent

    func placeholder(in context: Context) -> ActiveDownloadsEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectServerIntent, in context: Context) async -> ActiveDownloadsEntry {
        if context.isPreview { return .placeholder }
        return await fetchEntry(serverID: configuration.server?.id)
    }

    func timeline(for configuration: SelectServerIntent, in context: Context) async -> Timeline<ActiveDownloadsEntry> {
        let entry = await fetchEntry(serverID: configuration.server?.id)
        let interval = WidgetTimelinePolicy.activeDownloadsRefreshInterval(
            activeCount: entry.snapshot.activeCount
        )
        return Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: interval)))
    }

    private func fetchEntry(serverID: String?) async -> ActiveDownloadsEntry {
        let snapshot = await WidgetDataFetcher.fetchActiveDownloads(serverID: serverID)
        return ActiveDownloadsEntry(date: .now, snapshot: snapshot)
    }
}

// MARK: - Views

struct ActiveDownloadsWidgetEntryView: View {
    let entry: ActiveDownloadsEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.snapshot.activeCount }
    private var isUnavailable: Bool { entry.snapshot.errorMessage != nil }

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircularLayout
        case .systemMedium:
            mediumLayout
        default:
            smallLayout
        }
    }

    /// Lock-screen dial. The count has no natural maximum, so it fills against a
    /// fixed ceiling rather than pretending to know the user's queue depth.
    private var accessoryCircularLayout: some View {
        Gauge(
            value: WidgetGlanceFormatter.countGaugeFraction(
                count: count,
                ceiling: WidgetGlanceFormatter.activeDownloadsGaugeCeiling
            )
        ) {
            Image(systemName: isUnavailable ? "wifi.exclamationmark" : "arrow.down")
        } currentValueLabel: {
            Text(isUnavailable ? "--" : "\(count)")
                .monospacedDigit()
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(ActiveDownloadsWidget.trawlDownloadsURL)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetHeader

            Spacer(minLength: 4)

            Text(isUnavailable ? "--" : "\(count)")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(count > 0 ? .blue : .secondary)

            Text(count == 1 ? "Active Download" : "Active Downloads")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let top = entry.snapshot.topDownload {
                topDownloadFooter(top)
            } else {
                Text(isUnavailable ? (entry.snapshot.errorMessage ?? "Unavailable") : "Idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(ActiveDownloadsWidget.trawlDownloadsURL)
    }

    private var mediumLayout: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                widgetHeader
                Spacer(minLength: 4)
                Text(isUnavailable ? "--" : "\(count)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(count > 0 ? .blue : .secondary)
                Text(entry.snapshot.serverName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 118, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let top = entry.snapshot.topDownload {
                    Text("Top Download")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(top.name)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    ProgressView(value: top.progress)
                        .tint(.blue)
                    HStack(spacing: 8) {
                        Label(ByteFormatter.formatSpeed(bytesPerSecond: top.dlspeed), systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        if let etaText = top.etaText {
                            Label(etaText, systemImage: "clock")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Image(systemName: isUnavailable ? "wifi.exclamationmark" : "checkmark.circle.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isUnavailable ? .orange : .green)
                    Text(isUnavailable ? "Unavailable" : "No active downloads")
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(ActiveDownloadsWidget.trawlDownloadsURL)
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: count > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(count > 0 ? .blue : .secondary)
            Text("Downloads")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if count > 0 {
                Circle()
                    .fill(.blue)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private func topDownloadFooter(_ download: WidgetDataFetcher.WidgetActiveDownloadSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(download.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            ProgressView(value: download.progress)
                .tint(.blue)
            Text(ByteFormatter.formatSpeed(bytesPerSecond: download.dlspeed))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
                .lineLimit(1)
        }
    }
}

// MARK: - Widget

struct ActiveDownloadsWidget: Widget {
    let kind = "com.poole.james.Trawl.ActiveDownloadsWidget"

    static let trawlDownloadsURL = URL(string: "trawl://downloads")!

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectServerIntent.self,
            provider: ActiveDownloadsProvider()
        ) { entry in
            ActiveDownloadsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Active Downloads")
        .description("Active downloads across qBittorrent and SABnzbd, with top progress.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview Data

private extension WidgetDataFetcher.WidgetActiveDownloadsSnapshot {
    static let activeDownloadsPlaceholder = WidgetDataFetcher.WidgetActiveDownloadsSnapshot(
        activeCount: 4,
        topDownload: WidgetDataFetcher.WidgetActiveDownloadSnapshot(
            name: "Foundation S03E02 2160p",
            progress: 0.64,
            dlspeed: 4_718_592,
            etaText: "18m",
            state: "Downloading"
        ),
        serverName: "Trawl Server",
        errorMessage: nil
    )

    static func activeDownloadsUnavailable(_ message: String) -> WidgetDataFetcher.WidgetActiveDownloadsSnapshot {
        WidgetDataFetcher.WidgetActiveDownloadsSnapshot(
            activeCount: 0,
            topDownload: nil,
            serverName: message,
            errorMessage: message
        )
    }
}

#Preview(as: .systemSmall) {
    ActiveDownloadsWidget()
} timeline: {
    ActiveDownloadsEntry.placeholder
    ActiveDownloadsEntry(date: .now, snapshot: .activeDownloadsUnavailable("Unavailable"))
}

#Preview(as: .systemMedium) {
    ActiveDownloadsWidget()
} timeline: {
    ActiveDownloadsEntry.placeholder
}

#Preview(as: .accessoryCircular) {
    ActiveDownloadsWidget()
} timeline: {
    ActiveDownloadsEntry.placeholder
    ActiveDownloadsEntry(date: .now, snapshot: .activeDownloadsUnavailable("Unavailable"))
}
