import SwiftUI

// MARK: - View

struct JellyfinScheduledTasksView: View {
    let apiClient: JellyfinAPIClient

    @State private var viewModel: JellyfinScheduledTasksViewModel?
    @State private var errorAlert: ErrorAlertItem?
    @State private var taskPendingStop: JellyfinScheduledTask?

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
        .task {
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
        .background(MoreDestinationGradientBackground(accent: .seerr))
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

    @ViewBuilder
    private func taskRow(_ task: JellyfinScheduledTask, viewModel: JellyfinScheduledTasksViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.isRunning ? "clock.arrow.2.circlepath" : "clock")
                .font(.title3)
                .foregroundStyle(task.isRunning ? .green : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    taskStateBadge(task)
                }

                if let description = task.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if task.isRunning, let progress = task.currentProgressPercentage {
                    ProgressView(value: progress, total: 100)
                        .tint(.green)
                }

                if let result = task.lastExecutionResult {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(result.isSuccess ? .green : .red)
                            .frame(width: 6, height: 6)
                        Text(result.statusBadge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(result.isSuccess ? .green : .red)

                        if let start = result.startTimeUtc, let end = result.endTimeUtc {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text(durationText(start: start, end: end))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer()

            if task.isRunning || task.isCancelling {
                Button {
                    taskPendingStop = task
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await viewModel.startTask(id: task.id) }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func taskStateBadge(_ task: JellyfinScheduledTask) -> some View {
        Text(task.stateBadge)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateColor(task.state).opacity(0.15), in: Capsule())
            .foregroundStyle(stateColor(task.state))
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "Running": .green
        case "Cancelling": .orange
        default: .secondary
        }
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
