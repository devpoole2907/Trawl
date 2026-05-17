import SwiftUI

struct ArrScheduledTasksView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var states: [ArrServiceType: TasksViewState] = [:]
    @State private var unavailable: Set<ArrServiceType> = []

    private enum TasksViewState {
        case arr(ArrScheduledTasksViewModel)
        case bazarr(BazarrScheduledTasksViewModel)
    }

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
        if serviceManager.hasBazarrInstance { services.append(.bazarr) }
        return services
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("Add a Sonarr, Radarr, Prowlarr, or Bazarr server in Settings to view tasks.")
                )
            } else if unavailable.contains(selectedService) {
                ContentUnavailableView(
                    "Service Unreachable",
                    systemImage: "network.slash",
                    description: Text("\(selectedService.displayName) is configured but currently unreachable.")
                )
            } else {
                switch states[selectedService] {
                case .arr(let vm):
                    arrTaskContent(vm)
                        .id(selectedService)
                        .transition(.opacity)
                case .bazarr(let vm):
                    bazarrTaskContent(vm)
                        .id(selectedService)
                        .transition(.opacity)
                case nil:
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
        }
        .animation(.default, value: selectedService)
        .navigationTitle("Tasks")
        .moreDestinationBackground(.mediaManagement)
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
        .loadServicesPeriodically(availableServices) { service in
            await loadService(service)
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    // MARK: - Load

    @MainActor
    private func loadService(_ service: ArrServiceType) async {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else { unavailable.insert(service); return }
            await cachedArrVM(for: service, client: client).load()
        case .radarr:
            guard let client = serviceManager.radarrClient else { unavailable.insert(service); return }
            await cachedArrVM(for: service, client: client).load()
        case .prowlarr:
            guard let client = serviceManager.prowlarrClient else { unavailable.insert(service); return }
            await cachedArrVM(for: service, client: client).load()
        case .bazarr:
            guard let client = serviceManager.activeBazarrEntry?.client else { unavailable.insert(service); return }
            let vm: BazarrScheduledTasksViewModel
            if case .bazarr(let existing) = states[service] {
                vm = existing
            } else {
                vm = BazarrScheduledTasksViewModel(client: client)
                withAnimation { states[service] = .bazarr(vm) }
            }
            await vm.load()
        }
    }

    @MainActor
    private func cachedArrVM(for service: ArrServiceType, client: any SharedArrClient) -> ArrScheduledTasksViewModel {
        if case .arr(let existing) = states[service] { return existing }
        let vm = ArrScheduledTasksViewModel(client: client)
        withAnimation { states[service] = .arr(vm) }
        return vm
    }

    @ViewBuilder
    private func arrTaskContent(_ vm: ArrScheduledTasksViewModel) -> some View {
        List {
            if let error = vm.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if vm.isLoading && vm.scheduledTasks.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else {
                if !vm.scheduledTasks.isEmpty {
                    Section("Scheduled") {
                        ForEach(vm.scheduledTasks) { task in
                            ArrScheduledTaskRow(task: task) {
                                await vm.triggerTask(task)
                            }
                        }
                    }
                }

                if !vm.commandQueue.isEmpty {
                    Section("Queue") {
                        ForEach(vm.commandQueue) { command in
                            ArrCommandQueueRow(command: command)
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
        .refreshable { await vm.load() }
    }

    @ViewBuilder
    private func bazarrTaskContent(_ vm: BazarrScheduledTasksViewModel) -> some View {
        List {
            if let error = vm.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if vm.isLoading && vm.tasks.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else if !vm.tasks.isEmpty {
                Section("Scheduled") {
                    ForEach(vm.tasks) { task in
                        BazarrTaskRow(task: task) {
                            await vm.runTask(task)
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
        .refreshable { await vm.load() }
    }
}

// MARK: - Arr Scheduled Task Row

private struct ArrScheduledTaskRow: View {
    let task: ArrScheduledTask
    let onTrigger: () async -> Void
    @State private var isTriggering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name ?? "Unknown Task")
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                HStack(spacing: 12) {
                    if let interval = task.interval {
                        label("clock", text: intervalText(interval))
                    }
                    if let last = task.lastExecution {
                        label("arrow.counterclockwise", text: relativeDate(last))
                    }
                }

                if let next = task.nextExecution {
                    label("arrow.clockwise", text: "Next: \(relativeDate(next))")
                        .foregroundStyle(.secondary)
                }

                if let duration = task.lastDuration, duration != "00:00:00" {
                    label("timer", text: duration)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

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
        .padding(.vertical, 2)
    }

    private func label(_ icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if task.jobRunning {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .symbolEffect(.rotate)
                    }
                    Text(task.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }

                if let interval = task.interval {
                    label("clock", text: interval)
                }

                if let nextRunIn = task.nextRunIn {
                    label("arrow.clockwise", text: "Next: \(nextRunIn)")
                }
            }

            Spacer(minLength: 8)

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
        .padding(.vertical, 2)
    }

    private func label(_ icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Command Queue Row

private struct ArrCommandQueueRow: View {
    let command: ArrCommand

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(command.commandName ?? command.name ?? "Command")
                    .font(.subheadline)

                if let queued = command.queued {
                    Text(relativeDate(queued))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let status = command.status {
                Text(status.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.vertical, 2)
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

// MARK: - Arr Tasks ViewModel

@MainActor
@Observable
final class ArrScheduledTasksViewModel {
    private(set) var scheduledTasks: [ArrScheduledTask] = []
    private(set) var commandQueue: [ArrCommand] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let client: any SharedArrClient

    init(client: any SharedArrClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let tasks = client.getScheduledTasks()
            async let queue = client.getCommandQueue()
            scheduledTasks = (try await tasks).sorted { ($0.name ?? "") < ($1.name ?? "") }
            commandQueue = (try await queue)
                .sorted { ($0.queued ?? "") > ($1.queued ?? "") }
                .prefix(20)
                .map { $0 }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func triggerTask(_ task: ArrScheduledTask) async {
        guard let taskName = task.taskName else { return }
        do {
            _ = try await client.postCommand(name: taskName)
            try? await Task.sleep(for: .seconds(1))
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Bazarr Tasks ViewModel

@MainActor
@Observable
final class BazarrScheduledTasksViewModel {
    private(set) var tasks: [BazarrTask] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let client: BazarrAPIClient

    init(client: BazarrAPIClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            tasks = (try await client.getTasks()).sorted { $0.name < $1.name }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func runTask(_ task: BazarrTask) async {
        do {
            try await client.runTask(taskId: task.jobId)
            try? await Task.sleep(for: .seconds(1))
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
