import SwiftUI

struct SeerrJobsView: View {
    let apiClient: SeerrAPIClient

    @State private var jobs: [SeerrJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pollingTask: Task<Void, Never>?

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

// MARK: - Row

private struct SeerrJobRow: View {
    let job: SeerrJob
    let onRun: () async -> Void
    let onCancel: () async -> Void
    @State private var isActioning = false

    var body: some View {
        ScheduledTaskRowView(
            icon: job.running == true ? "clock.arrow.2.circlepath" : "clock",
            iconColor: job.running == true ? .green : .secondary,
            title: job.name ?? job.id,
            badge: job.running == true ? ScheduledTaskRowBadge("RUNNING", color: .green) : nil,
            details: jobDetails
        ) {
            if job.running == true {
                Button {
                    Task {
                        isActioning = true
                        await onCancel()
                        isActioning = false
                    }
                } label: {
                    if isActioning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isActioning)
            } else {
                Button {
                    Task {
                        isActioning = true
                        await onRun()
                        isActioning = false
                    }
                } label: {
                    if isActioning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isActioning)
            }
        }
    }

    private var jobDetails: [ScheduledTaskRowDetail] {
        var details: [ScheduledTaskRowDetail] = []

        if let interval = job.interval {
            details.append(ScheduledTaskRowDetail(icon: "clock", text: interval))
        }
        if let next = job.nextExecutionTime {
            details.append(ScheduledTaskRowDetail(icon: "arrow.clockwise", text: relativeDate(next)))
        }

        return details
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
