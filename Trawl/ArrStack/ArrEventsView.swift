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
    let exception: String?
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
    @State private var showSettings = false
    @State private var selectedEntry: UnifiedLogEntry?

    #if DEBUG
    init(previewEntries: [ArrServiceType: [UnifiedLogEntry]] = [:], selectedService: ArrServiceType? = nil) {
        var previewVM = ArrEventsViewModel()
        previewVM.setPreviewEntries(previewEntries)
        _vm = State(initialValue: previewVM)
        if let selectedService {
            _selectedSelection = State(initialValue: .service(selectedService))
        }
    }

    init(previewLoadingServices: [ArrServiceType], selectedService: ArrServiceType? = nil) {
        var previewVM = ArrEventsViewModel()
        previewVM.setPreviewLoading(previewLoadingServices)
        _vm = State(initialValue: previewVM)
        if let selectedService {
            _selectedSelection = State(initialValue: .service(selectedService))
        }
    }

    init(previewError: String, services: [ArrServiceType], selectedService: ArrServiceType? = nil) {
        var previewVM = ArrEventsViewModel()
        previewVM.setPreviewError(previewError, for: services)
        _vm = State(initialValue: previewVM)
        if let selectedService {
            _selectedSelection = State(initialValue: .service(selectedService))
        }
    }
    #endif

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
        if serviceManager.hasBazarrInstance { services.append(.bazarr) }
        return services
    }

    private var isAnyConnecting: Bool {
        serviceManager.isInitializing || availableServices.contains { serviceManager.isConnecting($0) }
    }

    private var hasAnyConnected: Bool {
        availableServices.contains { serviceManager.isConnected($0) }
    }

    private var primarySettingsService: ArrServiceType? {
        availableServices.first { !serviceManager.isConnected($0) } ?? availableServices.first
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
        let query = committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: [UnifiedLogEntry]
        if !query.isEmpty {
            raw = availableServices
                .flatMap { vm.entries(for: $0) }
                .sorted { $0.timestamp > $1.timestamp }
        } else {
            switch selectedSelection {
            case .all:
                raw = availableServices
                    .flatMap { vm.entries(for: $0) }
                    .sorted { $0.timestamp > $1.timestamp }
            case .service(let t):
                raw = vm.entries(for: t)
            }
        }

        let levelFiltered = raw.filter { entry in
            entry.service == .bazarr
                ? selectedLevel.includesBazarrLevel(entry.level)
                : selectedLevel.includesArrLevel(entry.level)
        }

        guard !query.isEmpty else { return levelFiltered }
        return levelFiltered.filter {
            $0.message.localizedCaseInsensitiveContains(query) ||
            ($0.logger ?? "").localizedCaseInsensitiveContains(query)
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

    private var navigationSubtitleText: String {
        switch selectedSelection {
        case .all: availableServices.count > 1 ? "All Services" : availableServices.first?.displayName ?? ""
        case .service(let t): t.displayName
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
            } else if !hasAnyConnected {
                ArrServicesConnectionStatusView(
                    services: availableServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured services."
                )
            } else {
                logList
            }
        }
        .navigationTitle("Events")
        .navigationSubtitle(navigationSubtitleText)
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
                alignment: .leading
            )
        }
        .loadServicesPeriodically(
            id: availableServices.map { "\($0.rawValue):\(serviceManager.isConnected($0))" }.joined(),
            keys: availableServices
        ) { service in
            await loadService(service)
        }
        .sheet(isPresented: $showSettings) {
            if let service = primarySettingsService {
                NavigationStack {
                    ArrServiceSettingsView(serviceType: service)
                        .environment(serviceManager)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
        }
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                ArrEventDetailView(entry: entry)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                        Button {
                            selectedEntry = entry
                        } label: {
                            UnifiedEventRow(
                                entry: entry,
                                showServiceBadge: selectedSelection == .all
                            )
                        }
                        .buttonStyle(.plain)
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
        #if DEBUG
        if ArrPreviewRuntime.isActive { return }
        #endif
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

// MARK: - Arr Event Detail View

private struct ArrEventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: UnifiedLogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: levelIcon)
                        .font(.title2)
                        .foregroundStyle(levelColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.logger ?? entry.service.serviceIdentity.displayName)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Label(entry.service.serviceIdentity.displayName, systemImage: entry.service.serviceIdentity.systemImage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(entry.service.serviceIdentity.brandColor)
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.message)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let exType = entry.exceptionType, !exType.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exception Type")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(exType)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let stack = entry.exception, !stack.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stack Trace")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(stack)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Event Detail")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
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
        default: "info.circle.fill"
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
            exceptionType: record.exceptionType,
            exception: record.exception
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
            exceptionType: nil,
            exception: nil
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

#if DEBUG
extension ArrEventsViewModel {
    func setPreviewEntries(_ entriesByService: [ArrServiceType: [UnifiedLogEntry]]) {
        for (service, entries) in entriesByService {
            mutate(service) {
                $0.entries = entries.sorted { $0.timestamp > $1.timestamp }
                $0.total = entries.count
                $0.isLoading = false
                $0.errorMessage = nil
            }
        }
    }

    func setPreviewLoading(_ services: [ArrServiceType]) {
        for service in services {
            mutate(service) {
                $0.isLoading = true
                $0.errorMessage = nil
            }
        }
    }

    func setPreviewError(_ error: String, for services: [ArrServiceType]) {
        for service in services {
            mutate(service) {
                $0.isLoading = false
                $0.errorMessage = error
            }
        }
    }
}

extension UnifiedLogEntry {
    static func preview(
        id: String,
        service: ArrServiceType,
        level: String,
        message: String,
        logger: String? = "Trawl.Preview",
        minutesAgo: Int = 0,
        exceptionType: String? = nil,
        exception: String? = nil
    ) -> UnifiedLogEntry {
        UnifiedLogEntry(
            id: id,
            service: service,
            level: level,
            logger: logger,
            message: message,
            timestamp: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            exceptionType: exceptionType,
            exception: exception
        )
    }
}
#endif

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

#if DEBUG
#Preview("Events - Loaded") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrEventsView(previewEntries: [
                .sonarr: [
                    .preview(id: "sonarr-1", service: .sonarr, level: "info", message: "RSS Sync completed", minutesAgo: 8),
                    .preview(id: "sonarr-2", service: .sonarr, level: "warn", message: "Indexer TorrentLeech unavailable", minutesAgo: 24),
                ],
                .radarr: [
                    .preview(id: "radarr-1", service: .radarr, level: "error", message: "Download client rejected release", minutesAgo: 31, exceptionType: "DownloadClientException"),
                ],
                .bazarr: [
                    .preview(id: "bazarr-1", service: .bazarr, level: "warning", message: "Provider throttled requests", minutesAgo: 16),
                ],
            ])
        }
    }
}

#Preview("Events - Empty") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrEventsView(previewEntries: [.sonarr: [], .radarr: []], selectedService: .sonarr)
        }
    }
}

#Preview("Events - Loading") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrEventsView(previewLoadingServices: [.sonarr, .radarr], selectedService: .sonarr)
        }
    }
}

#Preview("Events - Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrEventsView(
                previewError: "Failed to load: The operation couldn't be completed.",
                services: [.sonarr, .radarr],
                selectedService: .sonarr
            )
        }
    }
}

#Preview("Events - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrEventsView()
        }
    }
}
#endif
