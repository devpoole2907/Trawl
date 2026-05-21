import SwiftUI

struct ArrHistoryView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    let embedded: Bool
    let serviceFilter: ArrServiceFilter
    @State private var showSettings = false
    @State private var sonarrViewModel: SonarrViewModel?
    @State private var radarrViewModel: RadarrViewModel?
    @State private var prowlarrViewModel: ProwlarrViewModel?
    @State private var historyRefreshGeneration = 0

    init(embedded: Bool = false, serviceFilter: ArrServiceFilter = .all) {
        self.embedded = embedded
        self.serviceFilter = serviceFilter
    }

    var body: some View {
        Group {
            if embedded {
                historyContent
            } else {
                historyContent
                    .navigationTitle("History")
            }
        }
        .task(id: reloadKey) {
            await initializeIfNeeded()
            await reloadHistory()
            historyRefreshGeneration += 1
        }
        .refreshable {
            await reloadHistory()
            historyRefreshGeneration += 1
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ArrServiceSettingsView(serviceType: settingsServiceType)
                    .environment(serviceManager)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if !hasConfiguredService {
            ContentUnavailableView(
                "No Services Configured",
                systemImage: "server.rack",
                description: Text("Connect Sonarr, Radarr, or Prowlarr to view activity history.")
            )
        } else if !hasConnectedService {
            ArrServicesConnectionStatusView(
                services: configuredHistoryServices,
                title: "Services Unreachable",
                message: "Unable to reach your configured activity history services."
            )
        } else {
            ArrLoadingErrorEmptyView(
                isLoading: isLoading,
                error: nil,
                isEmpty: groupedItems.isEmpty,
                emptyTitle: "No History",
                emptyIcon: "tray",
                emptyDescription: "No download or import events are available yet.",
                onRetry: { Task {
                    await reloadHistory()
                    historyRefreshGeneration += 1
                } }
            ) {
                List {
                    ForEach(groupedItems) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                HistoryRow(item: item)
                            }
                        }
                    }
                    .animation(.default, value: groupedItems.map(\.id))

                    if shouldShowLoadMore {
                        Button {
                            Task {
                                await loadMoreHistory()
                                historyRefreshGeneration += 1
                            }
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
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var hasConfiguredService: Bool {
        switch serviceFilter {
        case .sonarr: serviceManager.hasSonarrInstance
        case .radarr: serviceManager.hasRadarrInstance
        case .prowlarr: serviceManager.hasProwlarrInstance
        case .all: serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance || serviceManager.hasProwlarrInstance
        case .bazarr: false
        }
    }

    private var configuredHistoryServices: [ArrServiceType] {
        switch serviceFilter {
        case .sonarr:
            return serviceManager.hasSonarrInstance ? [.sonarr] : []
        case .radarr:
            return serviceManager.hasRadarrInstance ? [.radarr] : []
        case .prowlarr:
            return serviceManager.hasProwlarrInstance ? [.prowlarr] : []
        case .all:
            var services: [ArrServiceType] = []
            if serviceManager.hasSonarrInstance { services.append(.sonarr) }
            if serviceManager.hasRadarrInstance { services.append(.radarr) }
            if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
            return services
        case .bazarr:
            return []
        }
    }

    private var isConnecting: Bool {
        guard !hasConnectedService else { return false }
        return serviceManager.isInitializing ||
            serviceManager.isConnecting(.sonarr) ||
            serviceManager.isConnecting(.radarr) ||
            serviceManager.isConnecting(.prowlarr)
    }

    private var settingsServiceType: ArrServiceType {
        switch serviceFilter {
        case .sonarr: return .sonarr
        case .radarr: return .radarr
        case .prowlarr: return .prowlarr
        case .all, .bazarr:
            if serviceManager.hasSonarrInstance && !serviceManager.sonarrConnected { return .sonarr }
            if serviceManager.hasRadarrInstance && !serviceManager.radarrConnected { return .radarr }
            if serviceManager.hasProwlarrInstance && !serviceManager.prowlarrConnected { return .prowlarr }
            return .sonarr
        }
    }

    private var hasConnectedService: Bool {
        switch serviceFilter {
        case .sonarr: serviceManager.sonarrConnected
        case .radarr: serviceManager.radarrConnected
        case .prowlarr: serviceManager.prowlarrConnected
        case .all: serviceManager.sonarrConnected || serviceManager.radarrConnected || serviceManager.prowlarrConnected
        case .bazarr: false
        }
    }

    private var isLoading: Bool {
        sonarrViewModel?.isLoadingHistory == true ||
            radarrViewModel?.isLoadingHistory == true ||
            prowlarrViewModel?.isLoadingHistory == true
    }

    private var isLoadingMore: Bool {
        isLoading
    }

    private var reloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)-\(serviceManager.prowlarrConnected)"
    }

    private var historyItems: [HistoryItem] {
        _ = historyRefreshGeneration
        var items: [HistoryItem] = []

        if serviceFilter == .all || serviceFilter == .sonarr, let sonarrViewModel {
            items.append(contentsOf: sonarrViewModel.history.map { HistoryItem(record: $0, source: .sonarr) })
        }

        if serviceFilter == .all || serviceFilter == .radarr, let radarrViewModel {
            items.append(contentsOf: radarrViewModel.history.map { HistoryItem(record: $0, source: .radarr) })
        }

        if serviceFilter == .all || serviceFilter == .prowlarr, let prowlarrViewModel {
            let indexerNamesByID = Dictionary(uniqueKeysWithValues: prowlarrViewModel.indexers.compactMap { indexer in
                indexer.name.map { (indexer.id, $0) }
            })
            items.append(contentsOf: prowlarrViewModel.history.map { record in
                HistoryItem(record: record, source: .prowlarr, indexerName: record.indexerId.flatMap { indexerNamesByID[$0] })
            })
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
        switch serviceFilter {
        case .all:
            return (sonarrViewModel?.canLoadMoreHistory == true) ||
                (radarrViewModel?.canLoadMoreHistory == true) ||
                (prowlarrViewModel?.canLoadMoreHistory == true)
        case .sonarr:
            return sonarrViewModel?.canLoadMoreHistory == true
        case .radarr:
            return radarrViewModel?.canLoadMoreHistory == true
        case .prowlarr:
            return prowlarrViewModel?.canLoadMoreHistory == true
        case .bazarr:
            return false
        }
    }

    private func initializeIfNeeded() async {
        if (serviceFilter == .all || serviceFilter == .sonarr),
           serviceManager.sonarrConnected,
           sonarrViewModel == nil {
            sonarrViewModel = SonarrViewModel(serviceManager: serviceManager)
        }

        if (serviceFilter == .all || serviceFilter == .radarr),
           serviceManager.radarrConnected,
           radarrViewModel == nil {
            radarrViewModel = RadarrViewModel(serviceManager: serviceManager)
        }

        if (serviceFilter == .all || serviceFilter == .prowlarr),
           serviceManager.prowlarrConnected,
           prowlarrViewModel == nil {
            prowlarrViewModel = ProwlarrViewModel(serviceManager: serviceManager)
        }

        if !serviceManager.sonarrConnected {
            sonarrViewModel = nil
        }

        if !serviceManager.radarrConnected {
            radarrViewModel = nil
        }

        if !serviceManager.prowlarrConnected {
            prowlarrViewModel = nil
        }
    }

    private func reloadHistory() async {
        await withTaskGroup(of: Void.self) { group in
            if (serviceFilter == .all || serviceFilter == .sonarr),
               serviceManager.sonarrConnected,
               let sonarrViewModel {
                group.addTask {
                    await sonarrViewModel.loadHistory(page: 1)
                }
            }

            if (serviceFilter == .all || serviceFilter == .radarr),
               serviceManager.radarrConnected,
               let radarrViewModel {
                group.addTask {
                    await radarrViewModel.loadHistory(page: 1)
                }
            }

            if (serviceFilter == .all || serviceFilter == .prowlarr),
               serviceManager.prowlarrConnected,
               let prowlarrViewModel {
                group.addTask {
                    await prowlarrViewModel.loadIndexers()
                    await prowlarrViewModel.loadHistory(page: 1)
                }
            }
        }
    }

    private func loadMoreHistory() async {
        await withTaskGroup(of: Void.self) { group in
            if (serviceFilter == .all || serviceFilter == .sonarr),
               let sonarrViewModel,
               sonarrViewModel.canLoadMoreHistory {
                group.addTask { await sonarrViewModel.loadNextHistoryPage() }
            }
            if (serviceFilter == .all || serviceFilter == .radarr),
               let radarrViewModel,
               radarrViewModel.canLoadMoreHistory {
                group.addTask { await radarrViewModel.loadNextHistoryPage() }
            }
            if (serviceFilter == .all || serviceFilter == .prowlarr),
               let prowlarrViewModel,
               prowlarrViewModel.canLoadMoreHistory {
                group.addTask { await prowlarrViewModel.loadNextHistoryPage() }
            }
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
    var indexerName: String?

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
            Image(systemName: serviceSymbol)
                .foregroundStyle(serviceColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let indexerName = item.indexerName, !indexerName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text(indexerName)
                        }
                    }
                    if let quality = item.record.quality?.quality?.name, !quality.isEmpty {
                        Text(quality)
                    }
                    if item.source == .prowlarr, let query = item.record.data?["query"], !query.isEmpty {
                        Text(query)
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

    private var serviceColor: Color {
        switch item.source {
        case .sonarr: .purple
        case .radarr: .orange
        case .prowlarr: .yellow
        case .bazarr: .secondary
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
