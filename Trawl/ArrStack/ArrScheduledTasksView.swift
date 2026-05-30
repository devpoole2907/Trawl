import SwiftUI

struct ArrScheduledTasksView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var vm = ArrTasksViewModel()
    @State private var selectedService: ArrServiceType = .sonarr
    @State private var showSettings = false
    @State private var taskSearchText = ""
    @State private var isSearchExpanded = false

    #if DEBUG
    init(
        previewTasks: [ArrServiceType: [ArrScheduledTask]] = [:],
        previewCommands: [ArrServiceType: [ArrCommand]] = [:],
        previewBazarrTasks: [BazarrTask] = [],
        selectedService: ArrServiceType = .sonarr
    ) {
        let previewVM = ArrTasksViewModel()
        previewVM.setPreviewTasks(tasks: previewTasks, commands: previewCommands, bazarrTasks: previewBazarrTasks)
        _vm = State(initialValue: previewVM)
        _selectedService = State(initialValue: selectedService)
    }

    init(previewLoadingServices: [ArrServiceType], selectedService: ArrServiceType = .sonarr) {
        let previewVM = ArrTasksViewModel()
        previewVM.setPreviewLoading(previewLoadingServices)
        _vm = State(initialValue: previewVM)
        _selectedService = State(initialValue: selectedService)
    }

    init(previewError: String, services: [ArrServiceType], selectedService: ArrServiceType = .sonarr) {
        let previewVM = ArrTasksViewModel()
        previewVM.setPreviewError(previewError, for: services)
        _vm = State(initialValue: previewVM)
        _selectedService = State(initialValue: selectedService)
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

    private var currentScheduledTasks: [ArrScheduledTask] {
        selectedService == .bazarr ? [] : vm.scheduledTasks(for: selectedService)
    }

    private var currentCommandQueue: [ArrCommand] {
        selectedService == .bazarr ? [] : vm.commandQueue(for: selectedService)
    }

    private var currentBazarrTasks: [BazarrTask] {
        selectedService == .bazarr ? vm.bazarrTasks : []
    }

    private var isCurrentLoading: Bool {
        vm.isLoading(for: selectedService)
    }

    private var currentError: String? {
        vm.errorMessage(for: selectedService)
    }

    private var taskSearchQuery: String {
        taskSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTaskSearch: Bool {
        !taskSearchQuery.isEmpty
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("Add a Sonarr, Radarr, Prowlarr, or Bazarr server in Settings to view tasks.")
                )
            } else if !hasAnyConnected {
                ArrServicesConnectionStatusView(
                    services: availableServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured services."
                )
            } else {
                taskList
            }
        }
        .navigationTitle("Tasks")
        .navigationSubtitle(hasTaskSearch ? "Search" : selectedService.displayName)
        .moreDestinationBackground(.tasks)
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Service",
                selection: Binding(
                    get: { selectedService },
                    set: { newService in withAnimation { selectedService = newService } }
                ),
                items: availableServices.map(\.segmentBarItem),
                searchText: $taskSearchText,
                searchHint: "Search tasks",
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
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var taskList: some View {
        List {
            if hasTaskSearch {
                searchResultsList
            } else if let error = currentError {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if isCurrentLoading && currentScheduledTasks.isEmpty && currentBazarrTasks.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else {
                if !currentScheduledTasks.isEmpty {
                    Section("Scheduled") {
                        ForEach(currentScheduledTasks) { task in
                            ArrScheduledTaskRow(task: task) {
                                await triggerArrTask(task)
                            }
                        }
                    }
                }

                if !currentCommandQueue.isEmpty {
                    Section("Queue") {
                        ForEach(currentCommandQueue) { command in
                            ArrCommandQueueRow(command: command)
                        }
                    }
                }

                if !currentBazarrTasks.isEmpty {
                    Section("Scheduled") {
                        ForEach(currentBazarrTasks) { task in
                            BazarrTaskRow(task: task) {
                                await triggerBazarrTask(task)
                            }
                        }
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
        .refreshable { await loadService(selectedService) }
        .animation(.default, value: currentScheduledTasks.map(\.id))
        .animation(.default, value: currentBazarrTasks.map(\.id))
    }

    @ViewBuilder
    private var searchResultsList: some View {
        let query = taskSearchQuery
        let sections = taskSearchSections(matching: query)

        if sections.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        } else {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        switch item.kind {
                        case .scheduled(let task):
                            ArrScheduledTaskRow(task: task) {
                                await triggerArrTask(task, service: item.service)
                            }
                        case .queue(let command):
                            ArrCommandQueueRow(command: command)
                        case .bazarr(let task):
                            BazarrTaskRow(task: task) {
                                await triggerBazarrTask(task)
                            }
                        }
                    }
                }
            }
        }
    }

    private func taskSearchSections(matching query: String) -> [TaskSearchSection] {
        availableServices.flatMap { service -> [TaskSearchSection] in
            if service == .bazarr {
                let items = vm.bazarrTasks
                    .filter { $0.matchesTaskSearch(query) }
                    .map { TaskSearchItem(service: service, kind: .bazarr($0)) }
                return items.isEmpty ? [] : [TaskSearchSection(title: "\(service.displayName) Scheduled", items: items)]
            }

            let scheduled = vm.scheduledTasks(for: service)
                .filter { $0.matchesTaskSearch(query) }
                .map { TaskSearchItem(service: service, kind: .scheduled($0)) }
            let queue = vm.commandQueue(for: service)
                .filter { $0.matchesTaskSearch(query) }
                .map { TaskSearchItem(service: service, kind: .queue($0)) }

            var sections: [TaskSearchSection] = []
            if !scheduled.isEmpty {
                sections.append(TaskSearchSection(title: "\(service.displayName) Scheduled", items: scheduled))
            }
            if !queue.isEmpty {
                sections.append(TaskSearchSection(title: "\(service.displayName) Queue", items: queue))
            }
            return sections
        }
    }

    // MARK: - Load & Trigger

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
    private func triggerArrTask(_ task: ArrScheduledTask) async {
        await triggerArrTask(task, service: selectedService)
    }

    @MainActor
    private func triggerArrTask(_ task: ArrScheduledTask, service: ArrServiceType) async {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else { return }
            await vm.triggerTask(task, service: .sonarr, client: client)
        case .radarr:
            guard let client = serviceManager.radarrClient else { return }
            await vm.triggerTask(task, service: .radarr, client: client)
        case .prowlarr:
            guard let client = serviceManager.prowlarrClient else { return }
            await vm.triggerTask(task, service: .prowlarr, client: client)
        case .bazarr:
            break
        }
        await loadService(service)
    }

    @MainActor
    private func triggerBazarrTask(_ task: BazarrTask) async {
        guard let client = serviceManager.activeBazarrEntry?.client else { return }
        await vm.triggerBazarrTask(task, client: client)
        await loadService(.bazarr)
    }
}

