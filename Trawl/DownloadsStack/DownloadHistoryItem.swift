import SwiftUI

struct HistoryItem: Identifiable {
    let record: ArrHistoryRecord
    let source: ArrServiceType
    var indexerName: String?

    var id: String { "\(source.rawValue)-\(record.id)" }

    var sortDate: Date {
        HistoryDateParser.parse(record.date) ?? .distantPast
    }

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
        switch item.source {
        case .sonarr: .purple
        case .radarr: .orange
        case .prowlarr: .yellow
        case .bazarr: .secondary
        }
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

private enum HistoryDateParser {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalISO.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}
