import SwiftUI

struct ArrScheduledTasksView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var vm = ArrTasksViewModel()
    /// Which server's task list is on screen. Scheduled tasks and the command
    /// queue are per-server - a refresh running on the HD box says nothing about
    /// the 4K one - so the selector picks a server, not a service.
    @State private var selectedInstanceID: UUID?
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

    /// Every server that runs tasks: both halves of each Arr pair, plus Prowlarr
    /// and Bazarr.
    private var availableInstances: [ArrInstanceRef] {
        availableServices.flatMap { service in
            if service == .bazarr {
                return serviceManager.instanceRef(.bazarr, id: serviceManager.activeBazarrProfileID).map { [$0] } ?? []
            }
            return serviceManager.refs(for: service)
        }
    }

    private var selectedInstance: ArrInstanceRef? {
        availableInstances.first { $0.id == selectedInstanceID } ?? availableInstances.first
    }

    private var currentScheduledTasks: [ArrScheduledTask] {
        guard let instance = selectedInstance, instance.serviceType != .bazarr else { return [] }
        return vm.scheduledTasks(for: instance.id)
    }

    private var currentCommandQueue: [ArrCommand] {
        guard let instance = selectedInstance, instance.serviceType != .bazarr else { return [] }
        return vm.commandQueue(for: instance.id)
    }

    private var currentBazarrTasks: [BazarrTask] {
        selectedInstance?.serviceType == .bazarr ? vm.bazarrTasks : []
    }

    private var isCurrentLoading: Bool {
        guard let instance = selectedInstance else { return false }
        return instance.serviceType == .bazarr ? vm.isBazarrLoading : vm.isLoading(for: instance.id)
    }

    private var currentError: String? {
        guard let instance = selectedInstance else { return nil }
        return instance.serviceType == .bazarr ? vm.bazarrErrorMessage : vm.errorMessage(for: instance.id)
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
                ContentUnavailableView {
                    Label("No Services Configured", systemImage: "clock.arrow.2.circlepath")
                } description: {
                    Text("Add a Sonarr, Radarr, Prowlarr, or Bazarr server in Settings to view tasks.")
                } actions: {
                    MoreSettingsNavigationLink()
                }
                .scrollableUnavailableState()
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
        .navigationSubtitle(hasTaskSearch ? "Search" : (selectedInstance.map { serviceManager.scopeLabel(for: $0) } ?? ""))
        .moreDestinationBackground(.tasks)
        .safeAreaInset(edge: .top) {
            if !availableInstances.isEmpty {
                TrawlSegmentBar(
                    "Server",
                    selection: Binding(
                        get: { selectedInstance?.id },
                        set: { newValue in withAnimation { selectedInstanceID = newValue } }
                    ),
                    items: availableInstances.map {
                        TrawlSegmentBarItem(serviceManager.scopeLabel(for: $0), value: Optional($0.id))
                    },
                    searchText: $taskSearchText,
                    searchHint: "Search tasks",
                    isSearchExpanded: $isSearchExpanded,
                    searchPlacement: .leading,
                    alignment: .leading
                )
            }
        }
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
        .onAppear {
            if selectedInstanceID == nil || !availableInstances.contains(where: { $0.id == selectedInstanceID }) {
                selectedInstanceID = availableInstances.first?.id
            }
        }
        .onChange(of: selectedInstance?.serviceType) { _, newValue in
            if let newValue { selectedService = newValue }
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
        .refreshable { if let instance = selectedInstance { await loadService(instance) } }
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
                                if let instance = item.instance {
                                    await triggerArrTask(task, on: instance)
                                }
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

    /// Searches every server, not every service - with a pair configured the same
    /// task name exists twice and each hit has to run on its own box.
    private func taskSearchSections(matching query: String) -> [TaskSearchSection] {
        availableInstances.flatMap { instance -> [TaskSearchSection] in
            let service = instance.serviceType
            let title = serviceManager.scopeLabel(for: instance)

            if service == .bazarr {
                let items = vm.bazarrTasks
                    .filter { $0.matchesTaskSearch(query) }
                    .map { TaskSearchItem(service: service, instance: nil, kind: .bazarr($0)) }
                return items.isEmpty ? [] : [TaskSearchSection(title: "\(title) Scheduled", items: items)]
            }

            let scheduled = vm.scheduledTasks(for: instance.id)
                .filter { $0.matchesTaskSearch(query) }
                .map { TaskSearchItem(service: service, instance: instance, kind: .scheduled($0)) }
            let queue = vm.commandQueue(for: instance.id)
                .filter { $0.matchesTaskSearch(query) }
                .map { TaskSearchItem(service: service, instance: instance, kind: .queue($0)) }

            var sections: [TaskSearchSection] = []
            if !scheduled.isEmpty {
                sections.append(TaskSearchSection(title: "\(title) Scheduled", items: scheduled))
            }
            if !queue.isEmpty {
                sections.append(TaskSearchSection(title: "\(title) Queue", items: queue))
            }
            return sections
        }
    }

    // MARK: - Load & Trigger

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
        await vm.load(instance: instance.id, client: client)
    }

    @MainActor
    private func triggerArrTask(_ task: ArrScheduledTask) async {
        guard let instance = selectedInstance else { return }
        await triggerArrTask(task, on: instance)
    }

    /// Runs the task on the server whose list it came from. "Refresh Series" on
    /// the HD box does nothing for the 4K one, so sending it to the wrong server
    /// looks like it worked and changes nothing the user was looking at.
    @MainActor
    private func triggerArrTask(_ task: ArrScheduledTask, on instance: ArrInstanceRef) async {
        guard instance.serviceType != .bazarr,
              let client = serviceManager.sharedClient(for: instance) else { return }
        await vm.triggerTask(task, instance: instance.id, client: client)
        await loadService(instance)
    }

    @MainActor
    private func triggerBazarrTask(_ task: BazarrTask) async {
        guard let client = serviceManager.activeBazarrEntry?.client else { return }
        await vm.triggerBazarrTask(task, client: client)
        if let bazarr = serviceManager.refs(for: .bazarr).first {
            await loadService(bazarr)
        }
    }
}

