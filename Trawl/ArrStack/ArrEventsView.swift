import SwiftUI

// MARK: - Unified Log Entry

struct UnifiedLogEntry: Identifiable, Sendable {
    let id: String
    let service: ArrServiceType
    /// The server that logged this line. Both halves of a pair log the same
    /// messages, so a merged "All" view is unreadable without it.
    var instance: ArrInstanceRef?
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
    case instance(ArrInstanceRef)
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
        let previewVM = ArrEventsViewModel()
        previewVM.setPreviewEntries(previewEntries)
        _vm = State(initialValue: previewVM)
        if let selectedService {
            _selectedSelection = State(initialValue: .instance(.preview(selectedService)))
        }
    }

    init(previewLoadingServices: [ArrServiceType], selectedService: ArrServiceType? = nil) {
        let previewVM = ArrEventsViewModel()
        previewVM.setPreviewLoading(previewLoadingServices)
        _vm = State(initialValue: previewVM)
        if let selectedService {
            _selectedSelection = State(initialValue: .instance(.preview(selectedService)))
        }
    }

    init(previewError: String, services: [ArrServiceType], selectedService: ArrServiceType? = nil) {
        let previewVM = ArrEventsViewModel()
        previewVM.setPreviewError(previewError, for: services)
        _vm = State(initialValue: previewVM)
        if let selectedService {
            _selectedSelection = State(initialValue: .instance(.preview(selectedService)))
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
        if availableInstances.count > 1 {
            items.append(TrawlSegmentBarItem("All", value: .all))
        }
        for instance in availableInstances {
            items.append(TrawlSegmentBarItem(serviceManager.scopeLabel(for: instance), value: .instance(instance)))
        }
        return items
    }

    /// Every server that logs: both halves of each Arr pair, plus Prowlarr and
    /// Bazarr.
    private var availableInstances: [ArrInstanceRef] {
        availableServices.flatMap { service in
            if service == .bazarr {
                return serviceManager.instanceRef(.bazarr, id: serviceManager.activeBazarrProfileID).map { [$0] } ?? []
            }
            return serviceManager.refs(for: service)
        }
    }

    /// The badge for a log line, suppressed when its service has only one server.
    private func instanceBadge(for entry: UnifiedLogEntry) -> ArrInstanceRef? {
        guard let instance = entry.instance,
              serviceManager.showsInstanceProvenance(for: instance.serviceType) else { return nil }
        return instance
    }

    private func stateKey(for instance: ArrInstanceRef) -> UUID {
        instance.serviceType == .bazarr ? ArrEventsViewModel.bazarrStateKey : instance.id
    }

    private var allEntries: [UnifiedLogEntry] {
        availableInstances
            .flatMap { vm.entries(for: stateKey(for: $0)) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var displayedEntries: [UnifiedLogEntry] {
        let query = committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: [UnifiedLogEntry]
        if !query.isEmpty {
            raw = allEntries
        } else {
            switch selectedSelection {
            case .all:
                raw = allEntries
            case .instance(let instance):
                raw = vm.entries(for: stateKey(for: instance))
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
        case .all: availableInstances.contains { vm.isLoading(for: stateKey(for: $0)) }
        case .instance(let instance): vm.isLoading(for: stateKey(for: instance))
        }
    }

    private var currentError: String? {
        switch selectedSelection {
        case .all: nil
        case .instance(let instance): vm.errorMessage(for: stateKey(for: instance))
        }
    }

    private var navigationSubtitleText: String {
        switch selectedSelection {
        case .all: availableInstances.count > 1 ? "All Servers" : (availableInstances.first.map { serviceManager.scopeLabel(for: $0) } ?? "")
        case .instance(let instance): serviceManager.scopeLabel(for: instance)
        }
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ServiceSetupView(title: "No Services Configured", message: "Add a Sonarr, Radarr, Prowlarr, or Bazarr server in Settings to view events.", systemImage: "list.bullet.rectangle")
                .scrollableUnavailableState()
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
        .toolbar { eventsToolbar }
        .loadServicesPeriodically(
            id: availableInstances.map(\.id.uuidString).joined(separator: "|"),
            keys: availableInstances
        ) { instance in
            await loadService(instance)
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
            if case .all = selectedSelection, availableInstances.count < 2, let first = availableInstances.first {
                withAnimation { selectedSelection = .instance(first) }
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var logList: some View {
        List {
            if let error = currentError {
                ServiceErrorView(
                    title: "Events Unavailable",
                    message: error,
                    hasContent: !displayedEntries.isEmpty,
                    onRetry: { for instance in availableInstances { await loadService(instance) } }
                )
            }

            if isCurrentLoading && displayedEntries.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else if displayedEntries.isEmpty {
                if currentError == nil {
                    ContentUnavailableView(
                        "No Events",
                        systemImage: "list.bullet.rectangle",
                        description: Text("No log entries match the current filter.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(displayedEntries) { entry in
                        Button {
                            selectedEntry = entry
                        } label: {
                            UnifiedEventRow(
                                entry: entry,
                                showServiceBadge: selectedSelection == .all,
                                instanceBadge: instanceBadge(for: entry)
                            )
                        }
                        .buttonStyle(.plain)
                        .task {
                            guard case .instance(let instance) = selectedSelection,
                                  entry.id == vm.entries(for: stateKey(for: instance)).last?.id
                            else { return }
                            await loadMore(for: instance)
                        }
                    }
                    if case .instance(let instance) = selectedSelection,
                       vm.isLoadingMore(for: stateKey(for: instance)) {
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
        // Background and filter bar both on the list, in that order - the
        // arrangement Seerr Logs and Jellyfin Activity use, and the one this screen
        // did not: it painted the gradient on the outer `Group` and then added the
        // bar outside it, so the bar sat on unpainted white. The outer `Group` keeps
        // its own background for the empty and unreachable states, which are not
        // lists and have no list background to clear.
        .moreDestinationBackground(.logsAndEvents)
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
        .refreshable {
            await withTaskGroup(of: Void.self) { group in
                for instance in availableInstances {
                    group.addTask { await loadService(instance) }
                }
            }
        }
        .animation(.default, value: displayedEntries.map(\.id))
    }

    // MARK: - Load

    /// Lifted out of `body`: the filter menu plus the export/share items in one
    /// expression pushed the type checker past its budget once the selection
    /// started carrying a server.
    @ToolbarContentBuilder
    private var eventsToolbar: some ToolbarContent {
        if !availableServices.isEmpty {
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                ShareLink(item: exportText, preview: SharePreview("Arr Events")) {
                    Label("Share Events", systemImage: "square.and.arrow.up")
                }
                .disabled(displayedEntries.isEmpty)

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
                    Label(
                        "Filter Log Level",
                        systemImage: selectedLevel == .all
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    @MainActor
    private func loadService(_ instance: ArrInstanceRef) async {
        #if DEBUG
        if ArrPreviewRuntime.isActive { return }
        #endif
        if instance.serviceType == .bazarr {
            guard let client = serviceManager.activeBazarrEntry?.client else { return }
            await vm.loadBazarr(client: client)
            return
        }
        guard let client = serviceManager.sharedClient(for: instance) else { return }
        await vm.load(instance: instance, client: client)
    }

    @MainActor
    private func loadMore(for instance: ArrInstanceRef) async {
        if instance.serviceType == .bazarr {
            guard let client = serviceManager.activeBazarrEntry?.client else { return }
            await vm.loadMoreBazarr(client: client)
            return
        }
        guard let client = serviceManager.sharedClient(for: instance) else { return }
        await vm.loadMore(instance: instance, client: client)
    }

    private var exportText: String {
        let lines = displayedEntries.map { entry in
            var details = [
                "[\(entry.timestamp.formatted(date: .numeric, time: .standard))]",
                "[\(entry.service.displayName)]",
                "[\(entry.level.uppercased())]"
            ]
            if let instance = entry.instance,
               serviceManager.showsInstanceProvenance(for: instance.serviceType) {
                details.insert("[\(instance.shortLabel)]", at: 2)
            }
            if let logger = entry.logger, !logger.isEmpty {
                details.append("[\(logger)]")
            }
            details.append(entry.message)
            if let exceptionType = entry.exceptionType, !exceptionType.isEmpty {
                details.append("\nException: \(exceptionType)")
            }
            if let exception = entry.exception, !exception.isEmpty {
                details.append("\n\(exception)")
            }
            return details.joined(separator: " ")
        }
        return (["Arr Events", "Exported \(Date.now.formatted(date: .numeric, time: .standard))", ""] + lines)
            .joined(separator: "\n")
    }
}

// MARK: - Unified Event Row

private struct UnifiedEventRow: View {
    let entry: UnifiedLogEntry
    let showServiceBadge: Bool
    /// The server that logged the line, when there is more than one of its
    /// service. Both halves of a pair log identical messages, so an unbadged
    /// merged view cannot be read.
    var instanceBadge: ArrInstanceRef? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if showServiceBadge {
                    Image(systemName: entry.service.serviceIdentity.systemImage)
                        .font(.caption2)
                        .foregroundStyle(entry.service.serviceIdentity.brandColor)
                }
                if let instanceBadge {
                    ArrInstanceBadge(label: instanceBadge.shortLabel, ordinal: instanceBadge.ordinal)
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

    // Keyed by server: each box keeps its own log.
    private var states: [UUID: ServiceState] = [:]
    private let pageSize = 50

    func entries(for instance: UUID) -> [UnifiedLogEntry] {
        states[instance]?.entries ?? []
    }

    func isLoading(for instance: UUID) -> Bool {
        states[instance]?.isLoading ?? false
    }

    func isLoadingMore(for instance: UUID) -> Bool {
        states[instance]?.isLoadingMore ?? false
    }

    func hasMore(for instance: UUID) -> Bool {
        states[instance]?.hasMore ?? false
    }

    func errorMessage(for instance: UUID) -> String? {
        states[instance]?.errorMessage
    }

    func load(instance: ArrInstanceRef, client: any SharedArrClient) async {
        mutate(instance.id) { $0.isLoading = true; $0.errorMessage = nil; $0.loadMoreFailed = false }
        do {
            let page = try await client.getLog(page: 1, pageSize: pageSize, level: nil)
            let entries = (page.records ?? []).compactMap { makeEntry(from: $0, instance: instance) }
            mutate(instance.id) {
                $0.entries = entries
                $0.total = page.totalRecords ?? 0
                $0.isLoading = false
            }
        } catch {
            mutate(instance.id) { $0.errorMessage = error.localizedDescription; $0.isLoading = false }
        }
    }

    func loadMore(instance: ArrInstanceRef, client: any SharedArrClient) async {
        guard states[instance.id]?.hasMore == true, states[instance.id]?.isLoadingMore == false else { return }
        mutate(instance.id) { $0.isLoadingMore = true }
        do {
            let count = states[instance.id]?.entries.count ?? 0
            let nextPage = (count / pageSize) + 1
            let page = try await client.getLog(page: nextPage, pageSize: pageSize, level: nil)
            let newEntries = (page.records ?? []).compactMap { makeEntry(from: $0, instance: instance) }
            mutate(instance.id) {
                $0.entries.append(contentsOf: newEntries)
                $0.total = page.totalRecords ?? $0.total
                $0.isLoadingMore = false
            }
        } catch {
            mutate(instance.id) { $0.loadMoreFailed = true; $0.isLoadingMore = false }
        }
    }

    func loadBazarr(client: BazarrAPIClient) async {
        mutate(Self.bazarrStateKey) { $0.isLoading = true; $0.errorMessage = nil; $0.loadMoreFailed = false }
        do {
            let page = try await client.getLogs(start: 0, length: pageSize)
            let entries = page.data.compactMap { makeEntry(from: $0) }
            mutate(Self.bazarrStateKey) { $0.entries = entries; $0.total = page.total; $0.isLoading = false }
        } catch {
            mutate(Self.bazarrStateKey) { $0.errorMessage = error.localizedDescription; $0.isLoading = false }
        }
    }

    func loadMoreBazarr(client: BazarrAPIClient) async {
        guard states[Self.bazarrStateKey]?.hasMore == true, states[Self.bazarrStateKey]?.isLoadingMore == false else { return }
        mutate(Self.bazarrStateKey) { $0.isLoadingMore = true }
        do {
            let count = states[Self.bazarrStateKey]?.entries.count ?? 0
            let page = try await client.getLogs(start: count, length: pageSize)
            let newEntries = page.data.compactMap { makeEntry(from: $0) }
            mutate(Self.bazarrStateKey) {
                $0.entries.append(contentsOf: newEntries)
                $0.total = page.total
                $0.isLoadingMore = false
            }
        } catch {
            mutate(Self.bazarrStateKey) { $0.loadMoreFailed = true; $0.isLoadingMore = false }
        }
    }

    /// Bazarr has no Arr pair, so it gets a fixed key of its own rather than a
    /// server ID.
    static let bazarrStateKey = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1))

    private func mutate(_ instance: UUID, _ modify: (inout ServiceState) -> Void) {
        var state = states[instance] ?? ServiceState()
        modify(&state)
        states[instance] = state
    }

    private func makeEntry(from record: ArrLogRecord, instance: ArrInstanceRef) -> UnifiedLogEntry? {
        guard let timestamp = parseArrDate(record.time) else { return nil }
        return UnifiedLogEntry(
            // Keyed by server: both instances number their log rows from the same
            // sequence, so the service alone is not unique across a pair.
            id: "\(instance.id.uuidString)-\(record.id)",
            service: instance.serviceType,
            instance: instance,
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
            mutate(ArrInstanceRef.preview(service).id) {
                $0.entries = entries.sorted { $0.timestamp > $1.timestamp }
                $0.total = entries.count
                $0.isLoading = false
                $0.errorMessage = nil
            }
        }
    }

    func setPreviewLoading(_ services: [ArrServiceType]) {
        for service in services {
            mutate(ArrInstanceRef.preview(service).id) {
                $0.isLoading = true
                $0.errorMessage = nil
            }
        }
    }

    func setPreviewError(_ error: String, for services: [ArrServiceType]) {
        for service in services {
            mutate(ArrInstanceRef.preview(service).id) {
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
