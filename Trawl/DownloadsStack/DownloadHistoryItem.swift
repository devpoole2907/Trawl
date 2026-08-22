import SwiftUI

struct HistoryItem: Identifiable {
    let record: ArrHistoryRecord
    let source: ArrServiceType
    var indexerName: String?

    /// Parsed once at construction rather than on every read. This is the sort key
    /// for the whole history list, so a computed version was re-parsing the date
    /// twice per comparison — thousands of parses per sort.
    let sortDate: Date

    init(record: ArrHistoryRecord, source: ArrServiceType, indexerName: String? = nil) {
        self.record = record
        self.source = source
        self.indexerName = indexerName
        self.sortDate = HistoryDateParser.parse(record.date) ?? .distantPast
    }

    var id: String { "\(source.rawValue)-\(record.id)" }

    var dayKey: String {
        sortDate.formatted(date: .abbreviated, time: .omitted)
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        ArrInfoRowView(
            icon: (serviceSymbol, serviceColor),
            title: displayTitle,
            subtitleLeading: serviceName,
            subtitleTrailing: timeLabel,
            chips: chips
        )
    }

    private var eventType: String {
        item.record.eventType?.lowercased() ?? ""
    }

    private var eventLabel: String {
        item.record.eventDisplayName
    }

    private var iconColor: Color {
        if eventType.contains("delete") { return .red }
        if item.record.successful == false { return .red }
        if eventType.contains("upgrade") { return .blue }
        if eventType.contains("import") { return .green }
        if eventType.contains("grabbed") { return .orange }
        if eventType.contains("query") || eventType.contains("search") { return .yellow }
        return .secondary
    }

    private var displayTitle: String {
        let candidates = [
            item.record.sourceTitle,
            item.record.data?["sourceTitle"],
            item.record.data?["releaseTitle"],
            item.record.data?["title"],
            item.record.data?["query"],
            prowlarrEventTitle,
            item.indexerName,
            item.record.indexerId.map { "Indexer #\($0)" }
        ]

        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Unknown"
    }

    private var prowlarrEventTitle: String? {
        guard item.source == .prowlarr else { return nil }
        guard eventLabel != "Event" else { return nil }
        return eventLabel
    }

    private var timeLabel: String {
        item.sortDate.formatted(date: .omitted, time: .shortened)
    }

    private var chips: [ArrReleaseInfoChip] {
        var chips = [
            ArrReleaseInfoChip(eventLabel, color: iconColor, isProminent: true)
        ]

        if let quality = item.record.quality?.quality?.name, !quality.isEmpty {
            chips.append(ArrReleaseInfoChip(quality, color: .primary))
        }

        if let indexerName = item.indexerName, !indexerName.isEmpty {
            chips.append(ArrReleaseInfoChip(indexerName, color: .secondary))
        }

        if item.source == .prowlarr,
           let query = item.record.data?["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            chips.append(ArrReleaseInfoChip(query, color: .secondary))
        }

        return chips
    }

    private var serviceColor: Color {
        item.source.serviceIdentity.brandColor
    }

    private var serviceName: String {
        switch item.source {
        case .sonarr: "Sonarr"
        case .radarr: "Radarr"
        case .prowlarr: "Prowlarr"
        case .bazarr: "Bazarr"
        }
    }

    private var serviceSymbol: String {
        switch item.source {
        case .sonarr: "tv"
        case .radarr: "film"
        case .prowlarr: "network"
        case .bazarr: "questionmark"
        }
    }
}

/// Formatters are held rather than built per call. Constructing an
/// `ISO8601DateFormatter` is expensive enough that allocating three of them per
/// parse dominated the cost of rendering the History segment.
private enum HistoryDateParser {
    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso = ISO8601DateFormatter()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        if let date = fractionalISO.date(from: value) {
            return date
        }

        if let date = iso.date(from: value) {
            return date
        }

        return dayOnly.date(from: value)
    }
}
