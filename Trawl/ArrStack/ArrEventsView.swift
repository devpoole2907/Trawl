import SwiftUI

// MARK: - Unified Log Entry

struct UnifiedLogEntry: Identifiable, Sendable {
    let id: String
    let service: ArrServiceType
    let level: String
    let logger: String?
    let message: String
    let timestamp: Date
    let exceptionType: String?
}

// MARK: - Service Selection

private enum ArrEventsSelection: Hashable, Sendable {
    case all
    case service(ArrServiceType)
}

// MARK: - View

struct ArrEventsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var vm = ArrEventsViewModel()
    @State private var selectedSelection: ArrEventsSelection = .all
    @State private var selectedLevel: ArrLogLevelFilter = .all
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var isSearchExpanded = false
    @State private var searchDebounceTask: Task<Void, Never>?

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
        if serviceManager.hasBazarrInstance { services.append(.bazarr) }
        return services
    }

    private var segmentItems: [TrawlSegmentBarItem<ArrEventsSelection>] {
        var items: [TrawlSegmentBarItem<ArrEventsSelection>] = []
        if availableServices.count > 1 {
            items.append(TrawlSegmentBarItem("All", value: .all))
        }
        for service in availableServices {
            items.append(TrawlSegmentBarItem(service.displayName, value: .service(service)))
        }
        return items
    }

    private var displayedEntries: [UnifiedLogEntry] {
        let raw: [UnifiedLogEntry]
        switch selectedSelection {
        case .all:
            raw = availableServices
                .flatMap { vm.entries(for: $0) }
                .sorted { $0.timestamp > $1.timestamp }
        case .service(let t):
            raw = vm.entries(for: t)
        }

        let levelFiltered = raw.filter { entry in
            entry.service == .bazarr
                ? selectedLevel.includesBazarrLevel(entry.level)
                : selectedLevel.includesArrLevel(entry.level)
        }

        guard !committedSearchText.isEmpty else { return levelFiltered }
        return levelFiltered.filter {
            $0.message.localizedCaseInsensitiveContains(committedSearchText) ||
            ($0.logger ?? "").localizedCaseInsensitiveContains(committedSearchText)
        }
    }

    private var isCurrentLoading: Bool {
        switch selectedSelection {
        case .all: availableServices.contains { vm.isLoading(for: $0) }
        case .service(let t): vm.isLoading(for: t)
        }
    }

    private var currentError: String? {
        switch selectedSelection {
        case .all: nil
        case .service(let t): vm.errorMessage(for: t)
        }
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Add a Sonarr, Radarr, Prowlarr, or Bazarr server in Settings to view events.")
                )
            } else {
                logList
            }
        }
        .navigationTitle("Events")
        .moreDestinationBackground(.logsAndEvents)
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Menu {
                    ForEach(ArrLogLevelFilter.allCases, id: \.self) { level in
                        Button {
                            withAnimation { selectedLevel = level }
                        } label: {
                            if selectedLevel == level {
                                Label(level.displayName, systemImage: "checkmark")
                            } else {
                                Text(level.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: selectedLevel == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Service",
                selection: Binding(
                    get: { selectedSelection },
                    set: { newSelection in withAnimation { selectedSelection = newSelection } }
                ),
                items: segmentItems,
                searchText: $searchText,
                searchHint: "Search events",
                isSearchExpanded: $isSearchExpanded,
                searchPlacement: .leading,
                alignment: .center
            )
        }
        .loadServicesPeriodically(availableServices) { service in
            await loadService(service)
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                committedSearchText = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .onAppear {
            if case .all = selectedSelection, availableServices.count < 2, let first = availableServices.first {
                withAnimation { selectedSelection = .service(first) }
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var logList: some View {
        List {
            if let error = currentError {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if isCurrentLoading && displayedEntries.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else if displayedEntries.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "list.bullet.rectangle",
                    description: Text("No log entries match the current filter.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(displayedEntries) { entry in
                        UnifiedEventRow(
                            entry: entry,
                            showServiceBadge: selectedSelection == .all
                        )
                        .task {
                            guard case .service(let t) = selectedSelection,
                                  entry.id == vm.entries(for: t).last?.id
                            else { return }
                            await loadMore(for: t)
                        }
                    }
                    if case .service(let t) = selectedSelection, vm.isLoadingMore(for: t) {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable {
            await withTaskGroup(of: Void.self) { group in
                for service in availableServices {
                    group.addTask { await loadService(service) }
                }
            }
        }
        .animation(.default, value: displayedEntries.map(\.id))
    }

    // MARK: - Load

    @MainActor
    private func loadService(_ service: ArrServiceType) async {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else { return }
            await vm.load(service: .sonarr, client: client)
        case .radarr:
            guard let client = serviceManager.radarrClient else { return }
            await vm.load(service: .radarr, client: client)
        case .prowlarr:
            guard let client = serviceManager.prowlarrClient else { return }
            await vm.load(service: .prowlarr, client: client)
        case .bazarr:
            guard let client = serviceManager.activeBazarrEntry?.client else { return }
            await vm.loadBazarr(client: client)
        }
    }

    @MainActor
    private func loadMore(for service: ArrServiceType) async {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else { return }
            await vm.loadMore(service: .sonarr, client: client)
        case .radarr:
            guard let client = serviceManager.radarrClient else { return }
            await vm.loadMore(service: .radarr, client: client)
        case .prowlarr:
            guard let client = serviceManager.prowlarrClient else { return }
            await vm.loadMore(service: .prowlarr, client: client)
        case .bazarr:
            guard let client = serviceManager.activeBazarrEntry?.client else { return }
            await vm.loadMoreBazarr(client: client)
        }
    }
}

// MARK: - Unified Event Row

private struct UnifiedEventRow: View {
    let entry: UnifiedLogEntry
    let showServiceBadge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if showServiceBadge {
                    Image(systemName: entry.service.serviceIdentity.systemImage)
                        .font(.caption2)
                        .foregroundStyle(entry.service.serviceIdentity.brandColor)
                }
                Image(systemName: levelIcon)
                    .font(.caption2)
                    .foregroundStyle(levelColor)
                Text(entry.logger ?? entry.service.serviceIdentity.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(entry.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
            if let exType = entry.exceptionType, !exType.isEmpty {
                Text(exType).font(.caption2).foregroundStyle(.red.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var levelColor: Color {
        switch entry.level.lowercased() {
        case "error", "fatal", "critical": .red
        case "warn", "warning": .orange
        default: .secondary
        }
    }

    private var levelIcon: String {
        switch entry.level.lowercased() {
        case "error", "fatal", "critical": "xmark.octagon.fill"
        case "warn", "warning": "exclamationmark.triangle.fill"
        default: "circle.fill"
        }
    }
}

// MARK: - Arr Event Row (public, used by detail views)

struct ArrEventRow: View {
    let record: ArrLogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: levelIcon)
                    .font(.caption2)
                    .foregroundStyle(levelColor)
                Text(record.logger ?? "Unknown")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let time = formattedTime {
                    Text(time).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(record.message ?? "No message")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
            if let exType = record.exceptionType, !exType.isEmpty {
                Text(exType).font(.caption2).foregroundStyle(.red.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var levelColor: Color {
        switch record.level?.lowercased() {
        case "error", "fatal": .red
        case "warn": .orange
        default: .secondary
        }
    }

    private var levelIcon: String {
        switch record.level?.lowercased() {
        case "error", "fatal": "xmark.octagon.fill"
        case "warn": "exclamationmark.triangle.fill"
        default: "circle.fill"
        }
    }

    private var formattedTime: String? {
        guard let raw = record.time else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date.formatted(date: .abbreviated, time: .shortened) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date.formatted(date: .abbreviated, time: .shortened) }
        return raw
    }
}

// MARK: - Events ViewModel

@MainActor
@Observable
final class ArrEventsViewModel {
    private struct ServiceState {
        var entries: [UnifiedLogEntry] = []
        var total: Int = 0
        var isLoading = false
        var isLoadingMore = false
        var loadMoreFailed = false
        var errorMessage: String?

        var hasMore: Bool { !loadMoreFailed && entries.count < total }
    }

    private var states: [ArrServiceType: ServiceState] = [:]
    private let pageSize = 50

    func entries(for service: ArrServiceType) -> [UnifiedLogEntry] {
        states[service]?.entries ?? []
    }

    func isLoading(for service: ArrServiceType) -> Bool {
        states[service]?.isLoading ?? false
    }

    func isLoadingMore(for service: ArrServiceType) -> Bool {
        states[service]?.isLoadingMore ?? false
    }

    func hasMore(for service: ArrServiceType) -> Bool {
        states[service]?.hasMore ?? false
    }

    func errorMessage(for service: ArrServiceType) -> String? {
        states[service]?.errorMessage
    }

    func load(service: ArrServiceType, client: any SharedArrClient) async {
        mutate(service) { $0.isLoading = true; $0.errorMessage = nil; $0.loadMoreFailed = false }
        do {
            let page = try await client.getLog(page: 1, pageSize: pageSize, level: nil)
            let entries = (page.records ?? []).compactMap { makeEntry(from: $0, service: service) }
            mutate(service) {
                $0.entries = entries
                $0.total = page.totalRecords ?? 0
                $0.isLoading = false
            }
        } catch {
            mutate(service) { $0.errorMessage = error.localizedDescription; $0.isLoading = false }
        }
    }

    func loadMore(service: ArrServiceType, client: any SharedArrClient) async {
        guard states[service]?.hasMore == true, states[service]?.isLoadingMore == false else { return }
        mutate(service) { $0.isLoadingMore = true }
        do {
            let count = states[service]?.entries.count ?? 0
            let nextPage = (count / pageSize) + 1
            let page = try await client.getLog(page: nextPage, pageSize: pageSize, level: nil)
            let newEntries = (page.records ?? []).compactMap { makeEntry(from: $0, service: service) }
            mutate(service) {
                $0.entries.append(contentsOf: newEntries)
                $0.total = page.totalRecords ?? $0.total
                $0.isLoadingMore = false
            }
        } catch {
            mutate(service) { $0.loadMoreFailed = true; $0.isLoadingMore = false }
        }
    }

    func loadBazarr(client: BazarrAPIClient) async {
        mutate(.bazarr) { $0.isLoading = true; $0.errorMessage = nil; $0.loadMoreFailed = false }
        do {
            let page = try await client.getLogs(start: 0, length: pageSize)
            let entries = page.data.compactMap { makeEntry(from: $0) }
            mutate(.bazarr) { $0.entries = entries; $0.total = page.total; $0.isLoading = false }
        } catch {
            mutate(.bazarr) { $0.errorMessage = error.localizedDescription; $0.isLoading = false }
        }
    }

    func loadMoreBazarr(client: BazarrAPIClient) async {
        guard states[.bazarr]?.hasMore == true, states[.bazarr]?.isLoadingMore == false else { return }
        mutate(.bazarr) { $0.isLoadingMore = true }
        do {
            let count = states[.bazarr]?.entries.count ?? 0
            let page = try await client.getLogs(start: count, length: pageSize)
            let newEntries = page.data.compactMap { makeEntry(from: $0) }
            mutate(.bazarr) {
                $0.entries.append(contentsOf: newEntries)
                $0.total = page.total
                $0.isLoadingMore = false
            }
        } catch {
            mutate(.bazarr) { $0.loadMoreFailed = true; $0.isLoadingMore = false }
        }
    }

    private func mutate(_ service: ArrServiceType, _ modify: (inout ServiceState) -> Void) {
        var state = states[service] ?? ServiceState()
        modify(&state)
        states[service] = state
    }

    private func makeEntry(from record: ArrLogRecord, service: ArrServiceType) -> UnifiedLogEntry? {
        guard let timestamp = parseArrDate(record.time) else { return nil }
        return UnifiedLogEntry(
            id: "\(service.rawValue)-\(record.id)",
            service: service,
            level: record.level ?? "info",
            logger: record.logger,
            message: record.message ?? "",
            timestamp: timestamp,
            exceptionType: record.exceptionType
        )
    }

    private func makeEntry(from entry: BazarrLogEntry) -> UnifiedLogEntry? {
        guard let timestamp = parseBazarrDate(entry.timestamp) else { return nil }
        return UnifiedLogEntry(
            id: entry.id.uuidString,
            service: .bazarr,
            level: entry.level,
            logger: nil,
            message: entry.message,
            timestamp: timestamp,
            exceptionType: nil
        )
    }

    private func parseArrDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private func parseBazarrDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss,SSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

// MARK: - Level Filter

enum ArrLogLevelFilter: String, CaseIterable, Sendable {
    case all = "all"
    case info = "info"
    case warn = "warn"
    case error = "error"

    var apiValue: String? { self == .all ? nil : rawValue }

    var displayName: String {
        switch self {
        case .all: "All Levels"
        case .info: "Info"
        case .warn: "Warn"
        case .error: "Error"
        }
    }

    func includesBazarrLevel(_ level: String) -> Bool {
        let priority: [String: Int] = ["debug": 0, "info": 1, "warning": 2, "error": 3, "critical": 4]
        let min: Int = switch self { case .all: -1; case .info: 1; case .warn: 2; case .error: 3 }
        return (priority[level.lowercased()] ?? 0) >= min
    }

    func includesArrLevel(_ level: String) -> Bool {
        switch self {
        case .all: true
        case .info: !["trace", "debug"].contains(level.lowercased())
        case .warn: ["warn", "error", "fatal"].contains(level.lowercased())
        case .error: ["error", "fatal"].contains(level.lowercased())
        }
    }
}