private struct TaskSearchSection: Identifiable {
    let title: String
    let items: [TaskSearchItem]

    var id: String { title }
}

private struct TaskSearchItem: Identifiable {
    let service: ArrServiceType
    let kind: TaskSearchItemKind

    var id: String {
        "\(service.rawValue)-\(kind.id)"
    }
}

private enum TaskSearchItemKind {
    case scheduled(ArrScheduledTask)
    case queue(ArrCommand)
    case bazarr(BazarrTask)

    var id: String {
        switch self {
        case .scheduled(let task):
            "scheduled-\(task.id)"
        case .queue(let command):
            "queue-\(command.id.map(String.init) ?? command.commandName ?? command.name ?? command.queued ?? "unknown")"
        case .bazarr(let task):
            "bazarr-\(task.id)"
        }
    }
}

private extension ArrScheduledTask {
    func matchesTaskSearch(_ query: String) -> Bool {
        [
            name,
            taskName,
            lastStartMessage
        ].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

private extension ArrCommand {
    func matchesTaskSearch(_ query: String) -> Bool {
        [
            name,
            commandName,
            status,
            trigger,
            exception
        ].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

private extension BazarrTask {
    func matchesTaskSearch(_ query: String) -> Bool {
        [
            name,
            jobId,
            interval
        ].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

#if DEBUG
extension ArrTasksViewModel {
    func setPreviewTasks(
        tasks: [ArrServiceType: [ArrScheduledTask]],
        commands: [ArrServiceType: [ArrCommand]] = [:],
        bazarrTasks: [BazarrTask] = []
    ) {
        for service in [ArrServiceType.sonarr, .radarr, .prowlarr] {
            mutate(service) {
                $0.scheduledTasks = tasks[service] ?? []
                $0.commandQueue = commands[service] ?? []
                $0.isLoading = false
                $0.errorMessage = nil
            }
        }
        bazarr.tasks = bazarrTasks
        bazarr.isLoading = false
        bazarr.errorMessage = nil
    }

    func setPreviewLoading(_ services: [ArrServiceType]) {
        for service in services where service != .bazarr {
            mutate(service) { $0.isLoading = true; $0.errorMessage = nil }
        }
        if services.contains(.bazarr) {
            bazarr.isLoading = true
            bazarr.errorMessage = nil
        }
    }

    func setPreviewError(_ error: String, for services: [ArrServiceType]) {
        for service in services where service != .bazarr {
            mutate(service) { $0.isLoading = false; $0.errorMessage = error }
        }
        if services.contains(.bazarr) {
            bazarr.isLoading = false
            bazarr.errorMessage = error
        }
    }
}

#Preview("Tasks - Loaded") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrScheduledTasksView(
                previewTasks: [.sonarr: ArrScheduledTask.previewList],
                previewCommands: [.sonarr: ArrCommand.previewList],
                previewBazarrTasks: [
                    BazarrTask(interval: "Every 6 hours", jobId: "series-sync", jobRunning: false, name: "Sync Series", nextRunIn: "2 hours", nextRunTime: "2026-05-24 12:00:00")
                ]
            )
        }
    }
}

#Preview("Tasks - Empty") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrScheduledTasksView(previewTasks: [.sonarr: []])
        }
    }
}

