import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct SeerrInboxEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetDataFetcher.WidgetSeerrInboxSnapshot

    var relevance: TimelineEntryRelevance? {
        let score: Float
        if snapshot.totalPending > 0 {
            score = 12
        } else if snapshot.totalOpenIssues > 0 {
            score = 9
        } else {
            score = 1
        }
        return TimelineEntryRelevance(score: score)
    }

    static let placeholder = SeerrInboxEntry(date: .now, snapshot: .inboxPlaceholder)
    static let noConfig = SeerrInboxEntry(date: .now, snapshot: .inboxUnavailable("No Seerr"))
}

// MARK: - Provider

struct SeerrInboxProvider: AppIntentTimelineProvider {
    typealias Entry = SeerrInboxEntry
    typealias Intent = SelectSeerrServerIntent

    func placeholder(in context: Context) -> SeerrInboxEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectSeerrServerIntent, in context: Context) async -> SeerrInboxEntry {
        if context.isPreview { return .placeholder }
        return await fetchEntry(serverID: configuration.server?.id)
    }

    func timeline(for configuration: SelectSeerrServerIntent, in context: Context) async -> Timeline<SeerrInboxEntry> {
        let entry = await fetchEntry(serverID: configuration.server?.id)
        let interval = WidgetTimelinePolicy.seerrInboxRefreshInterval(
            pendingCount: entry.snapshot.totalPending,
            openIssueCount: entry.snapshot.totalOpenIssues
        )
        return Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: interval)))
    }

    private func fetchEntry(serverID: String?) async -> SeerrInboxEntry {
        do {
            let snapshot = try await WidgetDataFetcher.fetchSeerrInbox(profileID: serverID)
            return SeerrInboxEntry(date: .now, snapshot: snapshot)
        } catch {
            return .noConfig
        }
    }
}

// MARK: - Views

struct SeerrInboxWidgetEntryView: View {
    let entry: SeerrInboxEntry
    @Environment(\.widgetFamily) private var family

    private var pendingCount: Int { entry.snapshot.totalPending }
    private var issueCount: Int { entry.snapshot.totalOpenIssues }
    private var isUnavailable: Bool { entry.snapshot.errorMessage != nil }

