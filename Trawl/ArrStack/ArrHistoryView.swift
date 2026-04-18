import SwiftUI

struct ArrHistoryView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    let embedded: Bool
    @State private var sonarrViewModel: SonarrViewModel?
    @State private var radarrViewModel: RadarrViewModel?
    @State private var scope: ArrHistoryScope = .all

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                VStack(spacing: 0) {
                    historyScopePicker
                    historyContent
                }
            } else {
                historyContent
                    .navigationTitle("History")
                    .safeAreaInset(edge: .top) {
                        historyScopePicker
                            .background(.bar)
                    }
            }
        }
        .task(id: reloadKey) {
            await initializeIfNeeded()
            await reloadHistory()
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if !hasConnectedService {
            ContentUnavailableView(
                "No Arr Services Connected",
                systemImage: "clock.arrow.circlepath",
                description: Text("Connect Sonarr or Radarr to view download and import history.")
            )
        } else if isLoading && groupedItems.isEmpty {
            ProgressView("Loading history...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groupedItems.isEmpty {
            ContentUnavailableView(
                "No History",
                systemImage: "tray",
                description: Text("No download or import events are available yet.")
            )
        } else {
            List {
                ForEach(groupedItems) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            HistoryRow(item: item)
                        }
                    }
                }

                if shouldShowLoadMore {
                    Button {
                        Task { await loadMoreHistory() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoadingMore {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Load More")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isLoadingMore)
                }
            }
            .listStyle(.plain)
        }
    }

    private var historyScopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(ArrHistoryScope.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var isLoading: Bool {
        sonarrViewModel?.isLoadingHistory == true || radarrViewModel?.isLoadingHistory == true
    }

    private var isLoadingMore: Bool {
        isLoading
    }

    private var reloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }

    private var historyItems: [HistoryItem] {
        var items: [HistoryItem] = []

        if scope != .radarr, let sonarrViewModel {
            items.append(contentsOf: sonarrViewModel.history.map { HistoryItem(record: $0, source: .sonarr) })
        }

        if scope != .sonarr, let radarrViewModel {
            items.append(contentsOf: radarrViewModel.history.map { HistoryItem(record: $0, source: .radarr) })
        }

        return items.sorted { $0.sortDate > $1.sortDate }
    }

    private var groupedItems: [HistorySection] {
        let grouped = Dictionary(grouping: historyItems, by: \.dayKey)
        return grouped
            .map { HistorySection(title: $0.key, items: $0.value.sorted { $0.sortDate > $1.sortDate }) }
            .sorted { $0.sortDate > $1.sortDate }
    }

    private var shouldShowLoadMore: Bool {
        switch scope {
        case .all:
            return (sonarrViewModel?.canLoadMoreHistory == true) || (radarrViewModel?.canLoadMoreHistory == true)
        case .sonarr:
            return sonarrViewModel?.canLoadMoreHistory == true
        case .radarr:
            return radarrViewModel?.canLoadMoreHistory == true
        }
    }

    private func initializeIfNeeded() async {
        if serviceManager.sonarrConnected, sonarrViewModel == nil {
            sonarrViewModel = SonarrViewModel(serviceManager: serviceManager)
        }

        if serviceManager.radarrConnected, radarrViewModel == nil {
            radarrViewModel = RadarrViewModel(serviceManager: serviceManager)
        }

        if !serviceManager.sonarrConnected {
            sonarrViewModel = nil
        }

        if !serviceManager.radarrConnected {
            radarrViewModel = nil
        }
    }

    private func reloadHistory() async {
        await withTaskGroup(of: Void.self) { group in
            if let sonarrViewModel {
                group.addTask {
                    await sonarrViewModel.loadHistory(page: 1)
                }
            }

            if let radarrViewModel {
                group.addTask {
                    await radarrViewModel.loadHistory(page: 1)
                }
            }
        }
    }

    private func loadMoreHistory() async {
        await withTaskGroup(of: Void.self) { group in
            if scope != .radarr, let sonarrViewModel, sonarrViewModel.canLoadMoreHistory {
                group.addTask {
                    await sonarrViewModel.loadNextHistoryPage()
                }
            }

            if scope != .sonarr, let radarrViewModel, radarrViewModel.canLoadMoreHistory {
                group.addTask {
                    await radarrViewModel.loadNextHistoryPage()
                }
            }
        }
    }
}

private enum ArrHistoryScope: CaseIterable, Hashable {
    case all
    case sonarr
    case radarr

    var title: String {
        switch self {
        case .all:
            "All"
        case .sonarr:
            "Sonarr"
        case .radarr:
            "Radarr"
        }
    }
}

private struct HistorySection: Identifiable {
    let title: String
    let items: [HistoryItem]

    var id: String { title }
    var sortDate: Date { items.first?.sortDate ?? .distantPast }
}

private struct HistoryItem: Identifiable {
    let record: ArrHistoryRecord
    let source: ArrServiceType

    var id: String { "\(source.rawValue)-\(record.id)" }

    var sortDate: Date {
        HistoryDateParser.parse(record.date) ?? .distantPast
    }

    var dayKey: String {
        sortDate.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.record.sourceTitle ?? "Unknown")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    Text(item.source.displayName)
                    if let quality = item.record.quality?.quality?.name, !quality.isEmpty {
                        Text("• \(quality)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(timeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(eventLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(iconColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(iconColor.opacity(0.14))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var eventType: String {
        item.record.eventType?.lowercased() ?? ""
    }

    private var eventLabel: String {
        if eventType.contains("grabbed") { return "Grabbed" }
        if eventType.contains("import") { return "Imported" }
        if eventType.contains("upgrade") { return "Upgraded" }
        if eventType.contains("delete") { return "Deleted" }
        if eventType.contains("download") { return "Downloaded" }
        return "Event"
    }

    private var iconName: String {
        if eventType.contains("grabbed") { return "magnifyingglass" }
        if eventType.contains("import") { return "checkmark" }
        if eventType.contains("upgrade") { return "arrow.up.circle" }
        if eventType.contains("delete") { return "trash" }
        if eventType.contains("download") { return "arrow.down" }
        return "clock"
    }

    private var iconColor: Color {
        if eventType.contains("delete") { return .red }
        if eventType.contains("upgrade") { return .blue }
        if eventType.contains("import") { return .green }
        if eventType.contains("grabbed") { return .orange }
        return .secondary
    }

    private var timeLabel: String {
        item.sortDate.formatted(date: .omitted, time: .shortened)
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