#Preview("Tasks - Loading") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrScheduledTasksView(previewLoadingServices: [.sonarr], selectedService: .sonarr)
        }
    }
}

#Preview("Tasks - Error") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrScheduledTasksView(
                previewError: "Failed to load tasks: The operation couldn't be completed.",
                services: [.sonarr],
                selectedService: .sonarr
            )
        }
    }
}

#Preview("Tasks - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrScheduledTasksView()
        }
    }
}
#endif

// MARK: - Arr Scheduled Task Row

private struct ArrScheduledTaskRow: View {
    let task: ArrScheduledTask
    let onTrigger: () async -> Void

    var body: some View {
        ScheduledTaskControlRow(item: task, action: taskAction)
    }

    private var taskAction: ScheduledTaskRowAction {
        ScheduledTaskRowAction.runTask(
            title: task.scheduledTaskRowTitle,
            isDisabled: task.taskName == nil || task.isRunning == true
        ) {
            await onTrigger()
        }
    }
}

extension ArrScheduledTask: ScheduledTaskRowRepresentable {
    var scheduledTaskRowTitle: String {
        name ?? "Unknown Task"
    }

    var scheduledTaskRowStatus: ScheduledTaskRowStatus {
        .activity(isRunning: isRunning == true)
    }

    var scheduledTaskRowDetails: [ScheduledTaskRowDetail] {
        var details: [ScheduledTaskRowDetail] = []

        if let interval {
            details.append(.interval(ScheduledTaskRowFormatter.compactIntervalText(minutes: interval)))
        }
        if let lastExecutionDetail {
            details.append(lastExecutionDetail)
        }
        if let nextExecutionDetail {
            details.append(nextExecutionDetail)
        }
        if let duration = ScheduledTaskRowFormatter.cleanedText(lastDuration), duration != "00:00:00" {
            details.append(.duration(duration))
        }

        return details
    }

    private var lastExecutionDetail: ScheduledTaskRowDetail? {
        ScheduledTaskRowDetail.lastRun(from: lastExecution)
    }

    private var nextExecutionDetail: ScheduledTaskRowDetail? {
        ScheduledTaskRowDetail.nextRun(from: nextExecution)
    }
}

// MARK: - Bazarr Task Row

private struct BazarrTaskRow: View {
    let task: BazarrTask
    let onTrigger: () async -> Void

    var body: some View {
        ScheduledTaskControlRow(item: task, action: taskAction)
    }

    private var taskAction: ScheduledTaskRowAction {
        ScheduledTaskRowAction.runTask(
            title: task.scheduledTaskRowTitle,
            isDisabled: task.jobRunning
        ) {
            await onTrigger()
        }
    }
}

extension BazarrTask: ScheduledTaskRowRepresentable {
    var scheduledTaskRowTitle: String {
        name
    }

    var scheduledTaskRowStatus: ScheduledTaskRowStatus {
        .activity(isRunning: jobRunning)
    }

    var scheduledTaskRowDetails: [ScheduledTaskRowDetail] {
        [
            ScheduledTaskRowFormatter.cleanedText(interval).map { ScheduledTaskRowDetail.interval($0) },
            nextRunDetail
        ].compactMap { $0 }
    }

