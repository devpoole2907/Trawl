import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct SeerrPendingRequestsEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetDataFetcher.WidgetSeerrPendingSnapshot

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: snapshot.totalPending > 0 ? 12 : 1)
    }

    static let placeholder = SeerrPendingRequestsEntry(date: .now, snapshot: .pendingPlaceholder)
    static let noConfig = SeerrPendingRequestsEntry(date: .now, snapshot: .pendingUnavailable("No Seerr"))
}

// MARK: - Provider

struct SeerrPendingRequestsProvider: AppIntentTimelineProvider {
    typealias Entry = SeerrPendingRequestsEntry
    typealias Intent = SelectSeerrServerIntent

    func placeholder(in context: Context) -> SeerrPendingRequestsEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectSeerrServerIntent, in context: Context) async -> SeerrPendingRequestsEntry {
        if context.isPreview { return .placeholder }
        return await fetchEntry(serverID: configuration.server?.id)
    }

    func timeline(for configuration: SelectSeerrServerIntent, in context: Context) async -> Timeline<SeerrPendingRequestsEntry> {
        let entry = await fetchEntry(serverID: configuration.server?.id)
        let interval: TimeInterval = entry.snapshot.totalPending > 0 ? 10 * 60 : 30 * 60
        return Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: interval)))
    }

    private func fetchEntry(serverID: String?) async -> SeerrPendingRequestsEntry {
        do {
            let snapshot = try await WidgetDataFetcher.fetchSeerrPendingRequests(profileID: serverID)
            return SeerrPendingRequestsEntry(date: .now, snapshot: snapshot)
        } catch {
            return .noConfig
        }
    }
}

// MARK: - Views

struct SeerrPendingRequestsWidgetEntryView: View {
    let entry: SeerrPendingRequestsEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.snapshot.totalPending }
    private var isUnavailable: Bool { entry.snapshot.errorMessage != nil }

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

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetHeader

            Spacer(minLength: 4)

            Text(isUnavailable ? "--" : "\(count)")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(count > 0 ? .orange : .secondary)

            Text(count == 1 ? "Pending Request" : "Pending Requests")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            footerText
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(SeerrPendingRequestsWidget.trawlRequestsURL)
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
                    .foregroundStyle(count > 0 ? .orange : .secondary)
                Text(entry.snapshot.serverLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let top = entry.snapshot.topRequest {
                    Text("Next Approval")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(top.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(detailLine(for: top))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Image(systemName: isUnavailable ? "wifi.exclamationmark" : "checkmark.circle.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isUnavailable ? .orange : .green)
                    Text(isUnavailable ? "Unavailable" : "No pending requests")
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(SeerrPendingRequestsWidget.trawlRequestsURL)
    }

    private var accessoryCircularLayout: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: isUnavailable ? "wifi.exclamationmark" : "clock.badge.exclamationmark")
                    .font(.caption.weight(.semibold))
                Text(isUnavailable ? "--" : "\(count)")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("REQ")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .widgetURL(SeerrPendingRequestsWidget.trawlRequestsURL)
    }

    private var accessoryInlineLayout: some View {
        Label(accessoryInlineText, systemImage: isUnavailable ? "wifi.exclamationmark" : (count > 0 ? "clock.badge.exclamationmark" : "checkmark.circle"))
            .widgetURL(SeerrPendingRequestsWidget.trawlRequestsURL)
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.pink)
            Text("Seerr")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if count > 0 {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
            }
        }
    }

    private var footerText: some View {
        Group {
            if let top = entry.snapshot.topRequest {
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
                Text(isUnavailable ? (entry.snapshot.errorMessage ?? "Unavailable") : "All caught up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var accessoryInlineText: String {
        if isUnavailable { return "Seerr unavailable" }
        if count == 1 { return "1 pending Seerr request" }
        return "\(count) pending Seerr requests"
    }

    private func detailLine(for item: WidgetDataFetcher.WidgetSeerrItemSnapshot) -> String {
        var parts = [item.kindLabel]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        if entry.snapshot.checkedServerCount > 1 { parts.append(item.serverName) }
        return parts.joined(separator: " - ")
    }
}

// MARK: - Widget

struct SeerrPendingRequestsWidget: Widget {
    let kind = "com.poole.james.Trawl.SeerrPendingRequestsWidget"

    static let trawlRequestsURL = URL(string: "trawl://seerr-requests")!

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectSeerrServerIntent.self,
            provider: SeerrPendingRequestsProvider()
        ) { entry in
            SeerrPendingRequestsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Seerr Pending Requests")
        .description("Requests waiting for approval.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview Data

private extension WidgetDataFetcher.WidgetSeerrPendingSnapshot {
    static let pendingPlaceholder = WidgetDataFetcher.WidgetSeerrPendingSnapshot(
        totalPending: 3,
        topRequest: WidgetDataFetcher.WidgetSeerrItemSnapshot(
            title: "Severance",
            subtitle: "by Alex",
            kindLabel: "Series",
            serverName: "Home Seerr",
            createdAt: .now.addingTimeInterval(-1800)
        ),
        serverLabel: "Home Seerr",
        checkedServerCount: 1,
        errorMessage: nil
    )

    static func pendingUnavailable(_ message: String) -> WidgetDataFetcher.WidgetSeerrPendingSnapshot {
        WidgetDataFetcher.WidgetSeerrPendingSnapshot(
            totalPending: 0,
            topRequest: nil,
            serverLabel: message,
            checkedServerCount: 0,
            errorMessage: message
        )
    }
}

#Preview(as: .systemSmall) {
    SeerrPendingRequestsWidget()
} timeline: {
    SeerrPendingRequestsEntry.placeholder
    SeerrPendingRequestsEntry(date: .now, snapshot: .pendingUnavailable("Unavailable"))
}

#Preview(as: .systemMedium) {
    SeerrPendingRequestsWidget()
} timeline: {
    SeerrPendingRequestsEntry.placeholder
}

#Preview(as: .accessoryCircular) {
    SeerrPendingRequestsWidget()
} timeline: {
    SeerrPendingRequestsEntry.placeholder
}

#Preview(as: .accessoryInline) {
    SeerrPendingRequestsWidget()
} timeline: {
    SeerrPendingRequestsEntry.placeholder
}
