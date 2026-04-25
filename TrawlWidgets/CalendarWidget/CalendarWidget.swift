import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct CalendarEntry: TimelineEntry {
    let date: Date
    let events: [WidgetCalendarEvent]

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
}

// MARK: - Provider

struct CalendarProvider: TimelineProvider {
    typealias Entry = CalendarEntry

    func placeholder(in context: Context) -> CalendarEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        Task {
            let entry = await fetchEntry()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        Task {
            do {
                let allEvents = try await WidgetDataFetcher.fetchUpcomingReleases(days: 14)
                let entries = buildEntries(from: allEvents)
                let nextUpdate: Date
                if entries.isEmpty {
                    nextUpdate = Calendar.current.date(byAdding: .hour, value: 6, to: .now) ?? .now
                } else {
                    nextUpdate = Calendar.current.date(byAdding: .hour, value: 5, to: .now) ?? .now
                }
                completion(Timeline(entries: entries.isEmpty ? [.empty] : entries, policy: .after(nextUpdate)))
            } catch {
                let nextUpdate = Calendar.current.date(byAdding: .hour, value: 12, to: .now) ?? .now
                completion(Timeline(entries: [.empty], policy: .after(nextUpdate)))
            }
        }
    }

    private func fetchEntry() async -> CalendarEntry {
        do {
            let events = try await WidgetDataFetcher.fetchUpcomingReleases(days: 14)
            return CalendarEntry(date: .now, events: events)
        } catch {
            return .empty
        }
    }

    /// Creates one entry per unique calendar day. Each entry carries events from
    /// that day forward so the widget advances automatically without re-fetching.
    private func buildEntries(from events: [WidgetCalendarEvent]) -> [CalendarEntry] {
        guard !events.isEmpty else { return [] }
        let cal = Calendar.current
        let now = Date.now
        let dayStarts = Set(events.map { cal.startOfDay(for: $0.date) }).sorted()

        // Build per-day entries
        let perDayEntries = dayStarts.map { dayStart in
            let remaining = events.filter { $0.date >= dayStart }
            return CalendarEntry(date: dayStart, events: remaining)
        }

        // Ensure we have an entry at or before now to avoid timeline gaps
        if dayStarts.isEmpty || dayStarts.first! > cal.startOfDay(for: now) {
            // Prepend an entry at now with future events
            let nowEntry = CalendarEntry(date: now, events: events.filter { $0.date >= now })
            return [nowEntry] + perDayEntries
        }

        return perDayEntries
    }
}

// MARK: - Views

struct CalendarWidgetEntryView: View {
    var entry: CalendarEntry
    @Environment(\.widgetFamily) private var family

    private var maxEvents: Int { family == .systemLarge ? 7 : 3 }

    var body: some View {
        if entry.events.isEmpty {
            emptyView
        } else {
            eventList
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

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "app.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                    .frame(width: 20, height: 20)
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
        let destination = CalendarWidget.trawlCalendarURL
        Link(destination: destination) {
            HStack(spacing: family == .systemLarge ? 10 : 8) {
                if family == .systemLarge {
                    posterThumbnail(event)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(accentColor(for: event.accentColorName))
                            .frame(width: 6, height: 6)
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let badge = event.badgeLabel {
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(accentColor(for: event.accentColorName).opacity(0.15))
                                .foregroundStyle(accentColor(for: event.accentColorName))
                                .clipShape(Capsule())
                        }
                        Spacer(minLength: 0)
                        if event.isDownloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green.opacity(0.8))
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
            if let url = event.posterURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholderPoster(event)
                    }
                }
            } else {
                placeholderPoster(event)
            }
        }
        .frame(width: 28, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func placeholderPoster(_ event: WidgetCalendarEvent) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(accentColor(for: event.accentColorName).opacity(0.15))
            .overlay {
                Image(systemName: event.placeholderIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor(for: event.accentColorName).opacity(0.6))
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
        StaticConfiguration(kind: kind, provider: CalendarProvider()) { entry in
            CalendarWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Upcoming Releases")
        .description("Upcoming Sonarr episodes and Radarr movie releases.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    CalendarWidget()
} timeline: {
    CalendarEntry.placeholder
    CalendarEntry.empty
}

#Preview(as: .systemLarge) {
    CalendarWidget()
} timeline: {
    CalendarEntry.placeholder
}