    private var nextRunDetail: ScheduledTaskRowDetail? {
        if let detail = ScheduledTaskRowDetail.nextRun(from: nextRunTime) { return detail }
        return ScheduledTaskRowFormatter.cleanedText(nextRunIn).map { .nextRun($0) }
    }
}

// MARK: - Arr Command Queue Row

private struct ArrCommandQueueRow: View {
    let command: ArrCommand

    var body: some View {
        ScheduledTaskRowView(
            icon: statusIcon,
            iconColor: statusColor,
            title: command.commandName ?? command.name ?? "Command",
            badge: command.status.map { ScheduledTaskRowBadge($0.capitalized, color: statusColor) },
            details: commandDetails
        )
    }

    private var commandDetails: [ScheduledTaskRowDetail] {
        guard let queued = queuedDetail else { return [] }
        return [queued]
    }

    private var queuedDetail: ScheduledTaskRowDetail? {
        ScheduledTaskRowDetail.queued(from: command.queued)
    }

    private var statusIcon: String {
        switch command.status {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "started": "arrow.triangle.2.circlepath"
        default: "clock"
        }
    }

    private var statusColor: Color {
        switch command.status {
        case "completed": .green
        case "failed": .red
        case "started": .blue
        default: .secondary
        }
    }

}

// MARK: - Tasks ViewModel

@MainActor
@Observable
final class ArrTasksViewModel {
    private struct ArrState {
        var scheduledTasks: [ArrScheduledTask] = []
        var commandQueue: [ArrCommand] = []
        var isLoading = false
        var errorMessage: String?
    }

    private struct BazarrState {
        var tasks: [BazarrTask] = []
        var isLoading = false
        var errorMessage: String?
    }

    private var arrStates: [ArrServiceType: ArrState] = [:]
    private var bazarr = BazarrState()

    func scheduledTasks(for service: ArrServiceType) -> [ArrScheduledTask] {
        arrStates[service]?.scheduledTasks ?? []
    }

    func commandQueue(for service: ArrServiceType) -> [ArrCommand] {
        arrStates[service]?.commandQueue ?? []
    }

    var bazarrTasks: [BazarrTask] { bazarr.tasks }

    func isLoading(for service: ArrServiceType) -> Bool {
        service == .bazarr ? bazarr.isLoading : (arrStates[service]?.isLoading ?? false)
    }

    func errorMessage(for service: ArrServiceType) -> String? {
        service == .bazarr ? bazarr.errorMessage : arrStates[service]?.errorMessage
    }

    func load(service: ArrServiceType, client: any SharedArrClient) async {
        mutate(service) { $0.isLoading = true; $0.errorMessage = nil }
        do {
            async let tasks = client.getScheduledTasks()
            async let queue = client.getCommandQueue()
            let sorted = (try await tasks).sorted { ($0.name ?? "") < ($1.name ?? "") }
            let trimmed = (try await queue)
                .sorted { ($0.queued ?? "") > ($1.queued ?? "") }
                .prefix(20)
                .map { $0 }
            mutate(service) {
                $0.scheduledTasks = sorted
                $0.commandQueue = trimmed
                $0.isLoading = false
            }
        } catch {
            mutate(service) { $0.errorMessage = error.localizedDescription; $0.isLoading = false }
        }
    }

    func loadBazarr(client: BazarrAPIClient) async {
        bazarr.isLoading = true
        bazarr.errorMessage = nil
        do {
            bazarr.tasks = (try await client.getTasks()).sorted { $0.name < $1.name }
        } catch {
            bazarr.errorMessage = error.localizedDescription
        }
        bazarr.isLoading = false
    }

    func triggerTask(_ task: ArrScheduledTask, service: ArrServiceType, client: any SharedArrClient) async {
        guard let taskName = task.taskName else { return }
        do {
            _ = try await client.postCommand(name: taskName)
            try? await Task.sleep(for: .seconds(1))
        } catch {
            mutate(service) { $0.errorMessage = error.localizedDescription }
        }
    }

    func triggerBazarrTask(_ task: BazarrTask, client: BazarrAPIClient) async {
        do {
            try await client.runTask(taskId: task.jobId)
            try? await Task.sleep(for: .seconds(1))
        } catch {
            bazarr.errorMessage = error.localizedDescription
        }
    }

    private func mutate(_ service: ArrServiceType, _ modify: (inout ArrState) -> Void) {
        var state = arrStates[service] ?? ArrState()
        modify(&state)
        arrStates[service] = state
    }
}
