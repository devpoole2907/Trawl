import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct LibraryHealthEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetDataFetcher.WidgetLibraryHealthSnapshot

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: snapshot.totalIssueCount > 0 ? 10 : 1)
    }

    static let placeholder = LibraryHealthEntry(date: .now, snapshot: .healthPlaceholder)
    static let noConfig = LibraryHealthEntry(date: .now, snapshot: .healthUnavailable("No Arr Services"))
}

// MARK: - Provider

struct LibraryHealthProvider: TimelineProvider {
    func placeholder(in context: Context) -> LibraryHealthEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (LibraryHealthEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }

        Task {
            completion(await fetchEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryHealthEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let interval: TimeInterval = entry.snapshot.totalIssueCount > 0 ? 15 * 60 : 60 * 60
            completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: interval))))
        }
    }

    private func fetchEntry() async -> LibraryHealthEntry {
        do {
            let snapshot = try await WidgetDataFetcher.fetchLibraryHealth()
            return LibraryHealthEntry(date: .now, snapshot: snapshot)
        } catch {
            return .noConfig
        }
    }
}

// MARK: - Views

struct LibraryHealthWidgetEntryView: View {
    let entry: LibraryHealthEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int { entry.snapshot.totalIssueCount }
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
                .foregroundStyle(count > 0 ? severityColor(entry.snapshot.worstOffender?.severity) : .secondary)

            Text(count == 1 ? "Library Issue" : "Library Issues")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let offender = entry.snapshot.worstOffender {
                offenderFooter(offender)
            } else {
                Text(isUnavailable ? (entry.snapshot.errorMessage ?? "Unavailable") : "No warnings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(LibraryHealthWidget.trawlHealthURL)
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
                    .foregroundStyle(count > 0 ? severityColor(entry.snapshot.worstOffender?.severity) : .secondary)
                HStack(spacing: 8) {
                    metricLabel("Health", value: entry.snapshot.healthIssueCount)
                    metricLabel("Queue", value: entry.snapshot.queueIssueCount)
                }
            }
            .frame(width: 128, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                if let offender = entry.snapshot.worstOffender {
                    Text("Worst Offender")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(offender.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(offender.serviceName) - \(offender.detail)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    Image(systemName: isUnavailable ? "wifi.exclamationmark" : "checkmark.circle.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(isUnavailable ? .orange : .green)
                    Text(isUnavailable ? "Unavailable" : "No health warnings")
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }

                if !entry.snapshot.services.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(entry.snapshot.services.prefix(3))) { service in
                            servicePill(service)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .containerBackground(.regularMaterial, for: .widget)
        .widgetURL(LibraryHealthWidget.trawlHealthURL)
    }

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: count > 0 ? "heart.text.square.fill" : "heart.text.square")
                .font(.caption.weight(.semibold))
                .foregroundStyle(count > 0 ? .orange : .green)
            Text("Library Health")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    private func metricLabel(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("\(value)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? .orange : .secondary)
        }
    }

    private func offenderFooter(_ offender: WidgetDataFetcher.WidgetLibraryHealthOffender) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(offender.serviceName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(offender.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func servicePill(_ service: WidgetDataFetcher.WidgetLibraryHealthServiceSnapshot) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(service.totalIssueCount > 0 ? severityColor(service.worstOffender?.severity) : .green)
                .frame(width: 6, height: 6)
            Text("\(service.serviceType) \(service.totalIssueCount)")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.secondary.opacity(0.12), in: Capsule())
    }

    private func severityColor(_ severity: WidgetDataFetcher.WidgetLibraryHealthSeverity?) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .notice: .yellow
        case nil: .green
        }
    }
}

// MARK: - Widget

struct LibraryHealthWidget: Widget {
    let kind = "com.poole.james.Trawl.LibraryHealthWidget"

    static let trawlHealthURL = URL(string: "trawl://health")!

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LibraryHealthProvider()) { entry in
            LibraryHealthWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Library Health")
        .description("Sonarr and Radarr warnings with stuck queue items.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview Data

private extension WidgetDataFetcher.WidgetLibraryHealthSnapshot {
    static let healthPlaceholder = WidgetDataFetcher.WidgetLibraryHealthSnapshot(
        totalIssueCount: 5,
        healthIssueCount: 2,
        queueIssueCount: 3,
        worstOffender: WidgetDataFetcher.WidgetLibraryHealthOffender(
            serviceName: "Sonarr",
            serviceType: "Sonarr",
            title: "Import stalled",
            detail: "Unable to import downloaded episode",
            severity: .error
        ),
        services: [
            WidgetDataFetcher.WidgetLibraryHealthServiceSnapshot(
                serviceName: "Sonarr",
                serviceType: "Sonarr",
                healthIssueCount: 1,
                queueIssueCount: 3,
                worstOffender: WidgetDataFetcher.WidgetLibraryHealthOffender(
                    serviceName: "Sonarr",
                    serviceType: "Sonarr",
                    title: "Import stalled",
                    detail: "Unable to import downloaded episode",
                    severity: .error
                )
            ),
            WidgetDataFetcher.WidgetLibraryHealthServiceSnapshot(
                serviceName: "Radarr",
                serviceType: "Radarr",
                healthIssueCount: 1,
                queueIssueCount: 0,
                worstOffender: WidgetDataFetcher.WidgetLibraryHealthOffender(
                    serviceName: "Radarr",
                    serviceType: "Radarr",
                    title: "Indexer unavailable",
                    detail: "One indexer is failing",
                    severity: .warning
                )
            )
        ],
        errorMessage: nil
    )

    static func healthUnavailable(_ message: String) -> WidgetDataFetcher.WidgetLibraryHealthSnapshot {
        WidgetDataFetcher.WidgetLibraryHealthSnapshot(
            totalIssueCount: 0,
            healthIssueCount: 0,
            queueIssueCount: 0,
            worstOffender: nil,
            services: [],
            errorMessage: message
        )
    }
}

#Preview(as: .systemSmall) {
    LibraryHealthWidget()
} timeline: {
    LibraryHealthEntry.placeholder
    LibraryHealthEntry(date: .now, snapshot: .healthUnavailable("Unavailable"))
}

#Preview(as: .systemMedium) {
    LibraryHealthWidget()
} timeline: {
    LibraryHealthEntry.placeholder
}
