import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline Entry

struct CalendarEntry: TimelineEntry {
    let date: Date
    let events: [WidgetCalendarEvent]
    var errorMessage: String? = nil

    var isUnavailable: Bool { errorMessage != nil }

    var relevance: TimelineEntryRelevance? {
        let todayHasEvent = events.contains { Calendar.current.isDateInToday($0.date) }
        return TimelineEntryRelevance(
            score: todayHasEvent ? 10 : 3,
            duration: todayHasEvent ? 86_400 : 0
        )
    }

    static let placeholder = CalendarEntry(
        date: .now,
        events: [
            WidgetCalendarEvent(
                id: "placeholder-1",
                date: .now,
                title: "Breaking Bad",
                subtitle: "S05E14",
                posterURL: nil,
                placeholderIcon: "tv",
                accentColorName: "purple",
                badgeLabel: nil,
                isDownloaded: false
            ),
            WidgetCalendarEvent(
                id: "placeholder-2",
                date: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now,
                title: "Inception",
                subtitle: "2010",
                posterURL: nil,
                placeholderIcon: "film",
                accentColorName: "blue",
                badgeLabel: "Digital",
                isDownloaded: false
            ),
            WidgetCalendarEvent(
                id: "placeholder-3",
                date: Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now,
                title: "The Last of Us",
                subtitle: "S02E03",
                posterURL: nil,
                placeholderIcon: "tv",
                accentColorName: "purple",
                badgeLabel: nil,
                isDownloaded: true
            ),
        ]
    )

    static let empty = CalendarEntry(date: .now, events: [])

    static func unavailable(_ message: String) -> CalendarEntry {
        CalendarEntry(date: .now, events: [], errorMessage: message)
    }
}

/// Maps a fetch error to a short, honest widget message.
private func calendarUnavailableMessage(for error: Error) -> String {
    WidgetTimelinePolicy.calendarUnavailableMessage(for: error)
}

// MARK: - Provider

struct CalendarProvider: AppIntentTimelineProvider {
    typealias Entry = CalendarEntry
    typealias Intent = SelectCalendarScopeIntent

    func placeholder(in context: Context) -> CalendarEntry {
        .placeholder
    }

    func snapshot(for configuration: SelectCalendarScopeIntent, in context: Context) async -> CalendarEntry {
        if context.isPreview { return .placeholder }
        return await fetchEntry(scope: configuration.scope)
    }

    func timeline(for configuration: SelectCalendarScopeIntent, in context: Context) async -> Timeline<CalendarEntry> {
        do {
            let allEvents = try await WidgetDataFetcher.fetchUpcomingReleases(
                days: 14,
                includeUnmonitored: configuration.scope.includeUnmonitored
            )
            let entries = buildEntries(from: allEvents)
            // The small tile prints a countdown rather than a list, so it needs a
            // tighter cadence than the list families as the next release nears.
            let interval: TimeInterval
            if context.family == .systemSmall {
                interval = WidgetTimelinePolicy.calendarCountdownRefreshInterval(
                    secondsUntilNextRelease: allEvents.first?.date.timeIntervalSinceNow
                )
            } else {
                interval = WidgetTimelinePolicy.calendarRefreshInterval(
                    hasEntries: !entries.isEmpty,
                    isFailure: false
                )
            }
            let nextUpdate = Date.now.addingTimeInterval(interval)
            return Timeline(entries: entries.isEmpty ? [.empty] : entries, policy: .after(nextUpdate))
        } catch {
            let nextUpdate = Date.now.addingTimeInterval(
                WidgetTimelinePolicy.calendarRefreshInterval(hasEntries: false, isFailure: true)
            )
            return Timeline(entries: [.unavailable(calendarUnavailableMessage(for: error))], policy: .after(nextUpdate))
        }
    }

    private func fetchEntry(scope: CalendarScopeOption) async -> CalendarEntry {
        do {
            let events = try await WidgetDataFetcher.fetchUpcomingReleases(
                days: 14,
                includeUnmonitored: scope.includeUnmonitored
            )
            return CalendarEntry(date: .now, events: events)
        } catch {
            return .unavailable(calendarUnavailableMessage(for: error))
        }
    }

