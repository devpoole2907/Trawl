import SwiftUI

struct ArrScheduledTasksView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var vm = ArrTasksViewModel()
    @State private var selectedService: ArrServiceType = .sonarr
    @State private var showSettings = false

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
        .navigationSubtitle(selectedService.displayName)
        .moreDestinationBackground(.tasks)
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Service",
                selection: Binding(
                    get: { selectedService },
                    set: { newService in withAnimation { selectedService = newService } }
                ),
                items: availableServices.map(\.segmentBarItem),
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
            if let error = currentError {
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
        switch selectedService {
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
        await loadService(selectedService)
    }

    @MainActor
    private func triggerBazarrTask(_ task: BazarrTask) async {
        guard let client = serviceManager.activeBazarrEntry?.client else { return }
        await vm.triggerBazarrTask(task, client: client)
        await loadService(.bazarr)
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
    @State private var isTriggering = false

    var body: some View {
        ScheduledTaskRowView(
            title: task.name ?? "Unknown Task",
            details: taskDetails
        ) {
            Button {
                Task {
                    isTriggering = true
                    await onTrigger()
                    isTriggering = false
                }
            } label: {
                if isTriggering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isTriggering)
        }
    }

    private var taskDetails: [ScheduledTaskRowDetail] {
        var details: [ScheduledTaskRowDetail] = []

        if let interval = task.interval {
            details.append(ScheduledTaskRowDetail(icon: "clock", text: intervalText(interval)))
        }
        if let last = task.lastExecution {
            details.append(ScheduledTaskRowDetail(icon: "arrow.counterclockwise", text: relativeDate(last)))
        }
        if let next = task.nextExecution {
            details.append(ScheduledTaskRowDetail(icon: "arrow.clockwise", text: "Next: \(relativeDate(next))"))
        }
        if let duration = task.lastDuration, duration != "00:00:00" {
            details.append(ScheduledTaskRowDetail(icon: "timer", text: duration))
        }

        return details
    }

    private func intervalText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private func relativeDate(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date.formatted(.relative(presentation: .named)) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date.formatted(.relative(presentation: .named)) }
        return raw
    }
}

// MARK: - Bazarr Task Row

private struct BazarrTaskRow: View {
    let task: BazarrTask
    let onTrigger: () async -> Void
    @State private var isTriggering = false

    var body: some View {
        ScheduledTaskRowView(
            icon: task.jobRunning ? "arrow.triangle.2.circlepath" : "clock",
            iconColor: task.jobRunning ? .blue : .secondary,
            title: task.name,
            badge: task.jobRunning ? ScheduledTaskRowBadge("RUNNING", color: .blue) : nil,
            details: taskDetails
        ) {
            Button {
                Task {
                    isTriggering = true
                    await onTrigger()
                    isTriggering = false
                }
            } label: {
                if isTriggering {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isTriggering || task.jobRunning)
        }
    }

    private var taskDetails: [ScheduledTaskRowDetail] {
        var details: [ScheduledTaskRowDetail] = []

        if let interval = task.interval {
            details.append(ScheduledTaskRowDetail(icon: "clock", text: interval))
        }
        if let nextRunIn = task.nextRunIn {
            details.append(ScheduledTaskRowDetail(icon: "arrow.clockwise", text: "Next: \(nextRunIn)"))
        }

        return details
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
        guard let queued = command.queued else { return [] }
        return [ScheduledTaskRowDetail(icon: "clock", text: relativeDate(queued))]
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

    private func relativeDate(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date.formatted(.relative(presentation: .named)) }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date.formatted(.relative(presentation: .named)) }
        return raw
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
