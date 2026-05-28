import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct ActiveTorrentsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetDataFetcher.WidgetActiveTorrentsSnapshot

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: snapshot.activeCount > 0 ? 8 : 1)
    }

    static let placeholder = ActiveTorrentsEntry(date: .now, snapshot: .activeTorrentsPlaceholder)
    static let noConfig = ActiveTorrentsEntry(date: .now, snapshot: .activeTorrentsUnavailable("No Server"))
}

// MARK: - Provider

struct ActiveTorrentsProvider: AppIntentTimelineProvider {
    typealias Entry = ActiveTorrentsEntry
    typealias Intent = SelectServerIntent

    func placeholder(in context: Context) -> ActiveTorrentsEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectServerIntent, in context: Context) async -> ActiveTorrentsEntry {
        if context.isPreview { return .placeholder }
        return await fetchEntry(serverID: configuration.server?.id)
    }

    func timeline(for configuration: SelectServerIntent, in context: Context) async -> Timeline<ActiveTorrentsEntry> {
        let entry = await fetchEntry(serverID: configuration.server?.id)
        let interval: TimeInterval = entry.snapshot.activeCount > 0 ? 5 * 60 : 30 * 60
        return Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: interval)))
    }

    private func fetchEntry(serverID: String?) async -> ActiveTorrentsEntry {
        do {
            let snapshot = try await WidgetDataFetcher.fetchActiveTorrents(serverID: serverID)
            return ActiveTorrentsEntry(date: .now, snapshot: snapshot)
        } catch {
            return .noConfig
        }
    }
}

// MARK: - Views

struct ActiveTorrentsWidgetEntryView: View {
    let entry: ActiveTorrentsEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.snapshot.activeCount }
    private var isUnavailable: Bool { entry.snapshot.errorMessage != nil }

    var body: some View {
        switch family {
        case .systemMedium:
            mediumLayout
        default:
            smallLayout
        }
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

            Text(count == 1 ? "Active Torrent" : "Active Torrents")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let top = entry.snapshot.topTorrent {
                topTorrentFooter(top)
            } else {
                Text(isUnavailable ? (entry.snapshot.errorMessage ?? "Unavailable") : "Idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(ActiveTorrentsWidget.trawlTorrentsURL)
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
                if let top = entry.snapshot.topTorrent {
                    Text("Top Torrent")
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
                    Text(isUnavailable ? "Unavailable" : "No active torrents")
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(ActiveTorrentsWidget.trawlTorrentsURL)
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: count > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(count > 0 ? .blue : .secondary)
            Text("Torrents")
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

    private func topTorrentFooter(_ torrent: WidgetDataFetcher.WidgetActiveTorrentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(torrent.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            ProgressView(value: torrent.progress)
                .tint(.blue)
            Text(ByteFormatter.formatSpeed(bytesPerSecond: torrent.dlspeed))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.blue)
                .lineLimit(1)
        }
    }
}

// MARK: - Widget

struct ActiveTorrentsWidget: Widget {
    let kind = "com.poole.james.Trawl.ActiveTorrentsWidget"

    static let trawlTorrentsURL = URL(string: "trawl://torrents")!

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectServerIntent.self,
            provider: ActiveTorrentsProvider()
        ) { entry in
            ActiveTorrentsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Active Torrents")
        .description("Active qBittorrent downloads and top progress.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview Data

private extension WidgetDataFetcher.WidgetActiveTorrentsSnapshot {
    static let activeTorrentsPlaceholder = WidgetDataFetcher.WidgetActiveTorrentsSnapshot(
        activeCount: 4,
        topTorrent: WidgetDataFetcher.WidgetActiveTorrentSnapshot(
            name: "Foundation S03E02 2160p",
            progress: 0.64,
            dlspeed: 4_718_592,
            etaText: "18m",
            state: "Downloading"
        ),
        serverName: "Trawl Server",
        errorMessage: nil
    )

    static func activeTorrentsUnavailable(_ message: String) -> WidgetDataFetcher.WidgetActiveTorrentsSnapshot {
        WidgetDataFetcher.WidgetActiveTorrentsSnapshot(
            activeCount: 0,
            topTorrent: nil,
            serverName: message,
            errorMessage: message
        )
    }
}

#Preview(as: .systemSmall) {
    ActiveTorrentsWidget()
} timeline: {
    ActiveTorrentsEntry.placeholder
    ActiveTorrentsEntry(date: .now, snapshot: .activeTorrentsUnavailable("Unavailable"))
}

#Preview(as: .systemMedium) {
    ActiveTorrentsWidget()
} timeline: {
    ActiveTorrentsEntry.placeholder
}
