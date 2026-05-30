import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct SeerrOpenIssuesEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetDataFetcher.WidgetSeerrIssuesSnapshot

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: snapshot.totalOpen > 0 ? 9 : 1)
    }

    static let placeholder = SeerrOpenIssuesEntry(date: .now, snapshot: .issuesPlaceholder)
    static let noConfig = SeerrOpenIssuesEntry(date: .now, snapshot: .issuesUnavailable("No Seerr"))
}

// MARK: - Provider

struct SeerrOpenIssuesProvider: TimelineProvider {
    func placeholder(in context: Context) -> SeerrOpenIssuesEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SeerrOpenIssuesEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }

        Task {
            completion(await fetchEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SeerrOpenIssuesEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let interval: TimeInterval = entry.snapshot.totalOpen > 0 ? 15 * 60 : 45 * 60
            completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: interval))))
        }
    }

    private func fetchEntry() async -> SeerrOpenIssuesEntry {
        do {
            let snapshot = try await WidgetDataFetcher.fetchSeerrOpenIssues()
            return SeerrOpenIssuesEntry(date: .now, snapshot: snapshot)
        } catch {
            return .noConfig
        }
    }
}

// MARK: - Views

struct SeerrOpenIssuesWidgetEntryView: View {
    let entry: SeerrOpenIssuesEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.snapshot.totalOpen }
    private var isUnavailable: Bool { entry.snapshot.errorMessage != nil }

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircularLayout
        default:
            smallLayout
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Seerr Issues")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 4)

            Text(isUnavailable ? "--" : "\(count)")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(count > 0 ? .orange : .secondary)

            Text(count == 1 ? "Open Issue" : "Open Issues")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let top = entry.snapshot.topIssue {
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(detailLine(for: top))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(isUnavailable ? (entry.snapshot.errorMessage ?? "Unavailable") : "No open issues")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(SeerrOpenIssuesWidget.trawlIssuesURL)
    }

    private var accessoryCircularLayout: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: isUnavailable ? "wifi.exclamationmark" : "exclamationmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                Text(isUnavailable ? "--" : "\(count)")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("ISS")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .widgetURL(SeerrOpenIssuesWidget.trawlIssuesURL)
    }

    private func detailLine(for item: WidgetDataFetcher.WidgetSeerrItemSnapshot) -> String {
        var parts = [item.kindLabel]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        if entry.snapshot.checkedServerCount > 1 { parts.append(item.serverName) }
        return parts.joined(separator: " - ")
    }
}

// MARK: - Widget

struct SeerrOpenIssuesWidget: Widget {
    let kind = "com.poole.james.Trawl.SeerrOpenIssuesWidget"

    static let trawlIssuesURL = URL(string: "trawl://seerr-issue")!

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SeerrOpenIssuesProvider()) { entry in
            SeerrOpenIssuesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Seerr Open Issues")
        .description("Open Seerr issues needing review.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview Data

private extension WidgetDataFetcher.WidgetSeerrIssuesSnapshot {
    static let issuesPlaceholder = WidgetDataFetcher.WidgetSeerrIssuesSnapshot(
        totalOpen: 2,
        topIssue: WidgetDataFetcher.WidgetSeerrItemSnapshot(
            title: "Dune: Part Two",
            subtitle: "by Jamie",
            kindLabel: "Audio",
            serverName: "Home Seerr",
            createdAt: .now.addingTimeInterval(-5400)
        ),
        serverLabel: "Home Seerr",
        checkedServerCount: 1,
        errorMessage: nil
    )

    static func issuesUnavailable(_ message: String) -> WidgetDataFetcher.WidgetSeerrIssuesSnapshot {
        WidgetDataFetcher.WidgetSeerrIssuesSnapshot(
            totalOpen: 0,
            topIssue: nil,
            serverLabel: message,
            checkedServerCount: 0,
            errorMessage: message
        )
    }
}

#Preview(as: .systemSmall) {
    SeerrOpenIssuesWidget()
} timeline: {
    SeerrOpenIssuesEntry.placeholder
    SeerrOpenIssuesEntry(date: .now, snapshot: .issuesUnavailable("Unavailable"))
}

#Preview(as: .accessoryCircular) {
    SeerrOpenIssuesWidget()
} timeline: {
    SeerrOpenIssuesEntry.placeholder
}
