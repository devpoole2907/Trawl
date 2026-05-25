import SwiftUI

// MARK: - View

struct JellyfinScheduledTasksView: View {
    let apiClient: JellyfinAPIClient

    @State private var viewModel: JellyfinScheduledTasksViewModel?
    @State private var errorAlert: ErrorAlertItem?
    @State private var taskPendingStop: JellyfinScheduledTask?
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        Group {
            if let viewModel {
                tasksContent(viewModel)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Scheduled Tasks")
        .navigationSubtitle("Jellyfin")
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            let vm = JellyfinScheduledTasksViewModel(apiClient: apiClient)
            viewModel = vm
            await vm.startPolling()
        }
        .onDisappear {
            viewModel?.stopPolling()
        }
        .errorAlert(item: $errorAlert)
        .onChange(of: viewModel?.errorMessage) { _, message in
            guard let message else { return }
            errorAlert = ErrorAlertItem(title: "Task Action Failed", message: message)
            viewModel?.clearError()
        }
    }

    @ViewBuilder
    private func tasksContent(_ viewModel: JellyfinScheduledTasksViewModel) -> some View {
        List {
            if let error = viewModel.errorMessage, viewModel.tasks.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isLoading && viewModel.tasks.isEmpty {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else if viewModel.tasks.isEmpty {
                ContentUnavailableView(
                    "No Scheduled Tasks",
                    systemImage: "clock.badge.questionmark",
                    description: Text("No scheduled tasks were returned by Jellyfin.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(groupedCategories, id: \.key) { category, tasks in
                    Section(category.isEmpty ? "General" : category) {
                        ForEach(tasks) { task in
                            taskRow(task, viewModel: viewModel)
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
        .background(MoreDestinationGradientBackground(accent: .jellyfin))
        .refreshable {
            await viewModel.refresh()
        }
        .alert("Stop Scheduled Task?", isPresented: stopTaskAlertPresented) {
            Button("Cancel", role: .cancel) {
                taskPendingStop = nil
            }
            Button("Stop", role: .destructive) {
                if let task = taskPendingStop {
                    Task { await viewModel.stopTask(id: task.id) }
                }
                taskPendingStop = nil
            }
        } message: {
            if let task = taskPendingStop {
                Text("This asks Jellyfin to stop \(task.name).")
            }
        }
    }

    private func taskRow(_ task: JellyfinScheduledTask, viewModel: JellyfinScheduledTasksViewModel) -> some View {
        ScheduledTaskRowView(
            status: taskStatus(task),
            title: task.name,
            subtitle: task.description,
            progress: task.isRunning ? task.currentProgressPercentage : nil,
            result: taskResult(task.lastExecutionResult),
            action: taskAction(task, viewModel: viewModel)
        )
    }

    private func taskAction(
        _ task: JellyfinScheduledTask,
        viewModel: JellyfinScheduledTasksViewModel
    ) -> ScheduledTaskRowAction {
        if task.isRunning || task.isCancelling {
            ScheduledTaskRowAction.stop(
                accessibilityLabel: "Stop \(task.name)"
            ) {
                taskPendingStop = task
            }
        } else {
            ScheduledTaskRowAction.run(
                accessibilityLabel: "Run \(task.name)"
            ) {
                await viewModel.startTask(id: task.id)
            }
        }
    }

    private func taskStatus(_ task: JellyfinScheduledTask) -> ScheduledTaskRowStatus {
        if task.isRunning { return .running }
        if task.isCancelling { return .cancelling }
        return .idle
    }

    private func taskResult(_ result: JellyfinScheduledTaskResult?) -> ScheduledTaskRowResult? {
        guard let result else { return nil }

        var detail: String?
        if let start = result.startTimeUtc, let end = result.endTimeUtc {
            detail = durationText(start: start, end: end)
        }

        return ScheduledTaskRowResult(
            title: result.statusBadge,
            detail: detail,
            color: result.isSuccess ? .green : .red
        )
    }

    private var groupedCategories: [(key: String, value: [JellyfinScheduledTask])] {
        guard let viewModel else { return [] }
        let grouped = Dictionary(grouping: viewModel.tasks) { $0.category ?? "" }
        return grouped.sorted { $0.key < $1.key }
    }

    private func durationText(start: String, end: String) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parse = { (raw: String) -> Date? in
            isoFormatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }
        guard let startDate = parse(start), let endDate = parse(end) else { return "" }
        let interval = endDate.timeIntervalSince(startDate)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else {
            return "\(Int(interval / 3600))h \(Int(interval.truncatingRemainder(dividingBy: 3600) / 60))m"
        }
    }

    private var stopTaskAlertPresented: Binding<Bool> {
        Binding(
            get: { taskPendingStop != nil },
            set: { if !$0 { taskPendingStop = nil } }
        )
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class JellyfinScheduledTasksViewModel {
    private(set) var tasks: [JellyfinScheduledTask] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let apiClient: JellyfinAPIClient
    private var pollingTask: Task<Void, Never>?

    init(apiClient: JellyfinAPIClient) {
        self.apiClient = apiClient
    }

    func startPolling() async {
        await loadTasks()
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await loadTasks(showLoading: false)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() async {
        await loadTasks(showLoading: false)
    }

    private func loadTasks(showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        errorMessage = nil

        do {
            tasks = try await apiClient.getScheduledTasks()
        } catch {
            errorMessage = error.localizedDescription
        }

        if showLoading { isLoading = false }
    }

    func startTask(id: String) async {
        do {
            try await apiClient.startScheduledTask(id: id)
            await loadTasks(showLoading: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopTask(id: String) async {
        do {
            try await apiClient.stopScheduledTask(id: id)
            await loadTasks(showLoading: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }
}

#if DEBUG
extension JellyfinScheduledTasksView {
    init(
        apiClient: JellyfinAPIClient = .preview(),
        previewViewModel: JellyfinScheduledTasksViewModel
    ) {
        self.apiClient = apiClient
        self._viewModel = State(initialValue: previewViewModel)
        self.isPreview = true
    }
}

extension JellyfinScheduledTasksViewModel {
    convenience init(
        previewTasks: [JellyfinScheduledTask],
        isLoading: Bool = false,
        errorMessage: String? = nil,
        apiClient: JellyfinAPIClient = .preview()
    ) {
        self.init(apiClient: apiClient)
        self.tasks = previewTasks
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }
}

#Preview("Jellyfin Tasks - Loaded") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinScheduledTasksView(
                previewViewModel: JellyfinScheduledTasksViewModel(previewTasks: JellyfinScheduledTask.previewList)
            )
        }
    }
}

#Preview("Jellyfin Tasks - Empty") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connected)) {
        NavigationStack {
            JellyfinScheduledTasksView(
                previewViewModel: JellyfinScheduledTasksViewModel(previewTasks: [])
            )
        }
    }
}

#Preview("Jellyfin Tasks - Loading") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.connecting)) {
        NavigationStack {
            JellyfinScheduledTasksView(
                previewViewModel: JellyfinScheduledTasksViewModel(previewTasks: [], isLoading: true)
            )
        }
    }
}

#Preview("Jellyfin Tasks - Error") {
    PreviewHost(profiles: .jellyfinOnly, jellyfin: .preview(.error("Unable to load tasks."))) {
        NavigationStack {
            JellyfinScheduledTasksView(
                previewViewModel: JellyfinScheduledTasksViewModel(
                    previewTasks: [],
                    errorMessage: "Task scheduler endpoint timed out."
                )
            )
        }
    }
}
#endif
