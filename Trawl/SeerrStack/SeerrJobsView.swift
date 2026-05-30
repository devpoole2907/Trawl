import SwiftUI

struct SeerrJobsView: View {
    let apiClient: SeerrAPIClient

    @State private var jobs: [SeerrJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pollingTask: Task<Void, Never>?
    #if DEBUG
    private var isPreview = false
    #endif

    init(apiClient: SeerrAPIClient) {
        self.apiClient = apiClient
    }

    var body: some View {
        List {
            if let error = errorMessage, jobs.isEmpty {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoading && jobs.isEmpty {
                Section {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } else if jobs.isEmpty {
                ContentUnavailableView(
                    "No Jobs",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("No scheduled jobs were returned by Seerr.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(jobs) { job in
                        SeerrJobRow(job: job) {
                            await trigger(job)
                        } onCancel: {
                            await cancel(job)
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
        .navigationTitle("Seerr Jobs")
        .refreshable { await load() }
        .task {
            #if DEBUG
            if isPreview { return }
            #endif
            await load()
            startPolling()
        }
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            jobs = try await apiClient.getJobs()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if let updated = try? await apiClient.getJobs() {
                    jobs = updated
                }
            }
        }
    }

    private func trigger(_ job: SeerrJob) async {
        try? await apiClient.runJob(id: job.id)
        try? await Task.sleep(for: .seconds(1))
        await load()
    }

    private func cancel(_ job: SeerrJob) async {
        try? await apiClient.cancelJob(id: job.id)
        try? await Task.sleep(for: .seconds(1))
        await load()
    }
}

#if DEBUG
extension SeerrJobsView {
    init(
        apiClient: SeerrAPIClient = .preview(),
        previewJobs: [SeerrJob],
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) {
        self.apiClient = apiClient
        self._jobs = State(initialValue: previewJobs)
        self._isLoading = State(initialValue: isLoading)
        self._errorMessage = State(initialValue: errorMessage)
        self.isPreview = true
    }
}

#Preview("Seerr Jobs - Loaded") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrJobsView(previewJobs: SeerrJob.previewList)
        }
    }
}

#Preview("Seerr Jobs - Empty") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connected)) {
        NavigationStack {
            SeerrJobsView(previewJobs: [])
        }
    }
}

#Preview("Seerr Jobs - Loading") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.connecting)) {
        NavigationStack {
            SeerrJobsView(previewJobs: [], isLoading: true)
        }
    }
}

#Preview("Seerr Jobs - Error") {
    PreviewHost(profiles: .seerrOnly, seerr: .preview(.error("Unable to load jobs."))) {
        NavigationStack {
            SeerrJobsView(
                previewJobs: [],
                errorMessage: "Scheduled jobs endpoint returned 503."
            )
        }
    }
}
#endif

// MARK: - Row

private struct SeerrJobRow: View {
    let job: SeerrJob
    let onRun: () async -> Void
    let onCancel: () async -> Void

    var body: some View {
        ScheduledTaskControlRow(item: job, action: jobAction)
    }

    private var jobAction: ScheduledTaskRowAction {
        ScheduledTaskRowAction.runOrStopTask(
            title: job.scheduledTaskRowTitle,
            isRunning: job.running == true,
            stopVerb: "Cancel"
        ) {
            await onRun()
        } stop: {
            await onCancel()
        }
    }
}

extension SeerrJob: ScheduledTaskRowRepresentable {
    var scheduledTaskRowTitle: String {
        name ?? id
    }

    var scheduledTaskRowStatus: ScheduledTaskRowStatus {
        .activity(isRunning: running == true)
    }

    var scheduledTaskRowSubtitle: String? {
        guard let type = ScheduledTaskRowFormatter.cleanedText(type), type.lowercased() != "process" else { return nil }
        return type.capitalized
    }

    var scheduledTaskRowDetails: [ScheduledTaskRowDetail] {
        [
            ScheduledTaskRowFormatter.cadenceText(from: interval).map { ScheduledTaskRowDetail.interval($0) },
            nextExecutionDetail
        ].compactMap { $0 }
    }

    private var nextExecutionDetail: ScheduledTaskRowDetail? {
        ScheduledTaskRowDetail.nextRun(from: nextExecutionTime)
    }
}