    /// Creates one entry per unique calendar day. Each entry carries events from
    /// that day forward so the widget advances automatically without re-fetching.
    private func buildEntries(from events: [WidgetCalendarEvent]) -> [CalendarEntry] {
        WidgetTimelinePolicy.calendarSlices(from: events).map {
            CalendarEntry(date: $0.date, events: $0.events)
        }
    }
}

// MARK: - Views

struct CalendarWidgetEntryView: View {
    var entry: CalendarEntry
    @Environment(\.widgetFamily) private var family

    private var maxEvents: Int { family == .systemLarge ? 7 : 3 }
    private var posterWidth: CGFloat { family == .systemLarge ? 28 : 24 }
    private var posterHeight: CGFloat { family == .systemLarge ? 42 : 36 }

    var body: some View {
        if entry.isUnavailable {
            unavailableView
        } else if entry.events.isEmpty {
            emptyView
        } else if family == .systemSmall {
            nextReleaseView
        } else {
            eventList
        }
    }

    /// Small family: the single next release plus how long until it lands. Reuses
    /// the snapshot the provider already fetched - no extra networking.
    @ViewBuilder
    private var nextReleaseView: some View {
        if let next = entry.events.first {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                    Text("Next Up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if next.isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.bottom, 8)

                HStack(alignment: .top, spacing: 8) {
                    posterThumbnail(next)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        if let subtitle = next.subtitle {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 6)

                Text(WidgetGlanceFormatter.releaseCountdown(to: next.date))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(accentColor(for: next.accentColorName))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(next.date, style: .date)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.regularMaterial, for: .widget)
            .widgetURL(CalendarWidget.trawlCalendarURL)
        } else {
            emptyView
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No Upcoming Releases")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.regularMaterial, for: .widget)
    }

    private var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(entry.errorMessage ?? "Unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Open Trawl to set up")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(URL(string: "trawl://calendar"))
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                Text("Upcoming")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)

            ForEach(Array(entry.events.prefix(maxEvents).enumerated()), id: \.element.id) { index, event in
                let isLast = index == min(maxEvents, entry.events.count) - 1
                eventRow(event, isLast: isLast)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(CalendarWidget.trawlCalendarURL)
    }

    @ViewBuilder
    private func eventRow(_ event: WidgetCalendarEvent, isLast: Bool) -> some View {
        Link(destination: CalendarWidget.trawlCalendarURL) {
            HStack(spacing: 10) {
                posterThumbnail(event)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let badge = event.badgeLabel {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(accentColor(for: event.accentColorName).opacity(0.15))
                                .foregroundStyle(accentColor(for: event.accentColorName))
                                .clipShape(Capsule())
                        }
                        Spacer(minLength: 0)
                        if event.isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                    }

                    HStack(spacing: 4) {
                        if let subtitle = event.subtitle {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(event.date, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 5)
        }

        if !isLast {
            Divider()
        }
    }

    @ViewBuilder
    private func posterThumbnail(_ event: WidgetCalendarEvent) -> some View {
        Group {
            if let path = event.posterLocalPath, let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderPoster(event)
            }
        }
        .frame(width: posterWidth, height: posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func placeholderPoster(_ event: WidgetCalendarEvent) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(accentColor(for: event.accentColorName).opacity(0.12))
            Image(systemName: event.placeholderIcon)
                .font(.system(size: 12))
                .foregroundStyle(accentColor(for: event.accentColorName))
        }
    }

    private func accentColor(for name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "blue":   return .blue
        case "indigo": return .indigo
        case "orange": return .orange
        default:       return .accentColor
        }
    }
}

// MARK: - Widget

struct CalendarWidget: Widget {
    let kind = "com.poole.james.Trawl.CalendarWidget"

    static let trawlCalendarURL = URL(string: "trawl://calendar")!

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectCalendarScopeIntent.self,
            provider: CalendarProvider()
        ) { entry in
            CalendarWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Upcoming Releases")
        .description("Upcoming Sonarr episodes and Radarr movie releases.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    CalendarWidget()
} timeline: {
    CalendarEntry.placeholder
    CalendarEntry.empty
    CalendarEntry.unavailable("No Sonarr or Radarr")
}

#Preview(as: .systemLarge) {
    CalendarWidget()
} timeline: {
    CalendarEntry.placeholder
}

#Preview(as: .systemSmall) {
    CalendarWidget()
} timeline: {
    CalendarEntry.placeholder
    CalendarEntry.empty
    CalendarEntry.unavailable("No Sonarr or Radarr")
}