    private var primaryURL: URL {
        URL(string: WidgetGlanceFormatter.seerrInboxDestination(
            pendingCount: pendingCount,
            openIssueCount: issueCount
        ).rawValue)!
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircularLayout
        case .accessoryInline:
            accessoryInlineLayout
        case .systemMedium:
            mediumLayout
        default:
            smallLayout
        }
    }

    // MARK: Small

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetHeader

            Spacer(minLength: 2)

            countRow(
                icon: "clock.badge.exclamationmark",
                tint: .orange,
                count: pendingCount,
                label: pendingCount == 1 ? "Request" : "Requests"
            )

            Divider()

            countRow(
                icon: "exclamationmark.bubble.fill",
                tint: .red,
                count: issueCount,
                label: issueCount == 1 ? "Issue" : "Issues"
            )

            Spacer(minLength: 2)

            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(primaryURL)
    }

    // MARK: Medium

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            widgetHeader

            HStack(spacing: 12) {
                inboxColumn(
                    destination: SeerrInboxWidget.trawlRequestsURL,
                    icon: "clock.badge.exclamationmark",
                    tint: .orange,
                    count: pendingCount,
                    title: pendingCount == 1 ? "Pending Request" : "Pending Requests",
                    item: entry.snapshot.topRequest,
                    emptyLabel: "All caught up"
                )

                Divider()

                inboxColumn(
                    destination: SeerrInboxWidget.trawlIssuesURL,
                    icon: "exclamationmark.bubble.fill",
                    tint: .red,
                    count: issueCount,
                    title: issueCount == 1 ? "Open Issue" : "Open Issues",
                    item: entry.snapshot.topIssue,
                    emptyLabel: "No open issues"
                )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(primaryURL)
    }

    // MARK: Accessories

    private var accessoryCircularLayout: some View {
        Gauge(
            value: WidgetGlanceFormatter.countGaugeFraction(
                count: pendingCount + issueCount,
                ceiling: WidgetGlanceFormatter.activeDownloadsGaugeCeiling
            )
        ) {
            Image(systemName: "tray.full")
        } currentValueLabel: {
            Text(isUnavailable ? "--" : "\(pendingCount + issueCount)")
                .monospacedDigit()
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(primaryURL)
    }

    private var accessoryInlineLayout: some View {
        Label(
            WidgetGlanceFormatter.seerrInboxInlineText(
                pendingCount: pendingCount,
                openIssueCount: issueCount,
                isUnavailable: isUnavailable
            ),
            systemImage: inlineSymbol
        )
        .widgetURL(primaryURL)
    }

    private var inlineSymbol: String {
        if isUnavailable { return "wifi.exclamationmark" }
        if pendingCount > 0 { return "clock.badge.exclamationmark" }
        if issueCount > 0 { return "exclamationmark.bubble" }
        return "checkmark.circle"
    }

    // MARK: Pieces

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.pink)
            Text("Seerr Inbox")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if pendingCount > 0 || issueCount > 0 {
                Circle()
                    .fill(pendingCount > 0 ? .orange : .red)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private func countRow(icon: String, tint: Color, count: Int, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(count > 0 ? tint : .secondary)
            Text(isUnavailable ? "--" : "\(count)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(count > 0 ? tint : .secondary)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func inboxColumn(
        destination: URL,
        icon: String,
        tint: Color,
        count: Int,
        title: String,
        item: WidgetDataFetcher.WidgetSeerrItemSnapshot?,
        emptyLabel: String
    ) -> some View {
        Link(destination: destination) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: isUnavailable ? "wifi.exclamationmark" : icon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(count > 0 ? tint : .secondary)
                    Text(isUnavailable ? "--" : "\(count)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(count > 0 ? tint : .secondary)
                }

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let item {
                    Text(item.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(detailLine(for: item))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(isUnavailable ? (entry.snapshot.errorMessage ?? "Unavailable") : emptyLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerText: String {
        if isUnavailable { return entry.snapshot.errorMessage ?? "Unavailable" }
        if let top = entry.snapshot.topRequest ?? entry.snapshot.topIssue { return top.title }
        return entry.snapshot.serverLabel
    }

    private func detailLine(for item: WidgetDataFetcher.WidgetSeerrItemSnapshot) -> String {
        var parts = [item.kindLabel]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        if entry.snapshot.checkedServerCount > 1 { parts.append(item.serverName) }
        return parts.joined(separator: " - ")
    }
}

// MARK: - Widget

struct SeerrInboxWidget: Widget {
    let kind = "com.poole.james.Trawl.SeerrInboxWidget"

    static let trawlRequestsURL = URL(string: WidgetGlanceFormatter.SeerrInboxDestination.requests.rawValue)!
    static let trawlIssuesURL = URL(string: WidgetGlanceFormatter.SeerrInboxDestination.issues.rawValue)!

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectSeerrServerIntent.self,
            provider: SeerrInboxProvider()
        ) { entry in
            SeerrInboxWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Seerr Inbox")
        .description("Pending Seerr requests and open issues in one tile.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview Data

private extension WidgetDataFetcher.WidgetSeerrInboxSnapshot {
    static let inboxPlaceholder = WidgetDataFetcher.WidgetSeerrInboxSnapshot(
        totalPending: 3,
        totalOpenIssues: 2,
        topRequest: WidgetDataFetcher.WidgetSeerrItemSnapshot(
            title: "Severance",
            subtitle: "by Alex",
            kindLabel: "Series",
            serverName: "Home Seerr",
            createdAt: .now.addingTimeInterval(-1800)
        ),
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

    static func inboxUnavailable(_ message: String) -> WidgetDataFetcher.WidgetSeerrInboxSnapshot {
        WidgetDataFetcher.WidgetSeerrInboxSnapshot(
            totalPending: 0,
            totalOpenIssues: 0,
            topRequest: nil,
            topIssue: nil,
            serverLabel: message,
            checkedServerCount: 0,
            errorMessage: message
        )
    }
}

#Preview(as: .systemSmall) {
    SeerrInboxWidget()
} timeline: {
    SeerrInboxEntry.placeholder
    SeerrInboxEntry(date: .now, snapshot: .inboxUnavailable("Unavailable"))
}

#Preview(as: .systemMedium) {
    SeerrInboxWidget()
} timeline: {
    SeerrInboxEntry.placeholder
}

#Preview(as: .accessoryCircular) {
    SeerrInboxWidget()
} timeline: {
    SeerrInboxEntry.placeholder
}

#Preview(as: .accessoryInline) {
    SeerrInboxWidget()
} timeline: {
    SeerrInboxEntry.placeholder
}
