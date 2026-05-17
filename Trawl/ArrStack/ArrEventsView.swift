import SwiftUI

// MARK: - Service Selection

private enum ArrEventsSelection: Hashable, Sendable {
    case all
    case service(ArrServiceType)

    var taskId: String {
        switch self {
        case .all: "all"
        case .service(let t): t.rawValue
        }
    }
}

// MARK: - View

struct ArrEventsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var selectedSelection: ArrEventsSelection = .all
    @State private var selectedLevel: ArrLogLevelFilter = .all
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var isSearchExpanded = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var states: [ArrEventsSelection: LogsViewState] = [:]
    @State private var unavailable: Set<ArrEventsSelection> = []

    private enum LogsViewState {
        case arr(ArrEventsViewModel)
        case bazarr(BazarrEventsViewModel)
        case all(AllEventsViewModel)
    }

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

    // All selections that should be preloaded in parallel.
    private var allSelections: [ArrEventsSelection] {
        var result: [ArrEventsSelection] = []
        if availableServices.count > 1 { result.append(.all) }
        for service in availableServices { result.append(.service(service)) }
        return result
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Add a Sonarr, Radarr, Prowlarr, or Bazarr server in Settings to view events.")
                )
            } else if unavailable.contains(selectedSelection) {
                ContentUnavailableView(
                    "Service Unreachable",
                    systemImage: "network.slash",
                    description: Text("The selected service is configured but currently unreachable.")
                )
            } else {
                switch states[selectedSelection] {
                case .arr(let vm): arrLogList(vm)
                        .id(selectedSelection)
                        .transition(.opacity)
                case .bazarr(let vm): bazarrLogList(vm)
                        .id(selectedSelection)
                        .transition(.opacity)
                case .all(let vm): allLogList(vm)
                        .id(selectedSelection)
                        .transition(.opacity)
                case nil:
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
        }
        .animation(.default, value: selectedSelection)
        .navigationTitle("Events")
        .moreDestinationBackground(.mediaManagement)
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
                    Image(systemName: selectedLevel == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
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
        // Preloads all selections in parallel on appear; refreshes every 30 s.
        // Use the id: overload because ArrEventsSelection's Hashable conformance is
        // @MainActor-isolated (InferIsolatedConformances + default-isolation=MainActor).
        .loadServicesPeriodically(id: allSelections.map(\.taskId), keys: allSelections) { selection in
            await loadSelection(selection)
        }
        // Level changes need an immediate reload for the visible single-Arr selection
        // (server-side filter). Other Arr selections update on the next 30 s cycle.
        .onChange(of: selectedLevel) { _, _ in
            guard case .service(let t) = selectedSelection, t != .bazarr else { return }
            Task { await loadSelection(selectedSelection) }
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
            // If "All" is selected but only one service is available, switch to it.
            if case .all = selectedSelection, availableServices.count < 2, let first = availableServices.first {
                withAnimation { selectedSelection = .service(first) }
            }
        }
    }

    // MARK: - Load

    @MainActor
    private func loadSelection(_ selection: ArrEventsSelection) async {
        switch selection {
        case .all:
            let vm: AllEventsViewModel
            if case .all(let existing) = states[selection] {
                vm = existing
            } else {
                vm = AllEventsViewModel(
                    sonarrClient: serviceManager.sonarrClient,
                    radarrClient: serviceManager.radarrClient,
                    prowlarrClient: serviceManager.prowlarrClient,
                    bazarrClient: serviceManager.activeBazarrEntry?.client
                )
                withAnimation { states[selection] = .all(vm) }
            }
            await vm.load()

        case .service(.sonarr):
            guard let client = serviceManager.sonarrClient else { unavailable.insert(selection); return }
            await loadArrSelection(selection, client: client)

        case .service(.radarr):
            guard let client = serviceManager.radarrClient else { unavailable.insert(selection); return }
            await loadArrSelection(selection, client: client)

        case .service(.prowlarr):
            guard let client = serviceManager.prowlarrClient else { unavailable.insert(selection); return }
            await loadArrSelection(selection, client: client)

        case .service(.bazarr):
            guard let client = serviceManager.activeBazarrEntry?.client else { unavailable.insert(selection); return }
            let vm: BazarrEventsViewModel
            if case .bazarr(let existing) = states[selection] {
                vm = existing
            } else {
                vm = BazarrEventsViewModel(client: client)
                withAnimation { states[selection] = .bazarr(vm) }
            }
            await vm.load()

        case .service:
            break
        }
    }

    @MainActor
    private func loadArrSelection(_ selection: ArrEventsSelection, client: any SharedArrClient) async {
        let vm: ArrEventsViewModel
        if case .arr(let existing) = states[selection] {
            vm = existing
        } else {
            vm = ArrEventsViewModel(client: client)
            withAnimation { states[selection] = .arr(vm) }
        }
        await vm.load(level: selectedLevel.apiValue)
    }

    // MARK: - Arr list

    @ViewBuilder
    private func arrLogList(_ vm: ArrEventsViewModel) -> some View {
        let filtered = committedSearchText.isEmpty ? vm.records : vm.records.filter {
            ($0.logger ?? "").localizedCaseInsensitiveContains(committedSearchText) ||
            ($0.message ?? "").localizedCaseInsensitiveContains(committedSearchText)
        }
        List {
            if let error = vm.errorMessage, vm.records.isEmpty {
                Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            if vm.isLoading && vm.records.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if filtered.isEmpty {
                ContentUnavailableView("No Events", systemImage: "list.bullet.rectangle",
                    description: Text("No log entries match the current filter."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filtered) { record in
                        ArrEventRow(record: record)
                            .task {
                                if record.id == vm.records.last?.id {
                                    await vm.loadMore(level: selectedLevel.apiValue)
                                }
                            }
                    }
                    if vm.isLoadingMore {
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
        .refreshable { await vm.load(level: selectedLevel.apiValue) }
    }

    // MARK: - Bazarr list

    @ViewBuilder
    private func bazarrLogList(_ vm: BazarrEventsViewModel) -> some View {
        let levelFiltered = vm.entries.filter { selectedLevel.includesBazarrLevel($0.level) }
        let filtered = committedSearchText.isEmpty ? levelFiltered : levelFiltered.filter {
            $0.message.localizedCaseInsensitiveContains(committedSearchText)
        }
        List {
            if let error = vm.errorMessage, vm.entries.isEmpty {
                Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            if vm.isLoading && vm.entries.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if filtered.isEmpty {
                ContentUnavailableView("No Events", systemImage: "list.bullet.rectangle",
                    description: Text("No log entries match the current filter."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filtered) { entry in
                        BazarrEventRow(entry: entry)
                            .task {
                                if entry.id == vm.entries.last?.id {
                                    await vm.loadMore()
                                }
                            }
                    }
                    if vm.isLoadingMore {
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
        .refreshable { await vm.load() }
    }

    // MARK: - All list

    @ViewBuilder
    private func allLogList(_ vm: AllEventsViewModel) -> some View {
        let levelFiltered = vm.entries.filter { entry in
            entry.service == .bazarr
                ? selectedLevel.includesBazarrLevel(entry.level)
                : selectedLevel.includesArrLevel(entry.level)
        }
        let filtered = committedSearchText.isEmpty ? levelFiltered : levelFiltered.filter {
            $0.message.localizedCaseInsensitiveContains(committedSearchText) ||
            ($0.logger ?? "").localizedCaseInsensitiveContains(committedSearchText)
        }
        List {
            if let error = vm.errorMessage, vm.entries.isEmpty {
                Section { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            if vm.isLoading && vm.entries.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if filtered.isEmpty {
                ContentUnavailableView("No Events", systemImage: "list.bullet.rectangle",
                    description: Text("No log entries match the current filter."))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filtered) { entry in
                        AllEventsEntryRow(entry: entry)
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
        .refreshable { await vm.load() }
    }
}

// MARK: - Arr Event Row

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

// MARK: - Bazarr Event Row

private struct BazarrEventRow: View {
    let entry: BazarrLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: levelIcon)
                    .font(.caption2)
                    .foregroundStyle(levelColor)
                Text(entry.level.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let time = formattedTime {
                    Text(time).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(entry.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
        .padding(.vertical, 3)
    }

    private var levelColor: Color {
        switch entry.level.lowercased() {
        case "error", "critical": .red
        case "warning": .orange
        default: .secondary
        }
    }

    private var levelIcon: String {
        switch entry.level.lowercased() {
        case "error", "critical": "xmark.octagon.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "circle.fill"
        }
    }

    private var formattedTime: String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss,SSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: entry.timestamp) {
                return date.formatted(date: .abbreviated, time: .shortened)
            }
        }
        return entry.timestamp
    }
}

// MARK: - All Events Entry Row

private struct AllEventsEntryRow: View {
    let entry: AllEventsViewModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: entry.service.serviceIdentity.systemImage)
                    .font(.caption2)
                    .foregroundStyle(entry.service.serviceIdentity.brandColor)

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

// MARK: - Arr Events ViewModel

@MainActor
@Observable
final class ArrEventsViewModel {
    private(set) var records: [ArrLogRecord] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    private let client: any SharedArrClient
    private let pageSize = 50
    private var totalRecords = 0
    private var loadMoreFailed = false

    var hasMore: Bool { !loadMoreFailed && records.count < totalRecords }

    init(client: any SharedArrClient) {
        self.client = client
    }

    func load(level: String?) async {
        isLoading = true
        errorMessage = nil
        loadMoreFailed = false
        do {
            let page = try await client.getLog(page: 1, pageSize: pageSize, level: level)
            records = page.records ?? []
            totalRecords = page.totalRecords ?? 0
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore(level: String?) async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let nextPage = (records.count / pageSize) + 1
            let page = try await client.getLog(page: nextPage, pageSize: pageSize, level: level)
            records.append(contentsOf: page.records ?? [])
            totalRecords = page.totalRecords ?? totalRecords
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}

// MARK: - Bazarr Events ViewModel

@MainActor
@Observable
final class BazarrEventsViewModel {
    private(set) var entries: [BazarrLogEntry] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    private let client: BazarrAPIClient
    private let pageSize = 50
    private var totalEntries = 0
    private var loadMoreFailed = false

    var hasMore: Bool { !loadMoreFailed && entries.count < totalEntries }

    init(client: BazarrAPIClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        loadMoreFailed = false
        do {
            let page = try await client.getLogs(start: 0, length: pageSize)
            entries = page.data
            totalEntries = page.total
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let page = try await client.getLogs(start: entries.count, length: pageSize)
            entries.append(contentsOf: page.data)
            totalEntries = page.total
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}

// MARK: - All Events ViewModel

@MainActor
@Observable
final class AllEventsViewModel {
    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let service: ArrServiceType
        let level: String
        let logger: String?
        let message: String
        let timestamp: Date
        let exceptionType: String?
    }

    private(set) var entries: [Entry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let sonarrClient: (any SharedArrClient)?
    private let radarrClient: (any SharedArrClient)?
    private let prowlarrClient: (any SharedArrClient)?
    private let bazarrClient: BazarrAPIClient?
    private let pageSize = 50

    init(
        sonarrClient: (any SharedArrClient)?,
        radarrClient: (any SharedArrClient)?,
        prowlarrClient: (any SharedArrClient)?,
        bazarrClient: BazarrAPIClient?
    ) {
        self.sonarrClient = sonarrClient
        self.radarrClient = radarrClient
        self.prowlarrClient = prowlarrClient
        self.bazarrClient = bazarrClient
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        let pageSize = self.pageSize
        let sonarrClient = self.sonarrClient
        let radarrClient = self.radarrClient
        let prowlarrClient = self.prowlarrClient
        let bazarrClient = self.bazarrClient

        var allEntries: [Entry] = []

        await withTaskGroup(of: [Entry].self) { group in
            if let client = sonarrClient {
                group.addTask { await Self.arrEntries(client: client, service: .sonarr, pageSize: pageSize) }
            }
            if let client = radarrClient {
                group.addTask { await Self.arrEntries(client: client, service: .radarr, pageSize: pageSize) }
            }
            if let client = prowlarrClient {
                group.addTask { await Self.arrEntries(client: client, service: .prowlarr, pageSize: pageSize) }
            }
            if let client = bazarrClient {
                group.addTask { await Self.bazarrEntries(client: client, pageSize: pageSize) }
            }
            for await batch in group { allEntries.append(contentsOf: batch) }
        }

        entries = allEntries.sorted { $0.timestamp > $1.timestamp }
        isLoading = false
    }

    private static func arrEntries(client: any SharedArrClient, service: ArrServiceType, pageSize: Int) async -> [Entry] {
        guard let page = try? await client.getLog(page: 1, pageSize: pageSize, level: nil) else { return [] }
        return (page.records ?? []).compactMap { record in
            guard let timestamp = parseArrDate(record.time) else { return nil }
            return Entry(
                service: service,
                level: record.level ?? "info",
                logger: record.logger,
                message: record.message ?? "",
                timestamp: timestamp,
                exceptionType: record.exceptionType
            )
        }
    }

    private static func bazarrEntries(client: BazarrAPIClient, pageSize: Int) async -> [Entry] {
        guard let page = try? await client.getLogs(start: 0, length: pageSize) else { return [] }
        return page.data.compactMap { logEntry in
            guard let timestamp = parseBazarrDate(logEntry.timestamp) else { return nil }
            return Entry(
                service: .bazarr,
                level: logEntry.level,
                logger: nil,
                message: logEntry.message,
                timestamp: timestamp,
                exceptionType: nil
            )
        }
    }

    private static func parseArrDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func parseBazarrDate(_ raw: String) -> Date? {
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

    // Bazarr levels: DEBUG, INFO, WARNING, ERROR, CRITICAL
    func includesBazarrLevel(_ level: String) -> Bool {
        let priority: [String: Int] = ["debug": 0, "info": 1, "warning": 2, "error": 3, "critical": 4]
        let min: Int = switch self { case .all: -1; case .info: 1; case .warn: 2; case .error: 3 }
        return (priority[level.lowercased()] ?? 0) >= min
    }

    // Arr levels: trace, debug, info, warn, error, fatal
    func includesArrLevel(_ level: String) -> Bool {
        switch self {
        case .all: true
        case .info: !["trace", "debug"].contains(level.lowercased())
        case .warn: ["warn", "error", "fatal"].contains(level.lowercased())
        case .error: ["error", "fatal"].contains(level.lowercased())
        }
    }
}