private struct TaskSearchSection: Identifiable {
    let title: String
    let items: [TaskSearchItem]

    var id: String { title }
}

private struct TaskSearchItem: Identifiable {
    let service: ArrServiceType
    /// The server the task belongs to, so a search hit can be run on the right
    /// one. `nil` for Bazarr, which has no Arr pair.
    let instance: ArrInstanceRef?
    let kind: TaskSearchItemKind

    var id: String {
        "\(instance?.id.uuidString ?? service.rawValue)-\(kind.id)"
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
            mutate(ArrInstanceRef.preview(service).id) {
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
            mutate(ArrInstanceRef.preview(service).id) { $0.isLoading = true; $0.errorMessage = nil }
        }
        if services.contains(.bazarr) {
            bazarr.isLoading = true
            bazarr.errorMessage = nil
        }
    }

    func setPreviewError(_ error: String, for services: [ArrServiceType]) {
        for service in services where service != .bazarr {
            mutate(ArrInstanceRef.preview(service).id) { $0.isLoading = false; $0.errorMessage = error }
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

    // Keyed by server: both halves of a pair run their own schedule and their own
    // command queue, and a refresh in flight on one says nothing about the other.
    private var arrStates: [UUID: ArrState] = [:]
    private var bazarr = BazarrState()

    func scheduledTasks(for instance: UUID) -> [ArrScheduledTask] {
        arrStates[instance]?.scheduledTasks ?? []
    }

    func commandQueue(for instance: UUID) -> [ArrCommand] {
        arrStates[instance]?.commandQueue ?? []
    }

    var bazarrTasks: [BazarrTask] { bazarr.tasks }
    var isBazarrLoading: Bool { bazarr.isLoading }
    var bazarrErrorMessage: String? { bazarr.errorMessage }

    func isLoading(for instance: UUID) -> Bool {
        arrStates[instance]?.isLoading ?? false
    }

    func errorMessage(for instance: UUID) -> String? {
        arrStates[instance]?.errorMessage
    }

    func load(instance: UUID, client: any SharedArrClient) async {
        mutate(instance) { $0.isLoading = true; $0.errorMessage = nil }
        do {
            async let tasks = client.getScheduledTasks()
            async let queue = client.getCommandQueue()
            let sorted = (try await tasks).sorted { ($0.name ?? "") < ($1.name ?? "") }
            let trimmed = (try await queue)
                .sorted { ($0.queued ?? "") > ($1.queued ?? "") }
                .prefix(20)
                .map { $0 }
            mutate(instance) {
                $0.scheduledTasks = sorted
                $0.commandQueue = trimmed
                $0.isLoading = false
            }
        } catch {
            mutate(instance) { $0.errorMessage = error.localizedDescription; $0.isLoading = false }
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

    func triggerTask(_ task: ArrScheduledTask, instance: UUID, client: any SharedArrClient) async {
        guard let taskName = task.taskName else { return }
        do {
            _ = try await client.postCommand(name: taskName)
            try? await Task.sleep(for: .seconds(1))
        } catch {
            mutate(instance) { $0.errorMessage = error.localizedDescription }
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

    private func mutate(_ instance: UUID, _ modify: (inout ArrState) -> Void) {
        var state = arrStates[instance] ?? ArrState()
        modify(&state)
        arrStates[instance] = state
    }
}
